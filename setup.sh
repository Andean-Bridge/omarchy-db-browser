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

echo "DB Studio is ready. Opening the panel..."
omarchy-shell shell summon andean-bridge.db-browser '{}'
