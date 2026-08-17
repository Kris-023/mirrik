#!/usr/bin/env bash
# Erzeugt die vollstaendige Kombination aus Compositor x Modifier x Config-Weg und laesst
# jede einzeln laufen. Nicht Stichprobe, sondern Vollzaehlung der Auswahlpfade.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# wm-Nummer : Konfigurationsdatei : Art des Zweiges
WMS=(
  "1:.config/hypr/hyprland.conf:snippet"
  "2:.config/sway/config:snippet"
  "3:.config/i3/config:snippet"
  "4:.config/niri/config.kdl:snippet-nur-drucken"
  "5:.config/river/init:snippet"
  "6:.config/awesome/rc.lua:snippet"
  "7:.config/sxhkd/sxhkdrc:snippet"
  "8::werkzeug"
  "9::werkzeug"
  "10::hinweis"
  "11::werkzeug"
  "12::hinweis"
  "13::hinweis"
)
printf '%s\n' "# erzeugt $(date '+%F %H:%M') — Compositor x Modifier x Config-Weg"
for entry in "${WMS[@]}"; do
    IFS=':' read -r wm cfg kind <<<"$entry"
    for mods in 1 2 3 4; do
        case "$kind" in
            snippet)
                echo "matrix-wm${wm}-mods${mods}-append|,y,$wm,$mods,a,1,y|check_appended|cfg=$cfg"
                echo "matrix-wm${wm}-mods${mods}-print|,y,$wm,$mods,a,2|check_printed|cfg=$cfg" ;;
            snippet-nur-drucken)
                echo "matrix-wm${wm}-mods${mods}-print|,y,$wm,$mods,a,2|check_printed|cfg=$cfg" ;;
            werkzeug)
                echo "matrix-wm${wm}-mods${mods}-ja|,y,$wm,$mods,a,y|check_tool_called|"
                echo "matrix-wm${wm}-mods${mods}-nein|,y,$wm,$mods,a,n|check_manual_hint|" ;;
            hinweis)
                echo "matrix-wm${wm}-mods${mods}|,y,$wm,$mods,a|check_manual_hint|" ;;
        esac
    done
done
