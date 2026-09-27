#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"

remove_own_link() {
  local link="$1" target="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    rm -- "$link"
  fi
}

remove_own_link "$HOME/.local/bin/db-studio" "$plugin_dir/bin/db-studio"
skill_dir="$plugin_dir/skills/db-studio"
skill_dirs=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
  "$HOME/.codex/skills"
  "$HOME/.pi/agent/skills"
  "$HOME/.hermes/skills"
)
if [[ -d "$HOME/.hermes/profiles" ]]; then
  for profile in "$HOME"/.hermes/profiles/*/; do
    [[ -d "$profile" ]] && skill_dirs+=("${profile%/}/skills")
  done
fi
for skills_dir in "${skill_dirs[@]}"; do
  remove_own_link "$skills_dir/db-studio" "$skill_dir"
done

desktop="$data_dir/applications/db-studio.desktop"
icon="$data_dir/icons/hicolor/scalable/apps/db-studio.svg"
if [[ -f "$desktop" && ! -L "$desktop" ]] && cmp -s "$plugin_dir/db-studio.desktop" "$desktop"; then
  rm -- "$desktop"
fi
if [[ -f "$icon" && ! -L "$icon" ]] && cmp -s "$plugin_dir/assets/db-studio.svg" "$icon"; then
  rm -- "$icon"
fi

echo "DB Studio launcher and skill links removed. Saved connections remain available."
