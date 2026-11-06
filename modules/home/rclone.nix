# rclone + Google Drive for this user (ad-hoc uploads + scheduled backup).
#
# Two things live here:
#   1. A declarative `gdrive` rclone remote via home-manager's `programs.rclone`.
#      The non-secret bits (type=drive, scope, client_id) are rendered into
#      ~/.config/rclone/rclone.conf by the generated `rclone-config` user
#      service; the OAuth `token` (and `client_secret`, if you use your own
#      OAuth client) are read at activation time from files OUTSIDE the Nix
#      store and injected with `rclone config update --non-interactive`. This
#      mirrors the telegram-notify token bootstrap: secrets never enter the
#      world-readable store. The rendered rclone.conf is a real *writable* file,
#      so rclone can persist refreshed access tokens in place.
#   2. An optional `gdrive-sync` user timer that `rclone copy`s a local dir to
#      Drive on a schedule (default every 6h, additive — never deletes remote).
#   3. A tiny `gdrive-upload` helper for ad-hoc pushes to <remote>:<uploadBase>/.
#
# ── One-time bootstrap (not Nix-expressible — this is Google/account state) ──
#
#   A. Get an OAuth token. Two tiers:
#
#      Minimal (uses rclone's built-in, globally rate-limited client_id):
#        On any machine WITH a browser + rclone:
#          rclone authorize "drive"
#        Consent in the browser; it prints a token JSON blob:
#          {"access_token":"...","refresh_token":"...","expiry":"..."}
#        Leave `clientId = ""` below.
#
#      Recommended (your own client — avoids the shared rate limit):
#        https://rclone.org/drive/#making-your-own-client-id
#        1. Google Cloud Console: new project -> enable "Google Drive API".
#        2. OAuth consent screen: External, add your Google account as a Test
#           user (keeps the app in "testing" so the refresh token stays valid).
#        3. Credentials -> create OAuth client -> type "Desktop app".
#           Gives a client_id (not secret) and client_secret (secret).
#        4. On a browser machine:
#             rclone authorize "drive" "<CLIENT_ID>" "<CLIENT_SECRET>"
#           Set `clientId = "<CLIENT_ID>"` below and install client_secret (B).
#
#   B. Install the secret file(s) on this host (mode 600, owned by you):
#        mkdir -p ~/.config/rclone/secrets
#        printf '%s' '<TOKEN_JSON_FROM_A>' > ~/.config/rclone/secrets/token
#        # only if using your own client:
#        printf '%s' '<CLIENT_SECRET>'     > ~/.config/rclone/secrets/client_secret
#        chmod 600 ~/.config/rclone/secrets/*
#
#   C. Rebuild, then (re)start the renderer and smoke-test:
#        systemctl --user restart rclone-config.service
#        rclone lsd gdrive:                 # should list your Drive folders
#        gdrive-upload ./some-file          # -> gdrive:<uploadBase>/
#
# Before the secret file(s) exist, rclone-config.service fails loudly and keeps
# the previous config intact — that is expected until step B is done.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.gdrive;
  secretsDir = "${config.xdg.configHome}/rclone/secrets";

  syncScript = pkgs.writeShellApplication {
    name = "gdrive-sync";
    runtimeInputs = [ cfg.package pkgs.coreutils ];
    text = ''
      SRC=${lib.escapeShellArg cfg.sync.source}
      DEST=${lib.escapeShellArg cfg.sync.dest}
      if [[ ! -d "$SRC" ]]; then
        echo "gdrive-sync: source $SRC missing — nothing to do" >&2
        exit 0
      fi
      echo "gdrive-sync: ${cfg.sync.mode} $SRC -> $DEST"
      exec rclone ${cfg.sync.mode} "$SRC" "$DEST" \
        ${lib.concatStringsSep " " (map lib.escapeShellArg cfg.sync.extraArgs)}
    '';
  };

  uploadScript = pkgs.writeShellApplication {
    name = "gdrive-upload";
    runtimeInputs = [ cfg.package ];
    text = ''
      if [[ $# -lt 1 ]]; then
        echo "usage: gdrive-upload <local-path>...   (-> ${cfg.remoteName}:${cfg.uploadBase}/)" >&2
        echo "for an arbitrary destination use: rclone copy <src> ${cfg.remoteName}:<path>" >&2
        exit 2
      fi
      for p in "$@"; do
        echo "gdrive-upload: $p -> ${cfg.remoteName}:${cfg.uploadBase}/"
        rclone copy -P "$p" "${cfg.remoteName}:${cfg.uploadBase}/"
      done
    '';
  };
in
{
  options.services.gdrive = {
    enable = lib.mkEnableOption "rclone + Google Drive remote for this user";

    package = lib.mkPackageOption pkgs "rclone" { };

    remoteName = lib.mkOption {
      type = lib.types.str;
      default = "gdrive";
      description = "Name of the rclone remote (used as `<name>:` in commands).";
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        OAuth client_id for your own Google API client. Not secret. Leave empty
        to use rclone's built-in (globally rate-limited) client_id. When set, the
        matching client_secret must be installed at ${secretsDir}/client_secret.
      '';
    };

    scope = lib.mkOption {
      type = lib.types.str;
      default = "drive";
      description = ''
        Drive OAuth scope. "drive" = full access (needed for ad-hoc uploads to
        arbitrary existing folders). "drive.file" = least privilege (rclone only
        sees files it created) — good if this remote is backup-only.
      '';
    };

    uploadBase = lib.mkOption {
      type = lib.types.str;
      default = "uploads";
      description = "Default remote subdir for the `gdrive-upload` helper.";
    };

    sync = {
      enable = lib.mkEnableOption "scheduled `rclone copy` of a local dir to Drive";

      source = lib.mkOption {
        type = lib.types.str;
        example = "/home/elijah/combo-geology-nsl/NSL2-geology-task/models";
        description = "Local directory to push to Drive.";
      };

      dest = lib.mkOption {
        type = lib.types.str;
        example = "gdrive:backups/models";
        description = "Remote destination, `<remote>:path`.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "copy" "sync" ];
        default = "copy";
        description = ''
          "copy" = additive, never deletes on Drive (safe backup).
          "sync" = mirror, deletes remote files no longer present locally.
        '';
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 00/6:00:00";
        description = "systemd OnCalendar expression (default: every 6 hours).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "--fast-list" "--drive-chunk-size=64M" ];
        description = "Extra flags appended to the rclone copy/sync command.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.rclone = {
      enable = true;
      package = cfg.package;
      remotes.${cfg.remoteName} = {
        config = {
          type = "drive";
          scope = cfg.scope;
        } // lib.optionalAttrs (cfg.clientId != "") { client_id = cfg.clientId; };
        # Secrets are FILE PATHS, read at activation time — never in the store.
        secrets = {
          token = "${secretsDir}/token";
        } // lib.optionalAttrs (cfg.clientId != "") {
          client_secret = "${secretsDir}/client_secret";
        };
      };
    };

    # rclone itself comes from programs.rclone; this just adds the helper.
    home.packages = [ uploadScript ];

    systemd.user.services.gdrive-sync = lib.mkIf cfg.sync.enable {
      Unit = {
        Description = "rclone ${cfg.sync.mode}: ${cfg.sync.source} -> ${cfg.sync.dest}";
        # rclone-config.service renders rclone.conf with the gdrive remote.
        Requires = [ "rclone-config.service" ];
        After = [ "rclone-config.service" "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe syncScript;
      };
    };

    systemd.user.timers.gdrive-sync = lib.mkIf cfg.sync.enable {
      Unit.Description = "Timer for gdrive-sync (${cfg.sync.onCalendar})";
      Timer = {
        OnCalendar = cfg.sync.onCalendar;
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
