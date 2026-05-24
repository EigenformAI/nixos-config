# GPU disconnect watchdog: auto-reboots the host on NVIDIA Xid 79/154 events
# on either RTX 4090 (BDFs 0000:05:00 and 0000:0b:00). Stopgap mitigation
# while the hardware remediation in docs/design/gpu1-remediation-2026-05-24.md
# is pending. Designed to be ripped out once the cable swap restores
# multi-day MTBF.
#
# Design doc: docs/design/gpu-watchdog-2026-05-24.md
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
# Companion: services.telegramNotify (modules/common/telegram-notify.nix)
#   provides the `telegram-notify` CLI used to broadcast each reboot event.
#   The watchdog will still reboot if telegram-notify is missing — the
#   notification is best-effort.
#
# Manual kill-switches:
#   systemctl stop gpu-watchdog            # disable until next boot
#   systemctl disable gpu-watchdog         # disable across reboots
#   systemctl set-environment GPU_WATCHDOG_DRYRUN=1 \
#     && systemctl restart gpu-watchdog    # log-only mode (no actual reboot)
{ config, lib, pkgs, ... }:
let
  cfg = config.services.gpuWatchdog;

  watchdogScript = pkgs.writeShellScript "gpu-watchdog" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.gnugrep pkgs.coreutils ]}:/run/current-system/sw/bin

    LOG=/var/lib/gpu-watchdog/reboot-log
    mkdir -p /var/lib/gpu-watchdog

    # `-n 0` starts following from the live tail, so we never re-fire on a
    # ghost Xid from a previous boot still in the journal.
    journalctl -k -f -n 0 -o cat \
      | grep --line-buffered -E 'NVRM: Xid \(PCI:0000:(05|0b):00\):? (79|154)' \
      | while IFS= read -r line; do
          ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          echo "$ts $line" >> "$LOG"
          recent=$(tail -n 5 "$LOG")
          msg="GPU disconnect on limiting-factor at $ts

    $line

    Recent events:
    $recent

    Rebooting in ~30s. systemctl stop gpu-watchdog (from another shell) aborts."

          timeout 10 telegram-notify "$msg" || true &
          systemctl stop --no-block docker.service || true

          sleep 30
          sync
          sleep 1

          if [[ "''${GPU_WATCHDOG_DRYRUN:-0}" == "1" ]]; then
            echo "[gpu-watchdog] DRYRUN: would systemctl reboot --force now" >&2
            exit 0
          fi
          exec systemctl reboot --force
        done
  '';
in
{
  options.services.gpuWatchdog = {
    enable = lib.mkEnableOption "auto-reboot on NVIDIA Xid 79/154 GPU disconnect";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/gpu-watchdog 0755 root root - -"
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
  };
}
