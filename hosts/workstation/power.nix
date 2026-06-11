# Power policy for limiting-factor: never sleep.
#
# This is a GPU workstation running long training/inference jobs. Unintended
# suspend mid-run is costly (wasted hours, half-written checkpoints, Docker
# containers in weird states). We enforce "always on" at two layers:
#
#   1. GNOME settings-daemon — stop it from ever *requesting* a suspend, and
#      make the Settings > Power panel reflect "Never" so the UI matches
#      reality.
#   2. systemd — mask the sleep/suspend/hibernate targets so nothing (not even
#      a misbehaving app calling `systemctl suspend` directly, and not even
#      logind's IdleAction) can transition the box into a low-power state.
#
# Poweroff and reboot are unaffected.
{ config, pkgs, lib, ... }:

{
  # ── Layer 1: GNOME ──────────────────────────────────────────────────────────
  # Merges with the dconf database in gui.nix via nix list concat.
  programs.dconf.profiles.user.databases = [{
    settings = {
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-ac-timeout = lib.gvariant.mkUint32 0;
        sleep-inactive-battery-type = "nothing";
        sleep-inactive-battery-timeout = lib.gvariant.mkUint32 0;
        idle-dim = false;
      };
      "org/gnome/desktop/session" = {
        # 0 = never go idle. Screen lock is a separate setting (screensaver).
        idle-delay = lib.gvariant.mkUint32 0;
      };
    };
  }];

  # ── Layer 2: systemd ────────────────────────────────────────────────────────
  # Disabling the targets makes `systemctl suspend` (and any DBus call that
  # ultimately triggers them) a no-op.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Logind: don't suspend on idle; ignore lid-switch (harmless on a desktop,
  # but belt-and-suspenders if this config ever runs on a laptop).
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  # ── Hardware watchdog (SP5100 TCO) ─────────────────────────────────────────
  # The AMD chipset TCO watchdog is already loaded (sp5100_tco). We arm only
  # the *reboot* phase: if a `systemctl reboot` command can't complete its
  # shutdown sequence within 30s, the chipset forces a hardware-level reset.
  #
  # Motivation: the gpu-watchdog stopgap fires `systemctl reboot --force`
  # when an Xid 79/154 lands. In practice that has sometimes wedged before
  # power-cycling — leaving us to press the physical reset button. The TCO
  # watchdog is the only mechanism here that survives a stuck PCIe domain
  # or a kernel that has lost its grip, because the reset is signalled from
  # the southbridge, not from the CPU.
  #
  # We deliberately do NOT enable `runtimeTime` (heartbeat during normal
  # operation). It would catch a fully-wedged kernel but adds a periodic
  # wake; not worth it while Xid events still produce log lines that the
  # userspace watchdog can act on. If we ever see a wedge that produces
  # *no* Xid trail, layer it on then.
  #
  # 30s is a balance: long enough for systemd to flush filesystems and stop
  # remaining units after `--force` (which itself only SIGKILLs userspace
  # — the kernel still does the orderly unmount/remount-ro phase); short
  # enough that a stuck shutdown doesn't sit indefinitely.
  # (Renamed from the deprecated `systemd.watchdog.rebootTime` in 26.05.)
  systemd.settings.Manager.RebootWatchdogSec = "30s";
}
