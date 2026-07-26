# GNOME desktop environment with Pop Shell tiling.
# Designed to be familiar for Ubuntu users while providing tiling window management.
{ config, pkgs, lib, ... }:

{
  # X11/Wayland display server
  services.xserver.enable = true;

  # GNOME desktop environment
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Keyboard: remap Caps Lock to Ctrl (matches your other configs)
  services.xserver.xkb = {
    layout = "us";
    options = "ctrl:nocaps";
  };

  # Remove bloat from GNOME
  environment.gnome.excludePackages = with pkgs; [
    epiphany        # web browser
    geary           # email
    gnome-music
    gnome-tour
    gnome-contacts
    yelp            # help viewer
    cheese          # webcam
    totem           # video player (we have VLC)
  ];

  # GNOME extensions and tools
  environment.systemPackages = with pkgs; [
    # Tiling window management (Pop!_OS style)
    gnomeExtensions.pop-shell

    # Useful GNOME extensions
    gnomeExtensions.appindicator      # system tray icons
    gnomeExtensions.dash-to-dock      # dock (Ubuntu-like)
    gnomeExtensions.blur-my-shell     # aesthetic blur effects
    gnomeExtensions.night-theme-switcher

    # GNOME tools
    gnome-tweaks
    dconf-editor
  ];

  # Enable extensions system-wide via dconf so they are active on first login.
  programs.dconf.profiles.user.databases = [{
    settings = {
      "org/gnome/shell" = {
        enabled-extensions = [
          "pop-shell@system76.com"
          "appindicatorsupport@rgcjonas.gmail.com"
          "dash-to-dock@micxgx.gmail.com"
          "blur-my-shell@aunetx"
          "nightthemeswitcher@romainvigier.fr"
        ];
      };
    };
  }];

  # AppIndicator support (for tray icons - Tailscale, Docker, etc.)
  services.udev.packages = [ pkgs.gnome-settings-daemon ];

  # Audio
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  # Thumbnails
  services.tumbler.enable = true;

  # Auto-mount removable media
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # Printing (useful for a shared workstation)
  services.printing.enable = true;

  # cups-browsed has a known runaway-memory bug: on 2026-07-22 it leaked to
  # 108 GB RSS and starved the box, livelocking a data-gen run for ~16 h
  # (see NSL2-geology-task docs/design/cups-browsed-ram-leak-supervisor-
  # livelock-2026-07-22.md). Cgroup-bound it so systemd OOM-kills and
  # restarts it long before it can pressure the host, while keeping
  # network-printer discovery working.
  systemd.services.cups-browsed.serviceConfig = {
    MemoryHigh = "384M";
    MemoryMax = "512M";
    Restart = "on-failure";
    RestartSec = "30s";
  };
}
