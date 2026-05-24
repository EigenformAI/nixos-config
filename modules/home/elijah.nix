# Elijah's personal home-manager profile.
#
# The shared DX layer (dx.nix) and AI tool configs (ai-tools.nix) are applied
# automatically via sharedModules in flake.nix. This file adds: git identity,
# dotfiles symlinks, and personal preferences (themes, keybindings, prompt).
#
# Other users: copy this file, change the username/identity, and remove the
# parts you don't need. Register your profile in flake.nix under hmUsers.
{ config, pkgs, lib, ... }:

{
  imports = [
    ./nsl2-resume.nix
  ];

  home = {
    username = "elijah";
    homeDirectory = "/home/elijah";
    packages = with pkgs; [
      zsh-powerlevel10k

      # Neovim and its dependencies
      neovim
      lua5_1
      luarocks
      imagemagick  # image.nvim
    ];

    # Symlink dotfiles-managed configs.
    # Source of truth lives in ~/dotfiles so configs can be edited without a
    # home-manager rebuild. If ~/dotfiles is missing, the corresponding feature
    # falls back to defaults (e.g. p10k runs its configuration wizard).
    activation.linkDotfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DOTFILES_DIR="$HOME/dotfiles"

      link_config() {
        local src="$1"
        local dest="$2"
        if [ -e "$src" ]; then
          if [ -e "$dest" ] || [ -L "$dest" ]; then
            rm -rf "$dest"
          fi
          mkdir -p "$(dirname "$dest")"
          ln -sf "$src" "$dest"
          echo "Linked: $src -> $dest"
        else
          echo "Warning: Source not found, skipping: $src"
        fi
      }

      link_config "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"
      link_config "$DOTFILES_DIR/nixos-config/modules/shared/config/p10k.zsh" "$HOME/.p10k.zsh"
    '';
  };

  programs = {
    # ── Zsh — powerlevel10k prompt ───────────────────────────────────────
    # The p10k config file (~/.p10k.zsh) is symlinked from dotfiles in the
    # activation hook above. Sourcing it from initContent makes the prompt
    # "just work" after login without invoking `p10k configure`.
    zsh = {
      plugins = [
        {
          name = "powerlevel10k";
          src = pkgs.zsh-powerlevel10k;
          file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
        }
      ];

      initContent = lib.mkAfter ''
        # Load p10k config (symlinked from ~/dotfiles by home-manager activation)
        [[ -f $HOME/.p10k.zsh ]] && source $HOME/.p10k.zsh

        # Personal aliases
        alias notion-cat="uv run $HOME/dotfiles/scripts/notion_cat.py"
        alias ncat="notion-cat"
      '';
    };

    # ── Git — identity ───────────────────────────────────────────────────
    git.settings = {
      user.name = "0xEljh";
      user.email = "elijahng96@gmail.com";
      credential.helper = "${pkgs.gh}/bin/gh auth git-credential";
    };

    # ── Vim — airline, keybindings, 2-space tabs ─────────────────────────
    vim = {
      plugins = with pkgs.vimPlugins; [
        vim-airline
        vim-airline-themes
        vim-startify
        vim-tmux-navigator
      ];
      settings = { relativenumber = true; };
      extraConfig = ''
        set relativenumber
        set rnu
        set shiftwidth=2
        set softtabstop=2
        let g:airline_theme='bubblegum'
        let g:airline_powerline_fonts = 1
        let mapleader=","
        let maplocalleader=" "
        nnoremap j gj
        nnoremap k gk
        nnoremap <leader>q :q<cr>
        nnoremap <C-h> <C-w>h
        nnoremap <C-j> <C-w>j
        nnoremap <C-k> <C-w>k
        nnoremap <C-l> <C-w>l
        nnoremap Y y$
        nnoremap <tab> :bnext<cr>
        nnoremap <S-tab> :bprev<cr>
        cmap w!! w !sudo tee % >/dev/null
      '';
    };

    # ── Tmux — gold theme, C-x prefix, custom bindings ──────────────────
    tmux = {
      prefix = "C-x";
      plugins = with pkgs.tmuxPlugins; [
        vim-tmux-navigator
        prefix-highlight
        {
          plugin = power-theme;
          extraConfig = ''
            set -g @tmux_power_theme 'gold'
          '';
        }
      ];
      extraConfig = ''
        set -g prefix2 C-b
        bind-key -T prefix C-b send-prefix -2

        unbind '"'
        unbind %

        bind-key x split-window -v
        bind-key v split-window -h

        bind-key -n M-k select-pane -U
        bind-key -n M-h select-pane -L
        bind-key -n M-j select-pane -D
        bind-key -n M-l select-pane -R

        # vim-tmux-navigator: seamless C-hjkl navigation across vim/tmux
        is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
          | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
        bind-key -n 'C-h' if-shell "$is_vim" 'send-keys C-h'  'select-pane -L'
        bind-key -n 'C-j' if-shell "$is_vim" 'send-keys C-j'  'select-pane -D'
        bind-key -n 'C-k' if-shell "$is_vim" 'send-keys C-k'  'select-pane -U'
        bind-key -n 'C-l' if-shell "$is_vim" 'send-keys C-l'  'select-pane -R'
        tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'
        if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
          "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\'  'select-pane -l'"
        if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
          "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\\\'  'select-pane -l'"

        bind-key -T copy-mode-vi 'C-h' select-pane -L
        bind-key -T copy-mode-vi 'C-j' select-pane -D
        bind-key -T copy-mode-vi 'C-k' select-pane -U
        bind-key -T copy-mode-vi 'C-l' select-pane -R
        bind-key -T copy-mode-vi 'C-\\' select-pane -l

        set -s extended-keys on
        set -s user-keys[0] "\x1b[13;2u"
        bind-key -n User0 send-keys Escape "[13;2u"

        set -g @yank_action 'copy-pipe-no-clear'
        bind -T copy-mode MouseDown1Pane select-pane \; send-keys -X clear-selection
        bind -T copy-mode-vi MouseDown1Pane select-pane \; send-keys -X clear-selection
        bind -T copy-mode DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-pipe-no-clear
        bind -T copy-mode-vi DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-pipe-no-clear
        bind -n DoubleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-word \; send-keys -X copy-pipe-no-clear
        bind -T copy-mode TripleClick1Pane select-pane \; send-keys -X select-line \; send-keys -X copy-pipe-no-clear
        bind -T copy-mode-vi TripleClick1Pane select-pane \; send-keys -X select-line \; send-keys -X copy-pipe-no-clear
        bind -n TripleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-line \; send-keys -X copy-pipe-no-clear
        bind-key M-r run-shell "rm -rf $HOME/.cache/tmux/resurrect/*" \; display-message "Resurrect data cleared"
      '';
    };

    # ── Kitty — Catppuccin theme, keybindings ────────────────────────────
    kitty = {
      themeFile = "Catppuccin-Mocha";
      settings = {
        confirm_os_window_close = 0;
        background_opacity = "0.90";
        window_padding_width = 8;
        inactive_text_alpha = "0.80";
        inactive_border_color = "#1e1e2e";
        active_border_color = "#cba6f7";
        tab_bar_edge = "top";
        tab_bar_min_tabs = 2;
        tab_title_template = "{index}:{title}";
        active_tab_foreground = "#1e1e2e";
        active_tab_background = "#a6e3a1";
      };
      keybindings = {
        "ctrl+shift+enter" = "new_os_window_with_cwd";
        "ctrl+shift+t" = "new_tab_with_cwd";
        "alt+h" = "neighbor left";
        "alt+l" = "neighbor right";
        "alt+k" = "neighbor up";
        "alt+j" = "neighbor down";
        "ctrl+]" = "next_tab";
        "ctrl+[" = "previous_tab";
        "ctrl+shift+c" = "copy_to_clipboard";
        "ctrl+shift+v" = "paste_from_clipboard";
        "shift+enter" = "send_text all \\x1b[13;2u";
      };
    };

    # ── SSH — include external config ────────────────────────────────────
    ssh = {
      enableDefaultConfig = false;
      includes = [
        "${config.home.homeDirectory}/.ssh/config_external"
      ];
    };
  };
}
