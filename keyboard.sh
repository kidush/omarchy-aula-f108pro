#!/usr/bin/env bash
# Backend for the AULA F108 Pro plugin and its Omarchy hooks.
#
#   keyboard.sh info | sync-time           almactl passthrough
#   keyboard.sh light get                  saved backlight state as JSON
#   keyboard.sh light set key value ...    update the saved state and apply it
#   keyboard.sh light apply                reapply the saved state (boot, theme change)
#
# Light keys: color (RRGGBB), mode (static|breathing|cycle|off),
#             brightness (0-100), followTheme (true|false)
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
almactl="$plugin_dir/bin/almactl"
state_file="${XDG_STATE_HOME:-$HOME/.local/state}/aula-f108pro/light.json"
theme_colors="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml"
defaults='{"color":"FF0000","mode":"static","brightness":100,"followTheme":false}'

if [[ ! -x "$almactl" ]]; then
  echo "almactl is not built yet: run bash $plugin_dir/install.sh" >&2
  exit 1
fi

# Serialize requests across monitors, the panel and hooks; bound hardware waits.
device() {
  flock -w 5 "${XDG_RUNTIME_DIR:?}/aula-f108pro.lock" timeout 5 "$almactl" "$@"
}

theme_accent() {
  sed -n 's/^accent *= *"#\?\([0-9A-Fa-f]\{6\}\)".*/\1/p' "$theme_colors" 2>/dev/null | head -1
}

light_state() {
  local saved='{}'
  [[ -f "$state_file" ]] && saved=$(jq -c . "$state_file" 2>/dev/null || echo '{}')
  jq -c --argjson d "$defaults" --arg accent "$(theme_accent)" \
    '$d + . | .themeColor = $accent
     | .effectiveColor = (if .followTheme and $accent != "" then $accent else .color end | ascii_upcase)' \
    <<<"$saved"
}

light_apply() {
  local s mode color level
  s=$(light_state)
  mode=$(jq -r .mode <<<"$s")
  color=$(jq -r .effectiveColor <<<"$s")
  # The keyboard has 5 brightness levels; 0-100 maps to 1-5.
  level=$((($(jq -r .brightness <<<"$s") + 19) / 20))
  case "$mode" in
    breathing) device light -b "$level" breath "$color" ;;
    cycle) device light -b "$level" spectrum ;;
    off) device light off ;;
    *) device light -b "$level" static "$color" ;;
  esac
}

light_set() {
  local s
  s=$(light_state)
  while (($# >= 2)); do
    case "$1" in
      brightness) s=$(jq -c --argjson v "$2" '.brightness = ([0, ([100, $v] | min)] | max)' <<<"$s") ;;
      followTheme) s=$(jq -c --argjson v "$2" '.followTheme = $v' <<<"$s") ;;
      color) s=$(jq -c --arg v "${2#\#}" '.color = ($v | ascii_upcase) | .followTheme = false' <<<"$s") ;;
      mode) s=$(jq -c --arg v "$2" '.mode = $v' <<<"$s") ;;
    esac
    shift 2
  done
  mkdir -p "$(dirname "$state_file")"
  jq 'del(.themeColor, .effectiveColor)' <<<"$s" >"$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  # The state is saved even if the keyboard is asleep; the next apply catches up.
  light_apply || echo "Keyboard did not answer; the setting is saved and will apply on the next wake" >&2
  light_state
}

case "${1:-}" in
  info | sync-time) device "$1" ;;
  light)
    case "${2:-get}" in
      get) light_state ;;
      apply) light_apply ;;
      set) shift 2; light_set "$@" ;;
      *) echo "Usage: keyboard.sh light get|apply|set key value ..." >&2; exit 2 ;;
    esac
    ;;
  *) echo "Usage: keyboard.sh info|sync-time|light ..." >&2; exit 2 ;;
esac
