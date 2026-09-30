#!/bin/bash
# AULA F108 Pro: restore the backlight and set the display clock after login.
# The keyboard may still be asleep at boot, so keep trying for about 2 minutes.
keyboard="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/kidush.aula-f108pro/keyboard.sh"
(
  for _ in $(seq 12); do
    bash "$keyboard" light apply >/dev/null 2>&1 && bash "$keyboard" sync-time >/dev/null 2>&1 && exit 0
    sleep 10
  done
) &
