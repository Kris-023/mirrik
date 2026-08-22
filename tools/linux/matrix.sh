#!/usr/bin/env bash
# Builds every combination of compositor x modifier x config path and runs each one on
# its own. This isn't a sample of cases - it's the whole set of selection paths.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Each entry: wm number : config file : which branch it takes
WMS=(
  "1:.config/hypr/hyprland.conf:snippet"
  "2:.config/sway/config:snippet"
  "3:.config/i3/config:snippet"
  "4:.config/niri/config.kdl:snippet-niri"
  "5:.config/river/init:snippet"
  "6:.config/awesome/rc.lua:snippet"
  "7:.config/sxhkd/sxhkdrc:snippet"
  "8::tool"
  "9::tool"
  "10::hint"
  "11::tool"
  "12::hint"
  "13::hint"
  "14::tool-mate"
  "15::hint"
)
printf '%s\n' "# generated $(date '+%F %H:%M') — compositor x modifier x config path"
for entry in "${WMS[@]}"; do
    IFS=':' read -r wm cfg kind <<<"$entry"
    for mods in 1 2 3 4; do
        case "$kind" in
            snippet)
                echo "matrix-wm${wm}-mods${mods}-append|,y,$wm,$mods,a,1,y|check_appended|cfg=$cfg"
                echo "matrix-wm${wm}-mods${mods}-print|,y,$wm,$mods,a,2|check_printed|cfg=$cfg" ;;
            snippet-niri)
                # niri doesn't use markers - it's just one binds block - so it gets its
                # own check function. See the note next to check_printed_niri in
                # test-install.sh for the full story.
                echo "matrix-wm${wm}-mods${mods}-print|,y,$wm,$mods,a,2|check_printed_niri|cfg=$cfg" ;;
            tool)
                echo "matrix-wm${wm}-mods${mods}-yes|,y,$wm,$mods,a,y|check_tool_called|"
                echo "matrix-wm${wm}-mods${mods}-no|,y,$wm,$mods,a,n|check_manual_hint|" ;;
            tool-mate)
                # Same shape as `tool`, but the "yes" side gets MATE's own check: its
                # schema uses different key names, and it picks its dconf slot itself.
                echo "matrix-wm${wm}-mods${mods}-yes|,y,$wm,$mods,a,y|check_mate_keys|"
                echo "matrix-wm${wm}-mods${mods}-no|,y,$wm,$mods,a,n|check_manual_hint|" ;;
            hint)
                echo "matrix-wm${wm}-mods${mods}|,y,$wm,$mods,a|check_manual_hint|" ;;
        esac
    done
done
