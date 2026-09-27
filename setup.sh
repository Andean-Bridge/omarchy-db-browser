#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"

if [[ ! -f "$plugin_dir/manifest.json" || ! -f "$plugin_dir/package-lock.json" ]]; then
  echo "Run setup.sh from the installed DB Studio plugin directory." >&2
  exit 1
fi

omarchy pkg add npm
node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 20 )); then
  echo "DB Studio requires Node.js 20 or newer (found $(node --version))." >&2
  exit 1
fi

(cd "$plugin_dir" && npm ci --omit=dev --no-bin-links)
install -Dm644 "$plugin_dir/assets/db-studio.svg" "$data_dir/icons/hicolor/scalable/apps/db-studio.svg"
install -Dm644 "$plugin_dir/db-studio.desktop" "$data_dir/applications/db-studio.desktop"
chmod +x "$plugin_dir/bin/db-studio"
mkdir -p "$HOME/.local/bin"
command_link="$HOME/.local/bin/db-studio"
if [[ -L "$command_link" && "$(readlink "$command_link")" == "$plugin_dir/bin/db-studio" ]]; then
  :
elif [[ ! -e "$command_link" && ! -L "$command_link" ]]; then
  ln -s "$plugin_dir/bin/db-studio" "$command_link"
else
  echo "A different db-studio command already exists in ~/.local/bin; leaving it unchanged." >&2
fi

# Omarchy links its bundled skills into each supported agent's skill directory.
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
  mkdir -p "$skills_dir"
  skill_link="$skills_dir/db-studio"
  if [[ -L "$skill_link" && "$(readlink "$skill_link")" == "$skill_dir" ]]; then
    continue
  fi
  if [[ -e "$skill_link" || -L "$skill_link" ]]; then
    echo "A different db-studio skill exists at $skill_link; leaving it unchanged." >&2
    continue
  fi
  ln -s "$skill_dir" "$skill_link"
done

echo "DB Studio is ready. Opening the panel..."
omarchy-shell shell summon andean-bridge.db-browser '{}'
