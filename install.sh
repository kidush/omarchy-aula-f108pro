#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/kidush.aula-f108pro"

if [[ $# == 2 && $1 == --binary ]]; then
  binary=$(realpath -- "$2")
elif [[ $# == 0 ]]; then
  cd "$source_dir"
  mkdir -p bin
  go build -o bin/almactl ./cmd/almactl
  binary="$source_dir/bin/almactl"
else
  echo "Usage: bash install.sh [--binary /path/to/almactl]" >&2
  exit 2
fi
[[ -x "$binary" ]] || { echo "Executable not found: $binary" >&2; exit 1; }
omarchy plugin validate "$source_dir"

# Back up an existing installation and layout before enabling the widget.
stamp=$(date +%Y%m%d-%H%M%S)
if [[ -d "$target" ]]; then
  backup="${XDG_STATE_HOME:-$HOME/.local/state}/aula-f108pro/backups/$stamp"
  mkdir -p "$backup"
  cp -a -- "$target" "$backup/plugin"
fi
config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
[[ ! -f "$config" ]] || cp -a -- "$config" "${config}.backup-${stamp}"
mkdir -p "$target/bin"
if [[ "$source_dir" != "$target" ]]; then
  install -m 644 "$source_dir/manifest.json" "$source_dir/Panel.qml" "$source_dir/KeyboardScreen.qml" "$source_dir/keyboard.sh" "$target/"
fi
if [[ "$binary" != "$target/bin/almactl" ]]; then
  install -m 755 "$binary" "$target/bin/almactl"
fi
omarchy-shell shell rescanPlugins
omarchy plugin enable kidush.aula-f108pro --section right

# Restore the backlight and clock at login, and follow theme changes.
omarchy hook install post-boot "$source_dir/hooks/post-boot.d/aula-f108pro.sh"
omarchy hook install theme-set "$source_dir/hooks/theme-set.d/aula-f108pro.sh"
