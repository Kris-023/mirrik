#!/usr/bin/env bash
#
# fmt -> clippy -> cargo test (the four Linux crates, not the bare default-members
# subset) -> the installer bench. One line of balance at the end instead of remembering
# five separate commands from AGENTS.md.
#
# Usage:  tools/check.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

CRATES=(-p mirrik-core -p mirrik-backend-linux -p mirrik-cli -p mirrik-gui)
ok=(); failed=''

run() {  # run <label> <command...>
    local label="$1"; shift
    if "$@"; then ok+=("$label"); else failed="$label"; fi
}

run fmt    cargo fmt --check
[ -z "$failed" ] && run clippy cargo clippy --release "${CRATES[@]}" -- -D warnings
[ -z "$failed" ] && run test   cargo test --release "${CRATES[@]}"
[ -z "$failed" ] && run bench  bash tools/linux/test-install.sh

echo
if [ -n "$failed" ]; then
    echo "check.sh: ${ok[*]:-nothing} passed, $failed failed - stopped there"
    exit 1
fi
echo "check.sh: all green (${ok[*]})"
