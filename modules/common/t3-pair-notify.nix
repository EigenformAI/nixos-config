# Deliver the `t3 serve` pairing link to Telegram instead of the console.
#
# Background — how t3 pairing works (verified against t3 v0.0.33):
#   A pairing credential is a one-time coupon (12 chars from
#   23456789ABCDEFGHJKLMNPQRSTUVWXYZ) stored PLAINTEXT in
#   ~/.t3/userdata/state.sqlite (auth_pairing_links.credential). It is:
#     - single-use  (redeeming it mints a session; then consumed_at is set)
#     - time-bound  (TTL is a flag — see `ttl` below; 5 min if unspecified)
#     - privileged  (scopes cover orchestration:operate and terminal:operate,
#                    i.e. redeeming it means code execution as the serving user,
#                    so treat the link like a password)
#   Redeeming it yields a session that PERSISTS across server restarts, so you
#   only pair when a device is new or its session was cleared — NOT every boot.
#
#   `t3 serve` also prints a fresh credential + QR at startup, but only to the
#   console, which is useless on a headless box that reboots for GPU recovery.
#
# This module bridges that gap. A single root helper (`t3-pair-notify`) mints a
# link with `t3 auth pairing create` and DMs it to one authorised Telegram chat:
#   --auto   send ONLY if there is no active session (you actually need to pair)
#            and not within throttleSeconds of the last send. Used by the boot
#            prompt.
#   --force  always mint a fresh link and send it. Used by /t3pair.
#
# `auth pairing create` writes directly to the store and does not need the
# server to be up, so neither mode has to touch `t3-serve` — an earlier version
# of this module restarted the unit to force a re-mint, which dropped whatever
# the agent was doing and could not issue a link while a session was live.
#
# The helper runs as root because root already reads the root-only bot token,
# and it drops to the serving user (via `runuser`) for the mint itself so the
# sqlite store keeps its ownership. The on-demand `/t3pair` command lives in the
# gpu-watchdog control loop (the host's single Telegram getUpdates consumer);
# this module only ever calls sendMessage, so it never competes for updates.
#
# Companion: services.gpuWatchdog.telegramControl.t3Pair (gpu-watchdog.nix)
#            services.t3Serve (modules/home/t3-serve.nix, the home-manager unit)
{ config, lib, pkgs, ... }:
let
  cfg = config.services.t3PairNotify;

  notifyScript = pkgs.writeShellApplication {
    name = "t3-pair-notify";
    runtimeInputs = with pkgs; [ curl jq coreutils sqlite util-linux nodejs_24 ];
    text = ''
      TOKEN_FILE=${lib.escapeShellArg cfg.botTokenFile}
      DB=${lib.escapeShellArg cfg.dbPath}
      SCHEME=${lib.escapeShellArg cfg.pairUrl.scheme}
      HOST=${lib.escapeShellArg cfg.pairUrl.host}
      PORT=${toString cfg.pairUrl.port}
      DEFAULT_CHAT=${toString cfg.chatId}
      RUN_USER=${lib.escapeShellArg cfg.user}
      T3_ENTRY=${lib.escapeShellArg cfg.t3Entry}
      # The t3 data directory (the parent of userdata/, which holds the DB).
      BASE_DIR=$(dirname "$(dirname "$DB")")
      TTL=${lib.escapeShellArg cfg.ttl}
      LABEL=${lib.escapeShellArg cfg.label}
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
      # Mint a fresh link. `auth pairing create` writes straight to the user's
      # sqlite store, so it runs as that user: a root-created WAL/journal file
      # alongside the DB would break the server's own writes. It builds the URL
      # against the TAILNET host, because t3's own connection string uses the
      # LAN IP, which is useless when you are remote.
      #
      # Everything after `runuser --` is an ABSOLUTE path, and the store is
      # named with --base-dir rather than inherited from HOME. runuser resets
      # PATH (and HOME) for the target user to the login defaults, which on
      # NixOS resolve to nothing — so a bare `node`, or wrapping the call in
      # `env`, fails with a bare "No such file or directory". That is invisible
      # when testing from a login shell, where the caller's PATH happens to
      # cover it, and only bites under the transient systemd unit that /t3pair
      # launches.
      mint_url() {
        runuser -u "$RUN_USER" -- \
          ${pkgs.nodejs_24}/bin/node "$T3_ENTRY" auth pairing create \
            --base-dir "$BASE_DIR" \
            --ttl "$TTL" --label "$LABEL" \
            --base-url "$SCHEME://$HOST:$PORT" --json 2>/dev/null \
          | jq -r '.pairUrl // empty'
      }

      send_link() {
        local url="$1"
        send "$TO" "T3 Code pairing link (valid $TTL, single use):
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
      fi

      # Both modes mint the same way. Minting does not require the server to be
      # running, so the boot prompt does not have to wait for `t3-serve` to come
      # up — the link stays valid for its whole TTL either way.
      url=$(mint_url || true)
      if [[ -z "$url" ]]; then
        send "$TO" "❌ Couldn't mint a T3 pairing link — is the t3 install intact? \
      Check: systemctl --user status t3-serve"
        echo "t3-pair-notify: 'auth pairing create' produced no pairUrl" >&2
        exit 1
      fi
      send_link "$url"
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

    user = lib.mkOption {
      type = lib.types.str;
      example = "elijah";
      description = ''
        The user that runs `t3-serve` and owns the t3 store. Minting drops to
        this user so the sqlite files keep their ownership.
      '';
    };

    userHome = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}";
      defaultText = lib.literalExpression ''"/home/''${config.services.t3PairNotify.user}"'';
      description = "Home directory of `user`; only used to derive `t3Entry`.";
    };

    t3Entry = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.userHome}/.local/state/t3-serve/node_modules/t3/dist/bin.mjs";
      defaultText = lib.literalExpression ''"''${userHome}/.local/state/t3-serve/node_modules/t3/dist/bin.mjs"'';
      description = ''
        Path to the t3 CLI entrypoint. Defaults to the install tree that
        services.t3Serve (modules/home/t3-serve.nix) maintains.
      '';
    };

    ttl = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      example = "30d";
      description = ''
        Lifetime of a minted link, as `t3 auth pairing create --ttl` accepts it
        (`5m`, `1h`, `30d`, ...). This is how long the UNREDEEMED coupon stays
        usable; the session it grants outlives it. Kept short by default because
        the link is delivered over Telegram and grants code execution — long
        TTLs leave a live credential sitting in a chat log.
      '';
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "telegram";
      description = "Label recorded on the grant, so `auth pairing list` is legible.";
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
