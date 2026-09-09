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
# t3 is distributed on npm, so the unit installs a pinned version into
# ~/.local/state/t3-serve on first start and execs it directly. It deliberately
# does not use `npx`: see the comments in the wrapper below for the two ways
# that hidden cache took the server down silently.
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
    runtimeInputs = [
      pkgs.nodejs_24
      pkgs.bun
      # node-pty (a t3 dependency) publishes prebuilt binaries for darwin and
      # win32 only. On linux-x64 it must be compiled from source, which needs a
      # C++ toolchain and Python on PATH.
      pkgs.node-gyp
      pkgs.gnumake
      pkgs.gcc
      pkgs.python3
    ] ++ lib.optional cfg.useTailscaleServe pkgs.tailscale;
    text = ''
      export NPM_CONFIG_YES=true
      export NPM_CONFIG_LOGLEVEL=warn

      # Install into a directory this module owns rather than letting `npx`
      # manage a hidden tree under ~/.npm/_npx/<hash>. That cache turned out to
      # be the weakest link in the whole service:
      #   - It is written non-atomically. A power cut mid-install (this host
      #     power-cycles itself to recover a wedged GPU) leaves zero-length
      #     files behind. node runs an empty entrypoint as a successful no-op,
      #     so the unit exits 0 — indistinguishable from a clean stop, and
      #     `Restart=on-failure` therefore never fires.
      #   - Every `npx` invocation takes a `concurrency.lock` in that directory.
      #     A lock left behind by a killed process blocks the next start
      #     indefinitely, while systemd still reports the unit as active.
      # A plain prefix install is inspectable, verifiable and repairable.
      PREFIX="$HOME/.local/state/t3-serve"
      ENTRY="$PREFIX/node_modules/t3/dist/bin.mjs"
      PTY="$PREFIX/node_modules/node-pty/build/Release/pty.node"
      STAMP="$PREFIX/.installed-version"
      WANT=${lib.escapeShellArg cfg.t3Version}

      install_t3() {
        echo "t3-serve: installing t3@$WANT into $PREFIX"
        rm -rf "$PREFIX"
        mkdir -p "$PREFIX"
        npm install --prefix "$PREFIX" --no-audit --no-fund "t3@$WANT"
        # node-pty's own `install` script swallows a failed source build, and
        # the damage only surfaces much later as a NodePtyModuleLoadError when
        # the server starts. Build it here, where a failure fails the unit.
        ( cd "$PREFIX/node_modules/node-pty" \
            && node-gyp rebuild --nodedir=${pkgs.nodejs_24} )
        printf '%s' "$WANT" > "$STAMP"
      }

      # Reinstall when the tree is missing, truncated, or the wrong version.
      # `-s` (non-empty) rather than `-e` is the point: it is exactly the
      # zero-length-after-crash case that a plain existence check misses.
      HAVE=$(cat "$STAMP" 2>/dev/null || true)
      if [ ! -s "$ENTRY" ] || [ ! -s "$PTY" ] || [ "$HAVE" != "$WANT" ]; then
        install_t3
      fi

      # Run the entrypoint directly. Going through `npx`/`npm exec` would
      # re-resolve the package against the registry on every start, take the
      # lock described above, and add a process layer that has to be killed
      # twice to stop the server.
      exec node "$ENTRY" ${argString}
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
      default = "0.0.33";
      description = ''
        npm version of `t3` to install and run. Keep this pinned to a known-good
        release: t3 publishes alpha builds frequently, and a bad one picked up
        automatically takes remote access to this host down at exactly the
        moment you are not sitting in front of it. Changing this value triggers
        a reinstall on the next unit start.
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
        # Paired with Restart=always below: retry a genuinely broken install a
        # few times, then stop and stay stopped rather than reinstalling t3 in
        # a tight loop.
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };

      Service = {
        Type = "simple";
        ExecStart = "${t3Wrapper}/bin/t3-serve-wrapper";
        # `always`, not `on-failure`. For a server, exiting 0 is still an
        # outage — and it is the exact shape the corrupted-install bug took:
        # node ran a zero-length entrypoint, exited 0, and on-failure sat there
        # while the host went unreachable.
        Restart = "always";
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
