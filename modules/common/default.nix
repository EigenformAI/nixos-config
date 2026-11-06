{ pkgs, lib, ... }:

{
  # Nixpkgs configuration
  nixpkgs.config = {
    allowUnfree = true;
    cudaSupport = true;
  };

  nix = {
    settings = {
      allowed-users = [ "@wheel" ];
      trusted-users = [ "@wheel" ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://cache.numtide.com"
        "https://cache.nixos-cuda.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
    };
    package = pkgs.nix;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Timezone - adjust as needed
  time.timeZone = lib.mkDefault "Asia/Singapore";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";

  # Essential system packages (available to all users)
  environment.systemPackages = with pkgs; [
    curl
    git
    inetutils
    tmux
    vim
    wget
    htop
    pciutils
    usbutils
  ];

  # Enable zsh system-wide
  programs.zsh.enable = true;

  # Docker daemon (CLI tools are in packages.nix via home-manager)
  virtualisation.docker.enable = true;

  # nix-ld for running unpatched binaries (python wheels, etc.)
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
      glib
      libglvnd
    ];
  };

  # Fonts

  fonts = {
   packages = with pkgs; [
   	dejavu_fonts
    noto-fonts
    noto-fonts-color-emoji
    meslo-lgs-nf
    nerd-fonts.jetbrains-mono
    noto-fonts-cjk-sans
    ];
    
    fontconfig.defaultFonts = {
      monospace = [ "MesloLGS NF" "JetBrainsMono Nerd Font"];
      sansSerif = [ "Noto Sans" ];
      serif = [ "Noto Serif" ];
    };
  };

  system.stateVersion = "24.11";
}
