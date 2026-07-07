# T3 Code headless agent server (`t3 serve`).
#
# T3 Code is an opencode-based coding agent. `t3 serve` runs it headless so you
# can drive it remotely (e.g. from the T3 Code app/CLI on another machine). With
# `useTailscaleServe = true` the server is published over your tailnet with TLS
# via `tailscale serve`, so it is reachable from any device on the tailnet and
# from nowhere else.
#
# This is a home-manager module: `t3 serve` runs as a `systemd --user` service
# so it inherits the user's $HOME (where T3/opencode auth and config live). The
# host must therefore enable lingering for the user (see modules/common/users.nix)
# so the service starts at boot and survives logout.
#
# One-time setup (none of this is expressible in Nix — it's tailnet/host state):
#   1. Admin console: enable HTTPS certificates for the tailnet
#      (https://login.tailscale.com/admin/dns -> "Enable HTTPS").
#      Without this, `tailscale serve --https` hangs on cert provisioning and
#      t3 logs a TailscaleCommandError with exitCode: null.
#   2. Admin console: enable Serve for the tailnet
#      (https://login.tailscale.com/f/serve), else serve reports
#      "Serve is not enabled on your tailnet".
#   3. On the host (the service runs as the user, not root):
#        sudo tailscale up                    # if not already on the tailnet
#        sudo tailscale set --operator=elijah  # let the user run serve/cert without root
# Then `systemctl --user restart t3-serve` and connect from a remote device on
# the tailnet at https://<host>.<tailnet>.ts.net:8443 (default port).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.t3Serve;

  serveArgs =
    if cfg.useTailscaleServe then [
      "serve"
      "--tailscale-serve"
      "--tailscale-serve-port"
      (toString cfg.tailscaleServePort)
    ] else [
      "serve"
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
    ];

  argString = lib.concatStringsSep " " (map lib.escapeShellArg serveArgs);

  t3Wrapper = pkgs.writeShellApplication {
    name = "t3-serve-wrapper";
    runtimeInputs = [ pkgs.nodejs_24 pkgs.bun ] ++ lib.optional cfg.useTailscaleServe pkgs.tailscale;
    text = ''
      export NPM_CONFIG_YES=true
      export NPM_CONFIG_LOGLEVEL=warn
      # Pre-warm the npx cache so the first real run doesn't hang on download.
      npx -y t3@${cfg.t3Version} --version >/dev/null 2>&1 || true
      exec npx -y t3@${cfg.t3Version} ${argString}
    '';
  };
in
{
  options.services.t3Serve = {
    enable = lib.mkEnableOption "T3 Code headless agent server (`t3 serve`)";

    useTailscaleServe = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bind the server via `tailscale serve`, exposing it over the tailnet with TLS.
        When false, bind to `host`:`port` directly.
      '';
    };

    tailscaleServePort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Port for `--tailscale-serve` to listen on (HTTPS).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host to bind when `useTailscaleServe = false`.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
      description = "Port to bind when `useTailscaleServe = false` (T3 Code default 3773).";
    };

    t3Version = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = ''
        npm tag or version of `t3` to run via `npx`. Pin to a specific version
        once you have a known-good build to avoid alpha churn.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.t3-serve = {
      Unit = {
        Description = "T3 Code headless agent server (npx t3 serve)";
        Documentation = [ "https://github.com/pingdotgg/t3code/blob/main/REMOTE.md" ];
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${t3Wrapper}/bin/t3-serve-wrapper";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = "%h";
        Environment = [
          "HOME=%h"
          "XDG_CONFIG_HOME=%h/.config"
          "XDG_CACHE_HOME=%h/.cache"
        ];
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
