# User definitions for limiting-factor.
#
# To add yourself, create an entry in users.users below and (optionally) a
# home-manager profile in modules/home/<you>.nix — see modules/home/elijah.nix
# as an example. Then register it in flake.nix under hmUsers.
{ pkgs, lib, ... }:

{
  # ── Elijah ─────────────────────────────────────────────────────────────
  users.users.elijah = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Elijah";
    extraGroups = [ "wheel" "docker" "video" "render" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDlOVZ9KcD3aokJ6r9ex0c1eOJX72eiQvY8eDlcQolqh"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJhFpUfIbtvUjCO15YjsuyN9PjFLgNegURfmGoyJjEOV"
    ];
    initialPassword = "admin";
    # Lets `systemd --user` (and the nsl2-resume.service unit) start pre-login
    # so a reboot during a training run is auto-resumed without a desktop session.
    linger = true;
  };

  # ── Jennifer ───────────────────────────────────────────────────────────
  users.users.jennifer = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Jennifer";
    extraGroups = [ "wheel" "docker" "video" "render" ];
    initialPassword = "admin";
  };

  # ── Akira ─────────────────────────────────────────────────────────────
  users.users.akira = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Akira";
    extraGroups = [ "wheel" "docker" "video" "render" ];
    initialPassword = "admin";
  };

  # ── Michael ────────────────────────────────────────────────────────────
  users.users.michael = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Michael";
    extraGroups = [ "wheel" "docker" "video" "render" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP46GqmI1zYmmcAXtZk2XriAYSDmZX6N9LPiRt+JfB3y"
    ];
    initialPassword = "admin";
  };

  # Remove or extend once the machine is stable.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDlOVZ9KcD3aokJ6r9ex0c1eOJX72eiQvY8eDlcQolqh"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJhFpUfIbtvUjCO15YjsuyN9PjFLgNegURfmGoyJjEOV"
  ];

  users.users.root.initialPassword = "admin";

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };
}
