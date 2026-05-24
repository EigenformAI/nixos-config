# Tiny CLI for broadcasting messages to a Telegram bot's chat list.
#
# Usage:
#   telegram-notify "your message"     # discover new chats, then broadcast
#   telegram-notify --discover         # just refresh chat list (no send)
#
# Bootstrap (one-time, after rebuild):
#   sudo install -m 600 /dev/stdin /var/lib/telegram-notify/token <<< 'YOUR_BOT_TOKEN'
#   # subscribers send /start to the bot in Telegram, then:
#   telegram-notify --discover
#   telegram-notify "smoke test"
#
# Token is read from /var/lib/telegram-notify/token at runtime (NOT embedded
# in the nix store, where it would be world-readable). State (last update
# offset + known chat IDs) lives in /var/lib/telegram-notify/state.json.
#
# Designed for the gpu-watchdog stopgap (docs/design/gpu-watchdog-2026-05-24.md)
# but written as a generic utility — any service can call it.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.telegramNotify;

  notifyScript = pkgs.writeShellApplication {
    name = "telegram-notify";
    runtimeInputs = with pkgs; [ curl jq coreutils ];
    text = ''
      TOKEN_FILE=/var/lib/telegram-notify/token
      STATE_FILE=/var/lib/telegram-notify/state.json

      if [[ $# -eq 0 ]]; then
        echo "usage: telegram-notify [--discover] | <message>" >&2
        exit 2
      fi

      if [[ "$1" == "--discover" ]]; then
        MODE=discover
        MSG=""
      else
        MODE=send
        MSG="$1"
      fi

      if [[ ! -r "$TOKEN_FILE" ]]; then
        echo "telegram-notify: no token at $TOKEN_FILE" >&2
        # Discovery is commonly invoked before bootstrap (timer fires on boot);
        # exit 0 so the timer doesn't spam failures. Send is an explicit error.
        if [[ "$MODE" == "discover" ]]; then exit 0; else exit 1; fi
      fi
      TOKEN=$(< "$TOKEN_FILE")
      API="https://api.telegram.org/bot''${TOKEN}"

      mkdir -p "$(dirname "$STATE_FILE")"
      if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"last_update_id":0,"chat_ids":[]}' > "$STATE_FILE"
      fi

      # Refresh chat list: getUpdates with offset = last_update_id + 1.
      last=$(jq -r '.last_update_id' "$STATE_FILE")
      resp=$(curl -fsS --max-time 8 "''${API}/getUpdates?offset=$((last+1))&timeout=0" 2>/dev/null || echo "")
      if [[ -z "$resp" ]] || ! echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        echo "telegram-notify: getUpdates failed (check token and connectivity)" >&2
        resp='{"result":[]}'
      fi

      new_ids_raw=$(echo "$resp" | jq -r '.result[]?.message.chat.id' | sort -u)
      new_offset=$(echo "$resp" | jq -r '[.result[]?.update_id] | max // 0')

      tmp=$(mktemp "$STATE_FILE.XXXXXX")
      jq --argjson newoff "''${new_offset:-0}" --argjson last "$last" \
         --argjson ids "$(echo "$new_ids_raw" | jq -R -s 'split("\n") | map(tonumber? // empty)')" '
        .last_update_id = ([$last, $newoff] | max)
        | .chat_ids = (.chat_ids + $ids | unique)
      ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

      if [[ "$MODE" == "discover" ]]; then
        count=$(jq -r '.chat_ids | length' "$STATE_FILE")
        echo "telegram-notify: $count chat(s) registered"
        exit 0
      fi

      # Broadcast.
      jq -r '.chat_ids[]' "$STATE_FILE" | while read -r chat_id; do
        if ! curl -fsS --max-time 8 -X POST "''${API}/sendMessage" \
             --data-urlencode "chat_id=''${chat_id}" \
             --data-urlencode "text=''${MSG}" >/dev/null 2>&1; then
          echo "telegram-notify: send to ''${chat_id} failed" >&2
        fi
      done
    '';
  };
in
{
  options.services.telegramNotify = {
    enable = lib.mkEnableOption "Telegram broadcast notification CLI";

    discoveryTimer.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `telegram-notify --discover` every 5 minutes to refresh the
        chat-ID list. Telegram retains undelivered updates for ~24h, so
        polling keeps the list current between rare notification events.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ notifyScript ];

    systemd.tmpfiles.rules = [
      "d /var/lib/telegram-notify 0700 root root - -"
    ];

    systemd.services.telegram-notify-discover = lib.mkIf cfg.discoveryTimer.enable {
      description = "Refresh Telegram bot chat list";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${notifyScript}/bin/telegram-notify --discover";
      };
    };

    systemd.timers.telegram-notify-discover = lib.mkIf cfg.discoveryTimer.enable {
      description = "Refresh Telegram bot chat list every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "5min";
        Unit = "telegram-notify-discover.service";
      };
    };
  };
}
