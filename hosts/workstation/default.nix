# Full workstation configuration for limiting-factor.
# GNOME desktop + Pop Shell tiling, 2x RTX 4090, CUDA, Docker + GPU passthrough.
# Use: nixos-rebuild switch --flake .#limiting-factor
{ config, pkgs, lib, ... }:
let
  # PiKVM cold-cycle arm hook for the GPU watchdog (services.gpuWatchdog.
  # coldCycle.method = "external"). On a GPU1 drop in cold-cycle mode the
  # watchdog runs this BEFORE powering off: it SSHes to the PiKVM (kipperpikvm
  # on the tailnet) and runs /root/gpu-watchdog-arm.sh, which pre-flights KVMD
  # and schedules a revive job that presses ATX power once the box reaches S5.
  # Exit 0 (PIKVM_ARMED) ⇒ safe to power off; nonzero ⇒ the watchdog holds
  # (onArmFailure) rather than stranding the box. The SSH key + known_hosts live
  # under /var/lib/gpu-watchdog (root-only, outside the nix store). Setup and
  # validation steps: docs/design/gpu1-auto-recovery-2026-06-11.md.
  pikvmColdCycleArm = pkgs.writeShellScript "pikvm-coldcycle-arm" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.openssh pkgs.coreutils pkgs.gnugrep ]}
    KEY=/var/lib/gpu-watchdog/pikvm_id_ed25519
    KH=/var/lib/gpu-watchdog/known_hosts
    HOST=100.85.243.18
    out=$(ssh -i "$KEY" -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes -o ConnectTimeout=8 root@"$HOST" '/root/gpu-watchdog-arm.sh' 2>&1)
    rc=$?
    echo "[pikvm-arm] rc=$rc: $out" >&2
    [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PIKVM_ARMED
  '';
in
{
  imports = [
    ../../hardware-configuration.nix
    ../../modules/common
    ../../modules/common/users.nix
    ../../modules/common/remote-access.nix
    ../../modules/common/telegram-notify.nix
    ../../modules/common/gpu-watchdog.nix
    ../../modules/common/t3-pair-notify.nix
    ./gpu.nix
    ./gui.nix
    ./power.nix
  ];

  # GPU disconnect stopgap (docs/design/gpu-watchdog-2026-05-24.md).
  # Remove these two enables once the Tier-1 cable swap restores multi-day MTBF
  # (see docs/design/gpu1-remediation-2026-05-24.md).
  services.telegramNotify.enable = true;
  services.gpuWatchdog = {
    enable = true;
    # Path to the nsl2 active-run state file. Surfaces "what run is being
    # resumed" inside the back-online Telegram message after a watchdog
    # reboot. Hardcoded to elijah since this is a single-user workstation.
    resumeStatePath = "/home/elijah/.local/state/nsl2/active-run";

    # Cold-cycle recovery via the PiKVM (replaces the warm reboot that leaves
    # GPU1 un-enumerated). On a drop the watchdog arms the PiKVM to press ATX
    # power once the box is in S5, then powers off — a true cold cycle that
    # re-inits GPU1. Whether it fires automatically is still gated by the mode
    # file (hold|auto); enable = false reverts to a warm reboot.
    coldCycle = {
      enable = true;
      method = "external";
      externalArmCommand = "${pikvmColdCycleArm}";
    };

    # Flip the watchdog's recovery mode from Telegram: /auto /hold /recover
    # /status (admin), /id (anyone, prints your chat id). The control loop only
    # writes the mode file — the privileged reboot stays in gpu-watchdog. Both
    # registered chats are admins.
    telegramControl = {
      enable = true;
      adminChatIds = [ 302828184 448383615 ];

      # /t3pair: re-mint + DM a fresh `t3 serve` pairing link on demand. Locked
      # to elijah's chat only (NOT the full adminChatIds) — a pairing link is
      # admin/code-exec on the agent. Provided by services.t3PairNotify below.
      t3Pair = {
        enable = true;
        chatId = 448383615;
      };
    };
  };

  # Deliver `t3 serve` pairing links to Telegram (modules/common/t3-pair-notify.nix).
  # t3 mints a fresh, single-use, 5-min, admin-scoped pairing token on every
  # start and only prints it to the console — unusable on a headless box that
  # reboots for GPU recovery. This reads the token from t3's SQLite and DMs the
  # TAILNET pairing URL to elijah: once after boot if unpaired (sessions last 30
  # days, so this is quiet once paired), or on demand via /t3pair (re-minting).
  # Reachability is still gated by tailscale/LAN; Telegram delivery is the
  # convenience layer, not the security boundary.
  services.t3PairNotify = {
    enable = true;
    chatId = 448383615;
    dbPath = "/home/elijah/.t3/userdata/state.sqlite";
    pairUrl = {
      scheme = "http";                          # services.t3Serve binds plain HTTP
      host = "limiting-factor.tail6ee1b.ts.net"; # tailnet FQDN, not the LAN IP
      port = 3773;
    };
    restart = {
      machine = "elijah@.host";                 # t3-serve is elijah's user unit
      unit = "t3-serve.service";
    };
  };

  networking.hostName = "limiting-factor";

  # Boot
  boot.loader.systemd-boot = {
    enable = lib.mkDefault true;
    configurationLimit = 42;
  };
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Placeholder filesystem - hardware-configuration.nix will override
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Spare 2T NVMe (label "2T") used for bulk data / archived run snapshots.
  # `nofail` + a short device timeout so a missing or unhealthy spare disk
  # never blocks boot (it is non-essential, not on the root path).
  fileSystems."/mnt/data2t" = {
    device = "/dev/disk/by-uuid/1d653f23-fd54-4373-904d-72cd34341136";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Docker with GPU support.
  # `cdi-spec-dirs` must include `/var/run/cdi` because the upstream
  # `nvidia-container-toolkit-cdi-generator.service` writes its spec to
  # `/run/cdi/nvidia-container-toolkit.json` (via the unit's `RuntimeDirectory=cdi`).
  # Omitting it makes Docker blind to the generated spec and `--device
  # nvidia.com/gpu=all` fails with "unresolvable CDI devices". This list
  # matches Docker's own default; we just spell it out for clarity.
  #
  # `default-address-pools` overrides Docker's built-in pools (which top
  # out at ~31 usable /20 user bridge networks — enough for ~10 slots in
  # nsl2's thread-per-slot generator, then `all predefined address pools
  # have been fully subnetted`). Replacing with 10.0.0.0/8 at size=24
  # yields 65,536 /24 subnets (254 hosts each), so the practical ceiling
  # becomes CPU/RAM rather than IP space. Safe to drop in: existing
  # networks keep their current subnets until recreated.
  virtualisation.docker = {
    enable = true;
    logDriver = "json-file";
    daemon.settings = {
      features.cdi = true;
      "cdi-spec-dirs" = [ "/etc/cdi" "/var/run/cdi" ];
      default-address-pools = [
        { base = "10.0.0.0/8"; size = 24; }
      ];
    };
  };

  # Networking
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # Additional workstation packages
  environment.systemPackages = with pkgs; [
    # System tools
    parted
    gptfdisk
    lshw
    rsync
    rclone

    # Development
    gnumake
    cmake

    # Media / productivity
    vlc
    google-chrome
    xclip
    wl-clipboard

    # Monitoring
    nvtopPackages.nvidia
    lm_sensors
  ];

  # Enable envfs for compatibility with scripts expecting /usr/bin/env
  services.envfs.enable = true;

  # Syncthing for file sync
  services.syncthing = {
    enable = true;
    user = "elijah";
    dataDir = "/home/elijah";
    configDir = "/home/elijah/.config/syncthing";
    openDefaultPorts = true;
  };
}
