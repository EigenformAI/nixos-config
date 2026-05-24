# NVIDIA GPU configuration for 2x RTX 4090.
# Proprietary drivers + CUDA toolkit + container toolkit for Docker GPU passthrough.
{ config, pkgs, lib, ... }:

{
  # NVIDIA proprietary drivers
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.nvidia = {
    # Use the production driver branch (latest stable)
    package = config.boot.kernelPackages.nvidiaPackages.production;

    # Modesetting is required for Wayland and most compositors
    modesetting.enable = true;

    # Power management - disable for a workstation (always on)
    powerManagement.enable = false;

    # Enable the open-source kernel module (supported on RTX 4090, Turing+)
    # Set to false if you encounter issues; proprietary fallback is always safe
    open = true;

    # nvidia-settings GUI for driver tuning
    nvidiaSettings = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];

  # CUDA toolkit available system-wide
  environment.systemPackages = with pkgs; [
    cudatoolkit
  ];

  # CUDA environment variables
  environment.variables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
  };

  # NVIDIA container toolkit for Docker GPU passthrough.
  # This enables the upstream `nvidia-container-toolkit-cdi-generator.service`,
  # which writes `/run/cdi/nvidia-container-toolkit.json` on boot (the unit
  # declares `RuntimeDirectory=cdi`, and ordering is `after =
  # systemd-udev-settle.service` so it waits for the kernel module to appear).
  # Make sure `virtualisation.docker.daemon.settings."cdi-spec-dirs"` includes
  # `/var/run/cdi` (see hosts/workstation/default.nix) — otherwise Docker
  # silently never sees the generated spec.
  # Do NOT add a manual nvidia-cdi-generator service on top — it duplicates
  # the work and races against driver load on first boot.
  hardware.nvidia-container-toolkit.enable = true;

  # nix-ld libraries for CUDA applications (python wheels, etc.)
  programs.nix-ld.libraries = with pkgs; [
    cudatoolkit
    cudatoolkit.lib
    libglvnd
    linuxPackages.nvidia_x11
  ];

  # Kernel parameters for multi-GPU stability
  boot.kernelParams = [
    "nvidia-drm.modeset=1"
    "nvidia-drm.fbdev=1"
  ];

  # Persistent 350 W power cap on both RTX 4090s.
  # Mitigates the load-induced Xid 79 "GPU has fallen off the bus" disconnects
  # documented in docs/design/gpu-disconnect-2026-05-07.md (Phase 4c validated
  # the cap end-to-end with a full training run). Default per-card limit is
  # 450 W; capping at 350 W trims the sub-millisecond transient envelope
  # enough to keep PSU/12VHPWR within regulation. Does NOT address the
  # idle-disconnect mechanism (suspected GPU1 12VHPWR connector) — that needs
  # a physical inspection / reseat.
  systemd.services.nvidia-power-limit = {
    description = "Apply 350W power cap to NVIDIA GPUs (4090 disconnect mitigation)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    unitConfig.ConditionPathExists = "/dev/nvidia0";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nvidia-power-limit" ''
        set -eu
        SMI=${config.hardware.nvidia.package.bin}/bin/nvidia-smi
        "$SMI" -pm 1
        "$SMI" -pl 350 -i 0
        "$SMI" -pl 350 -i 1
      '';
    };
  };
}
