# GPU disconnect watchdog: auto-reboots the host on NVIDIA Xid 79/154 events
# on either RTX 4090 (BDFs 0000:05:00 and 0000:0b:00). Stopgap mitigation
# while the hardware remediation in docs/design/gpu1-remediation-2026-05-24.md
# is pending. Designed to be ripped out once the cable swap restores
# multi-day MTBF.
#
# Design doc: docs/design/gpu-watchdog-2026-05-24.md
#
# Two cooperating services in this module:
#
#   gpu-watchdog.service             — runs always, tails the kernel journal,
#                                       reboots on Xid 79/154. Before the
#                                       reboot it writes a "pending-boot"
#                                       marker so the next boot can be
#                                       attributed to this watchdog.
#
#   gpu-watchdog-boot-notify.service — runs once at boot after the network
#                                       is up. If the marker is present,
#                                       sends a "back online" Telegram
#                                       message with the post-boot GPU state
#                                       and resume-scheduling status, then
#                                       deletes the marker.
#
# Why systemctl reboot --force (and not the polite version):
#   run_train_loop_resumable.sh installs a SIGTERM trap that clears
#   ~/.local/state/nsl2/active-run on graceful exit. A normal reboot would
#   propagate SIGTERM through the user manager → clear the state file →
#   defeat nsl2-resume.service on next boot. --force SIGKILLs everything
#   without the TERM cycle, so the state file survives and the run resumes.
#   Docker is stopped explicitly *before* --force so containers still get a
#   polite SIGTERM and a chance to flush.
#
# Recovery mode (services.gpuWatchdog.coldCycle.enable):
#   Default recovery is a warm `systemctl reboot --force`. But on this host an
#   Xid 79 frequently wedges GPU1 so badly that a warm reboot brings it back
#   *un-enumerated* — the kernel logs "0000:00:03.1: broken device, retraining
#   failed" at the next boot, and 00:03.1 is exactly GPU1's PCIe root port.
#   Setting coldCycle.enable = true switches recovery to a true power cycle:
#   arm an RTC wake alarm (rtcwake -m no), then `systemctl poweroff --force`;
#   the board powers itself back on when the alarm fires, fully de-energizing
#   the GPU power domain in between. REQUIRES BIOS "Resume by Alarm"/RTC-wake
#   to be enabled and verified out-of-band first — otherwise the box powers off
#   and STAYS off. Safety rails (docs/design/gpu1-auto-recovery-2026-06-11.md):
#     - verify-before-destroy: the alarm is armed and read back (nonzero AND in
#       the future) BEFORE Docker is stopped; if it can't be armed the watchdog
#       does NOT power off.
#     - onArmFailure (default "hold"): on a failed arm, page + park in HOLD
#       (never strand the box, don't kill the fleet for a recovery that can't
#       happen); set "reboot" to fall back to a warm reboot instead.
#     - boot-loop guard (maxCyclesPerWindow / windowMinutes): cap power cycles
#       per window; on trip, AUTO degrades to HOLD and pages you.
#
# Telegram control (services.gpuWatchdog.telegramControl.enable):
#   A side loop lets you flip the recovery mode from chat. Modes live in
#   /var/lib/gpu-watchdog/mode:
#     auto (default) — reset immediately on a drop (good when you're away)
#     hold           — do NOT reset; notify and wait until you release it
#   Commands (admin): /auto /hold /recover /sbr /status; /help and /id are open
#   (/id prints your chat id for adminChatIds setup). Most commands only WRITE a
#   mode/recover/cancel file — gpu-watchdog does the privileged reset. The one
#   exception is /sbr, which does an in-place PCIe bus reset of GPU1 (no reboot,
#   isolated to GPU1's bridge 00:03.1) as a recovery attempt; on success it
#   drops a cancel file so a pending hold stands down without a reset. Empty
#   adminChatIds ⇒ inert. When enabled it becomes the getUpdates consumer, so
#   telegram-notify's discovery timer is force-disabled (shared update offset).
#
# Companion: services.telegramNotify (modules/common/telegram-notify.nix)
#   provides the `telegram-notify` CLI used by both services. The watchdog
#   will still reboot if telegram-notify is missing — the notification is
#   best-effort. The boot-notify service retries on failure (network may
#   come up after the unit first tries).
#
# Manual kill-switches:
#   systemctl stop gpu-watchdog            # disable until next boot
#   systemctl disable gpu-watchdog         # disable across reboots
#   systemctl set-environment GPU_WATCHDOG_DRYRUN=1 \
#     && systemctl restart gpu-watchdog    # log-only mode (no actual reboot)
{ config, lib, pkgs, ... }:
let
  cfg = config.services.gpuWatchdog;

  # Shared paths. Marker file is shell-sourceable (KEY=VALUE per line).
  stateDir = "/var/lib/gpu-watchdog";
  markerFile = "${stateDir}/pending-boot";
  rebootLog = "${stateDir}/reboot-log";
  # Recovery-mode toggle file (auto|hold) + one-shot recover trigger, written
  # by the Telegram control loop (or by hand), read by the watchdog.
  modeFile = "${stateDir}/mode";
  recoverNowFile = "${stateDir}/recover-now";
  # One-shot "stand down" signal: a successful /sbr drops this so the watchdog
  # aborts a pending hold-wait without resetting.
  cancelFile = "${stateDir}/cancel";

  # Recovery wording surfaced into the Telegram message, and how long to stay
  # powered off before the RTC alarm wakes us in cold-cycle mode. See the
  # coldCycle option and the header note for rationale.
  wakeSecs = toString cfg.coldCycle.wakeSeconds;
  recoveryVerb =
    if !cfg.coldCycle.enable then "Rebooting in ~30s."
    else if cfg.coldCycle.method == "external"
    then "Powering off in ~30s — an external controller will cold-cycle the box back on."
    else "Powering off in ~30s — the RTC alarm will cold-cycle the box back on in ~${wakeSecs}s.";

  watchdogScript = pkgs.writeShellScript "gpu-watchdog" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.gnugrep pkgs.coreutils pkgs.util-linux ]}:/run/current-system/sw/bin

    LOG=${rebootLog}
    MARKER=${markerFile}
    MODE_FILE=${modeFile}
    RECOVER_FILE=${recoverNowFile}
    CANCEL_FILE=${cancelFile}
    # Boot-loop guard state (persists across reboots): "count first_epoch".
    CYCLE_FILE=${stateDir}/cycle-count
    MAXCYC=${toString cfg.coldCycle.maxCyclesPerWindow}
    WINDOW_MIN=${toString cfg.coldCycle.windowMinutes}
    mkdir -p ${stateDir}

    # Map PCI BDF → human-readable card label. Canonical assignment per
    # docs/design/gpu-disconnect-2026-05-07.md and host memory:
    #   0000:05:00.0 = GPU0 (chipset-routed, lower slot)
    #   0000:0b:00.0 = GPU1 (CPU-direct, top slot)
    bdf_to_label() {
      case "$1" in
        05:00) echo "GPU0 (PCI:0000:05:00.0, chipset slot)" ;;
        0b:00) echo "GPU1 (PCI:0000:0b:00.0, CPU-direct slot)" ;;
        *)     echo "unknown ($1)" ;;
      esac
    }

    # `-n 0` starts following from the live tail, so we never re-fire on a
    # ghost Xid from a previous boot still in the journal.
    journalctl -k -f -n 0 -o cat \
      | grep --line-buffered -E 'NVRM: Xid \(PCI:0000:(05|0b):00\):? (79|154)' \
      | while IFS= read -r line; do
          ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          echo "$ts $line" >> "$LOG"

          # Extract "05:00" or "0b:00" from the Xid line.
          bdf=$(echo "$line" | grep -oE 'PCI:0000:(05|0b):00' | head -n1 | sed 's/^PCI:0000://')
          xid=$(echo "$line" | grep -oE 'Xid \(PCI:0000:(05|0b):00\):? [0-9]+' | grep -oE '[0-9]+$')
          card=$(bdf_to_label "$bdf")

          recent=$(tail -n 5 "$LOG")

          # Read the recovery mode (auto|hold) and clear stale recover/cancel
          # triggers. Mode is set via the Telegram control loop (/auto /hold
          # /recover /sbr) or by writing $MODE_FILE directly. Default: auto.
          rm -f "$RECOVER_FILE" "$CANCEL_FILE"
          mode=$(tr -dc 'a-z' < "$MODE_FILE" 2>/dev/null || true)
          [[ -z "$mode" ]] && mode=auto

          # Boot-loop guard: if we've already committed $MAXCYC auto recoveries
          # within the last $WINDOW_MIN minutes, stop auto-cycling and park in
          # HOLD — a power-cycle boot-loop is worse than a degraded GPU. The
          # counter ($CYCLE_FILE) is bumped at each commit and persists across
          # reboots; it self-resets once a window passes with no new commit.
          now_epoch=$(date +%s)
          gc=0; gf=0; read -r gc gf < "$CYCLE_FILE" 2>/dev/null || true
          [[ "$gc" =~ ^[0-9]+$ ]] || gc=0
          [[ "$gf" =~ ^[0-9]+$ ]] || gf=0
          guard_note=""
          if [[ "$mode" == "auto" && "$gf" -gt 0 \
                && $((now_epoch - gf)) -le $((WINDOW_MIN * 60)) \
                && "$gc" -ge "$MAXCYC" ]]; then
            mode=hold
            guard_note="⚠ BOOT-LOOP GUARD: $gc recoveries within ~''${WINDOW_MIN}min — auto-recovery PAUSED, holding instead of power-cycling. GPU1 likely needs hands-on / external recovery. "
          fi

          if [[ "$mode" == "hold" ]]; then
            action_note="''${guard_note}Mode=HOLD — NOT resetting. Reply /sbr to try recovering GPU1 with no reboot, /recover to reset now (stays in hold), or /auto to reset + go away-mode. /help for all."
          else
            action_note="Mode=AUTO — ${recoveryVerb} (Reply /hold to pause auto-reset; systemctl stop gpu-watchdog also aborts.)"
          fi

          msg="GPU disconnect on limiting-factor at $ts

    Card: $card
    Xid:  ''${xid:-unknown}

    $line

    Recent events:
    $recent

    $action_note
    Hardware watchdog (SP5100 TCO) will force a chipset-level reset if shutdown wedges."

          timeout 10 telegram-notify "$msg" || true &

          # Drop a marker so the post-reboot notifier can attribute the next
          # boot to this event and surface GPU/resume state once we're back.
          # Atomic write via tmp + mv so a crash mid-write leaves no marker.
          # Values are encoded with printf %q so the file is safely sourceable
          # even if a kernel log line contains shell metacharacters.
          tmp_marker="$MARKER.tmp.$$"
          {
            printf 'EVENT_ISO=%q\n' "$ts"
            printf 'BDF=%q\n'       "$bdf"
            printf 'XID=%q\n'       "''${xid:-unknown}"
            printf 'CARD=%q\n'      "$card"
            printf 'LINE=%q\n'      "$line"
          } > "$tmp_marker"
          mv "$tmp_marker" "$MARKER"

          WAKE_SECS=${wakeSecs}

          if [[ "''${GPU_WATCHDOG_DRYRUN:-0}" == "1" ]]; then
            echo "[gpu-watchdog] DRYRUN: mode=$mode; recovery=${if cfg.coldCycle.enable then "cold" else "reboot"}; (hold would wait for /auto or /recover); no action taken" >&2
            exit 0
          fi

          # HOLD: block until released. Exits: the mode is flipped off "hold",
          # or a /recover signal arrives → reset below. A /sbr that brings GPU1
          # back drops $CANCEL_FILE → we stand down and resume watching, with no
          # reset and Docker untouched. No further Xids are processed while we
          # wait; the box stays up on GPU0 with GPU1 dead until you decide.
          # (DRYRUN above never reaches here, so it can't hang a test.)
          if [[ "$mode" == "hold" ]]; then
            while :; do
              sleep 10
              if [[ -e "$CANCEL_FILE" ]]; then
                rm -f "$CANCEL_FILE" "$MARKER"
                echo "[gpu-watchdog] hold cancelled (GPU1 recovered) — resuming watch, no reset" >&2
                continue 2
              fi
              if [[ -e "$RECOVER_FILE" ]]; then rm -f "$RECOVER_FILE"; break; fi
              m=$(tr -dc 'a-z' < "$MODE_FILE" 2>/dev/null || true)
              if [[ -n "$m" && "$m" != "hold" ]]; then mode="$m"; break; fi
            done
          fi

          # ── Committed past the hold-wait. ───────────────────────────────
          # Determine the recovery mechanism. For a cold cycle, VERIFY we can
          # wake the box back up BEFORE doing anything destructive: if the alarm
          # can't be armed we must NOT power off (that would strand the box),
          # and since Docker is still running, holding is clean (fleet intact).
          RECOVERY=${if cfg.coldCycle.enable then "cold" else "reboot"}
          ON_ARM_FAIL=${cfg.coldCycle.onArmFailure}

          if [[ "$RECOVERY" == "cold" ]]; then
            # Verify we can bring the box back BEFORE anything destructive.
            # arm_ok is set by the configured mechanism; if it stays 0 we must
            # NOT power off (that would strand the box) — handled per onArmFailure
            # below, with Docker still up so a hold is clean.
            arm_ok=0
            ${if cfg.coldCycle.method == "external" then ''
            # External controller (e.g. PiKVM ATX). The arm command must verify
            # revivability AND schedule the power-on, then exit 0.
            if ${cfg.coldCycle.externalArmCommand}; then arm_ok=1; fi
            arm_detail="external power-on armed"
            '' else ''
            # RTC wake: arm WITHOUT sleeping (rtcwake -m no), read the alarm back,
            # require a real epoch in the FUTURE before committing.
            echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
            rtcwake -m no -s "$WAKE_SECS" >/dev/null 2>&1 || true
            alarm=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true)
            armed_at=$(date +%s)
            if [[ -n "$alarm" && "$alarm" =~ ^[0-9]+$ && "$alarm" -gt "$armed_at" ]]; then arm_ok=1; fi
            arm_detail="RTC alarm epoch ''${alarm:-none}"
            ''}
            if [[ "$arm_ok" != "1" ]]; then
              echo "[gpu-watchdog] cold-cycle arm FAILED (method=${cfg.coldCycle.method}); refusing to power off" >&2
              if [[ "$ON_ARM_FAIL" == "reboot" ]]; then
                timeout 10 telegram-notify "WARNING limiting-factor: cold-cycle arm failed (${cfg.coldCycle.method}) — falling back to a warm reboot, so GPU1 may not re-enumerate." || true
                RECOVERY=reboot
              else
                timeout 10 telegram-notify "WARNING limiting-factor: cold-cycle arm FAILED (${cfg.coldCycle.method}) — NOT powering off (would strand the box). Staying up, GPU1 degraded; mode set to HOLD. Fix the power controller, then /recover or /auto." || true
                printf 'hold' > "$MODE_FILE"
                rm -f "$MARKER"
                continue
              fi
            fi
          fi

          # Recovery is viable (warm reboot, or cold with a verified armed alarm).
          # Record this commit for the boot-loop guard (window-based reset).
          cnow=$(date +%s); pc=0; pf=0; read -r pc pf < "$CYCLE_FILE" 2>/dev/null || true
          [[ "$pc" =~ ^[0-9]+$ ]] || pc=0
          [[ "$pf" =~ ^[0-9]+$ ]] || pf=0
          if [[ "$pf" -gt 0 && $((cnow - pf)) -le $((WINDOW_MIN * 60)) ]]; then
            pc=$((pc + 1))
          else
            pc=1; pf=$cnow
          fi
          echo "$pc $pf" > "$CYCLE_FILE"

          # Destructive prep: stop Docker (containers get a polite SIGTERM to
          # flush) + ~30s grace — `systemctl stop gpu-watchdog` still aborts here.
          systemctl stop --no-block docker.service || true
          sleep 30
          sync
          sleep 1

          if [[ "$RECOVERY" == "cold" ]]; then
            echo "[gpu-watchdog] cold cycle (method=${cfg.coldCycle.method}, ''${arm_detail:-armed}): systemctl poweroff --force" >&2
            exec systemctl poweroff --force
          fi
          exec systemctl reboot --force
        done
  '';

  # Boot-time notifier. Runs after network-online so telegram-notify can
  # actually reach the API. If no marker, exits silently (a manual reboot
  # is not interesting). If marker present, composes a "back online" message
  # including GPU re-enumeration check + any scheduled nsl2-resume.
  bootNotifyScript = pkgs.writeShellScript "gpu-watchdog-boot-notify" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.gnugrep pkgs.coreutils pkgs.pciutils ]}:/run/current-system/sw/bin

    MARKER=${markerFile}
    LOG=${rebootLog}
    RESUME_STATE=${
      if cfg.resumeStatePath == null then "" else cfg.resumeStatePath
    }

    if [[ ! -f "$MARKER" ]]; then
      # No watchdog-attributed reboot pending. Nothing to do.
      exit 0
    fi

    # Source the marker into this shell. `set +u` so an unexpected missing
    # field doesn't abort before we can complain about it in the message.
    EVENT_ISO=""; BDF=""; XID=""; CARD=""; LINE=""
    # shellcheck disable=SC1090
    source "$MARKER" || true

    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Best-effort "seconds since boot" via /proc/uptime (no procps needed).
    uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "?")

    # GPU re-enumeration check. lspci is the authoritative source: if a card
    # is missing from the PCIe bus, nvidia-smi will also miss it but the
    # exit codes/output are less stable to parse.
    visible_pci=$(lspci -d 10de: 2>/dev/null | grep -E ' VGA | 3D ' | wc -l | tr -d ' ' || echo "?")
    smi_list=$(timeout 5 nvidia-smi -L 2>/dev/null || true)
    visible_smi=$(echo "$smi_list" | grep -c '^GPU ' || true)

    gpu_state_block="GPU state after boot:
      lspci 10de:           $visible_pci device(s)
      nvidia-smi -L count:  $visible_smi"
    if [[ -n "$smi_list" ]]; then
      gpu_state_block="$gpu_state_block
    $(echo "$smi_list" | sed 's/^/      /')"
    fi
    if [[ "$visible_pci" != "2" ]] || [[ "$visible_smi" != "2" ]]; then
      gpu_state_block="$gpu_state_block

    *** WARNING: expected 2 GPUs, see counts above. Physical intervention may be required ***"
    fi

    # Resume status from the active-run state file (if a path was configured
    # and the file exists). This is what nsl2-resume.service consumes; if
    # the file is present at boot, the user unit will re-launch the run.
    #
    # IMPORTANT: do NOT `source` the file — it is user-owned and we run as
    # root. A compromised user account could plant a malicious active-run
    # to escalate to root via the next watchdog reboot. We parse with grep
    # instead; values are only ever used as strings in the message body,
    # never executed.
    extract_kv() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2- || true; }

    resume_block="Resume status: not configured"
    if [[ -n "$RESUME_STATE" ]]; then
      if [[ -f "$RESUME_STATE" ]]; then
        run_id=$(extract_kv RUN_ID       "$RESUME_STATE")
        config_path=$(extract_kv CONFIG_PATH "$RESUME_STATE")
        project_dir=$(extract_kv PROJECT_DIR "$RESUME_STATE")
        started_at=$(extract_kv STARTED_AT  "$RESUME_STATE")
        resume_block="Resume scheduled (nsl2-resume.service will fire):
      run-id:       ''${run_id:-?}
      config:       ''${config_path:-?}
      project_dir:  ''${project_dir:-?}
      started_at:   ''${started_at:-?}"
      else
        resume_block="Resume status: no active-run state file present (nothing to resume)."
      fi
    fi

    recent=$(tail -n 5 "$LOG" 2>/dev/null || echo "(no reboot-log)")

    body="limiting-factor back online at $now_iso (uptime ''${uptime_secs}s)

    Triggered by watchdog event:
      when: ''${EVENT_ISO:-?}
      card: ''${CARD:-?}
      Xid:  ''${XID:-?}
      log:  ''${LINE:-?}

    $gpu_state_block

    $resume_block

    Recent watchdog events:
    $recent"

    # Send. If telegram-notify fails, exit non-zero so systemd retries.
    # We only delete the marker after a successful send so a transient
    # network/API hiccup doesn't lose the notification.
    if timeout 15 telegram-notify "$body"; then
      rm -f "$MARKER"
      echo "[gpu-watchdog-boot-notify] sent and cleared marker" >&2
      exit 0
    else
      echo "[gpu-watchdog-boot-notify] telegram-notify failed; will retry" >&2
      exit 1
    fi
  '';

  # Telegram control loop: lets the operator flip the watchdog's recovery mode
  # from chat. SECURITY: it only ever WRITES the mode/recover files and sends
  # replies — it never execs a reboot or anything else; the privileged action
  # stays in gpu-watchdog itself. Commands are honoured only from adminChatIds
  # (empty ⇒ inert). As the always-on getUpdates consumer it also subsumes
  # telegram-notify's chat discovery.
  adminList = lib.concatStringsSep " " (map toString cfg.telegramControl.adminChatIds);

  # Optional /t3pair command: re-mint + DM a fresh `t3 serve` pairing link via
  # the t3-pair-notify helper (services.t3PairNotify). Restricted to its own
  # single chatId — tighter than adminChatIds, since a pairing link grants
  # code-exec on the agent. Launched as a decoupled transient unit so the 30s
  # re-mint never blocks the getUpdates loop or dies with a control restart.
  t3PairChat = toString cfg.telegramControl.t3Pair.chatId;
  t3PairCase = lib.optionalString cfg.telegramControl.t3Pair.enable ''
    t3pair|pair)
      if [[ "$chat" == "$T3PAIR_CHAT" ]]; then
        send "$chat" "🔄 Re-minting your T3 pairing link — it'll arrive here in ~30s (valid ~5 min)."
        bin=$(command -v t3-pair-notify || true)
        if [[ -n "$bin" ]]; then
          systemd-run --quiet --collect "$bin" --force --to "$T3PAIR_CHAT" \
            || send "$chat" "failed to launch t3-pair-notify"
        else send "$chat" "t3-pair-notify not installed (enable services.t3PairNotify)"; fi
      else send "$chat" "not authorized for /t3pair"; fi ;;
  '';
  t3PairHelpLine = lib.optionalString cfg.telegramControl.t3Pair.enable
    "'/t3pair — DM a fresh t3 serve pairing link (you only)' ";

  controlScript = pkgs.writeShellScript "gpu-watchdog-telegram-control" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.pciutils pkgs.systemd pkgs.gnugrep ]}:/run/current-system/sw/bin

    TOKEN_FILE=/var/lib/telegram-notify/token
    STATE_FILE=/var/lib/telegram-notify/state.json
    MODE_FILE=${modeFile}
    RECOVER_FILE=${recoverNowFile}
    CANCEL_FILE=${cancelFile}
    ADMINS="${adminList}"
    T3PAIR_CHAT="${t3PairChat}"

    is_admin() {
      local c="$1" a
      for a in $ADMINS; do [[ "$a" == "$c" ]] && return 0; done
      return 1
    }
    send() {
      curl -fsS --max-time 8 -X POST "$API/sendMessage" \
        --data-urlencode "chat_id=$1" --data-urlencode "text=$2" >/dev/null 2>&1 || true
    }
    gpu1_alive() {
      timeout 6 nvidia-smi -i 0000:0B:00.0 --query-gpu=name --format=csv,noheader >/dev/null 2>&1
    }
    do_sbr() {
      # Privileged GPU1 recovery: detach both functions, Secondary Bus Reset on
      # the isolated bridge 00:03.1 (nothing else lives behind it), rescan.
      # Bounded to GPU1; never reboots. The one command that ACTS rather than
      # just writing a file — hence admin-gated.
      if [[ -w /sys/bus/pci/devices/0000:0b:00.1/remove ]]; then echo 1 > /sys/bus/pci/devices/0000:0b:00.1/remove 2>/dev/null || true; fi
      if [[ -w /sys/bus/pci/devices/0000:0b:00.0/remove ]]; then echo 1 > /sys/bus/pci/devices/0000:0b:00.0/remove 2>/dev/null || true; fi
      setpci -s 00:03.1 BRIDGE_CONTROL=40:40 >/dev/null 2>&1 || true
      sleep 1
      setpci -s 00:03.1 BRIDGE_CONTROL=00:40 >/dev/null 2>&1 || true
      sleep 1
      echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    }
    HELP=$(printf '%s\n' 'gpu-watchdog commands:' '/status — mode + GPUs on bus + watchdog state' '/hold — on a drop, wait for you (no reset)' '/auto — on a drop, reset automatically (default)' '/recover — reset a pending drop now (stays in hold)' "/sbr — recover GPU1 via PCIe bus reset, no reboot ('/sbr force' if it is alive)" '/id — show your chat id' '/help — this list' ${t3PairHelpLine}'(all but /id and /help are admin-only)')

    while :; do
      if [[ ! -r "$TOKEN_FILE" ]]; then sleep 30; continue; fi
      TOKEN=$(< "$TOKEN_FILE")
      API="https://api.telegram.org/bot''${TOKEN}"
      mkdir -p "$(dirname "$STATE_FILE")"
      [[ -f "$STATE_FILE" ]] || echo '{"last_update_id":0,"chat_ids":[]}' > "$STATE_FILE"
      last=$(jq -r '.last_update_id // 0' "$STATE_FILE" 2>/dev/null || echo 0)

      # Long-poll for updates (the single getUpdates consumer on this host).
      resp=$(curl -fsS --max-time 35 "$API/getUpdates?offset=$((last+1))&timeout=25" 2>/dev/null || echo "")
      if ! echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then sleep 5; continue; fi

      # Advance the offset + merge any new chat ids (subsumes --discover).
      new_off=$(echo "$resp" | jq -r '[.result[]?.update_id] | max // 0')
      new_ids=$(echo "$resp" | jq -r '.result[]?.message.chat.id' | sort -u)
      tmp=$(mktemp "$STATE_FILE.XXXXXX")
      if jq --argjson no "''${new_off:-0}" --argjson l "$last" \
            --argjson ids "$(echo "$new_ids" | jq -R -s 'split("\n") | map(tonumber? // empty)')" '
            .last_update_id = ([$l, $no] | max) | .chat_ids = (.chat_ids + $ids | unique)' \
            "$STATE_FILE" > "$tmp" 2>/dev/null; then mv "$tmp" "$STATE_FILE"; else rm -f "$tmp"; fi

      # Handle text commands. Non-admins only get a reply for /id.
      echo "$resp" \
        | jq -rc '.result[]? | select(.message.text != null) | [.message.chat.id, .message.text] | @tsv' 2>/dev/null \
        | while IFS=$'\t' read -r chat text; do
            low=$(printf '%s' "$text" | tr 'A-Z' 'a-z')
            cmd=''${low%% *}; cmd=''${cmd#/}; cmd=''${cmd%%@*}
            case "$low" in *force*) force=1 ;; *) force=0 ;; esac
            case "$cmd" in
              id)
                send "$chat" "your Telegram chat id: $chat" ;;
              help)
                send "$chat" "$HELP" ;;
              status)
                if is_admin "$chat"; then
                  m=$(tr -dc 'a-z' < "$MODE_FILE" 2>/dev/null || true); [[ -z "$m" ]] && m=auto
                  n=$(lspci -d 10de: 2>/dev/null | grep -cE ' VGA | 3D ' || echo '?')
                  send "$chat" "mode=$m | GPUs on bus: $n/2 | watchdog: $(systemctl is-active gpu-watchdog 2>/dev/null) | /help for commands"
                else send "$chat" "not authorized — send /id and add it to services.gpuWatchdog.telegramControl.adminChatIds"; fi ;;
              auto)
                if is_admin "$chat"; then printf 'auto' > "$MODE_FILE"; send "$chat" "mode set: AUTO (drops auto-reset)"; else send "$chat" "not authorized"; fi ;;
              hold)
                if is_admin "$chat"; then printf 'hold' > "$MODE_FILE"; send "$chat" "mode set: HOLD (drops wait — reply /recover, /sbr, or /auto)"; else send "$chat" "not authorized"; fi ;;
              recover)
                if is_admin "$chat"; then : > "$RECOVER_FILE"; send "$chat" "recover signalled — will reset at the pending/next drop"; else send "$chat" "not authorized"; fi ;;
              sbr)
                if ! is_admin "$chat"; then send "$chat" "not authorized";
                elif gpu1_alive && [[ "$force" != "1" ]]; then
                  send "$chat" "GPU1 looks ALIVE — /sbr would interrupt anything on it. Send '/sbr force' to reset it anyway."
                else
                  send "$chat" "GPU1: attempting PCIe bus-reset recovery (no reboot)…"
                  do_sbr
                  ok=0; for _ in 1 2 3; do if gpu1_alive; then ok=1; break; fi; sleep 3; done
                  if [[ "$ok" == "1" ]]; then
                    : > "$CANCEL_FILE"
                    send "$chat" "✅ GPU1 is back after bus reset — no reboot needed (any pending hold cancelled)."
                  else
                    send "$chat" "❌ GPU1 still down after bus reset. A reboot is needed — /recover or /auto with a drop pending."
                  fi
                fi ;;
              ${t3PairCase}*) : ;;
            esac
          done
    done
  '';
in
{
  options.services.gpuWatchdog = {
    enable = lib.mkEnableOption "auto-reboot on NVIDIA Xid 79/154 GPU disconnect";

    resumeStatePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/elijah/.local/state/nsl2/active-run";
      description = ''
        Optional path to an nsl2 active-run state file (shell-sourceable;
        defines PROJECT_DIR, CONFIG_PATH, RUN_ID, STARTED_AT). If set and
        the file exists at boot after a watchdog-triggered reboot, the
        boot-notify message will include the scheduled resume's run-id and
        config so the operator knows whether nsl2-resume.service will pick
        the run back up. Set to null to omit the resume block.
      '';
    };

    coldCycle = {
      enable = lib.mkEnableOption ''
        recovery via a full RTC-wake power cycle instead of a warm reboot. On
        Xid 79/154 the watchdog arms an RTC wake alarm and powers the machine
        OFF (rather than rebooting) so the GPU power domain fully de-energizes;
        the alarm then powers it back on. This recovers a card that a warm
        reboot leaves un-enumerated. REQUIRES BIOS "Resume by Alarm"/RTC-wake to
        be enabled and verified first — otherwise the machine powers off and
        STAYS off. If the alarm cannot be armed the watchdog falls back to a
        warm reboot'';
      method = lib.mkOption {
        type = lib.types.enum [ "rtc" "external" ];
        default = "rtc";
        description = ''
          How the cold cycle powers the box back ON. "rtc": arm an RTC wake
          alarm (rtcwake) — needs BIOS "Resume by Alarm" and is flaky on some
          boards (e.g. X570). "external": run externalArmCommand to schedule an
          out-of-band power-on (e.g. a PiKVM pressing ATX power once the box
          reaches S5) — preferred when such a controller exists. Only consulted
          when coldCycle.enable = true.
        '';
      };
      externalArmCommand = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "/run/current-system/sw/bin/pikvm-coldcycle-arm";
        description = ''
          Command run at recovery time when method = "external", BEFORE Docker
          is stopped (verify-before-destroy). It must (a) confirm the box can be
          powered back on and (b) schedule/arm that power-on, then exit 0. A
          nonzero exit is treated as an arm failure and handled per onArmFailure
          — the box is NOT powered off. Typically an SSH call to an out-of-band
          controller (e.g. a PiKVM) that schedules ATX action=on for once the
          box is in S5.
        '';
      };
      wakeSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 150;
        description = ''
          Seconds from when the alarm is ARMED until it fires. The alarm is now
          armed BEFORE the ~30s Docker grace + shutdown (verify-before-destroy),
          so this must comfortably exceed grace + shutdown (~55s) AND leave ≥30s
          of true G3 off-time. 150 ⇒ ~95s powered off after a ~55s shutdown.
          Keep well under any 24h RTC ceiling.
        '';
      };
      onArmFailure = lib.mkOption {
        type = lib.types.enum [ "hold" "reboot" ];
        default = "hold";
        description = ''
          What to do if the RTC wake alarm cannot be armed/verified at recovery
          time (cold-cycle mode only). "hold" (default): page and park in HOLD
          WITHOUT powering off — never strand the box, and don't kill the Docker
          fleet for a recovery that can't happen. "reboot": fall back to a warm
          `systemctl reboot --force` (note: a warm reboot frequently leaves GPU1
          un-enumerated on this host, so this trades stranding-risk for a likely
          still-broken GPU1).
        '';
      };
      maxCyclesPerWindow = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Boot-loop guard: the maximum number of auto recovery commits (cold
          cycles or warm reboots) allowed within windowMinutes before the
          watchdog stops auto-recovering. On trip, AUTO degrades to HOLD and
          pages you instead of power-cycling forever. The counter persists
          across reboots and resets once a window passes with no new commit.
        '';
      };
      windowMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Sliding window (minutes) for maxCyclesPerWindow.";
      };
    };

    telegramControl = {
      enable = lib.mkEnableOption ''
        a Telegram control loop that lets you flip the watchdog's recovery mode
        from chat. Admin commands: /auto, /hold, /recover, /sbr (in-place PCIe
        bus-reset recovery of GPU1, no reboot), /status; /help and /id are open.
        Most commands only WRITE a mode/recover file (gpu-watchdog does the
        privileged reset); /sbr is the exception and resets GPU1's PCIe link in
        place. Honoured only from telegramControl.adminChatIds (empty ⇒ inert)'';
      adminChatIds = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [ ];
        example = [ 123456789 ];
        description = ''
          Telegram chat IDs allowed to issue mode commands. Empty (default)
          means NO command is honoured — the loop is inert/safe until you add
          your own id (send /id to the bot to discover it). The bot token is a
          bearer credential (semi-exposed per the watchdog doc); keep this list
          to your own id and rotate the token if in doubt.
        '';
      };

      t3Pair = {
        enable = lib.mkEnableOption ''
          a /t3pair command that re-mints and DMs a fresh `t3 serve` pairing
          link (see services.t3PairNotify). Requires services.t3PairNotify to
          be enabled (it provides the t3-pair-notify helper). Restricted to
          t3Pair.chatId only — tighter than adminChatIds, since a pairing link
          grants admin/code-exec on the agent'';
        chatId = lib.mkOption {
          type = lib.types.int;
          default = 0;
          example = 448383615;
          description = ''
            The single chat allowed to run /t3pair and receive the link.
            Should match services.t3PairNotify.chatId.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root - -"
    ];

    assertions = [
      {
        assertion = !(cfg.coldCycle.enable && cfg.coldCycle.method == "external")
          || cfg.coldCycle.externalArmCommand != "";
        message = ''
          services.gpuWatchdog.coldCycle.method = "external" requires
          coldCycle.externalArmCommand to be set (the command that arms the
          out-of-band power-on, e.g. the PiKVM SSH hook).
        '';
      }
    ];

    systemd.services.gpu-watchdog = {
      description = "Auto-reboot on NVIDIA Xid 79/154 (GPU disconnect mitigation)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-journald.service" "nvidia-power-limit.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";
        ExecStart = "${watchdogScript}";
      };
    };

    # Boot-time notifier: fires once per boot, retries on failure (e.g. if
    # the network is slow to come up). Only sends if the watchdog left a
    # pending-boot marker — manual reboots stay silent.
    systemd.services.gpu-watchdog-boot-notify = {
      description = "Notify on boot after watchdog-triggered reboot";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "nvidia-power-limit.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bootNotifyScript}";
        # Retry if telegram-notify fails — usually a slow-to-come-up
        # network. StartLimit caps retries so a permanent failure (token
        # missing, API blocked) doesn't burn cycles forever; once the
        # limit is hit the marker stays and the next boot tries fresh.
        Restart = "on-failure";
        RestartSec = "15s";
        StartLimitIntervalSec = "10min";
        StartLimitBurst = 10;
      };
    };

    # Telegram control loop: turns chat commands into mode-file writes. The
    # privileged reboot stays in gpu-watchdog; this only sets a string. Inert
    # until telegramControl.adminChatIds is non-empty.
    systemd.services.gpu-watchdog-telegram-control = lib.mkIf cfg.telegramControl.enable {
      description = "Telegram mode toggles for gpu-watchdog (mode-file writer)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10s";
        ExecStart = "${controlScript}";
      };
    };

    # The control loop is the always-on getUpdates consumer; disable the
    # 5-minute discovery timer so the two don't fight over the update offset.
    services.telegramNotify.discoveryTimer.enable =
      lib.mkIf cfg.telegramControl.enable (lib.mkForce false);
  };
}
