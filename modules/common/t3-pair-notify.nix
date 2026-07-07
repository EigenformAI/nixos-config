# Deliver the `t3 serve` pairing link to Telegram instead of the console.
#
# Background — how t3 pairing actually works (t3 v0.0.27, reverse-engineered):
#   On every server start `t3 serve` mints a NEW one-time pairing credential
#   (12 chars from 23456789ABCDEFGHJKLMNPQRSTUVWXYZ), prints it as `Token:` /
#   `Pairing URL:`, and stores it PLAINTEXT in ~/.t3/userdata/state.sqlite
#   (auth_pairing_links.credential). It is:
#     - single-use   (consuming it mints a session; then consumed_at is set)
#     - short-lived   (TTL hardcoded to 5 min — no flag/env to extend)
#     - admin-scoped  (subject "administrative-bootstrap"; pairing == code-exec
#                      as the serving user, so the link is sensitive)
#   Consuming it yields a 30-DAY session (auth_sessions) that PERSISTS across
#   server restarts. So you only ever (re)pair when unpaired or after 30 days —
#   NOT on every reboot. There is no native "fixed code"; web/serve mode only
#   supports these random one-time tokens.
#
# This module bridges that gap. A single root helper (`t3-pair-notify`) reads
# the freshly-minted credential straight from the SQLite DB, rebuilds the URL
# against the TAILNET hostname (t3's own connection string uses the LAN IP,
# useless when you're remote), and DMs it to one authorised Telegram chat:
#   --auto   send ONLY if there is no active session (you actually need to pair)
#            and not within throttleSeconds of the last send. Never restarts the
#            server. Used by the boot prompt.
#   --force  ensure a valid unconsumed link exists (restart t3-serve to re-mint
#            if the last one is stale/consumed), then send. Used by /t3pair.
#
# It runs as root because root already (a) reads the root-only bot token, (b)
# reads the user's t3 DB, and (c) can restart the user's `t3-serve` unit — so no
# home-manager↔system permission coupling is needed. The on-demand `/t3pair`
# command lives in the gpu-watchdog control loop (the host's single Telegram
# getUpdates consumer); this module only ever calls sendMessage, so it never
# competes for updates.
#
# Companion: services.gpuWatchdog.telegramControl.t3Pair (gpu-watchdog.nix)
#            services.t3Serve (modules/home/t3-serve.nix, the home-manager unit)
{ config, lib, pkgs, ... }:
let
  cfg = config.services.t3PairNotify;

  notifyScript = pkgs.writeShellApplication {
    name = "t3-pair-notify";
    runtimeInputs = with pkgs; [ curl jq coreutils sqlite systemd ];
    text = ''
      TOKEN_FILE=${lib.escapeShellArg cfg.botTokenFile}
      DB=${lib.escapeShellArg cfg.dbPath}
      SCHEME=${lib.escapeShellArg cfg.pairUrl.scheme}
      HOST=${lib.escapeShellArg cfg.pairUrl.host}
      PORT=${toString cfg.pairUrl.port}
      DEFAULT_CHAT=${toString cfg.chatId}
      RESTART_MACHINE=${lib.escapeShellArg cfg.restart.machine}
      RESTART_UNIT=${lib.escapeShellArg cfg.restart.unit}
      THROTTLE=${toString cfg.throttleSeconds}
      STATE_DIR=/var/lib/t3-pair-notify
      STAMP="$STATE_DIR/last-sent"

      MODE=auto
      TO="$DEFAULT_CHAT"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --auto)  MODE=auto ;;
          --force) MODE=force ;;
          --to)    TO="$2"; shift ;;
          *) echo "t3-pair-notify: unknown arg: $1" >&2; exit 2 ;;
        esac
        shift
      done

      if [[ -z "''${TO//[0-9-]/}" && -n "$TO" ]]; then :; else
        echo "t3-pair-notify: invalid --to chat id: '$TO'" >&2; exit 2
      fi

      if [[ ! -r "$TOKEN_FILE" ]]; then
        echo "t3-pair-notify: bot token not readable at $TOKEN_FILE" >&2
        exit 1
      fi
      TOKEN=$(< "$TOKEN_FILE")
      API="https://api.telegram.org/bot''${TOKEN}"

      send() {
        curl -fsS --max-time 8 -X POST "$API/sendMessage" \
          --data-urlencode "chat_id=$1" \
          --data-urlencode "text=$2" >/dev/null 2>&1 || \
          echo "t3-pair-notify: send to $1 failed" >&2
      }

      # SQLite is WAL-mode; concurrent reads alongside the running server are safe.
      sql() { sqlite3 -batch -noheader "$DB" "$1" 2>/dev/null || true; }

      has_active_session() {
        local n
        n=$(sql "SELECT count(*) FROM auth_sessions
                 WHERE revoked_at IS NULL
                   AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now');")
        [[ "''${n:-0}" -gt 0 ]]
      }
      # Newest still-valid, unconsumed admin pairing credential (or empty).
      valid_credential() {
        sql "SELECT credential FROM auth_pairing_links
             WHERE consumed_at IS NULL AND revoked_at IS NULL
               AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
             ORDER BY created_at DESC LIMIT 1;"
      }
      # Newest credential of any state — used to detect a re-mint after restart.
      latest_credential() {
        sql "SELECT credential FROM auth_pairing_links
             ORDER BY created_at DESC LIMIT 1;"
      }

      send_link() {
        local cred="$1" url
        url="$SCHEME://$HOST:$PORT/pair#token=$cred"
        send "$TO" "T3 Code pairing link (admin; valid ~5 min, single use):
      $url

      Open it on a tailnet device to pair. Reply /t3pair for a fresh one."
        mkdir -p "$STATE_DIR"; : > "$STAMP" || true
        echo "t3-pair-notify: sent pairing link to $TO" >&2
      }

      throttled() {
        [[ -f "$STAMP" ]] || return 1
        local age now mt
        now=$(date +%s); mt=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
        age=$(( now - mt ))
        [[ "$age" -lt "$THROTTLE" ]]
      }

      if [[ "$MODE" == "auto" ]]; then
        # Boot prompt: only nag when you genuinely need to pair, and not repeatedly
        # (guards against a pre-pairing GPU boot-loop spamming the chat).
        if has_active_session; then
          echo "t3-pair-notify: active session present — nothing to do" >&2; exit 0
        fi
        if throttled; then
          echo "t3-pair-notify: throttled (sent < ''${THROTTLE}s ago)" >&2; exit 0
        fi
        # Server may still be coming up at boot; wait briefly for a valid link.
        cred=""
        for _ in $(seq 1 20); do
          cred=$(valid_credential); [[ -n "$cred" ]] && break; sleep 3
        done
        if [[ -z "$cred" ]]; then
          echo "t3-pair-notify: no valid pairing link yet; skipping (use /t3pair)" >&2
          exit 0
        fi
        send_link "$cred"
        exit 0
      fi

      # --force: ensure a fresh, valid link exists, restarting t3-serve to re-mint
      # if the latest one is stale or already consumed.
      cred=$(valid_credential)
      if [[ -z "$cred" ]]; then
        before=$(latest_credential)
        echo "t3-pair-notify: no valid link; restarting $RESTART_UNIT to re-mint" >&2
        systemctl --machine="$RESTART_MACHINE" --user restart "$RESTART_UNIT" \
          >/dev/null 2>&1 || echo "t3-pair-notify: restart command failed" >&2
        # Server takes ~25-30s to listen and mint; poll for a credential change.
        for _ in $(seq 1 30); do
          cur=$(valid_credential)
          if [[ -n "$cur" && "$cur" != "$before" ]]; then cred="$cur"; break; fi
          sleep 3
        done
      fi
      if [[ -z "$cred" ]]; then
        send "$TO" "❌ Couldn't mint a T3 pairing link — is t3-serve healthy? \
      Check: systemctl --user status t3-serve"
        echo "t3-pair-notify: failed to obtain a pairing link after restart" >&2
        exit 1
      fi
      send_link "$cred"
    '';
  };
in
{
  options.services.t3PairNotify = {
    enable = lib.mkEnableOption "Telegram delivery of t3 serve pairing links";

    chatId = lib.mkOption {
      type = lib.types.int;
      example = 448383615;
      description = ''
        The single Telegram chat id authorised to receive (and, via /t3pair,
        request) pairing links. A pairing link grants admin/code-exec on the
        t3 agent, so this is deliberately ONE chat — tighter than the broader
        gpu-watchdog adminChatIds.
      '';
    };

    botTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/telegram-notify/token";
      description = "Path to the Telegram bot token (shared with telegram-notify).";
    };

    dbPath = lib.mkOption {
      type = lib.types.str;
      example = "/home/elijah/.t3/userdata/state.sqlite";
      description = "Path to the t3 serve state SQLite DB (holds auth_pairing_links).";
    };

    pairUrl = {
      scheme = lib.mkOption {
        type = lib.types.enum [ "http" "https" ];
        default = "http";
        description = "URL scheme for the pairing link (http for the plain tailnet bind).";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        example = "limiting-factor.tail6ee1b.ts.net";
        description = ''
          Host used to build the pairing URL. Use the TAILNET FQDN: t3's own
          connection string uses the LAN IP, which is useless off-LAN.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3773;
        description = "Port t3 serve listens on (matches services.t3Serve.port).";
      };
    };

    restart = {
      machine = lib.mkOption {
        type = lib.types.str;
        example = "elijah@.host";
        description = ''
          systemd --machine target for the user running t3-serve, so this root
          helper can restart the user unit (`systemctl --machine=<m> --user`).
        '';
      };
      unit = lib.mkOption {
        type = lib.types.str;
        default = "t3-serve.service";
        description = "The user systemd unit to restart on a forced re-mint.";
      };
    };

    throttleSeconds = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Minimum seconds between --auto (boot-prompt) sends.";
    };

    bootPrompt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          After boot, if no t3 session is active, DM the pairing link once
          (subject to throttleSeconds). Quiet once paired (30-day sessions).
        '';
      };
      delay = lib.mkOption {
        type = lib.types.str;
        default = "150s";
        description = "OnBootSec delay so t3-serve has time to start and mint.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ notifyScript ];

    systemd.tmpfiles.rules = [
      "d /var/lib/t3-pair-notify 0700 root root - -"
    ];

    systemd.services.t3-pair-boot-prompt = lib.mkIf cfg.bootPrompt.enable {
      description = "Telegram pairing prompt if t3 serve is unpaired";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${notifyScript}/bin/t3-pair-notify --auto --to ${toString cfg.chatId}";
      };
    };

    systemd.timers.t3-pair-boot-prompt = lib.mkIf cfg.bootPrompt.enable {
      description = "Run the t3 pairing prompt shortly after boot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.bootPrompt.delay;
        Unit = "t3-pair-boot-prompt.service";
      };
    };
  };
}
