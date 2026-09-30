#!/bin/bash
# AULA F108 Pro: follow the new theme's accent color when "Cor do tema" is on.
keyboard="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/kidush.aula-f108pro/keyboard.sh"
bash "$keyboard" light apply >/dev/null 2>&1 &
