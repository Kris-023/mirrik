#!/usr/bin/env bash
#
# Guided setup for Mirrik on Linux.
#
# Checks what Mirrik actually needs at runtime, installs the two binaries, adds a desktop
# entry, and works out the key-binding line for your compositor or desktop. Every step
# asks first, and nothing is written to a config file without showing you the exact lines
# beforehand.
#
# Usage:  ./install.sh

set -euo pipefail

# ---------------------------------------------------------------- small helpers

if [ -t 1 ]; then
    C_HEAD=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'; C_DIM=$'\033[90m'; C_OFF=$'\033[0m'
else
    C_HEAD=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

say()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok()   { printf '%s%s%s\n' "$C_OK" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_WARN" "$*" "$C_OFF"; }
err()  { printf '%s%s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; }

heading() {
    printf '\n%s%s%s\n' "$C_HEAD" "$1" "$C_OFF"
    printf '%s%s%s\n' "$C_DIM" "$(printf '%*s' "${#1}" '' | tr ' ' '-')" "$C_OFF"
}

ask() {  # ask <question> <default> -> answer on stdout
    local answer
    read -r -p "$1 [$2]: " answer
    printf '%s' "${answer:-$2}"
}

confirm() {  # confirm <question> [y|n]  -> exit status
    local default="${2:-y}" hint answer
    if [ "$default" = y ]; then hint='Y/n'; else hint='y/N'; fi
    while true; do
        read -r -p "$1 [$hint]: " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     dim '  Please answer y or n.' ;;
        esac
    done
}

have() { command -v "$1" >/dev/null 2>&1; }

# We compare with sort -V here on purpose. Plain text or numeric sorting would rank
# 0.3.9 above 0.3.64, which is just wrong.
version_ge() {  # version_ge <have> <want>  -> 0 if have >= want
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Picks from a fixed list. Type something that's not on the list and we just ask again -
# we never want a typo to quietly turn into a choice nobody actually made. An empty
# answer takes the default, which is what pressing Enter (or hitting an early end of
# stdin) is supposed to do anyway.
choose() {  # choose <question> <default> <allowed...>
    local question="$1" default="$2"; shift 2
    local answer allowed=("$@") v
    while true; do
        answer="$(ask "$question" "$default")"
        for v in "${allowed[@]}"; do
            [ "$answer" = "$v" ] && { printf '%s' "$answer"; return 0; }
        done
        # This has to go to stderr. choose runs inside a command substitution, so
        # anything we print to stdout would get swallowed into the return value instead
        # of reaching the person reading it.
        dim "  Not one of the choices. Pick from: ${allowed[*]}" >&2
    done
}

# Appends a block to a config file, but only once. The markers are there so both this
# script and a human can find it again.
#
# Two spellings, because not every config file is shell-shaped: awesome's rc.lua is Lua,
# where `#` is the length operator and a `#` comment is a syntax error that takes the
# whole desktop down with it. Only the text between the dashes is searched for, so either
# spelling is recognised.
MARK_TEXT='--- Mirrik ---'
MARK_OPEN="# $MARK_TEXT"
MARK_CLOSE='# --- end Mirrik ---'
LUA_OPEN="-- $MARK_TEXT"
LUA_CLOSE='-- --- end Mirrik ---'

append_block() {  # append_block <file> <block> <what to say afterwards>
    local file="$1" block="$2" done_msg="$3"
    # -e, because the marker starts with a dash and grep would read it as an option.
    if [ -f "$file" ] && grep -qFe "$MARK_TEXT" "$file"; then
        warn "  $file already has a Mirrik block. Leaving it alone."
        dim "  Delete the old block by hand first if you want to change the key."
        return 0
    fi
    confirm "  Append them to $file?" || { dim '  Not written. Copy them in whenever you like.'; return 0; }
    mkdir -p "$(dirname "$file")"
    printf '\n%s\n' "$block" >> "$file"
    ok "  $done_msg"
    dim "  To undo: delete the block between the two '# --- Mirrik ---' lines."
}

# ---------------------------------------------------------------- state from earlier runs
#
# A small file remembers what a previous run actually wrote, so the closing "to undo"
# list can name exactly what is there instead of a generic guess - and so it can flag
# what a *different* earlier choice (a different compositor, a different install
# directory) left behind. This is read-only here: nothing is deleted or changed on the
# strength of it, the values only ever end up printed for the person running this
# script - same rule as every other destructive step in this file.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/mirrik"
statefile="$state_dir/install-state"
MIRRIK_STATE_WM=''; MIRRIK_STATE_BINDIR=''; MIRRIK_STATE_APPS=''
MIRRIK_STATE_PATH_RC=''; MIRRIK_STATE_CONFIG=''; MIRRIK_STATE_KEYBIND_KIND=''
# shellcheck disable=SC1090
[ -r "$statefile" ] && . "$statefile"

write_state() {  # persists this run's outcome, overwriting whatever was read above
    mkdir -p "$state_dir"
    {
        printf 'MIRRIK_STATE_WM=%q\n' "$state_wm"
        printf 'MIRRIK_STATE_BINDIR=%q\n' "$bindir"
        printf 'MIRRIK_STATE_APPS=%q\n' "$state_apps"
        printf 'MIRRIK_STATE_PATH_RC=%q\n' "$path_rc"
        printf 'MIRRIK_STATE_CONFIG=%q\n' "$state_config"
        printf 'MIRRIK_STATE_KEYBIND_KIND=%q\n' "$state_keybind_kind"
    } > "$statefile"
}

# ---------------------------------------------------------------- 0. what this is

cat <<'BANNER'

  M I R R I K
  Play the same sound on two or more output devices at once.

  This script will, asking before each step:
    1. check that everything Mirrik needs at runtime is present
    2. install mirrik and mirrik-gui into a directory on your PATH
    3. add a desktop entry so it shows up in your application launcher
    4. work out the key-binding line for your compositor or desktop

  No root except where you explicitly allow it, no system service, nothing
  outside your home directory.

BANNER

# ---------------------------------------------------------------- 1. runtime needs

heading '1. What Mirrik needs to be there'

# Mirrik drives PipeWire through its own command line tools rather than linking against
# libpipewire, so these four have to exist. They are easy to miss: a system can be running
# PipeWire perfectly and still not have pw-cli installed, because several distributions
# split the daemon and its tools into separate packages.
missing=()
for tool in pactl pw-cli pw-dump pw-metadata; do
    have "$tool" || missing+=("$tool")
done

# Distribution family, for naming the packages rather than guessing at them.
distro_id=''; distro_like=''; distro_name='your distribution'
# This path can be overridden so the test bench can exercise every distribution branch
# without actually being that distribution. Day to day, it's just /etc/os-release.
os_release="${MIRRIK_OS_RELEASE:-/etc/os-release}"
if [ -r "$os_release" ]; then
    # shellcheck disable=SC1091
    . "$os_release"
    distro_id="${ID:-}"; distro_like="${ID_LIKE:-}"; distro_name="${PRETTY_NAME:-${NAME:-$distro_id}}"
fi

install_hint=''
case " $distro_id $distro_like " in
    *" debian "*|*" ubuntu "*)
        install_hint='sudo apt install pipewire pipewire-pulse pipewire-bin pulseaudio-utils' ;;
    *" fedora "*|*" rhel "*|*" centos "*)
        install_hint='sudo dnf install pipewire pipewire-pulseaudio pipewire-utils pulseaudio-utils' ;;
    *" arch "*|*" archlinux "*|*" manjaro "*|*" endeavouros "*)
        install_hint='sudo pacman -S --needed pipewire pipewire-pulse libpulse' ;;
    *" suse "*|*" opensuse "*|*" opensuse-tumbleweed "*|*" opensuse-leap "*)
        install_hint='sudo zypper install pipewire pipewire-pulseaudio pipewire-tools pulseaudio-utils' ;;
    *" alpine "*)
        install_hint='sudo apk add pipewire pipewire-pulse pipewire-tools pulseaudio-utils' ;;
    *" void "*)
        install_hint='sudo xbps-install -S pipewire pulseaudio-utils' ;;
    *" gentoo "*)
        install_hint='sudo emerge media-video/pipewire media-sound/pulseaudio-daemon' ;;
    *" nixos "*)
        install_hint='NIXOS' ;;
esac

# Silverblue, Kinoite, Bazzite and the rest of the image-based Fedoras look exactly like
# Fedora in os-release, but dnf cannot write to /usr there. They layer packages instead,
# and the change only lands after a reboot.
if [ -e /run/ostree-booted ] && have rpm-ostree; then
    install_hint='sudo rpm-ostree install pipewire pipewire-pulseaudio pipewire-utils pulseaudio-utils'
fi

if [ ${#missing[@]} -eq 0 ]; then
    ok "  All four present: pactl, pw-cli, pw-dump, pw-metadata"
else
    warn "  Missing: ${missing[*]}"
    say ''
    dim "  Detected: $distro_name"
    say ''
    if [ "$install_hint" = NIXOS ]; then
        dim '  On NixOS nothing gets installed imperatively. Put this in your configuration'
        dim '  and rebuild:'
        say ''
        say '    services.pipewire = {'
        say '      enable = true;'
        say '      pulse.enable = true;   # provides pactl'
        say '    };'
        say '    environment.systemPackages = [ pkgs.pipewire ];   # provides pw-cli and friends'
        say ''
        confirm '  Continue anyway?' n || exit 1
    elif [ -n "$install_hint" ]; then
        dim '  On this system that is:'
        say "    $install_hint"
        say ''
        if confirm '  Run it now? (asks for your password)' n; then
            eval "$install_hint"
            missing=()
            for tool in pactl pw-cli pw-dump pw-metadata; do
                have "$tool" || missing+=("$tool")
            done
            if [ ${#missing[@]} -eq 0 ]; then
                ok '  All four present now.'
            else
                warn "  Still missing: ${missing[*]}"
                confirm '  Continue anyway?' n || exit 1
            fi
        else
            dim '  Skipped. Mirrik will refuse to start until they are there.'
            confirm '  Continue anyway?' n || exit 1
        fi
    else
        dim '  Install PipeWire, its PulseAudio layer and its command line tools with your'
        dim '  package manager. The tools are often a separate package - Debian calls it'
        dim '  pipewire-bin, Fedora pipewire-utils, and pactl usually lives in something'
        dim '  named after PulseAudio even on a PipeWire system.'
        say ''
        confirm '  Continue anyway?' n || exit 1
    fi
fi

# The window is OpenGL, and eframe loads GL, Wayland and xkbcommon with dlopen rather
# than linking them - `ldd mirrik-gui` lists libc and little else, so a missing one stays
# invisible until the window refuses to open. The command line half does not care, which
# is why this warns instead of stopping.
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && have ldconfig; then
    gui_missing=()
    for lib in libGL.so.1 libxkbcommon.so.0; do
        ldconfig -p 2>/dev/null | grep -q "$lib" || gui_missing+=("$lib")
    done
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        ldconfig -p 2>/dev/null | grep -q libwayland-client.so.0 || gui_missing+=(libwayland-client.so.0)
    else
        ldconfig -p 2>/dev/null | grep -q libX11.so.6 || gui_missing+=(libX11.so.6)
    fi
    if [ ${#gui_missing[@]} -gt 0 ]; then
        say ''
        warn "  The window needs these at runtime and they are not installed: ${gui_missing[*]}"
        dim '  They are loaded on demand, so nothing complains until the window opens and'
        dim '  then does not. The command line half works either way.'
        dim '  Look for packages named mesa or libglvnd, libxkbcommon, and libwayland.'
    fi
fi

# ---------------------------------------------------------------- 2. is it PipeWire

heading '2. Checking your audio server'

if have pactl; then
    server="$(pactl info 2>/dev/null | sed -n 's/^Server Name: //p' || true)"
    if printf '%s' "$server" | grep -qi pipewire; then
        ok "  PipeWire it is: $server"

        # Here's why we care about the exact version: Mirrik hooks its loopbacks onto a
        # device with `target.object`, a property that only exists from PipeWire 0.3.64
        # onwards. On anything older it was called `node.target` instead, and paired
        # with `node.dont-reconnect` an old version just quietly refuses to connect -
        # no error, no sound, nothing to go on. Way better to catch that now than to
        # leave someone wondering why nothing happens after they press the hotkey.
        # One detail that matters: the `|| true` at the end isn't just for show. grep
        # exits 1 when it finds nothing, and since we're running under `set -e`, that
        # would kill this assignment (and the whole script with it). Without it, a
        # server that doesn't report a version number would silently kill the installer.
        pw_version="$(printf '%s' "$server" | grep -oiE 'pipewire[ -]*[0-9]+(\.[0-9]+)+' | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
        if [ -z "$pw_version" ] && have pw-cli; then
            pw_version="$(pw-cli --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
        fi

        if [ -z "$pw_version" ]; then
            dim '  (Could not read the PipeWire version; 0.3.64 or newer is required.)'
        elif version_ge "$pw_version" 0.3.64; then
            ok "  Version $pw_version is new enough (0.3.64 or newer required)."
        else
            warn "  PipeWire $pw_version is too old. Mirrik needs 0.3.64 or newer."
            say ''
            dim '  Mirrik attaches its loopback with `target.object`, which older versions'
            dim '  do not know. They do not report an error - the mirror simply never'
            dim '  connects, and nothing plays on the second device.'
            dim '  Ubuntu 22.04 and Debian bullseye ship older versions; a backport or a'
            dim '  newer release fixes this.'
            say ''
            confirm '  Install anyway?' n || exit 1
        fi
    elif [ -z "$server" ]; then
        warn '  No audio server answered. Is the session running?'
        dim '  If you are on a fresh install, `systemctl --user status pipewire` is the'
        dim '  place to look. On some distributions the service needs enabling once:'
        dim '    systemctl --user enable --now pipewire pipewire-pulse'
        say ''
        confirm '  Continue anyway?' n || exit 1
    else
        warn "  Your audio server reports itself as: $server"
        say ''
        dim '  Mirrik requires PipeWire and refuses to run on plain PulseAudio. That is'
        dim '  deliberate: there, a loopback belongs to the daemon and would survive a'
        dim '  crash of this tool - which breaks its one promise, that switching off'
        dim '  leaves nothing behind.'
        say ''
        dim '  Most distributions can swap PulseAudio for PipeWire without touching'
        dim '  anything else; the package to look for is pipewire-pulse or'
        dim '  pipewire-pulseaudio.'
        say ''
        confirm '  Install anyway?' n || exit 1
    fi
else
    warn '  pactl is not installed, so the audio server cannot be identified. Skipping.'
fi

# ---------------------------------------------------------------- 3. binaries

heading '3. The program itself'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir=''
# Only release builds and the script's own folder. `target/debug` is deliberately not a
# candidate: a stray debug build there would be installed over a proper release without
# anyone noticing.
for dir in "$here/target/release" "$here"; do
    if [ -x "$dir/mirrik" ] && [ -x "$dir/mirrik-gui" ]; then
        source_dir="$dir"
        break
    fi
done

if [ -z "$source_dir" ]; then
    warn '  Could not find built binaries next to this script.'
    if have cargo; then
        dim '  Rust is installed, so they can be built now. The first build takes a few'
        dim '  minutes and needs an internet connection for the dependencies.'

        # Read from the workspace itself rather than duplicated here - measured with
        # `cargo msrv`; a copy in this script would drift the moment either the
        # toolchain or the dependencies move. Missing either number
        # (older Cargo.toml, `cargo --version` failing) just skips the check silently -
        # nothing here is worth blocking an install over.
        cargo_version="$(cargo --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
        msrv="$(grep -m1 '^rust-version' "$here/Cargo.toml" | grep -oE '[0-9]+(\.[0-9]+)+' || true)"
        build_default=y
        if [ -n "$cargo_version" ] && [ -n "$msrv" ] && ! version_ge "$cargo_version" "$msrv"; then
            say ''
            warn "  One thing first: Rust $cargo_version is installed, but Mirrik needs"
            warn "  $msrv or newer - eframe and egui set that floor. Building with an older"
            warn '  toolchain does not fail with a message about Rust being too old; it fails'
            warn '  with compiler errors from crates that have nothing to do with Mirrik.'
            dim '  `rustup update` gets you there, or your package manager'"'"'s usual upgrade path.'
            say ''
            build_default=n
        fi

        # -p even though the workspace's default-members already exclude the foreign
        # backend: this way the build does not silently depend on a setting in a file the
        # installer never reads. Without either, cargo would build backend-windows here
        # and stop with 16 errors from `windows-future`.
        if confirm '  Build them now?' "$build_default"; then
            cargo build --release --manifest-path "$here/Cargo.toml" \
                        -p mirrik-cli -p mirrik-gui
            source_dir="$here/target/release"
        else
            dim '  Nothing was changed. Build them yourself with:'
            say "    cargo build --release --manifest-path $here/Cargo.toml -p mirrik-cli -p mirrik-gui"
            exit 1
        fi
    else
        err '  Rust is not installed either, so there is nothing to install.'
        dim '  Install it from https://rustup.rs (or your package manager) and run this'
        dim '  script again. Building also needs a C linker and the ALSA and X11/Wayland'
        dim '  development headers, which your distribution groups under a name like'
        dim '  build-essential, base-devel or @development-tools.'
        exit 1
    fi
fi

ok "  Found them in: $source_dir"

bindir="$(ask '  Install into' "$HOME/.local/bin")"

# A space in this path causes more trouble than you'd expect. Every compositor's bind
# line is written unquoted (`exec, /path/mirrik-gui`), and a desktop entry's Exec line
# has to be quoted by spec whenever it contains a space - miss either one and the
# launcher just reads everything after the space as an argument. Neither problem shows
# up until someone actually presses the hotkey, so it's worth catching here instead.
case "$bindir" in
    *[[:space:]]*)
        warn '  That path contains a space.'
        dim '  The key binding written into your compositor config is not quoted - most'
        dim '  compositors would read everything after the space as an argument, and the'
        dim '  key would silently do nothing. A path without spaces avoids the whole'
        dim '  question; ~/.local/bin is the usual one.'
        say ''
        confirm '  Use it anyway?' n || bindir="$HOME/.local/bin"
        ;;
esac
# What is already there belongs to the version that is already there: its holder
# processes carry that version's node names and are matched by its pattern. Install over
# a running mirror and the new binary cannot recognise the old holders any more - which
# is exactly what happened when the tool was renamed. So say what is being replaced, and
# switch it off first. Borrowed from install.ps1, which has done this from the start
# because Windows refuses to overwrite a running .exe at all.
if [ -x "$bindir/mirrik" ]; then
    old_version="$("$bindir/mirrik" --version 2>/dev/null | head -n1 || true)"
    if [ -n "$old_version" ]; then
        dim "  Replacing what is already installed: $old_version"
    else
        dim '  There is already a mirrik in that directory; it will be replaced.'
    fi
    "$bindir/mirrik" off >/dev/null 2>&1 || true
fi

install -Dm755 "$source_dir/mirrik"     "$bindir/mirrik"
install -Dm755 "$source_dir/mirrik-gui" "$bindir/mirrik-gui"
ok "  Installed into $bindir"

path_rc=''   # set below if a shell rc ends up holding a Mirrik block (set -u is on)
case ":$PATH:" in
    *":$bindir:"*) ;;
    *)
        say ''
        warn "  $bindir is not on your PATH."
        # Naming the right file matters more than it looks: told "your shell startup
        # file", people edit .bashrc while running zsh and then wonder.
        case "$(basename "${SHELL:-sh}")" in
            zsh)  rc="$HOME/.zshrc";    line="export PATH=\"\$PATH:$bindir\"" ;;
            fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
                  line="fish_add_path $bindir" ;;
            *)    rc="$HOME/.bashrc";   line="export PATH=\"\$PATH:$bindir\"" ;;
        esac
        dim "  Your shell looks like $(basename "${SHELL:-sh}"), so this goes in $rc:"
        say "    $line"
        say ''
        # Guarded like the compositor configs: run twice in the same terminal - where the
        # PATH has not been picked up yet - and this would otherwise append twice.
        # path_rc is set in both cases, so the closing summary can name every file that
        # holds a Mirrik block - a block this script wrote earlier counts just as much.
        if [ -f "$rc" ] && grep -qFe "$MARK_TEXT" "$rc"; then
            dim "  $rc already has a Mirrik block. Open a new terminal to pick it up."
            path_rc="$rc"
        elif confirm "  Append it to $rc?" n; then
            mkdir -p "$(dirname "$rc")"
            printf '\n%s\n%s\n%s\n' "$MARK_OPEN" "$line" "$MARK_CLOSE" >> "$rc"
            ok '  Appended. Open a new terminal for it to take effect.'
            path_rc="$rc"
        fi
        ;;
esac

# ---------------------------------------------------------------- 4. desktop entry

heading '4. Application launcher entry'

dim '  A desktop entry makes the window findable in rofi, wofi, the GNOME overview,'
dim '  the KDE launcher and everything else that reads them. It is one small text'
dim '  file and costs nothing.'
say ''

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if confirm '  Add it?'; then
    mkdir -p "$apps"
    # Per the Desktop Entry Specification, an Exec path containing a space needs to sit
    # in double quotes - otherwise everything after that space gets treated as an
    # argument instead of part of the path.
    case "$bindir" in
        *[[:space:]]*) exec_field="\"$bindir/mirrik-gui\"" ;;
        *)             exec_field="$bindir/mirrik-gui" ;;
    esac
    cat > "$apps/mirrik.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mirrik
Comment=Play the same sound on two or more output devices at once
Exec=$exec_field
Terminal=false
Categories=AudioVideo;Audio;Settings;
StartupWMClass=mirrik
Keywords=audio;output;mirror;dual;speakers;headphones;
DESKTOP
    have update-desktop-database && update-desktop-database "$apps" 2>/dev/null || true
    ok "  Written to $apps/mirrik.desktop"
else
    dim '  Skipped.'
fi

# ---------------------------------------------------------------- 5. key binding

heading '5. Opening the window with a key'

dim '  This is how Mirrik is meant to be used: one key combination, the window opens'
dim '  over whatever you were doing, you change a destination, Esc closes it again.'
say ''
dim '  Your compositor or desktop owns the key bindings, not Mirrik - so this step'
dim '  works out the right line for your setup and you decide what happens to it.'
say ''

# A guess, so the menu opens on the likely answer instead of always on 1.
guess=12
for probe in "${XDG_CURRENT_DESKTOP:-}" "${DESKTOP_SESSION:-}"; do
    case "${probe,,}" in
        *hyprland*) guess=1 ;;
        *sway*)     guess=2 ;;
        *i3*)       guess=3 ;;
        *niri*)     guess=4 ;;
        *river*)    guess=5 ;;
        *awesome*)  guess=6 ;;
        *bspwm*)    guess=7 ;;
        # Before *gnome*: Mint reports X-Cinnamon, and Cinnamon is not GNOME here.
        *cinnamon*) guess=9 ;;
        *gnome*)    guess=8 ;;
        *kde*|*plasma*) guess=10 ;;
        *xfce*)     guess=11 ;;
    esac
    [ "$guess" != 12 ] && break
done

say '  Which one are you running?'
say '     1) Hyprland            8) GNOME'
say '     2) Sway                9) Cinnamon'
say '     3) i3                 10) KDE Plasma'
say '     4) niri               11) XFCE'
say '     5) river              12) Something else'
say '     6) awesome            13) Skip this step'
say '     7) bspwm / sxhkd'
wm="$(choose '  Choice' "$guess" 1 2 3 4 5 6 7 8 9 10 11 12 13)"

if [ "$wm" = 13 ]; then
    dim '  Skipped. The command to bind, whenever you get to it, is:'
    say "    $bindir/mirrik-gui"
    # No opinion this run - carry forward whatever an earlier run already knew, rather
    # than reading "skipped" as "nothing configured" and flagging a still-correct setup
    # as left over from a different, earlier choice.
    state_wm="$MIRRIK_STATE_WM"; state_config="$MIRRIK_STATE_CONFIG"
    state_keybind_kind="$MIRRIK_STATE_KEYBIND_KIND"
else
    say ''
    say '  Which modifiers?'
    say '    1) Super            3) Alt'
    say '    2) Super + Shift    4) Ctrl + Alt'
    mods="$(choose '  Choice' '2' 1 2 3 4)"

    key=''
    while [ -z "$key" ]; do
        typed="$(ask '  And which key? (a single letter or digit)' 'M')"
        if printf '%s' "$typed" | grep -Eq '^[A-Za-z0-9]$'; then
            key="$typed"
        else
            warn '  One letter or digit please.'
        fi
    done
    upper="${key^^}"; lower="${key,,}"

    # The same combination, written six different ways. Every project picked its own
    # spelling for the same three keys, so this is a translation table and nothing more.
    case "$mods" in
        1) hypr='SUPER';       sway='Mod4';         niri='Super'
           lua='"Mod4"';       sx='super';          gtk='<Super>';          human='Super' ;;
        3) hypr='ALT';         sway='Mod1';         niri='Alt'
           lua='"Mod1"';       sx='alt';            gtk='<Alt>';            human='Alt' ;;
        4) hypr='CTRL ALT';    sway='Control+Mod1'; niri='Ctrl+Alt'
           lua='"Control", "Mod1"'; sx='ctrl + alt'; gtk='<Control><Alt>';  human='Ctrl+Alt' ;;
        *) hypr='SUPER SHIFT'; sway='Mod4+Shift';   niri='Super+Shift'
           lua='"Mod4", "Shift"'; sx='super + shift'; gtk='<Super><Shift>'; human='Super+Shift' ;;
    esac

    gui="$bindir/mirrik-gui"
    conf_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    snippet=''; config=''; note=''; state_keybind_kind=''

    case "$wm" in
        1)
            config="$conf_home/hypr/hyprland.conf"
            # Wayland compositors place windows themselves, so the rules matter as much as
            # the binding: without them the window is tiled in with everything else.
            # `windowrulev2` became `windowrule` in 0.49. The wrong spelling is not a
            # warning but a config error at startup, so ask hyprctl instead of printing
            # both and hoping. Without hyprctl, assume current and say so.
            rule_keyword=windowrule
            if have hyprctl; then
                hypr_version="$(hyprctl version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | tr -d v || true)"
                if [ -n "$hypr_version" ] && ! version_ge "$hypr_version" 0.49; then
                    rule_keyword=windowrulev2
                    note="Hyprland $hypr_version needs windowrulev2, which is what these lines use. 0.49 and newer spell it windowrule."
                fi
            else
                note="hyprctl was not found, so these lines assume 0.49 or newer. Older versions spell the two rules 'windowrulev2'."
            fi
            snippet="$MARK_OPEN
bind = $hypr, $upper, exec, $gui
$rule_keyword = float, class:^(mirrik)\$
$rule_keyword = center, class:^(mirrik)\$
$MARK_CLOSE" ;;
        2)
            config="$conf_home/sway/config"
            snippet="$MARK_OPEN
bindsym $sway+$lower exec $gui
for_window [app_id=\"mirrik\"] floating enable, move position center
$MARK_CLOSE" ;;
        3)
            config="$conf_home/i3/config"
            snippet="$MARK_OPEN
bindsym $sway+$lower exec --no-startup-id $gui
for_window [class=\"mirrik\"] floating enable, move position center
$MARK_CLOSE" ;;
        4)
            config="$conf_home/niri/config.kdl"
            # niri wants its binds inside the one binds block, so this cannot simply be
            # appended to the end of the file the way the others can.
            snippet="binds {
    $niri+$upper { spawn \"$gui\"; }
}

window-rule {
    match app-id=\"^mirrik\$\"
    open-floating true
}"
            note="niri keeps all binds in a single 'binds { }' block, so paste the bind
  line inside the one you already have rather than appending a second block.
  The window-rule goes at the top level." ;;
        5)
            config="$conf_home/river/init"
            snippet="$MARK_OPEN
riverctl map normal $sway $upper spawn \"$gui\"
riverctl rule-add -app-id 'mirrik' float
$MARK_CLOSE"
            note="river's init is a shell script and has to stay executable:
  chmod +x $config" ;;
        6)
            config="$conf_home/awesome/rc.lua"
            # This is the modern append API; it works alongside whatever globalkeys table
            # the config already has, which the older awful.util.table.join style does not.
            snippet="$LUA_OPEN
awful.keyboard.append_global_keybindings({
    awful.key({ $lua }, \"$lower\", function() awful.spawn(\"$gui\") end,
              { description = \"open Mirrik\", group = \"launcher\" }),
})
awful.rules.rules[#awful.rules.rules + 1] = {
    rule = { class = \"mirrik\" },
    properties = { floating = true, placement = awful.placement.centered },
}
$LUA_CLOSE"
            note="This is Lua, and it uses awesome's newer append API - it sits happily
  next to an existing globalkeys table instead of replacing it. Needs
  awesome 4.3 or newer. Append it at the end of rc.lua, after awful is
  required." ;;
        7)
            config="$conf_home/sxhkd/sxhkdrc"
            snippet="$MARK_OPEN
$sx + $lower
    $gui
$MARK_CLOSE"
            note="Reload sxhkd afterwards: pkill -USR1 -x sxhkd
  For the window to float, bspwm needs this in its own bspwmrc:
    bspc rule -a mirrik state=floating center=on" ;;
        8)
            say ''
            dim '  GNOME keeps custom shortcuts in dconf. These three commands add one'
            dim '  without going through the settings window:'
            say ''
            path='/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/mirrik/'
            schema='org.gnome.settings-daemon.plugins.media-keys.custom-keybinding'
            say "    gsettings set $schema:$path name 'Mirrik'"
            say "    gsettings set $schema:$path command '$gui'"
            say "    gsettings set $schema:$path binding '$gtk$lower'"
            say ''
            dim '  ... plus one more to put it in the list of custom shortcuts, which is'
            dim '  the fiddly part, because that list must not be overwritten.'
            say ''
            if have gsettings && confirm '  Do all of that now?'; then
                state_keybind_kind=gnome
                gsettings set "$schema:$path" name 'Mirrik'
                gsettings set "$schema:$path" command "$gui"
                gsettings set "$schema:$path" binding "$gtk$lower"
                current="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)"
                if printf '%s' "$current" | grep -qF "$path"; then
                    ok '  Already in the list; the three values were refreshed.'
                else
                    if [ "$current" = '@as []' ] || [ "$current" = '[]' ]; then
                        updated="['$path']"
                    else
                        updated="${current%]}, '$path']"
                    fi
                    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$updated"
                    ok "  Done. $human+$upper opens the window."
                fi
                dim '  To undo: Settings > Keyboard > Custom Shortcuts, and remove "Mirrik".'
            else
                dim '  Not run. Settings > Keyboard > View and Customise Shortcuts >'
                dim "  Custom Shortcuts > + does the same thing by hand: name Mirrik,"
                dim "  command $gui, shortcut $human+$upper."
            fi ;;
        9)
            say ''
            dim '  Cinnamon keeps custom shortcuts in dconf like GNOME does, but under its'
            dim '  own schema, with the key combination stored as a list rather than a'
            dim '  string, and with short ids in the list rather than full paths.'
            say ''
            # The schema was renamed between Cinnamon generations and the documentation
            # disagrees with itself about which name is current, so ask the machine
            # instead of picking one. Guessing wrong here fails silently, which is the
            # worst way for a setup step to fail.
            cin=''
            if have gsettings; then
                for candidate in org.cinnamon.desktop.keybindings org.cinnamon.keybindings; do
                    if gsettings list-schemas 2>/dev/null | grep -qx "$candidate"; then
                        cin="$candidate"
                        break
                    fi
                done
            fi

            if [ -z "$cin" ]; then
                dim '  No Cinnamon keybinding schema on this machine, so this one is by hand:'
                say ''
                say '    Menu > Preferences > Keyboard > Shortcuts > Custom Shortcuts > Add'
                say "    Command:   $gui"
                say "    Shortcut:  $human+$upper"
            else
                dim "  Found: $cin"
                base="/$(printf '%s' "$cin" | tr . /)/custom-keybindings"
                list="$(gsettings get "$cin" custom-list 2>/dev/null || true)"
                [ -z "$list" ] && list='@as []'

                # Reuse our own slot if a previous run left one, so re-running does not
                # pile up a second, third and fourth Mirrik shortcut.
                slot=''
                for entry in $(printf '%s' "$list" | grep -oE "'[^']+'" | tr -d "'"); do
                    if [ "$(gsettings get "$cin.custom-keybinding:$base/$entry/" name 2>/dev/null)" = "'Mirrik'" ]; then
                        slot="$entry"
                        break
                    fi
                done
                if [ -z "$slot" ]; then
                    # Cinnamon's own settings page numbers these, so take the next free
                    # number rather than inventing a name it might choke on.
                    i=0
                    while printf '%s' "$list" | grep -q "'custom$i'"; do i=$((i + 1)); done
                    slot="custom$i"
                fi

                target="$cin.custom-keybinding:$base/$slot/"
                say ''
                say "    gsettings set $target name 'Mirrik'"
                say "    gsettings set $target command '$gui'"
                say "    gsettings set $target binding \"['$gtk$lower']\""
                say ''
                if confirm '  Do that now?'; then
                    state_keybind_kind=cinnamon
                    gsettings set "$target" name 'Mirrik'
                    gsettings set "$target" command "$gui"
                    gsettings set "$target" binding "['$gtk$lower']"
                    if printf '%s' "$list" | grep -q "'$slot'"; then
                        ok "  Refreshed the existing Mirrik shortcut ($slot)."
                    else
                        case "$list" in
                            '@as []'|'[]') updated="['$slot']" ;;
                            *)             updated="${list%]}, '$slot']" ;;
                        esac
                        gsettings set "$cin" custom-list "$updated"
                        ok "  Done. $human+$upper opens the window."
                    fi
                    dim '  To undo: Keyboard > Shortcuts > Custom Shortcuts, and remove "Mirrik".'
                else
                    dim '  Not run. Menu > Preferences > Keyboard > Shortcuts > Custom'
                    dim '  Shortcuts > Add does the same thing by hand.'
                fi
            fi ;;
        10)
            say ''
            dim '  KDE stores shortcuts in a way that is not safe to edit from a script'
            dim '  while Plasma is running - it caches the file and writes it back out.'
            dim '  So this one is by hand, and it is three clicks:'
            say ''
            say '    System Settings > Keyboard > Shortcuts > Add > Command'
            say "    Command:   $gui"
            say "    Shortcut:  $human+$upper"
            say ''
            dim '  For the window to float and centre: right-click its title bar > More'
            dim '  Actions > Configure Special Window Settings, match on the window class'
            dim '  "mirrik".' ;;
        11)
            say ''
            dim '  XFCE keeps custom shortcuts in xfconf. One command adds this one:'
            say ''
            say "    xfconf-query -c xfce4-keyboard-shortcuts \\"
            say "      -p '/commands/custom/$gtk$lower' -n -t string -s '$gui'"
            say ''
            if have xfconf-query && confirm '  Run it now?'; then
                state_keybind_kind=xfce
                xfconf-query -c xfce4-keyboard-shortcuts \
                    -p "/commands/custom/$gtk$lower" -n -t string -s "$gui"
                ok "  Done. $human+$upper opens the window."
                dim '  To undo: Settings > Keyboard > Application Shortcuts, and remove it.'
            else
                dim '  Not run. Settings > Keyboard > Application Shortcuts > Add does the'
                dim '  same thing by hand.'
            fi ;;
        *)
            say ''
            dim '  Every desktop has this somewhere under Settings, usually "Keyboard" and'
            dim '  then "Custom Shortcuts". Two things to put in:'
            say ''
            say "    Shortcut:  $human+$upper"
            say "    Command:   $gui"
            say ''
            dim '  If your window manager reads a config file instead, the window class to'
            dim '  match for a floating, centred window is: mirrik' ;;
    esac

    if [ -n "$snippet" ]; then
        say ''
        dim '  These are the lines for your setup:'
        say ''
        printf '%s\n' "$snippet" | sed 's/^/    /'
        say ''
        [ -n "$note" ] && { dim "  $note"; say ''; }

        # The question used to ask how the file is maintained ("by hand" vs "generated"),
        # which reads as "who types this in, you or me?" - the opposite of what it decides.
        # Ask about the action instead, and let the reasons live in the options.
        default_choice=1
        if [ ! -f "$config" ]; then
            warn "  $config does not exist."
            dim '  Either your configuration lives somewhere else, or it is in another'
            dim '  format. Appending would create a file your setup never reads.'
            say ''
            default_choice=2
        elif [ "$wm" = 1 ] && { compgen -G "$conf_home/hypr/*.lua" >/dev/null 2>&1 ||
                        compgen -G "$conf_home/hypr/*/*.lua" >/dev/null 2>&1; }; then
            # Hyprland can be driven from Lua by several community setups. The lines above
            # are conf syntax and will not work there as they stand.
            warn '  Lua files found next to your Hyprland config.'
            dim '  If your binds live in Lua, the lines above are the wrong syntax - they'
            dim '  have to be translated. With the common hl.* API that is roughly:'
            say ''
            say "    hl.bind(\"${hypr// / + } + $upper\", hl.dsp.exec_cmd(\"$gui\"))"
            say "    hl.window_rule({ match = { class = \"^mirrik\$\" }, float = true, center = true })"
            say ''
            default_choice=2
        fi

        dim '  What should happen with them?'
        say "    1) Append them to $config"
        say '    2) Nothing - print them and let me place them myself'
        dim '       (the right answer if the file is generated for you by Nix, Home'
        dim '        Manager or chezmoi, is split across includes, or is not conf syntax:'
        dim '        anything this script appends would be lost or ignored)'
        kind="$(choose '  Choice' "$default_choice" 1 2)"

        if [ "$kind" = 1 ]; then
            if [ "$wm" = 4 ]; then
                # niri's single binds block makes blind appending wrong, see the note.
                dim '  Not appending automatically - see the note above. Paste it yourself.'
            else
                append_block "$config" "$snippet" \
                    "Appended. Reload your compositor and $human+$upper opens the window."
            fi
        else
            dim '  Nothing written. The lines are above whenever you want them.'
        fi
    fi

    # Ground truth, not "did this run write it": a block left by an earlier run counts
    # the same as one written just now, and a block that was declined here but already
    # exists (re-run, "print only" chosen the second time) must not disappear from the
    # undo list either. wm 1-7 are the config-snippet desktops; 8/9/11 set
    # state_keybind_kind themselves, above, only once their write actually ran.
    state_wm="$wm"; state_config=''
    if [ -n "${config:-}" ] && [ -f "$config" ] && grep -qFe "$MARK_TEXT" "$config"; then
        state_config="$config"
    fi
    # Same desktop as last time, but its tool-based step was declined or is manual-only
    # (KDE, "something else"): keep what was already known rather than reading silence
    # as "nothing configured".
    if [ "$wm" = "$MIRRIK_STATE_WM" ] && [ -z "$state_keybind_kind" ]; then
        state_keybind_kind="$MIRRIK_STATE_KEYBIND_KIND"
    fi
fi

# ---------------------------------------------------------------- 6. does it work

heading '6. Checking it actually works'

if ! devices="$("$bindir/mirrik" devices 2>&1)"; then
    err '  Mirrik could not list your output devices:'
    printf '%s\n' "$devices" | sed 's/^/    /'
    say ''
    dim '  If it is complaining about PipeWire, go back to step 1 - one of the four'
    dim '  tools is probably still missing.'
    exit 1
fi

# Names are the lines starting with "* " or two spaces; the ids under them start with four.
count="$(printf '%s\n' "$devices" | grep -cE '^(\* |  )[^ ]' || true)"
ok "  Mirrik sees $count output device(s):"
printf '%s\n' "$devices" | sed 's/^/    /'

if [ "$count" -lt 2 ]; then
    say ''
    warn '  Only one output device. Mirroring needs at least two, so plug in a second'
    warn '  one (headphones, HDMI, Bluetooth) and it will show up here.'
fi

# ---------------------------------------------------------------- done

heading 'Done'

dim '  Open the window        your key combination, or the launcher entry'
dim '  From a terminal        mirrik devices / mirrik on <name> / mirrik off'
dim '  Closing the window     leaves the mirror running. `x` stops it.'
say ''

# Ground truth for the desktop entry too, same reasoning as state_config above: present
# on disk counts, regardless of whether this run wrote it or an earlier one did.
state_apps=''
[ -f "$apps/mirrik.desktop" ] && state_apps="$apps"

write_state

dim '  To undo all of this:'
say "    rm $bindir/mirrik $bindir/mirrik-gui"
# Each of the next lines is named only when it is actually there - listing something
# nobody touched invites someone to go looking for a file or a block that never
# existed.
if [ -n "$state_apps" ]; then
    say "    rm $state_apps/mirrik.desktop"
fi
if [ -n "$state_config" ]; then
    dim "    and delete the '# --- Mirrik ---' block from $state_config"
fi
if [ -n "$path_rc" ]; then
    dim "    and the same block from $path_rc (the PATH line)"
fi
case "$state_keybind_kind" in
    gnome)    dim '    and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts' ;;
    cinnamon) dim '    and remove "Mirrik" under Keyboard > Shortcuts > Custom Shortcuts' ;;
    xfce)     dim '    and remove it under Settings > Keyboard > Application Shortcuts' ;;
esac
say "    rm -r $state_dir"

# Anything a *different* earlier run left behind - a different install directory, a
# different compositor or desktop. Compared by what actually changed (bindir, apps
# directory, the chosen desktop) rather than by re-deriving strings, and re-checked on
# disk before being named, so nothing here is claimed on trust alone: someone who
# already cleaned it up by hand does not get told to clean it up again.
stale=0
note_stale() {
    [ "$stale" = 1 ] && return 0
    say ''
    dim '  Also still there from an earlier run with different settings:'
    stale=1
}
if [ -n "$MIRRIK_STATE_BINDIR" ] && [ "$MIRRIK_STATE_BINDIR" != "$bindir" ] \
   && [ -x "$MIRRIK_STATE_BINDIR/mirrik" ]; then
    note_stale
    say "    rm $MIRRIK_STATE_BINDIR/mirrik $MIRRIK_STATE_BINDIR/mirrik-gui"
fi
if [ -n "$MIRRIK_STATE_APPS" ] && [ "$MIRRIK_STATE_APPS" != "$state_apps" ] \
   && [ -f "$MIRRIK_STATE_APPS/mirrik.desktop" ]; then
    note_stale
    say "    rm $MIRRIK_STATE_APPS/mirrik.desktop"
fi
if [ -n "$MIRRIK_STATE_WM" ] && [ "$MIRRIK_STATE_WM" != "$state_wm" ]; then
    if [ -n "$MIRRIK_STATE_CONFIG" ] && [ -f "$MIRRIK_STATE_CONFIG" ] \
       && grep -qFe "$MARK_TEXT" "$MIRRIK_STATE_CONFIG"; then
        note_stale
        dim "    delete the '# --- Mirrik ---' block from $MIRRIK_STATE_CONFIG"
    fi
    case "$MIRRIK_STATE_KEYBIND_KIND" in
        gnome)
            note_stale
            dim '    remove "Mirrik" under Settings > Keyboard > Custom Shortcuts (if still on GNOME)' ;;
        cinnamon)
            note_stale
            dim '    remove "Mirrik" under Keyboard > Shortcuts > Custom Shortcuts (if still on Cinnamon)' ;;
        xfce)
            note_stale
            dim '    remove it under Settings > Keyboard > Application Shortcuts (if still on XFCE)' ;;
    esac
fi
say ''
