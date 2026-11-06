# T3 Code headless server. The package and its native dependencies are pinned
# by flake.lock and built before activation. User data remains in ~/.t3.
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

  t3Wrapper = pkgs.writeShellApplication {
    name = "t3-serve-wrapper";
    runtimeInputs = [ pkgs.bun pkgs.nodejs_24 ]
      ++ lib.optional cfg.useTailscaleServe pkgs.tailscale;
    text = ''
      # T3 manages its own authentication and launches loopback OpenCode children.
      unset OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME
      exec ${lib.getExe cfg.package} ${lib.escapeShellArgs serveArgs}
    '';
  };
in
{
  options.services.t3Serve = {
    enable = lib.mkEnableOption "T3 Code headless agent server (`t3 serve`)";
    package = lib.mkPackageOption pkgs "t3code" { };

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
      description = "Port to bind when `useTailscaleServe = false`.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    systemd.user.services.t3-serve = {
      Unit = {
        Description = "T3 Code headless agent server";
        Documentation = [ "https://github.com/pingdotgg/t3code" ];
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ];
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
      Service = {
        Type = "simple";
        ExecStart = "${t3Wrapper}/bin/t3-serve-wrapper";
        Restart = "always";
        RestartSec = 5;
        WorkingDirectory = "%h";
        EnvironmentFile = [ "-%h/.config/ai-tools/secrets.env" ];
        Environment = [
          "HOME=%h"
          "XDG_CONFIG_HOME=%h/.config"
          "XDG_CACHE_HOME=%h/.cache"
          "OPENCODE_CLAUDE_CLI=${pkgs.claude-code}/bin/claude"
          "OPENCODE_ENABLE_EXA=1"
          "CTX7_TELEMETRY_DISABLED=1"
        ];
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
