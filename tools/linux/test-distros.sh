#!/usr/bin/env bash
#
# Runs install.sh's distribution detection against real distro containers, not the
# os-release override tools/linux/test-install.sh uses to fake it. That bench proves the
# case-statement in install.sh maps IDs to the right package command; it never proves a
# real Debian, Fedora or Arch actually sets ID/ID_LIKE the way the case-statement expects.
# This script closes that gap - real /etc/os-release, real missing-tool detection (no
# PipeWire in a bare distro image), same install.sh, unmodified.
#
# Needs podman. On a filesystem where overlayfs will not mount (ext2/ext3, some network
# mounts), pass --storage-driver=vfs to every podman call - see erfahrungen.md for why.
#
# Usage:  tools/linux/test-distros.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
green=$'\033[32m'; red=$'\033[31m'; off=$'\033[0m'
[ -t 1 ] || { green=''; red=''; off=''; }

have() { command -v "$1" >/dev/null 2>&1; }
have podman || { echo "podman is not installed - nothing to run the containers with" >&2; exit 1; }

pass=0; fail=0

# image | expected line install.sh must print for that distro's missing PipeWire tools
CASES=(
    "docker.io/library/debian:12-slim|sudo apt install pipewire pipewire-pulse pipewire-bin pulseaudio-utils"
    "docker.io/library/fedora:latest|sudo dnf install pipewire pipewire-pulseaudio pipewire-utils pulseaudio-utils"
    "docker.io/library/archlinux:latest|sudo pacman -S --needed pipewire pipewire-pulse libpulse"
)

run_case() {  # <image> <expected-line>
    local image="$1" expected="$2"
    local out
    # A bare distro image has none of the four PipeWire tools and no cargo, so install.sh
    # runs into "1. What Mirrik needs" (prints the hint we are checking), declines the
    # `eval` of that command, skips the audio-server check (pactl is also missing), and
    # then stops at step 3 with "Rust is not installed either" - a non-zero exit here is
    # expected and not what this test is about.
    out="$(printf 'n\nn\n' | podman run --rm -i \
        -v "$REPO:/repo:ro" "$image" bash /repo/install.sh 2>&1)" || true

    if grep -qF "$expected" <<<"$out"; then
        printf '  %s✓%s %s\n' "$green" "$off" "$image"
        pass=$((pass + 1))
    else
        printf '  %s✗%s %s\n' "$red" "$off" "$image"
        printf '      expected to see: %s\n' "$expected"
        printf '%s\n' "$out" | tail -20 | sed 's/^/        | /'
        fail=$((fail + 1))
    fi
}

echo "install.sh — real distro containers"
for entry in "${CASES[@]}"; do
    IFS='|' read -r image expected <<<"$entry"
    podman pull -q "$image" >/dev/null
    run_case "$image" "$expected"
done

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
