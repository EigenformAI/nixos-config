# Hourly cleanup of leaked per-run Docker networks, plus a leak alarm.
#
# Motivation: the weval-agents/nsl2 slot generator creates one bridge network
# per slot (gen_<date>-<id>_slot_NN_*) and historically never removed them.
# By 2026-07-23, 6,782 leaked networks meant ~4,800 kernel bridges; the
# resulting D-Bus event flood tripped dbus-broker's per-UID quota, which
# evicted NetworkManager and took the box offline (see memory:
# docker-network-leak-crash). This module is the backstop for that class of
# failure; fixing the harness to clean up after itself is still the real fix.
#
# Safety invariants (training runs can last days and must never be touched):
#   1. Only networks matching cfg.namePrefixes are considered — compose
#      project networks, user networks, and Docker's built-ins are invisible
#      to this script.
#   2. A network is skipped if ANY container — running, stopped, restarting,
#      or exited-but-not-removed — references it (`docker ps -a --filter
#      network=`). This is stricter than `docker network prune`, which only
#      sees running endpoints and would delete a network out from under a
#      container mid-restart.
#   3. Networks younger than cfg.minAgeHours are skipped, so a network
#      created ahead of its first container can't be reaped in the gap.
#   4. Deletion uses `docker network rm`, which atomically refuses if an
#      endpoint attaches between our check and the rm.
#
# The alert fires when the TOTAL network count (any name) exceeds
# cfg.alertThreshold: with the cleaner keeping gen_* near zero, a high count
# means some new leaker the prefix filter doesn't cover — page instead of
# silently masking it. Delivered via the telegram-notify CLI
# (services.telegramNotify); alerting is best-effort and never fails the unit.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dockerNetworkPrune;

  # bash `case` pattern: "gen_*|foo_*"
  namePattern = lib.concatMapStringsSep "|" (p: "${p}*") cfg.namePrefixes;

  pruneScript = pkgs.writeShellApplication {
    name = "docker-network-prune-stale";
    runtimeInputs = [ config.virtualisation.docker.package pkgs.coreutils ];
    text = ''
      # Never wake a stopped/starting daemon — with a large leak, docker can
      # take many minutes to activate, and this unit must not pile on.
      if ! docker info >/dev/null 2>&1; then
        echo "docker daemon not responding; skipping this pass"
        exit 0
      fi

      now=$(date +%s)
      min_age_s=$(( ${toString cfg.minAgeHours} * 3600 ))
      removed=0
      skipped_inuse=0
      skipped_young=0
      skipped_unparsed=0

      while IFS= read -r name; do
        case "$name" in
          ${namePattern}) ;;
          *) continue ;;
        esac

        # `{{json .Created}}` marshals to RFC3339 ("2026-07-23T14:14:20+08:00"),
        # which GNU date parses; the bare `{{.Created}}` Go stringification
        # ("... +0800 +08") does not.
        created=$(docker network inspect -f '{{json .Created}}' "$name" 2>/dev/null | tr -d '"') || continue
        if ! created_s=$(date -d "$created" +%s 2>/dev/null); then
          echo "cannot parse creation time '$created' for $name — leaving it"
          skipped_unparsed=$((skipped_unparsed + 1))
          continue
        fi
        if (( now - created_s < min_age_s )); then
          skipped_young=$((skipped_young + 1))
          continue
        fi

        # Any container in ANY state pins the network (invariant 2).
        if [[ -n $(docker ps -aq --filter "network=$name" | head -n1) ]]; then
          skipped_inuse=$((skipped_inuse + 1))
          continue
        fi

        if docker network rm "$name" >/dev/null 2>&1; then
          removed=$((removed + 1))
        else
          echo "rm refused for $name (endpoint attached since check?) — leaving it"
        fi
      done < <(docker network ls --format '{{.Name}}')

      total=$(docker network ls -q | wc -l)
      echo "removed=$removed in-use=$skipped_inuse young=$skipped_young unparsed=$skipped_unparsed total-remaining=$total"

      if (( total > ${toString cfg.alertThreshold} )); then
        timeout 10 telegram-notify "WARNING ${config.networking.hostName}: docker network count is $total (threshold ${toString cfg.alertThreshold}) — something is leaking networks beyond what the gen_* cleaner covers. Unchecked, this eventually kills NetworkManager via the dbus quota (2026-07-23 incident)." || true
      fi
    '';
  };
in
{
  options.services.dockerNetworkPrune = {
    enable = lib.mkEnableOption "hourly cleanup of stale per-run Docker networks";

    namePrefixes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "gen_" ];
      description = "Only networks whose name starts with one of these prefixes are ever deleted.";
    };

    minAgeHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Never delete a network created less than this many hours ago.";
    };

    alertThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 200;
      description = "Send a Telegram warning when the total network count (any name) exceeds this.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.docker-network-prune = {
      description = "Remove stale per-run Docker networks";
      after = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pruneScript}/bin/docker-network-prune-stale";
      };
    };

    systemd.timers.docker-network-prune = {
      description = "Hourly stale Docker network cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "1h";
        Unit = "docker-network-prune.service";
      };
    };
  };
}
