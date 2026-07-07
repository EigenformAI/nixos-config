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

  # GPU1 di/dt prevention — phase A (docs/design/gpu1-auto-recovery-2026-06-11.md).
  # Force NVIDIA dynamic power management OFF so the dGPU never drops into the deep
  # low-power idle state whose load->idle power collapse triggers GPU1's Xid 79.
  # Rationale: the di/dt clock-lock above pins CLOCKS but not POWER DRAW — at
  # utilization 0 power still collapses ~350W->idle, so clock-locks cannot stop the
  # load-stop transient (confirmed 2026-06-11). Disabling dynamic PM keeps the rails
  # from bottoming out. One reported case had this *consistently* stop the idle
  # fall-off. Takes effect on the next driver load (the next cold cycle that recovers
  # GPU1) — it does NOT touch the currently running driver/fleet.
  # NOTE: GSP-firmware disable (NVreg_EnableGpuFirmware=0), which fixed some other
  # reports, is INCOMPATIBLE with `open = true` above, so it is deliberately omitted.
  boot.extraModprobeConfig = ''
    options nvidia NVreg_DynamicPowerManagement=0x00
  '';

  # Persistent 350 W power cap on both RTX 4090s, plus a di/dt clock-lock on
  # GPU1 only.
  #
  # Power caps: GPU0 stays at 350 W, GPU1 raised to stock 450 W (2026-06-17).
  # The 350 W cap originally trimmed the sub-millisecond transient envelope to
  # keep a marginal supply within regulation (docs/design/gpu-disconnect-2026-05-07.md).
  # v8 localized the disconnect to the FSP+octopus power chain (the fault followed
  # it to GPU0), exonerating the GPU1 board — so GPU1, now on the modern Seasonic
  # + native 12VHPWR, no longer needs the trim and runs at stock 450 W. GPU0 stays
  # capped while it remains on the marginal FSP chain.
  #
  # GPU1 clock-lock (2026-06-10): every Xid 79 on this host is GPU1 (0b:00.0),
  # and the drops cluster around P-state TRANSITIONS — minutes after load stops
  # (P0->P8 down-transition) or early in a run — not during steady load (matches
  # Arch BBS 313284 + NVIDIA open-gpu-kernel-modules #900). Pinning GPU1's memory
  # clock (10501) and raising its graphics-clock floor (1200) keeps it out of the
  # deep idle state, so it stops making those transitions. Boost ceiling stays at
  # 3120 and the 350 W cap bounds peak current, so there is no throughput loss —
  # only ~+30 W idle on GPU1. GPU0 is healthy and left untouched (the control for
  # the experiment). If this lifts GPU1 MTBF from ~daily to multi-day it is both
  # diagnosis and mitigation; if not, escalate to the hardware localization
  # (reseat / de-riser / slot swap).
  systemd.services.nvidia-power-limit = {
    description = "GPU0 350W + GPU1 450W power caps + GPU1 di/dt clock-lock (4090 disconnect mitigation)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    unitConfig.ConditionPathExists = "/dev/nvidia0";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nvidia-power-limit" ''
        set -eu
        SMI=${config.hardware.nvidia.package.bin}/bin/nvidia-smi
        # `|| true` on every line so a single downed/fallen-off GPU (GPU0 is now
        # the chronic dropper) can't abort the script under `set -eu` and leave
        # the surviving GPU without its cap/clock-lock. BDFs (not indices) because
        # nvidia-smi renumbers indices when a GPU is off the bus.
        "$SMI" -pm 1 || true
        "$SMI" -pl 350 -i 0000:05:00.0 || true   # GPU0 stays 350W (marginal FSP+octopus chain)
        "$SMI" -pl 450 -i 0000:0B:00.0 || true   # GPU1 stock 450W (good Seasonic chain, exonerated 2026-06-17)
        # GPU1 (0000:0B:00.0) di/dt mitigation — pin memory + raise graphics
        # floor so it stops the idle<->load transitions its Xid 79s cluster
        # around. `|| true` so a future driver dropping -lmc/-lgc support can't
        # wedge boot (set -eu is in effect).
        "$SMI" -i 0000:0B:00.0 -lmc 10501     || true
        "$SMI" -i 0000:0B:00.0 -lgc 1200,3120 || true
      '';
    };
  };
}
