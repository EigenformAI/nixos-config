# AI tool configuration for OpenCode and Claude Code.
#
# Config sources (checked in order, first match wins):
#   1. ~/dotfiles/ai-tools   — personal overrides (optional)
#   2. ./ai-tools             — in-repo defaults shipped with this flake
#
# To customise: either populate ~/dotfiles/ai-tools (mirrors the structure of
# ./ai-tools) or edit the in-repo defaults directly.
{ config, pkgs, lib, ... }:

{
  home.activation.setupAITools = lib.mkDefault (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    DOTFILES_AI="$HOME/dotfiles/ai-tools"
    REPO_AI="$(dirname "$(readlink -f "${toString ./ai-tools.nix}")")/ai-tools"

    # resolve SRC — prefer dotfiles, fall back to in-repo defaults.
    # Usage: resolve <relative-path>
    # Sets SRC to the first existing path, or empty if neither exists.
    resolve() {
      local rel="$1"
      if [ -e "$DOTFILES_AI/$rel" ]; then
        SRC="$DOTFILES_AI/$rel"
      elif [ -e "$REPO_AI/$rel" ]; then
        SRC="$REPO_AI/$rel"
      else
        SRC=""
      fi
    }

    link_config() {
      local src="$1" dest="$2"
      if [ -n "$src" ] && [ -e "$src" ]; then
        [ -e "$dest" ] || [ -L "$dest" ] && rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        ln -sf "$src" "$dest"
        echo "Linked: $src -> $dest"
      fi
    }

    concat_with_separator() {
      local base="$1" ext="$2" out="$3"
      if [ -n "$base" ] && [ -f "$base" ]; then
        mkdir -p "$(dirname "$out")"
        cat "$base" > "$out"
        if [ -n "$ext" ] && [ -f "$ext" ]; then
          printf '\n\n---\n\n' >> "$out"
          cat "$ext" >> "$out"
        fi
        echo "Generated: $out"
      fi
    }

    # ── OpenCode ──────────────────────────────────────────────────────────
    resolve "opencode/opencode.json"; link_config "$SRC" "$HOME/.config/opencode/opencode.json"
    resolve "shared/skills";          link_config "$SRC" "$HOME/.config/opencode/skills"
    resolve "opencode/agents";        link_config "$SRC" "$HOME/.config/opencode/agents"
    resolve "opencode/commands";      link_config "$SRC" "$HOME/.config/opencode/commands"

    resolve "shared/AI.md";           SHARED_AI="$SRC"
    resolve "opencode/AGENTS.md";     OC_AGENTS="$SRC"
    concat_with_separator "$SHARED_AI" "$OC_AGENTS" "$HOME/.config/opencode/AGENTS.md"

    # ── Claude Code ───────────────────────────────────────────────────────
    resolve "claude-code/settings.json"; link_config "$SRC" "$HOME/.claude/settings.json"
    resolve "shared/skills";             link_config "$SRC" "$HOME/.claude/skills"
    resolve "claude-code/agents";        link_config "$SRC" "$HOME/.claude/agents"

    resolve "shared/AI.md";              SHARED_AI="$SRC"
    resolve "claude-code/CLAUDE.md";     CC_CLAUDE="$SRC"
    concat_with_separator "$SHARED_AI" "$CC_CLAUDE" "$HOME/.claude/CLAUDE.md"
  '');
}
