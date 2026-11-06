{
  description = "NixOS configurations for limiting-factor (GPU workstation)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/c403d6fe45676177be10aa74643c4c06bf927d5f";
    # Keep the reviewed Linux 6.18 / NVIDIA R595 combination pinned together.
    nixpkgs-gpu.url = "github:nixos/nixpkgs/c403d6fe45676177be10aa74643c4c06bf927d5f";
    home-manager = {
      url = "github:nix-community/home-manager/b787c48e2ec57a9d098f5c2721882a3bc1e16f97";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix/38235de70aec5e5ca95070e8e020be0f31cd8c03";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dotfiles = {
      url = "github:0xEljh/dotfiles/e728dc90786f25e4e302aa0d2b6a6db0a778e194";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, llm-agents, dotfiles, ... } @inputs:
    let
      system = "x86_64-linux";

      # Share the reviewed runtime libraries while retaining upstream agent packages.
      ai-tools-overlay = final: prev: {
        # Keep CUDA 12 for existing projects rather than adopting a new major.
        cudatoolkit = final.cudaPackages_12.cudatoolkit;
        ollama = prev.ollama.override { cudaPackages = final.cudaPackages_12; };
        llm-agents = llm-agents.packages.${system};
        claude-code = final.llm-agents.claude-code;
        opencode = final.callPackage "${dotfiles}/nixos-config/packages/opencode-buffered" {
          opencode = final.llm-agents.opencode;
        };
        t3code = final.llm-agents.t3code.override {
          providerPackages = [ final.claude-code final.opencode ];
          t3code-unwrapped = final.llm-agents.t3code.unwrapped.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./patches/t3-preview-browser-security.patch ];
          });
        };
      };

      # ── Home-manager user profiles ───────────────────────────────────────
      # Each user imports the shared DX layer (modules/home/dx.nix) and adds
      # their personal config on top.  To add a new user:
      #   1. Create modules/home/<you>.nix  (see elijah.nix as a template)
      #   2. Add an entry to users.nix
      #   3. Add your username here
      hmUsers = {
        elijah = { pkgs, ... }: {
          imports = [
            ./modules/home/elijah.nix
            "${dotfiles}/nixos-config/modules/shared/ai-tools.nix"
          ];
          home.packages = [
            (pkgs.callPackage "${dotfiles}/nixos-config/packages/context7-cli" { })
            (pkgs.callPackage "${dotfiles}/nixos-config/packages/playwright-cli" { })
            pkgs.python3Packages.huggingface-hub
          ];
        };
        jennifer = import ./modules/home/jennifer.nix;
        akira = import ./modules/home/akira.nix;
        michael = import ./modules/home/michael.nix;
      };

      hmModule = {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "backup";
          overwriteBackup = true;
          sharedModules = [
            ./modules/home/dx.nix
            ./modules/home/ai-tools.nix
          ];
          users = hmUsers;
        };
      };
    in
    {
      nixosConfigurations = {
        # ── Bootstrap ──────────────────────────────────────────────────────
        # Minimal config for initial NixOS install and emergency/debug use.
        # No GUI, no CUDA — fast to evaluate and small closure.
        #   nixos-rebuild switch --flake .#bootstrap
        bootstrap = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = inputs;
          modules = [
            { nixpkgs.overlays = [ ai-tools-overlay ]; }
            home-manager.nixosModules.home-manager
            hmModule
            ./hosts/bootstrap
          ];
        };

        # ── Full workstation ───────────────────────────────────────────────
        # GNOME + Pop Shell tiling, 2x RTX 4090, CUDA, Docker GPU passthrough.
        #   nixos-rebuild switch --flake .#limiting-factor
        limiting-factor = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = inputs;
          modules = [
            { nixpkgs.overlays = [ ai-tools-overlay ]; }
            home-manager.nixosModules.home-manager
            hmModule
            ./hosts/workstation
          ];
        };
      };

      # Dev shell for working on this config
      devShells.${system}.default = let
        pkgs = nixpkgs.legacyPackages.${system};
      in pkgs.mkShell {
        nativeBuildInputs = with pkgs; [ git ];
      };
    };
}
