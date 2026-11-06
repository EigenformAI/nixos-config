# CLI tools and development packages shared across all users.
# Imported by modules/home/dx.nix as the shared home-manager package set.
#
# Only include tools that any developer on this machine should have
# out of the box.  Personal tools (editor plugins, themes) belong in
# individual user profiles (e.g. modules/home/elijah.nix).
{ pkgs }:

with pkgs; [
  # Shell and terminal
  bash-completion
  bat
  btop
  coreutils
  eza
  fd
  fzf
  jq
  killall
  fastfetch
  nushell
  ouch
  ripgrep
  tree
  unzip
  zip
  zoxide
  atuin
  difftastic
  lazygit

  # Encryption and security
  age
  gnupg
  magic-wormhole
  openssh

  # Git
  gh

  # Cloud / containers
  docker
  docker-compose

  # Node.js / JS
  nodejs_24
  bun

  # C / C++
  gcc
  gnumake
  cmake

  # Python
  python3
  uv
  ruff
  pyright

  # Data transfer
  aria2
  pv

  # Media
  ffmpeg

  # AI / LLM
  claude-code
  ollama
  opencode

  # Misc dev tools
  direnv
  sqlite
]
