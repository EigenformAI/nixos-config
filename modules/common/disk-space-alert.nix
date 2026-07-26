# Periodic disk-space watchdog: Telegram-alert when a filesystem fills up.
#
# Motivation: root on limiting-factor runs chronically ~87% full (big ML
# working trees under /home) and ML runs can spill tens of GB of checkpoints
# or JIT caches in minutes. A full root wedges the box (logind, docker, the
# gpu-watchdog control loop) far more quietly than it should. This is the
# early-warning analogue of docker-network-prune's leak alarm, and rides the
# same telegram-notify plumbing (services.telegramNotify) — no new secret, no
# new getUpdates consumer.
#
# Alerting is EDGE-TRIGGERED, not level-triggered, so it never spams:
#   - fire once when a mount first crosses cfg.thresholdPercent;
#   - stay quiet while it hovers, re-firing only if it climbs another
#     cfg.reAlertStepPercent points (escalation) since the last alert;
#   - send a one-shot "recovered" note when it drops back below threshold.
# Per-mount state (last-alerted percent, or "ok") lives in
# /var/lib/disk-space-alert; alerting is best-effort and never fails the unit.
#
# Design note (percent-only): a single percentage threshold is used rather
# than an absolute-free-bytes floor. On this host's mounts (448G–1.9T) 90%
# leaves 45–190G, which is a reasonable "act now" line across all of them, and
# one knob keeps the module simple. If a huge mount ever needs a tighter
# absolute floor, add a `minFreeGib` OR-trigger — deliberately deferred as
# YAGNI for now.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.diskSpaceAlert;

  mountArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.mounts;

  alertScript = pkgs.writeShellApplication {
    name = "disk-space-alert-check";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
    text = ''
      threshold=${toString cfg.thresholdPercent}
      step=${toString cfg.reAlertStepPercent}
      host=${lib.escapeShellArg config.networking.hostName}
      state_dir=/var/lib/disk-space-alert
      mkdir -p "$state_dir"

      warn=""      # accumulated over-threshold lines
      recovered="" # accumulated back-under-threshold lines

      for mount in ${mountArgs}; do
        # nofail mounts can be absent; skip anything df can't stat.
        line=$(df -Ph "$mount" 2>/dev/null | awk 'NR==2') || continue
        [[ -n "$line" ]] || continue

        use=$(echo "$line" | awk '{ gsub(/%/,"",$5); print $5 }')
        size_h=$(echo "$line" | awk '{ print $2 }')
        avail_h=$(echo "$line" | awk '{ print $4 }')
        [[ "$use" =~ ^[0-9]+$ ]] || continue

        # Force base-10 so a value like 08/09 never trips octal parsing.
        use=$((10#$use))

        key=''${mount//\//_}          # "/" -> "_", "/mnt/data2t" -> "_mnt_data2t"
        statefile="$state_dir/state_$key"
        prev=ok
        [[ -f "$statefile" ]] && prev=$(cat "$statefile")

        if (( use >= threshold )); then
          # New crossing, or escalated by >= step since the last alert.
          if [[ "$prev" == "ok" ]] || (( use >= 10#$prev + step )); then
            warn+="• $mount: ''${use}% used (''${avail_h} free of ''${size_h})"$'\n'
            echo "$use" > "$statefile"
          fi
        else
          if [[ "$prev" != "ok" ]]; then
            recovered+="• $mount: back to ''${use}% used (''${avail_h} free)"$'\n'
            echo ok > "$statefile"
          fi
        fi
      done

      msg=""
      [[ -n "$warn" ]] && msg+="⚠️ $host disk space warning (≥''${threshold}% full):"$'\n'"$warn"
      [[ -n "$recovered" ]] && { [[ -n "$msg" ]] && msg+=$'\n'; msg+="✅ $host disk space recovered:"$'\n'"$recovered"; }

      if [[ -n "$msg" ]]; then
        timeout 10 telegram-notify "$msg" || true
      fi
    '';
  };
in
{
  options.services.diskSpaceAlert = {
    enable = lib.mkEnableOption "periodic disk-space Telegram warnings";

    mounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/" ];
      example = [ "/" "/mnt/data2t" "/mnt/asis-archive" ];
      description = "Mountpoints to monitor. Missing mounts (nofail) are skipped.";
    };

    thresholdPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 90;
      description = "Warn when a monitored mount is at or above this % full.";
    };

    reAlertStepPercent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        Once a mount has alerted, only re-alert if it climbs at least this many
        percentage points further (escalation). Prevents per-interval spam
        while a mount hovers just over the threshold.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "systemd OnUnitActiveSec cadence for the check.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.services.telegramNotify.enable;
      message = "services.diskSpaceAlert needs services.telegramNotify.enable = true (it delivers via the telegram-notify CLI).";
    }];

    systemd.services.disk-space-alert = {
      description = "Warn via Telegram when a filesystem is filling up";
      # telegram-notify is in environment.systemPackages; give the unit a login-like PATH.
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${alertScript}/bin/disk-space-alert-check";
      };
    };

    systemd.timers.disk-space-alert = {
      description = "Periodic disk-space check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
        Unit = "disk-space-alert.service";
      };
    };
  };
}
