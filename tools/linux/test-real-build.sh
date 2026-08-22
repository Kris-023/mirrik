#!/usr/bin/env bash
#
# Runs the exact `cargo build` line install.sh runs, for real - no stub, no fake HOME.
#
# tools/linux/test-install.sh fakes `cargo` on purpose: a stub that just logs its
# arguments is what keeps the rest of the bench fast and free of surprises. The price is
# that the actual build path install.sh executes - the one line every real install
# depends on - is never exercised by anything automated, only by hand at the next real
# install. This script closes that gap, the same way test-install-windows.ps1 exists
# alongside the fully-faked Windows bench for the things only real Windows can answer.
#
# It is NOT part of test-install.sh's CASES table on purpose: it needs a real Rust
# toolchain and takes as long as an actual build, both wrong fits for a bench whose whole
# point is running in well under a second.
#
# Usage:  tools/linux/test-real-build.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
green=$'\033[32m'; red=$'\033[31m'; dim=$'\033[90m'; off=$'\033[0m'
[ -t 1 ] || { green=''; red=''; dim=''; off=''; }

dim()  { printf '%s%s%s\n' "$dim" "$1" "$off"; }
fail() { printf '%s✗%s %s\n' "$red" "$off" "$1" >&2; exit 1; }
pass() { printf '%s✓%s %s\n' "$green" "$off" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
have cargo || fail "cargo is not installed - nothing to build with"

workspace_version="$(grep -m1 '^version' "$REPO/Cargo.toml" | grep -oE '"[^"]+"' | tr -d '"')"
[ -n "$workspace_version" ] || fail "could not read version from Cargo.toml"

# exFAT (this repo's usual home, see erfahrungen.md) answers a rebuild that overwrites a
# just-executed build script with "Text file busy" - it has no real inode semantics, so a
# file still open for exec cannot be replaced in place the way ext4/btrfs allow. Building
# into a scratch directory on a real filesystem sidesteps that; CARGO_TARGET_DIR lets a
# caller override it, same escape hatch cargo itself offers.
target_dir="${CARGO_TARGET_DIR:-$(mktemp -d /tmp/mirrik-real-build.XXXXXX)}"
export CARGO_TARGET_DIR="$target_dir"
dim "Building into $target_dir (off exFAT - see erfahrungen.md on Text file busy)"

# The exact command install.sh runs when it cannot find pre-built binaries (see
# "3. The program itself" in install.sh) - -p on both crates, same as there, so a
# `default-members` change can never make this line silently diverge from that one.
dim "Building: cargo build --release --manifest-path $REPO/Cargo.toml -p mirrik-cli -p mirrik-gui"
cargo build --release --manifest-path "$REPO/Cargo.toml" -p mirrik-cli -p mirrik-gui \
    || fail "cargo build --release -p mirrik-cli -p mirrik-gui failed"
pass "cargo build --release -p mirrik-cli -p mirrik-gui"

bin="$target_dir/release/mirrik"
gui="$target_dir/release/mirrik-gui"
[ -x "$bin" ] || fail "target/release/mirrik was not produced"
[ -x "$gui" ] || fail "target/release/mirrik-gui was not produced"
pass "both binaries exist and are executable"

# Distinguishes a real build from a stub: `install.sh`'s test bench uses a `mirrik`
# stub that answers to `devices` but not `--version` in the same way a real build does.
got_version="$("$bin" --version)"
[ "$got_version" = "mirrik $workspace_version" ] \
    || fail "mirrik --version printed '$got_version', expected 'mirrik $workspace_version'"
pass "mirrik --version reports the real workspace version ($workspace_version)"

# Read-only: lists devices through the real, running audio server. Not a bookkeeping
# check like the rest of this project's tests - this is the one place confirming the
# freshly built binary can actually talk to PipeWire, not just that it links.
if devices="$("$bin" devices 2>&1)"; then
    pass "mirrik devices ran against the real audio server"
    printf '%s\n' "$devices" | sed 's/^/    /'
else
    printf '%s✗%s mirrik devices failed against the real audio server:\n' "$red" "$off" >&2
    printf '%s\n' "$devices" | sed 's/^/    /' >&2
    exit 1
fi
