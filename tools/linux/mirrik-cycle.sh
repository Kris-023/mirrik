#!/usr/bin/env bash
# Diagnosis for "the device is back, why is the mirror not?".
#
# Three witnesses, one clock:
#   * udev says when the kernel saw the sound card come or go,
#   * this script watches the sound server from outside and says when the sink
#     is actually there,
#   * MIRRIK_LOG=1 makes Mirrik itself say what it decided and when.
# All three stamp seconds since the epoch, so the merged, sorted timeline at the
# end shows where the waiting time actually went.
#
# usage:  tools/linux/mirrik-cycle.sh alsa_output.usb-Apple
#   1. close the Mirrik window first - a second instance exits without a word
#   2. this opens the window for you; unplug, wait, plug back in
#   3. close the window with Esc; the timeline is printed
#
# Reading it: the gap between the udev line and the pw line is the sound server
# taking its time, the gap from there to "rebuilt" is ours. Measured once on a
# USB headset: 0.9 s sound server, 0.67 s ours, 1.6 s from plug to sound.
set -u
match="${1:?give a substring of the sink id, e.g. alsa_output.usb-Apple}"

if pgrep -x mirrik-gui >/dev/null; then
    echo "A Mirrik window is already open. Close it first - a second one exits silently." >&2
    exit 1
fi

watch_log=/tmp/mirrik-watch.log
gui_log=/tmp/mirrik-gui.log
: >"$watch_log"
: >"$gui_log"

watch_sinks() {
    local prev="" line
    while :; do
        line=$(pw-dump 2>/dev/null | jq -r --arg m "$match" '
          [ .[] | select(.info.props."media.class" == "Audio/Sink")
                | .info.props."node.name" | select(test($m)) ] as $sinks
        | [ .[] | select(.info.props."node.name" // "" | startswith("mirrik.out."))
                | select((.info.props."node.name" | endswith(".in")) | not) ] as $h
        | ($h | map(.id)) as $hids
        | [ .[] | select(.type == "PipeWire:Interface:Link")
                | select(.info."output-node-id" as $o | $hids | index($o)) ] as $links
        | "sink=\($sinks | length) holder=\($h | length) link=\($links | length)"')
        # Only changes, or the log is one line every quarter second and unreadable.
        if [ "$line" != "$prev" ]; then
            printf '%s pw     %s\n' "$(date +%s.%3N)" "$line" >>"$watch_log"
            prev="$line"
        fi
        sleep 0.25
    done
}

# Third witness, and the earliest one: the kernel telling udev that a sound card
# came or went. That is as close to "the cable moved" as we get without sitting
# next to the machine with a stopwatch - and it splits the waiting time into
# "USB enumeration" and "PipeWire took its time".
udev_log=/tmp/mirrik-udev.log
: >"$udev_log"
udevadm monitor --udev --subsystem-match=sound 2>/dev/null \
  | while IFS= read -r ev; do
        case "$ev" in
            UDEV*add*|UDEV*remove*)
                printf '%s udev   %s\n' "$(date +%s.%3N)" "${ev##*] }" >>"$udev_log" ;;
        esac
    done &
udev=$!

watch_sinks &
watcher=$!
# `$!` is only the `while` at the tail of the pipeline; `udevadm` itself is a separate
# process and would keep running. Named explicitly so nothing is left behind.
stop_watchers() { kill "$watcher" "$udev" 2>/dev/null; pkill -f 'udevadm monitor --udev --subsystem-match=sound' 2>/dev/null; }
trap stop_watchers EXIT

echo "watching. unplug and replug now; press Esc in the window when done."
MIRRIK_LOG=1 mirrik-gui 2>"$gui_log"
stop_watchers

echo
echo "=== timeline (seconds from the first event) ==="
sort -n "$watch_log" "$gui_log" "$udev_log" | LC_ALL=C awk '
    NR == 1 { t0 = $1 }
    { $1 = sprintf("%7.2f", $1 - t0); print }'
