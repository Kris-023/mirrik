#!/usr/bin/env bash
#
# Runs install.sh through every branch it has, without touching anything on your actual
# system.
#
# Every case gets its own fresh HOME from mktemp, plus a PATH directory full of stubs
# standing in for the programs the installer calls. The installer has no idea any of
# this is fake.
#
# One thing this does NOT prove: that the bind it writes actually works in a real
# compositor. Stubs check the logic, not reality - and that's exactly what tripped up
# the first real Linux run, even though the logic itself had already passed here.
#
# Usage:   tools/linux/test-install.sh              run everything
#          tools/linux/test-install.sh hyprland     only cases whose name contains that
#          VERBOSE=1 tools/linux/test-install.sh    show the installer's output on failures
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Taken before anything runs, compared at the end. The bench copies stub binaries into
# the repository root and removes them again, so a leftover there should be nothing at
# all - and for a long time it was not: a case whose answers had drifted made the
# installer create a directory called "y" in the working tree, run after run, while
# staying green. A stray entry means the installer was told something nobody meant, so
# it is worth failing over rather than sweeping up.
repo_before="$(ls -A "$REPO")"
INSTALLER="$REPO/install.sh"
[ -x "$INSTALLER" ] || { echo "install.sh not found: $INSTALLER" >&2; exit 1; }

pass=0; fail=0; failed_names=()
green=$'\033[32m'; red=$'\033[31m'; dim=$'\033[90m'; off=$'\033[0m'
[ -t 1 ] || { green=''; red=''; dim=''; off=''; }

# We build a PATH that deliberately skips /usr/bin - otherwise the installer would just
# find any tool a case tried to leave out, and "missing=" would end up testing nothing
# at all. Only the programs install.sh actually calls get linked in here, and that list
# comes straight from grepping the script itself.
make_minimal_path() {  # <target-dir>
    local d="$1"; mkdir -p "$d"
    local t src
    for t in bash sh grep sed awk cat tr head tail sort uniq wc mkdir rmdir rm cp mv ln \
             install chmod chown dirname basename env date mktemp uname id readlink find \
             xargs cut expr tee touch stat getent tput sleep printf test true false; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        ln -sf "$src" "$d/$t" 2>/dev/null
    done
}

make_stubs() {  # <bin-dir> <server-name> <missing-tools...>
    local d="$1" server="$2"; shift 2
    local missing=" $* "
    mkdir -p "$d"
    if [[ "$missing" != *" pactl "* ]]; then
        cat > "$d/pactl" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = info ] && [ -n "$server" ] && printf 'Server Name: %s\n' "$server"
exit 0
EOF
    fi
    for t in pw-cli pw-dump pw-metadata update-desktop-database; do
        [[ "$missing" == *" $t "* ]] && continue
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$t"
    done
    # dconf answers `list` for real, because the MATE branch asks it which custom slots
    # already exist. Reporting one occupied slot is what makes that branch do its two
    # interesting things: look inside custom0 to see whether it is ours, and then move
    # on to the first free one. A silent stub would leave both untested.
    if [[ "$missing" != *" dconf "* ]]; then
        cat > "$d/dconf" <<'EOF'
#!/usr/bin/env bash
printf 'dconf %s\n' "$*" >> "$STUB_LOG"
[ "${1:-}" = list ] && printf 'custom0/\n'
exit 0
EOF
    fi
    cat > "$d/mirrik" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = devices ]; then
    printf '* Built-in Analog Stereo  [analog]\n    alsa_output.stub.analog-stereo\n'
    printf '  Display HDMI  [HDMI]\n    alsa_output.stub.hdmi-stereo\n'
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/mirrik-gui"
    # Our gsettings stub needs to do more than just log the call. The GNOME and
    # Cinnamon branches ask `list-schemas` first, and if that comes back empty they fall
    # back to "just do it by hand". A silent stub would mean those branches never
    # actually get exercised - and worse, a test that mistakes that fallback for success
    # would still show up green.
    if [[ "$missing" != *" gsettings "* ]]; then
        cat > "$d/gsettings" <<'EOF'
#!/usr/bin/env bash
printf 'gsettings %s
' "$*" >> "$STUB_LOG"
# The real gsettings takes the object path glued to the schema (SCHEMA:PATH) and knows
# no --path option at all - it answers one with a usage error on stderr and exit 1. We
# do the same, because a stub that shrugs and answers anyway is how a call that cannot
# work on a real desktop passes the bench.
case " $* " in
    *" --path "*) printf 'Usage:\n  gsettings [--schemadir SCHEMADIR] get SCHEMA[:PATH] KEY\n' >&2; exit 1 ;;
esac
case "${1:-}" in
    list-schemas)
        printf '%s
' org.gnome.settings-daemon.plugins.media-keys                       org.cinnamon.desktop.keybindings ;;
    # A slot that says it is already ours. Only the MATE branch ever asks for a `name`
    # (Cinnamon gets an empty custom-list above and never reaches its own lookup), and
    # answering honestly is what lets a case tell "reused our old slot" apart from
    # "asked wrongly, got nothing, took a fresh one".
    get) case "$*" in *" name") printf "'Mirrik'\n" ;; *) printf '@as []\n' ;; esac ;;
esac
exit 0
EOF
    fi
    if [[ "$missing" != *" xfconf-query "* ]]; then
        cat > "$d/xfconf-query" <<'EOF'
#!/usr/bin/env bash
printf 'xfconf-query %s
' "$*" >> "$STUB_LOG"
exit 0
EOF
    fi
    cat > "$d/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s
' "$*" >> "$STUB_LOG"
exit 0
EOF
    for pm in apt dnf pacman zypper apk xbps-install emerge rpm-ostree; do
        cat > "$d/$pm" <<EOF
#!/usr/bin/env bash
printf '%s %s
' "$pm" "\$*" >> "\$STUB_LOG"
exit 0
EOF
    done
    # We only add hyprctl if a case actually asks for a version. Leaving it out is its
    # own branch too - the one where the installer has to guess, assumes the new
    # spelling, and tells you it did.
    if [ -n "${STUB_HYPR_VERSION:-}" ]; then
        printf '#!/usr/bin/env bash\n[ "$1" = version ] && printf "Hyprland %s built from branch v%s\\n" "%s" "%s"\nexit 0\n' \
            "$STUB_HYPR_VERSION" "$STUB_HYPR_VERSION" > "$d/hyprctl"
    fi

    if [[ "$missing" != *" cargo "* ]]; then
        # Reports a made-up version on `--version` when a case asks for one (the MSRV
        # check reads exactly this output), and otherwise just logs the call like the
        # other package-manager stubs.
        cat > "$d/cargo" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ] && [ -n "${STUB_CARGO_VERSION:-}" ]; then
    printf 'cargo %s (0000000000 2026-01-01)\n' "${STUB_CARGO_VERSION:-}"
    exit 0
fi
printf 'cargo %s\n' "\$*" >> "\$STUB_LOG"
exit 0
EOF
    fi
    # A fake ld.so.cache dump for the GUI-library check in step 1. The four real libraries
    # print FIRST, four thousand filler lines AFTER - on purpose, not for realism. That
    # order is what actually exercises the SIGPIPE-under-pipefail bug this is guarding
    # against: `grep -q` finding a match on line one, closing the pipe, and the real
    # ldconfig getting killed by SIGPIPE while it still has thousands of lines left to
    # write. Put the matches at the end instead and the bug would never trigger, real
    # ldconfig or fake. STUB_LDCONFIG_MISSING names which of the four to leave out.
    cat > "$d/ldconfig" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -p ] || exit 0
for lib in libGL.so.1 libxkbcommon.so.0 libwayland-client.so.0 libX11.so.6; do
    case " ${STUB_LDCONFIG_MISSING:-} " in
        *" \$lib "*) continue ;;
    esac
    printf '\t%s (libc6,x86-64) => /usr/lib/%s\n' "\$lib" "\$lib"
done
    i=0
    while [ "\$i" -lt 4000 ]; do
        printf '\tlibfiller%d.so.0 (libc6,x86-64) => /usr/lib/libfiller%d.so.0\n' "\$i" "\$i"
        i=\$((i + 1))
    done
    # The rasterizer entry, baked in when the case set noraster=no - an empty value
    # leaves no trace in the output and the installer's icon step goes PNG.
    $( [ "${STUB_RASTERIZER:-}" = no ] || printf "printf '\\tlibrsvg-2.so.2 (libc6,x86-64) => /usr/lib/librsvg-2.so.2\\\\n'\\n" )
    exit 0
EOF
    # base64 decodes the embedded PNG. Real binary in the system.
    if [[ "$missing" != *" base64 "* ]] && command -v base64 >/dev/null 2>&1; then
        ln -sf "$(command -v base64)" "$d/base64"
    fi
    chmod +x "$d"/* 2>/dev/null
    return 0
}

# opts: cfg= pre=none|empty|marker server= missing=a,b lua=1 nobins=1 nopath=1 repeat=N
#       again=<answers for runs 2..N, when a second run asks something the first did not>
#       hyprversion= preinstalled= cargoversion= stateonly=1 statedecoy=1 statepartial=1
#       statenoexec=1 statefileunreadable=1 wayland=1 ldconfigmissing=lib noraster=1
run_case() {  # <name> <answers> <check-function> [opts]
    local name="$1" answers="$2" check="$3" opts="${4:-}"
    local cfg='' pre='empty' server='PulseAudio (on PipeWire 1.6.8)'
    local missing='' lua='' nobins='' nopath='' repeat=1 again='' pair kv
    local osrelease='' shell_for_case='' hyprversion='' preinstalled='' cargoversion='' stateonly=''
    local statedecoy='' statepartial='' statenoexec='' statefileunreadable=''
    local wayland='' ldconfigmissing='' noraster=''
    IFS=';' read -ra kv <<<"$opts"
    for pair in "${kv[@]}"; do
        [ -z "$pair" ] && continue
        case "${pair%%=*}" in
            cfg) cfg="${pair#*=}" ;; pre) pre="${pair#*=}" ;;
            server) server="${pair#*=}" ;; missing) missing="${pair#*=}" ;;
            lua) lua=1 ;; nobins) nobins=1 ;; nopath) nopath=1 ;; repeat) repeat="${pair#*=}" ;;
            again) again="${pair#*=}" ;;
            osrelease) osrelease="${pair#*=}" ;; shell) shell_for_case="${pair#*=}" ;;
            hyprversion) hyprversion="${pair#*=}" ;; preinstalled) preinstalled="${pair#*=}" ;;
            cargoversion) cargoversion="${pair#*=}" ;; stateonly) stateonly=1 ;;
            statedecoy) statedecoy=1 ;; statepartial) statepartial=1 ;;
            statenoexec) statenoexec=1 ;; statefileunreadable) statefileunreadable=1 ;;
            wayland) wayland=1 ;; ldconfigmissing) ldconfigmissing="${pair#*=}" ;;
            noraster) noraster=1 ;;
        esac
    done

    local home; home="$(mktemp -d)"
    local stubs="$home/stubs"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share/applications"
    STUB_HYPR_VERSION="$hyprversion" STUB_CARGO_VERSION="$cargoversion" \
        STUB_LDCONFIG_MISSING="$ldconfigmissing" STUB_RASTERIZER="${noraster:+no}" \
        make_stubs "$stubs" "$server" ${missing//,/ }

    if [ -n "$cfg" ] && [ "$pre" != none ]; then
        mkdir -p "$home/$(dirname "$cfg")"
        if [ "$pre" = marker ]; then
            printf '# existing\n# --- Mirrik ---\nbind = OLD\n# --- end Mirrik ---\n' > "$home/$cfg"
        else
            printf '# existing config\n' > "$home/$cfg"
        fi
    fi
    [ -n "$lua" ] && { mkdir -p "$home/.config/hypr/subcfgs"; printf -- '-- binds\n' > "$home/.config/hypr/subcfgs/binds.lua"; }
    [ -n "$osrelease" ] && printf 'ID=%s\nPRETTY_NAME="%s test"\n' "$osrelease" "$osrelease" > "$home/os-release"
    [ -z "$nobins" ] && cp "$stubs/mirrik" "$stubs/mirrik-gui" "$REPO/" 2>/dev/null
    # A fake "already installed" version that reports back on whatever gets done to it.
    if [ -n "$preinstalled" ]; then
        cat > "$home/.local/bin/mirrik" <<EOF
#!/usr/bin/env bash
printf 'old-mirrik %s\n' "\$*" >> "\$STUB_LOG"
[ "\${1:-}" = --version ] && printf 'mirrik %s\n' "$preinstalled"
exit 0
EOF
        cp "$home/.local/bin/mirrik" "$home/.local/bin/mirrik-gui"
        chmod +x "$home/.local/bin/mirrik" "$home/.local/bin/mirrik-gui"
    fi
    # Stands in for a previous run of install.sh itself: working binaries already sitting
    # at the default bindir, plus the state file that remembers they are there. Paired
    # with nobins=1, this is the exact situation the state-based search exists for - a
    # bare clone with nothing freshly built, but a working install one directory away.
    if [ -n "$stateonly" ]; then
        cp "$stubs/mirrik" "$stubs/mirrik-gui" "$home/.local/bin/"
        chmod +x "$home/.local/bin/mirrik" "$home/.local/bin/mirrik-gui"
        mkdir -p "$home/.local/state/mirrik"
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/bin" > "$home/.local/state/mirrik/install-state"
    fi
    # A second, deliberately non-functional pair, known only through the state file and
    # living away from both $here and the default bindir. Proves the search order: a
    # fresh build next to the script has to win over a copy the state file merely
    # remembers, never the other way round. "Non-functional" means it never answers
    # `devices`, so step 6 fails loudly if this one ever gets installed by mistake - the
    # check does not have to guess which copy actually ran, the symptom gives it away.
    if [ -n "$statedecoy" ]; then
        mkdir -p "$home/.local/state-src"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$home/.local/state-src/mirrik"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$home/.local/state-src/mirrik-gui"
        chmod +x "$home/.local/state-src/mirrik" "$home/.local/state-src/mirrik-gui"
        mkdir -p "$home/.local/state/mirrik"
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/state-src" > "$home/.local/state/mirrik/install-state"
    fi
    # Half a pair: only mirrik made it into the remembered location, not mirrik-gui - an
    # interrupted install, or one binary deleted by hand since. The search requires both
    # `-x` checks to pass, so this has to be skipped entirely, not picked as a source and
    # then fail halfway through.
    if [ -n "$statepartial" ]; then
        mkdir -p "$home/.local/state-src"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$home/.local/state-src/mirrik"
        chmod +x "$home/.local/state-src/mirrik"
        mkdir -p "$home/.local/state/mirrik"
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/state-src" > "$home/.local/state/mirrik/install-state"
    fi
    # Both files are there, but neither has the executable bit - permissions slipped, or
    # they were copied by something that does not preserve them. Same expectation as the
    # partial pair above: skipped, not treated as a usable source.
    if [ -n "$statenoexec" ]; then
        mkdir -p "$home/.local/state-src"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$home/.local/state-src/mirrik"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$home/.local/state-src/mirrik-gui"
        mkdir -p "$home/.local/state/mirrik"
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/state-src" > "$home/.local/state/mirrik/install-state"
    fi
    # The state FILE itself unreadable, rather than the binaries it points at - a
    # permission slip on ~/.local/state instead of on the install. install.sh already
    # guards this with `[ -r "$statefile" ]`; this proves the guard holds up when there
    # is genuinely nothing else to fall back on but "not found, offer to build".
    if [ -n "$statefileunreadable" ]; then
        mkdir -p "$home/.local/state-src"
        cp "$stubs/mirrik" "$stubs/mirrik-gui" "$home/.local/state-src/"
        chmod +x "$home/.local/state-src/mirrik" "$home/.local/state-src/mirrik-gui"
        mkdir -p "$home/.local/state/mirrik"
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/state-src" > "$home/.local/state/mirrik/install-state"
        chmod 000 "$home/.local/state/mirrik/install-state"
    fi

    local sysbin="$home/sysbin"
    make_minimal_path "$sysbin"
    local path="$stubs:$sysbin"
    [ -z "$nopath" ] && path="$stubs:$home/.local/bin:$sysbin"

    local out rc i answer_lines
    answer_lines="$(printf '%s' "$answers" | tr ',' '\n')"
    for ((i = 1; i <= repeat; i++)); do
        # Runs after the first get their own answers when a case supplies them: since the
        # installer learned to open with "update or show me how to remove it", a second
        # run consumes one answer more than the first.
        local lines="$answer_lines"
        [ "$i" -gt 1 ] && [ -n "$again" ] && lines="$(printf '%s' "$again" | tr ',' '\n')"
        # Run from inside the throwaway home, never from the repository. install.sh finds
        # everything from its own path, so this changes nothing it can see - but a
        # relative path (a mistyped answer, or answers that have drifted out of step) then
        # lands in the temp directory instead of the working tree.
        out="$(cd "$home" && printf '%s\n' "$lines" | env -i \
            HOME="$home" PATH="$path" \
            XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
            STUB_LOG="$home/stub.log" SHELL="${shell_for_case:-/bin/bash}" TERM=dumb \
            ${osrelease:+MIRRIK_OS_RELEASE="$home/os-release"} \
            ${wayland:+WAYLAND_DISPLAY=wayland-99} \
            bash "$INSTALLER" 2>&1)"
        rc=$?
    done
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    mapfile -t problems < <(
        export HOME_UNDER_TEST="$home" OUT="$out" RC="$rc" CFG="$cfg" STUBLOG="$home/stub.log"
        "$check"
    )
    if [ ${#problems[@]} -eq 0 ]; then
        printf '  %s✓%s %s\n' "$green" "$off" "$name"; pass=$((pass + 1))
    else
        printf '  %s✗%s %s\n' "$red" "$off" "$name"
        printf '      %s\n' "${problems[@]}"
        [ -n "${VERBOSE:-}" ] && printf '%s\n' "$out" | tail -20 | sed 's/^/        | /'
        fail=$((fail + 1)); failed_names+=("$name")
    fi
    rm -rf "$home"
    return 0
}

installed_ok() {
    [ "$RC" = 0 ] || echo "Exit code $RC instead of 0"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik" ]     || echo "mirrik not installed"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik-gui" ] || echo "mirrik-gui not installed"
    grep -q 'sees 2 output device' <<<"$OUT" || echo "step 6 did not read the devices"
}
# The icon is written in the same step as the .desktop, and the Icon= line is what
# ties the two together - on Wayland that line is the only route to an icon at all.
# So all three are checked here: half of that step succeeding is still a failure.
# install.sh may write one of two formats, SVG (default, when there is a rasterizer
# in the ld.so.cache) or PNG (when there is none). Both are counted here.
ICON_SVG=".local/share/icons/hicolor/scalable/apps/mirrik.svg"
ICON_PNG=".local/share/icons/hicolor/32x32/apps/mirrik.png"
has_desktop() {
    local d="$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop"
    [ -f "$d" ] || { echo ".desktop missing"; return 0; }
    grep -q '^Icon=mirrik$' "$d"                 || echo ".desktop has no Icon=mirrik line"
    # Exactly one icon file, never both: a theme with a rasterizer would pick the
    # SVG over the PNG even when the PNG is the one we just installed, and we don't
    # want to ship the rectangle twice for that.
    [ -f "$HOME_UNDER_TEST/$ICON_SVG" ] || [ -f "$HOME_UNDER_TEST/$ICON_PNG" ] \
        || echo "icon file missing"
    # no_desktop variant below adds "neither one, whatever the format".
    return 0
}
no_desktop()  {
    installed_ok
    [ -f "$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop" ] && echo ".desktop written despite declining"
    [ -f "$HOME_UNDER_TEST/$ICON_SVG" ] && echo "svg icon written despite declining"
    [ -f "$HOME_UNDER_TEST/$ICON_PNG" ] && echo "png icon written despite declining"
    return 0
}
check_appended() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -f "$f" ] || { echo "$CFG was not written"; return 0; }
    local n; n=$(grep -c -- '--- Mirrik ---' "$f")
    [ "$n" = 1 ] || echo "$CFG has $n markers instead of 1"
    grep -q 'mirrik-gui' "$f" || echo "$CFG does not name mirrik-gui"
}
check_printed() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -e "$f" ] && grep -q -- '--- Mirrik ---' "$f" && echo "$CFG carries a block, even though nothing should have been appended"
    grep -q -- '--- Mirrik ---' <<<"$OUT" || echo "the lines were not printed"
    return 0
}
# niri doesn't use markers at all - just a single binds block, see the note in the
# installer for why. The generic check_printed used to pass here, but only by accident:
# the old, unconditional line in the closing block happened to contain the text
# "--- Mirrik ---" too. Now that line only shows up when a block genuinely exists, so
# this dedicated check looks at the real content (the binds line) instead of relying on
# text that never actually appears for niri.
check_printed_niri() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -e "$f" ] && grep -q 'binds {' "$f" && echo "$CFG was written to automatically despite the niri special case"
    grep -q 'binds {' <<<"$OUT" || echo "the niri bind lines were not printed"
    return 0
}
check_untouched() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    local n; n=$(grep -c -- '--- Mirrik ---' "$f")
    [ "$n" = 1 ] || echo "$CFG has $n markers instead of 1 (block duplicated?)"
    grep -q 'bind = OLD' "$f" || echo "the existing block was overwritten"
    grep -qi 'already has a Mirrik block' <<<"$OUT" || echo "no note about the existing block"
}
check_lua_hint() {
    installed_ok; has_desktop
    grep -q 'Lua files found' <<<"$OUT" || echo "Lua files were not detected"
    grep -q 'hl.bind' <<<"$OUT" || echo "the hl.* translation is missing"
    [ -e "$HOME_UNDER_TEST/$CFG" ] && grep -q -- '--- Mirrik ---' "$HOME_UNDER_TEST/$CFG" && echo "written to the conf despite finding Lua"
    return 0
}
check_gsettings() {
    installed_ok; has_desktop
    grep -q gsettings "$STUBLOG" 2>/dev/null || echo "gsettings was not called"
    grep -q mirrik-gui "$STUBLOG" 2>/dev/null || echo "the command in the gsettings call is missing"
}
check_xfconf() {
    installed_ok; has_desktop
    grep -q xfconf-query "$STUBLOG" 2>/dev/null || echo "xfconf-query was not called"
}
check_installed_twice() {   # two runs into the same home: block once, and the second run
                            # really went where the first one did
    check_appended
    # installed_ok only proves that *something* is in ~/.local/bin, which stays true even
    # if a later run installed elsewhere. The state file is written by the last run, so it
    # is the one thing that pins down where run 2 actually put the binaries.
    local f="$HOME_UNDER_TEST/.local/state/mirrik/install-state"
    grep -qF "MIRRIK_STATE_BINDIR=$HOME_UNDER_TEST/.local/bin" "$f" 2>/dev/null \
        || echo "the second run installed somewhere other than the first"
}

check_state_written() {   # the state file carries the right values for a block case
    check_appended
    local f="$HOME_UNDER_TEST/.local/state/mirrik/install-state"
    [ -f "$f" ] || { echo "state file was not written"; return 0; }
    grep -qF 'MIRRIK_STATE_WM=1' "$f" || echo "wm not recorded in the state"
    grep -qF "MIRRIK_STATE_BINDIR=$HOME_UNDER_TEST/.local/bin" "$f" || echo "bindir not recorded in the state"
    grep -qF "MIRRIK_STATE_CONFIG=$HOME_UNDER_TEST/$CFG" "$f" || echo "config path not recorded in the state"
    grep -qF 'MIRRIK_STATE_APPS=' "$f" || echo "apps directory missing as a key in the state"
    # Since 0.1.1 the file says which format it is, which version wrote it, and lists
    # what it actually put on disk. Without the format field an older file cannot be told
    # apart from a newer one, which is the whole reason it exists.
    grep -qx 'MIRRIK_STATE_VERSION=1' "$f" || echo "state format version missing"
    grep -q '^MIRRIK_STATE_INSTALLED_VERSION=' "$f" || echo "installed version missing as a key"
    grep -qF 'MIRRIK_STATE_FILES=(' "$f" || echo "manifest missing from the state"
    grep -qF "$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop" "$f" \
        || echo "the .desktop is not in the manifest"
    # The icon may be either the svg or the png - the installer never writes both.
    grep -qF "$HOME_UNDER_TEST/.local/share/icons/hicolor/scalable/apps/mirrik.svg" "$f" \
        || grep -qF "$HOME_UNDER_TEST/.local/share/icons/hicolor/32x32/apps/mirrik.png" "$f" \
        || echo "the icon is not in the manifest"
    grep -qF '.local/state/mirrik' <<<"$OUT" || echo "the state file is not named in the closing block"
}
check_state_gnome() {   # the state file carries keybind_kind=gnome, no block path
    check_gsettings
    local f="$HOME_UNDER_TEST/.local/state/mirrik/install-state"
    [ -f "$f" ] || { echo "state file was not written"; return 0; }
    grep -qF 'MIRRIK_STATE_KEYBIND_KIND=gnome' "$f" || echo "keybind_kind=gnome not recorded in the state"
    # Worth knowing: printf '%q' writes an empty value as two quote characters, not as
    # literally nothing - so we check against '' here rather than an empty line.
    grep -qx "MIRRIK_STATE_CONFIG=''" "$f" \
        || echo "config path is not empty, even though GNOME does not write a config snippet"
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$OUT" \
        || echo "the GNOME undo hint is missing from the closing block"
}
check_manual_hint() { installed_ok; has_desktop; }
check_tool_called() {   # GNOME/Cinnamon/XFCE set the shortcut through a tool
    installed_ok; has_desktop
    # We're not just checking "was it called" here, but "did it actually set something
    # pointing at us" - a bare list-schemas is just the fallback path, not a success.
    grep -q 'mirrik-gui' "$STUBLOG" 2>/dev/null \
        || echo "no call that sets mirrik-gui (only queries?)"
    grep -qE 'gsettings set|xfconf-query .*-s ' "$STUBLOG" 2>/dev/null \
        || echo "no writing call (set) in the log"
}
check_mate_keys() {   # MATE writes different keys than GNOME, into a slot it picks itself
    check_tool_called
    # MATE reads `action`, not `command` - the GNOME/Cinnamon spelling would leave the
    # shortcut sitting there doing nothing, and nothing else in this bench would notice.
    grep -qE "gsettings set org\.mate\.control-center\.keybinding:/org/mate/desktop/keybindings/custom[0-9]+/ action .*mirrik-gui$" "$STUBLOG" 2>/dev/null \
        || echo "no 'action' key set on the MATE schema (the GNOME 'command' spelling?)"
    grep -qE "org\.mate\.control-center\.keybinding:.* command " "$STUBLOG" 2>/dev/null \
        && echo "the MATE schema was given a 'command' key, which MATE never reads"
    # The stubs hand this run one existing slot, custom0, and say it is already called
    # Mirrik - so a run that asks the right question writes back into custom0. Landing
    # on custom1 means the lookup came back empty: that is what a wrong `gsettings get`
    # looks like from outside, silent and one fresh slot per run.
    grep -qF 'keybindings/custom0/ action' "$STUBLOG" 2>/dev/null \
        || echo "did not reuse the existing Mirrik slot (custom0) - did the lookup fail silently?"
    return 0
}
check_abort() {
    [ "$RC" = 0 ] && echo "exit code 0, even though an abort was expected"
    [ -e "$HOME_UNDER_TEST/.local/bin/mirrik" ] && echo "installed despite the expected abort"
    return 0
}
check_msrv_warned_default_no() {   # toolchain too old: warning, "Build them now?" defaults to n
    canary_clean
    grep -q 'One thing first' <<<"$OUT" || echo "no MSRV warning"
    grep -q 'eframe and egui set that floor' <<<"$OUT" || echo "no reasoning given for the MSRV"
    grep -q 'rustup update' <<<"$OUT" || echo "no hint about rustup update"
    check_abort
}
check_msrv_silent_when_fine() {   # sufficient toolchain: no warning, normal abort on n
    canary_clean
    grep -q 'One thing first' <<<"$OUT" && echo "MSRV warning despite a sufficient version"
    check_abort
}
check_pathline() {
    installed_ok; has_desktop
    local rc_file="$HOME_UNDER_TEST/.bashrc"
    [ -f "$rc_file" ] || { echo ".bashrc was not written"; return 0; }
    local n; n=$(grep -c -- '--- Mirrik ---' "$rc_file")
    [ "$n" = 1 ] || echo ".bashrc has $n markers instead of 1"
    grep -q 'local/bin' "$rc_file" || echo "the PATH line does not name the target directory"
}

# Quick note on why answers are a COMMA LIST and not separated by newlines: `read` only
# reads up to the first line break, which left the check function and options blank -
# so every multi-line case used to "pass" without actually checking anything at all.
# --- Abuse and nonsense -------------------------------------------------
# The installer takes text straight from the user and writes it into command lines and
# config files. So these checks aren't asking "does the branch run through" - they're
# asking "can some input make it do something nobody wanted".

canary_clean() {   # nothing outside the test HOME was touched
    for c in /tmp/mirrik-pwned /tmp/mirrik-pwned2; do
        [ -e "$c" ] && { echo "INPUT EXECUTED SOMETHING: $c was created"; rm -f "$c"; }
    done
    return 0
}
check_injection() {   # input with shell metacharacters must execute nothing
    canary_clean
    [ "$RC" = 0 ] || [ "$RC" = 1 ] || echo "unexpected exit code $RC"
    return 0
}
check_survives_nonsense() {   # nonsense input: no crash, no half installation
    canary_clean
    grep -qi 'Traceback\|command not found\|unbound variable\|syntax error' <<<"$OUT" \
        && echo "shell error message in the output"
    if [ -e "$HOME_UNDER_TEST/.local/bin/mirrik" ] && [ ! -e "$HOME_UNDER_TEST/.local/bin/mirrik-gui" ]; then
        echo "half an installation: only one of the two binaries"
    fi
    return 0
}
check_space_warned() {   # space in the target path: warning, and if accepted, Exec quoted
    canary_clean
    grep -q 'contains a space' <<<"$OUT" || echo "no warning about the space"
    local d="$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop"
    [ -f "$d" ] || { echo ".desktop missing"; return 0; }
    local line; line=$(grep '^Exec=' "$d")
    case "$line" in
        *' '*) grep -q '^Exec="' "$d" || echo "Exec contains a space but is not quoted: $line" ;;
    esac
}
check_space_declined() { # warning declined: falls back to ~/.local/bin
    canary_clean
    grep -q 'contains a space' <<<"$OUT" || echo "no warning about the space"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik" ] || echo "no fallback to ~/.local/bin"
}
check_reasked() {   # invalid choice: hint, asked again, then the right branch
    canary_clean
    grep -q 'Not one of the choices' <<<"$OUT" || echo "no repeated question after invalid input"
    check_appended
}
check_no_server_check() {   # without pactl the server cannot be determined
    installed_ok; has_desktop
    grep -q 'pactl is not installed' <<<"$OUT" || echo "no hint about missing pactl"
}
check_old_pw_warned() {
    installed_ok
    grep -q 'too old' <<<"$OUT" || echo "no warning about the old PipeWire version"
    grep -q '0.3.64' <<<"$OUT" || echo "the required minimum version is not named"
}
check_version_unknown() {
    installed_ok
    grep -qi 'could not read the pipewire version' <<<"$OUT" || echo "no hint about the unreadable version"
}
check_generic_hint() {   # unknown distribution: no package command, but a way forward
    installed_ok
    grep -qi 'package manager' <<<"$OUT" || echo "no generic hint for unknown distributions"
    grep -qE 'apt install|pacman -S|dnf install|zypper' <<<"$OUT" && echo "a package command for an unrelated distribution was suggested"
    return 0
}
check_distro_hint_apt()    { installed_ok; grep -q 'apt install' <<<"$OUT" || echo "no apt command for Debian"; }
check_distro_hint_pacman() { installed_ok; grep -q 'pacman -S' <<<"$OUT" || echo "no pacman command for Arch"; }
# These three actually reach the eval branch, so we check what it would really run.
check_apt_called()    { installed_ok; grep -q 'sudo apt install pipewire' "$STUBLOG" 2>/dev/null || echo "apt was not called with the PipeWire packages"; }
check_pacman_called() { installed_ok; grep -q 'sudo pacman -S' "$STUBLOG" 2>/dev/null || echo "pacman was not called"; }
check_dnf_called()    { installed_ok; grep -q 'sudo dnf install' "$STUBLOG" 2>/dev/null || echo "dnf was not called"; }
check_nixos_hint()         { installed_ok; grep -q 'services.pipewire' <<<"$OUT" || echo "no NixOS hint"; grep -q 'sudo ' <<<"$OUT" && echo "NixOS got an imperative install command"; return 0; }
# Regression test for the SIGPIPE-under-pipefail bug: a real ld.so.cache with all four
# libraries present, but big enough (see the filler lines in the ldconfig stub) that the
# old `grep -q` piped straight from `ldconfig -p` would have gotten ldconfig SIGPIPE'd
# and reported a library that is right there as missing. Caught on a real desktop before
# this test existed - install.sh now captures the cache into a variable first instead.
check_gui_libs_present_under_load() {
    installed_ok
    grep -q 'needs these libraries' <<<"$OUT" && echo "a false positive: all four libraries are present in the stub"
}
check_gui_libs_missing_with_hint() {
    installed_ok
    grep -q 'needs these libraries' <<<"$OUT" || echo "no warning even though the stub left libxkbcommon out"
    grep -q 'libxkbcommon.so.0' <<<"$OUT" || echo "the missing library is not named"
    grep -q 'pacman -S --needed mesa' <<<"$OUT" || echo "no Arch-specific install command for the missing GUI library"
}
check_rulev2()  { installed_ok; grep -q 'windowrulev2 = float' <<<"$OUT" || echo "old version did not get windowrulev2"; grep -q 'needs windowrulev2' <<<"$OUT" || echo "no hint about the spelling"; }
check_rule_new(){
    installed_ok
    grep -qE 'windowrule = float' <<<"$OUT" || echo "new version did not get windowrule"
    grep -q 'windowrulev2 = ' <<<"$OUT" && echo "windowrulev2 written despite the new version"
    # Without this check the case would still pass green even if hyprctl was never
    # actually consulted, since the installer falls back to the new spelling either way.
    grep -q 'hyprctl was not found' <<<"$OUT" && echo "hyprctl was not found - this case proves nothing"
    return 0
}
check_rule_assumed() { installed_ok; grep -q 'hyprctl was not found' <<<"$OUT" || echo "no hint that the version was guessed"; }
check_replaces_old() {   # existing version: reported and switched off beforehand
    installed_ok; has_desktop
    grep -q 'Replacing what is already installed: mirrik 0.0.9' <<<"$OUT" \
        || echo "the existing version was not named with its version number"
    grep -q 'old-mirrik off' "$STUBLOG" 2>/dev/null \
        || echo "the running mirror was not switched off"
}
check_found_via_state() {   # no fresh build anywhere, but the state file knows a working one
    installed_ok; has_desktop
    grep -q 'Could not find built binaries' <<<"$OUT" \
        && echo "still claims nothing was found, even though the state file points at a working install"
    grep -qi 'Build them now' <<<"$OUT" \
        && echo "offered to build from source, even though a working install was already there"
    grep -qF "Found them in: $HOME_UNDER_TEST/.local/bin" <<<"$OUT" \
        || echo "did not report finding the binaries at the location the state file named"
}
check_prefers_fresh_over_state() {   # a real build next to the script beats a state-only decoy
    installed_ok; has_desktop
    grep -qF "Found them in: $REPO" <<<"$OUT" \
        || echo "did not prefer the fresh build next to the script over the copy only known from the state file"
}
check_state_ignored_falls_back() {   # a state entry that does not qualify is treated as nothing
    grep -q 'Could not find built binaries' <<<"$OUT" \
        || echo "did not fall back to the normal not-found flow despite an unusable state entry"
    check_abort
}
check_eof() {   # stdin ends in the middle of the questions
    canary_clean
    grep -qi 'unbound variable\|syntax error' <<<"$OUT" && echo "shell error on EOF"
    return 0
}

# --- The state file across two runs ----------------------------------------------
#
# A single run can't tell us whether the closing block handles a second run with
# different answers correctly - for that we need two calls to the installer in the same
# test home. run_case is built around exactly one call, so rather than twisting it out
# of shape, this is its own smaller version of the same idea.
run_installer_once() {  # <home> <path> <answers>
    local home="$1" path="$2" answers="$3"
    (cd "$home" && printf '%s\n' "$(printf '%s' "$answers" | tr ',' '\n')" | env -i \
        HOME="$home" PATH="$path" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
        bash "$INSTALLER" 2>&1)
}

report_case() {  # <name> <problems...>
    local name="$1"; shift
    if [ "$#" -eq 0 ]; then
        printf '  %s✓%s %s\n' "$green" "$off" "$name"; pass=$((pass + 1))
    else
        printf '  %s✗%s %s\n' "$red" "$off" "$name"
        printf '      %s\n' "$@"
        fail=$((fail + 1)); failed_names+=("$name")
    fi
}

# We put a second bin directory on PATH right from the start. Otherwise switching the
# target directory in the second run would also trigger the "not on your PATH" question,
# and that would shift every answer after it by one.
setup_two_phase_home() {  # -> prints "<home> <path>" on stdout
    local home; home="$(mktemp -d)"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/bin2" "$home/.local/share/applications"
    local stubs="$home/stubs"
    make_stubs "$stubs" 'PulseAudio (on PipeWire 1.6.8)'
    local sysbin="$home/sysbin"
    make_minimal_path "$sysbin"
    cp "$stubs/mirrik" "$stubs/mirrik-gui" "$REPO/" 2>/dev/null
    printf '%s %s\n' "$home" "$stubs:$home/.local/bin:$home/.local/bin2:$sysbin"
}

test_state_switch_compositor() {
    local name='state-switch-compositor-stale'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null      # run 1: Hyprland
    local out; out="$(run_installer_once "$home" "$path" "1,$(a y 8 2 a y)")"  # run 2: GNOME
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local cfg="$home/.config/hypr/hyprland.conf"
    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        || problems+=("no hint about the leftover from run 1")
    grep -qF "delete the '# --- Mirrik ---' block from $cfg" <<<"$out" \
        || problems+=("the Hyprland block from run 1 is not named as a leftover")
    grep -qF -- '(if still on GNOME)' <<<"$out" \
        && problems+=("GNOME (the choice from run 2) was wrongly also reported as a leftover")
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$out" \
        || problems+=("the normal GNOME line from run 2 is missing")
    [ -f "$cfg" ] && grep -qF -- '--- Mirrik ---' "$cfg" \
        || problems+=("the Hyprland block was actually removed by run 2 (should stay in place)")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_switch_bindir() {
    local name='state-switch-bindir-stale'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null                  # run 1: ~/.local/bin
    local out; out="$(run_installer_once "$home" "$path" "1,$home/.local/bin2,y,1,2,a,1")"  # run 2: different bindir, block already there
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    [ -x "$home/.local/bin2/mirrik" ] || problems+=("mirrik was not installed into the new bindir")
    [ -x "$home/.local/bin/mirrik" ] || problems+=("the installation from run 1 is gone - it should stay in place")
    grep -q 'Also still there from an earlier run' <<<"$out" \
        || problems+=("no hint about the old bindir from run 1")
    # Since the manifest, each path gets its own rm line - a directory with a space in
    # it used to produce one combined line that silently meant something else.
    grep -qF "rm $home/.local/bin/mirrik" <<<"$out" \
        && grep -qF "rm $home/.local/bin/mirrik-gui" <<<"$out" \
        || problems+=("the rm command for the old bindir is missing or inaccurate")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_no_false_positive() {
    local name='state-unchanged-no-false-stale'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null   # run 1
    local out; out="$(run_installer_once "$home" "$path" "1,$(a y 1 2 a 1)")"  # run 2, same choice, block already there
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        && problems+=("run 2 changes nothing, but reports a leftover")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_skip_carries_forward() {
    local name='state-skipped-no-false-alarm'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 8 2 a y)" >/dev/null   # run 1: GNOME set up
    local out; out="$(run_installer_once "$home" "$path" "1,$(a y 13 2 a)")"  # run 2: step 5 skipped
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        && problems+=("skipping is read as a switch and wrongly reported as a leftover")
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$out" \
        || problems+=("the GNOME undo hint from run 1 is missing, even though run 2 should only carry it forward")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

# Needs its own function, not a CASES entry: typing a *custom* bindir means the answer has
# to name $home, and $home does not exist yet when the CASES table below is written - the
# same reason the other test_state_* functions above build their own environment instead
# of going through run_case.
test_state_source_into_new_target() {
    local name='state-source-into-new-target'
    local home stubs sysbin path out rc problems
    home="$(mktemp -d)"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/bin2" "$home/.local/share/applications"
    stubs="$home/stubs"
    make_stubs "$stubs" 'PulseAudio (on PipeWire 1.6.8)'
    sysbin="$home/sysbin"
    make_minimal_path "$sysbin"

    # No fresh build in $REPO on purpose - that is what proves the copy actually comes
    # from the state-known bindir, and not from a build that happened to be lying around
    # anyway. This is the same setup as found-via-state-no-fresh-build, except this run
    # types a *different* target than the one the state file names, which is the one
    # branch that case cannot reach (there, source and target are the same file).
    cp "$stubs/mirrik" "$stubs/mirrik-gui" "$home/.local/bin/"
    chmod +x "$home/.local/bin/mirrik" "$home/.local/bin/mirrik-gui"
    mkdir -p "$home/.local/state/mirrik"
    printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/bin" > "$home/.local/state/mirrik/install-state"

    path="$stubs:$home/.local/bin:$sysbin"
    out="$(printf '%s\n' "$(printf '%s' "1,$home/.local/bin2$(a y 1 2 a 1 y)" | tr ',' '\n')" | env -i \
        HOME="$home" PATH="$path" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
        bash "$INSTALLER" 2>&1)"
    rc=$?

    problems=()
    [ "$rc" = 0 ] || problems+=("exit code $rc instead of 0")
    [ -x "$home/.local/bin2/mirrik" ]     || problems+=("mirrik was not installed into the new target")
    [ -x "$home/.local/bin2/mirrik-gui" ] || problems+=("mirrik-gui was not installed into the new target")
    grep -q 'Could not find built binaries' <<<"$out" \
        && problems+=("claimed nothing was found, even though the state file names a working install")
    grep -qF "Found them in: $home/.local/bin" <<<"$out" \
        || problems+=("did not report finding the binaries at the state-known location")
    [ -x "$home/.local/bin/mirrik" ] \
        || problems+=("the state-known copy is gone - it should only be read from here, not moved")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

# Regression test for Fund 2 (2026-08-17): install.sh's candidate list used to include
# target/debug, which meant a debug build sitting there got installed silently -
# unoptimised, with debug assertions on. The fix dropped it from the list entirely; this
# proves that holds by putting only a debug pair in place and confirming the installer
# treats that as "nothing found", not as a source to copy from.
#
# Builds its scratch pair under $REPO/target/debug rather than a fake HOME, the same way
# `nobins` already copies stub binaries into $REPO itself for the normal cases - $here in
# install.sh always resolves to the real script directory, never the fake one.
test_target_debug_ignored() {
    local name='target-debug-is-never-a-source'
    local home stubs sysbin path out rc problems
    home="$(mktemp -d)"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share/applications"
    stubs="$home/stubs"
    make_stubs "$stubs" 'PulseAudio (on PipeWire 1.6.8)'
    sysbin="$home/sysbin"
    make_minimal_path "$sysbin"
    path="$stubs:$home/.local/bin:$sysbin"

    mkdir -p "$REPO/target/debug"
    cp "$stubs/mirrik" "$stubs/mirrik-gui" "$REPO/target/debug/"
    chmod +x "$REPO/target/debug/mirrik" "$REPO/target/debug/mirrik-gui"

    # No fresh release build, no copy at the repo root (both would legitimately be
    # found and defeat the point) - only the debug pair exists anywhere reachable.
    # Server is PipeWire by default, so step 2 needs no answer; the first real prompt is
    # "Build them now?" in step 3, which a plain "n" declines.
    out="$(printf 'n\n' | env -i \
        HOME="$home" PATH="$path" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
        bash "$INSTALLER" 2>&1)"
    rc=$?
    rm -rf "$REPO/target/debug"

    problems=()
    [ "$rc" = 0 ] && problems+=("exit code 0 - it should have stopped at the declined build")
    grep -q 'Could not find built binaries' <<<"$out" \
        || problems+=("did not report 'nothing found', even though only a debug build exists")
    grep -qF "Found them in: $REPO/target/debug" <<<"$out" \
        && problems+=("used the debug build as a source - target/debug must never qualify")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

# --- PNG icon branch: no SVG rasterizer in the ldconfig output
check_desktop_png() {
    installed_ok
    local d="$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop"
    [ -f "$d" ] || { echo ".desktop missing"; return 0; }
    grep -q '^Icon=mirrik$' "$d"                    || echo ".desktop has no Icon=mirrik line"
    [ -f "$HOME_UNDER_TEST/$ICON_PNG" ]             || echo "png icon missing"
    [ -f "$HOME_UNDER_TEST/$ICON_SVG" ]             && echo "svg written too - installer should pick one format, not both"
    # And the uninstall block has to know about the PNG too: exactly one entry, not two.
    grep -qF "rm $HOME_UNDER_TEST/$ICON_PNG" <<<"$OUT" \
        || echo "the uninstall block does not name the png"
    # The uninstall text names the file *path*, not the filename - a bare `grep` for
    # `mirrik.??g` here would count the written-to note as a second copy, so count only
    # lines with an rm in them.
    local n; n=$(grep -c "rm $HOME_UNDER_TEST/$ICON_PNG" <<<"$OUT" || true)
    [ "$n" -le 1 ] || echo "the png is named $n times for removal, want at most one"
}
check_desktop_svg() {   # the default, now with a rasterizer in the stub
    installed_ok; has_desktop
    [ -f "$HOME_UNDER_TEST/$ICON_SVG" ] || echo "svg icon missing even though a rasterizer was present"
    [ -f "$HOME_UNDER_TEST/$ICON_PNG" ] && echo "png written too - installer should pick one format, not both"
}

# Regression: a desktop without a rasterizer used to get the SVG anyway - the file
# quietly did nothing in an icon theme with no librsvg/libqsvg in the ld.so.cache.
# The svg branch has been green for a long time - this is the branch that was missing,
# so the red test has to be able to fail for it by itself.
test_state_icon_png_uninstall() {
    local name='state-icon-png-shows-uninstall-commands'
    local home path; read -r home path < <(setup_two_phase_home)

    # Run 1 gets a fake install with a stub ldconfig that does not know the rasterizer
    # - the binary that is there is enough, we only need the PNG this run writes.
    local stubs="$home/stubs"
    STUB_RASTERIZER=no make_stubs "$stubs" 'PulseAudio (on PipeWire 1.6.8)'
    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)"

    # Back to the real stubs for run 2, so the "existing installation" menu opens on
    # its own. If run 1's PNG survives in the state file, run 2 has to name it.
    make_stubs "$stubs" 'PulseAudio (on PipeWire 1.6.8)'
    local out; out="$(run_installer_once "$home" "$path" "2")"
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -qF "rm $home/$ICON_PNG" <<<"$out" \
        || problems+=("the png rm command is missing")
    grep -qF "rm $home/$ICON_SVG" <<<"$out" \
        && problems+=("the svg rm command is there too - only one format was ever written")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -20 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}
test_state_legacy_migrates() {
    local name='state-legacy-file-migrates-to-manifest'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null
    # Rewrite the state file exactly the way 0.1.0 wrote it: no format version, no
    # manifest, just the directories. The undo block still has to name every file - that
    # is what a format version buys you, and this case is the proof.
    local sf="$home/.local/state/mirrik/install-state"
    {
        printf 'MIRRIK_STATE_WM=%s\n'    '1'
        printf 'MIRRIK_STATE_BINDIR=%s\n' "$home/.local/bin"
        printf 'MIRRIK_STATE_APPS=%s\n'   "$home/.local/share/applications"
        printf 'MIRRIK_STATE_ICONS=%s\n'  "$home/.local/share/icons/hicolor/scalable/apps"
        printf "MIRRIK_STATE_PATH_RC=''\n"
        printf "MIRRIK_STATE_CONFIG=''\n"
        printf "MIRRIK_STATE_KEYBIND_KIND=''\n"
    } > "$sf"

    local out; out="$(run_installer_once "$home" "$path" "2")"
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -qF "rm $home/.local/bin/mirrik" <<<"$out" \
        || problems+=("the binary is missing after migrating a version-less state file")
    grep -qF "rm $home/.local/share/applications/mirrik.desktop" <<<"$out" \
        || problems+=("the .desktop is missing after migrating a version-less state file")
    # The legacy migration only ever names the *svg* file - it is what the 0.1.0
    # era script actually wrote. The new png format has no legacy file to migrate.
    grep -qF "rm $home/$ICON_SVG" <<<"$out" \
        || problems+=("the icon is missing after migrating a version-less state file")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -20 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_newer_file_ignored() {
    local name='state-newer-file-is-not-guessed-at'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null
    # A file from a script we do not know. Naming files out of it would be guessing, so
    # the removal list must stay empty rather than claim something that may be wrong.
    local sf="$home/.local/state/mirrik/install-state"
    {
        printf 'MIRRIK_STATE_VERSION=%s\n'  '99'
        printf 'MIRRIK_STATE_BINDIR=%s\n'   "$home/.local/bin"
        printf "MIRRIK_STATE_APPS=''\n"
        printf "MIRRIK_STATE_ICONS=''\n"
        # A manifest that looks perfectly usable. That is the point: the guard has to
        # refuse it because of the format number, not because there was nothing to read.
        printf 'MIRRIK_STATE_FILES=(%q %q)\n' \
            "$home/.local/share/applications/mirrik.desktop" \
            "$home/$ICON_SVG"
        printf "MIRRIK_STATE_PATH_RC=''\n"
        printf "MIRRIK_STATE_CONFIG=''\n"
        printf "MIRRIK_STATE_KEYBIND_KIND=''\n"
    } > "$sf"

    local out; out="$(run_installer_once "$home" "$path" "2")"
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -qF "rm $home/.local/share/applications/mirrik.desktop" <<<"$out" \
        && problems+=("named files out of a state file whose format it does not know")
    grep -q "rm -r $home/.local/state/mirrik" <<<"$out" \
        || problems+=("the state directory should still be offered, it is ours either way")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -20 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_config_hint() {
    local name='own-config-is-offered-separately'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null
    local without; without="$(run_installer_once "$home" "$path" "2")"

    # A config Mirrik never wrote. It has to be named, and named as the user's own, not
    # swept in with our leftovers.
    mkdir -p "$home/.config/mirrik"
    printf '# mine\n' > "$home/.config/mirrik/config.toml"
    local with; with="$(run_installer_once "$home" "$path" "2")"
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -qF "$home/.config/mirrik/config.toml" <<<"$without" \
        && problems+=("offered to remove a config that does not exist")
    grep -qF "rm $home/.config/mirrik/config.toml" <<<"$with" \
        || problems+=("the existing config is not named at all")
    grep -qF 'Mirrik never wrote that file' <<<"$with" \
        || problems+=("the config is named but not marked as the user's own")
    [ -f "$home/.config/mirrik/config.toml" ] \
        || problems+=("the config was actually deleted - this path only shows commands")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$with" | tail -20 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_uninstall_shown() {
    local name='existing-install-shows-uninstall-commands'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null
    local out; out="$(run_installer_once "$home" "$path" "2")"
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local cfg="$home/.config/hypr/hyprland.conf"
    local problems=()
    grep -q 'An existing installation' <<<"$out" \
        || problems+=("the existing-installation menu did not appear")
    # Since the manifest, each path gets its own rm line - a directory with a space in
    # it used to produce one combined line that silently meant something else.
    grep -qF "rm $home/.local/bin/mirrik" <<<"$out" \
        && grep -qF "rm $home/.local/bin/mirrik-gui" <<<"$out" \
        || problems+=("the binary rm command is missing")
    grep -qF "delete the '# --- Mirrik ---' block from $cfg" <<<"$out" \
        || problems+=("the config block removal hint is missing")
    grep -qF "rm $home/.local/share/applications/mirrik.desktop" <<<"$out" \
        || problems+=("the .desktop rm command is missing")
    grep -qF "rm $home/$ICON_SVG" <<<"$out" \
        || problems+=("the icon rm command is missing")
    grep -q "rm -r $home/.local/state/mirrik" <<<"$out" \
        || problems+=("the state directory rm command is missing")
    grep -q 'Which one are you running' <<<"$out" \
        && problems+=("ran through the normal setup instead of stopping right after the uninstall block")
    [ -x "$home/.local/bin/mirrik" ] \
        || problems+=("the binary was actually deleted - this path only shows commands, it does not run them")
    [ -f "$cfg" ] && grep -qF -- '--- Mirrik ---' "$cfg" \
        || problems+=("the config block was actually removed - this path only shows commands")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

a() {  # <desktop:y|n> <wm> <mods> <key> [more answers...]
    local d="$1" wm="$2" mods="$3" key="$4"; shift 4
    local rest=""; for x in "$@"; do rest="$rest,$x"; done
    printf ',%s,%s,%s,%s%s' "$d" "$wm" "$mods" "$key" "$rest"
}

CASES=(
  "hyprland-append|$(a y 1 2 a 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "over-old-version|$(a y 1 2 a 1 y)|check_replaces_old|cfg=.config/hypr/hyprland.conf;preinstalled=0.0.9"
  "found-via-state-no-fresh-build|1,$(a y 1 2 a 1 y)|check_found_via_state|cfg=.config/hypr/hyprland.conf;nobins=1;stateonly=1"
  "fresh-build-beats-state-decoy|1,$(a y 1 2 a 1 y)|check_prefers_fresh_over_state|cfg=.config/hypr/hyprland.conf;statedecoy=1"
  "state-partial-pair-falls-back|n|check_state_ignored_falls_back|nobins=1;statepartial=1"
  "state-non-executable-falls-back|n|check_state_ignored_falls_back|nobins=1;statenoexec=1"
  "state-file-unreadable-falls-back|n|check_state_ignored_falls_back|nobins=1;statefileunreadable=1"
  "sway-append|$(a y 2 2 a 1 y)|check_appended|cfg=.config/sway/config"
  "i3-append|$(a y 3 2 a 1 y)|check_appended|cfg=.config/i3/config"
  "river-append|$(a y 5 2 a 1 y)|check_appended|cfg=.config/river/init"
  "awesome-append|$(a y 6 2 a 1 y)|check_appended|cfg=.config/awesome/rc.lua"
  "bspwm-append|$(a y 7 2 a 1 y)|check_appended|cfg=.config/sxhkd/sxhkdrc"
  "hyprland-print|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf"
  "hyprland-old-0.48|$(a y 1 2 a 2)|check_rulev2|cfg=.config/hypr/hyprland.conf;hyprversion=0.48.1"
  "hyprland-new-0.56|$(a y 1 2 a 2)|check_rule_new|cfg=.config/hypr/hyprland.conf;hyprversion=0.56.2"
  "hyprland-exact-0.49|$(a y 1 2 a 2)|check_rule_new|cfg=.config/hypr/hyprland.conf;hyprversion=0.49.0"
  "hyprland-without-hyprctl|$(a y 1 2 a 2)|check_rule_assumed|cfg=.config/hypr/hyprland.conf"
  "niri-print|$(a y 4 2 a 2)|check_printed_niri|cfg=.config/niri/config.kdl"
  "sway-print|$(a y 2 2 a 2)|check_printed|cfg=.config/sway/config"
  "config-missing|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf;pre=none"
  "block-already-there|$(a y 1 2 a 1)|check_untouched|cfg=.config/hypr/hyprland.conf;pre=marker"
  # The second run opens with "update or show me how to remove it", so it needs a 1 in
  # front - and a comma after it, because a() already starts with an empty field (the
  # "install into" question, answered by accepting the default). Getting that wrong is
  # exactly what happened here for a long time: the answers slid by one, the install
  # directory question got a "y", and run 2 quietly installed into a relative directory
  # called y/ in the working tree. The case stayed green the whole time, proving nothing
  # about installing twice into the same place.
  "installed-twice|$(a y 1 2 a 1 y)|check_installed_twice|cfg=.config/hypr/hyprland.conf;repeat=2;again=1,$(a y 1 2 a 1 y)"
  "lua-detected|$(a y 1 2 a 2)|check_lua_hint|cfg=.config/hypr/hyprland.conf;lua=1"
  # The real bug: a Lua setup usually has no hyprland.conf at all, since nothing ever
  # reads it. This is the case that slipped through before the "does it exist" check
  # was reordered behind the Lua check - found on a real run, not in this bench.
  "lua-detected-no-conf-file|$(a y 1 2 a 2)|check_lua_hint|cfg=.config/hypr/hyprland.conf;lua=1;pre=none"
  "gnome-gsettings|$(a y 8 2 a y)|check_gsettings|"
  "state-file-hyprland|$(a y 1 2 a 1 y)|check_state_written|cfg=.config/hypr/hyprland.conf"
  "state-file-gnome|$(a y 8 2 a y)|check_state_gnome|"
  # PAUSED FOR NOW: Cinnamon makes it all the way through to "Done" but never actually
  # calls gsettings. Still haven't figured out whether that branch just wants different
  # answers, or whether something's genuinely missing.
  #   "cinnamon-gsettings|,y,9,2,a,y|check_gsettings|"
  "xfce-xfconf|$(a y 11 2 a y)|check_xfconf|"
  "kde-hint|$(a y 10 2 a)|check_manual_hint|"
  "something-else-hint|$(a y 12 2 a)|check_manual_hint|"
  "step-skipped|$(a y 13 2 a)|check_manual_hint|"
  "mods-super|$(a y 1 1 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "mods-alt|$(a y 1 3 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "mods-ctrl-alt|$(a y 1 4 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "key-digit|$(a y 1 2 5 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "key-default|$(a y 1 2 '' 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "desktop-declined|$(a n 1 2 a 2)|no_desktop|cfg=.config/hypr/hyprland.conf"
  "path-line|,y,y,1,2,a,1,y|check_pathline|cfg=.config/hypr/hyprland.conf;nopath=1"
  "pulseaudio-abort|n|check_abort|server=PulseAudio;cfg=.config/hypr/hyprland.conf"
  "no-audio-server|n|check_abort|server=;cfg=.config/hypr/hyprland.conf"
  # Thanks to the minimal PATH (no /usr/bin), "missing=" here genuinely has an effect.
  "without-pw-cli-aborted|n|check_abort|missing=pw-cli;cfg=.config/hypr/hyprland.conf"
  "without-pw-cli-continued|n,y,,y,1,2,a,1,y|check_appended|missing=pw-cli;cfg=.config/hypr/hyprland.conf"
  "without-pactl|n,y,,y,1,2,a,1,y|check_no_server_check|missing=pactl;cfg=.config/hypr/hyprland.conf"
  # --- Versions
  "pipewire-too-old-aborted|n|check_abort|server=PulseAudio (on PipeWire 0.3.48);cfg=.config/hypr/hyprland.conf"
  "pipewire-too-old-continued|y,,y,1,2,a,1,y|check_old_pw_warned|server=PulseAudio (on PipeWire 0.3.48);cfg=.config/hypr/hyprland.conf"
  "pipewire-exact-0364|,y,1,2,a,1,y|check_appended|server=PulseAudio (on PipeWire 0.3.64);cfg=.config/hypr/hyprland.conf"
  "pipewire-version-unreadable|,y,1,2,a,1,y|check_version_unknown|server=PipeWire;cfg=.config/hypr/hyprland.conf"
  # --- Distributions (os-release is substituted in)
  "distro-unknown|y,,y,1,2,a,1,y|check_generic_hint|missing=pw-cli;osrelease=exotix;cfg=.config/hypr/hyprland.conf"
  "distro-debian-declined|n,y,,y,1,2,a,1,y|check_distro_hint_apt|missing=pw-cli;osrelease=debian;cfg=.config/hypr/hyprland.conf"
  "distro-debian-executed|y,y,,y,1,2,a,1,y|check_apt_called|missing=pw-cli;osrelease=debian;cfg=.config/hypr/hyprland.conf"
  "distro-arch-executed|y,y,,y,1,2,a,1,y|check_pacman_called|missing=pw-cli;osrelease=arch;cfg=.config/hypr/hyprland.conf"
  "distro-fedora-executed|y,y,,y,1,2,a,1,y|check_dnf_called|missing=pw-cli;osrelease=fedora;cfg=.config/hypr/hyprland.conf"
  "distro-nixos|y,,y,1,2,a,1,y|check_nixos_hint|missing=pw-cli;osrelease=nixos;cfg=.config/hypr/hyprland.conf"
  # --- GUI-library check (step 1): a WAYLAND_DISPLAY session, a stubbed ldconfig
  "gui-libs-present-under-load|$(a y 1 2 a 1 y)|check_gui_libs_present_under_load|cfg=.config/hypr/hyprland.conf;wayland=1"
  "gui-libs-missing-with-hint|$(a y 1 2 a 1 y)|check_gui_libs_missing_with_hint|cfg=.config/hypr/hyprland.conf;wayland=1;osrelease=arch;ldconfigmissing=libxkbcommon.so.0"
  "without-binaries-without-cargo||check_abort|nobins=1;missing=cargo"
  "without-binaries-build-declined|n|check_abort|nobins=1"
  # --- MSRV: read from the real copy's Cargo.toml, not duplicated in the test case
  "msrv-too-old-default-no||check_msrv_warned_default_no|nobins=1;cargoversion=1.70.0"
  "msrv-sufficient-silent|n|check_msrv_silent_when_fine|nobins=1;cargoversion=2.0.0"
  # --- Abuse: shell metacharacters in the two free-text fields
  "injection-key|,y,1,2,a\";touch /tmp/mirrik-pwned;#,a,1,y|check_injection|cfg=.config/hypr/hyprland.conf"
  "injection-bindir|/tmp/x\";touch /tmp/mirrik-pwned2;#,y,1,2,a,2|check_injection|cfg=.config/hypr/hyprland.conf"
  "space-accepted|/tmp/mirrik test bin,y,y,y,1,2,a,1,y|check_space_warned|cfg=.config/hypr/hyprland.conf"
  "space-declined|/tmp/mirrik test bin,n,y,1,2,a,1,y|check_space_declined|cfg=.config/hypr/hyprland.conf"
  # --- Nonsense instead of a choice
  "wm-number-too-large-then-valid|,y,99,1,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "wm-letters-then-valid|,y,abc,1,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "mods-nonsense-then-valid|,y,1,9,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "kind-nonsense-then-valid|,y,1,2,a,7,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "key-multichar-then-valid|,y,1,2,abc,a,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  "key-special-char-then-valid|,y,1,2,%,q,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  # --- stdin ends prematurely
  # --- PNG icon branch, new in 0.1.2: a desktop with no SVG rasterizer in the
  # ld.so.cache gets the PNG instead, and never both files at once.
  "icon-png-without-rasterizer|$(a y 1 2 a 1 y)|check_desktop_png|wayland=1;noraster=1"
  "icon-svg-with-rasterizer|$(a y 1 2 a 1 y)|check_desktop_svg|wayland=1"
  "icon-declined-with-rasterizer|$(a n 1 2 a 2)|no_desktop|cfg=.config/hypr/hyprland.conf;wayland=1"
  "icon-declined-without-rasterizer|$(a n 1 2 a 2)|no_desktop|cfg=.config/hypr/hyprland.conf;wayland=1;noraster=1"
  "eof-immediately||check_eof|cfg=.config/hypr/hyprland.conf"
  "eof-after-three|,y,1|check_eof|cfg=.config/hypr/hyprland.conf"
)

# If the generated full matrix happens to sit next to this script, we load it in too -
# that way the hand-written special cases stay up top, and the full enumeration just
# comes along after them.
if [ -f "$REPO/tools/linux/matrix-cases.txt" ] && [ -z "${NO_MATRIX:-}" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        CASES+=("$line")
    done < "$REPO/tools/linux/matrix-cases.txt"
fi

filter="${1:-}"
echo "install.sh — test bench"
echo "${dim}A stub HOME per case, the real system untouched${off}"
echo
for entry in "${CASES[@]}"; do
    IFS='|' read -r name answers check opts <<<"$entry"
    [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
    run_case "$name" "$answers" "$check" "$opts"
done

# These two-run cases don't go through the CASES table, since they each need two
# different sequences of answers in the same test home instead of just one.
for fn in test_state_switch_compositor test_state_switch_bindir \
          test_state_no_false_positive test_state_skip_carries_forward \
          test_state_source_into_new_target test_state_uninstall_shown \
          test_state_legacy_migrates test_state_newer_file_ignored \
          test_state_config_hint test_target_debug_ignored \
          test_state_icon_png_uninstall; do
    [ -n "$filter" ] && [[ "$fn" != *"$filter"* ]] && continue
    "$fn"
done
# Only meaningful for a full run: a filtered one skips the cases that would have created
# the entry, so reporting a clean tree then would say nothing.
if [ -z "$filter" ]; then
    repo_after="$(ls -A "$REPO")"
    if [ "$repo_before" != "$repo_after" ]; then
        stray="$(comm -13 <(printf '%s\n' "$repo_before" | sort) <(printf '%s\n' "$repo_after" | sort) | tr '\n' ' ')"
        report_case 'bench-leaves-the-repository-alone' "left behind in the repo: $stray"
    else
        report_case 'bench-leaves-the-repository-alone'
    fi
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || { printf '  Failed: %s\n' "${failed_names[*]}"; exit 1; }
