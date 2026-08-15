#!/usr/bin/env bash
#
# Guided setup for Mirrik on Linux.
#
# Installs the two binaries, adds a desktop entry, and helps you bind the window to a
# key combination in your compositor. Every step asks first, and nothing is written to a
# config file without showing you the exact lines beforehand.
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

# ---------------------------------------------------------------- 0. what this is

cat <<'BANNER'

  M I R R I K
  Play the same sound on two or more output devices at once.

  This script will, asking before each step:
    1. check that PipeWire is running, because Mirrik needs it
    2. install mirrik and mirrik-gui into a directory on your PATH
    3. add a desktop entry so it shows up in your application launcher
    4. help you bind the window to a key combination

  No root, no system service, nothing outside your home directory.

BANNER

# ---------------------------------------------------------------- 1. PipeWire

heading '1. Checking your audio server'

if ! command -v pactl >/dev/null 2>&1; then
    err '  pactl is not installed, so the audio server cannot be identified.'
    dim '  Install pipewire-pulse (it provides pactl) and run this again.'
    exit 1
fi

server="$(pactl info 2>/dev/null | sed -n 's/^Server Name: //p')"
if printf '%s' "$server" | grep -qi pipewire; then
    ok "  PipeWire it is: $server"
else
    warn "  Your audio server reports itself as: ${server:-unknown}"
    say ''
    dim '  Mirrik requires PipeWire and refuses to run on plain PulseAudio. That is'
    dim '  deliberate: there, a loopback belongs to the daemon and would survive a'
    dim '  crash of this tool — which breaks its one promise, that switching off'
    dim '  leaves nothing behind.'
    say ''
    confirm '  Install anyway?' n || exit 1
fi

# ---------------------------------------------------------------- 2. binaries

heading '2. The program itself'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir=''
for dir in "$here/code/mirrik/target/release" "$here/code/mirrik/target/debug" "$here"; do
    if [ -x "$dir/mirrik" ] && [ -x "$dir/mirrik-gui" ]; then
        source_dir="$dir"
        break
    fi
done

if [ -z "$source_dir" ]; then
    warn '  Could not find built binaries next to this script.'
    if command -v cargo >/dev/null 2>&1; then
        dim '  Rust is installed, so they can be built now. The first build takes a few'
        dim '  minutes and needs an internet connection for the dependencies.'
        if confirm '  Build them now?'; then
            cargo build --release --manifest-path "$here/code/mirrik/Cargo.toml"
            source_dir="$here/code/mirrik/target/release"
        else
            dim '  Nothing was changed. Build them yourself with:'
            say "    cargo build --release --manifest-path $here/code/mirrik/Cargo.toml"
            exit 1
        fi
    else
        err '  Rust is not installed either, so there is nothing to install.'
        dim '  Install Rust from https://rustup.rs and run this script again.'
        exit 1
    fi
fi

ok "  Found them in: $source_dir"

bindir="$(ask '  Install into' "$HOME/.local/bin")"
install -Dm755 "$source_dir/mirrik"     "$bindir/mirrik"
install -Dm755 "$source_dir/mirrik-gui" "$bindir/mirrik-gui"
ok "  Installed into $bindir"

case ":$PATH:" in
    *":$bindir:"*) ;;
    *)
        say ''
        warn "  $bindir is not on your PATH."
        dim '  Add this to your shell startup file (~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish):'
        say "    export PATH=\"\$PATH:$bindir\""
        ;;
esac

# ---------------------------------------------------------------- 3. desktop entry

heading '3. Application launcher entry'

dim '  A desktop entry makes the window findable in rofi, wofi, the GNOME overview,'
dim '  the KDE launcher and everything else that reads them. It is one small text'
dim '  file and costs nothing.'
say ''

if confirm '  Add it?'; then
    apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$apps"
    cat > "$apps/mirrik.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mirrik
Comment=Play the same sound on two or more output devices at once
Exec=$bindir/mirrik-gui
Terminal=false
Categories=AudioVideo;Audio;Settings;
StartupWMClass=mirrik
Keywords=audio;output;mirror;dual;speakers;headphones;
DESKTOP
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
    ok "  Written to $apps/mirrik.desktop"
else
    dim '  Skipped.'
fi

# ---------------------------------------------------------------- 4. key binding

heading '4. Opening the window with a key'

dim '  This is how Mirrik is meant to be used: one key combination, the window opens'
dim '  over whatever you were doing, you change a destination, Esc closes it again.'
say ''
dim '  Your compositor owns the key bindings, not Mirrik — so this step works out the'
dim '  right line for your setup and you decide whether to write it anywhere.'
say ''

say '  Which one are you running?'
say '    1) Hyprland'
say '    2) Sway'
say '    3) i3'
say '    4) Something else (GNOME, KDE, XFCE, awesome, ...)'
say '    5) Skip this step'
wm="$(ask '  Choice' '1')"

if [ "$wm" = 5 ]; then
    dim '  Skipped. The command to bind, whenever you get to it, is: mirrik-gui'
else
    say ''
    say '  Which modifiers?'
    say '    1) Super'
    say '    2) Super + Shift'
    say '    3) Alt'
    say '    4) Ctrl + Alt'
    mods="$(ask '  Choice' '2')"

    key=''
    while [ -z "$key" ]; do
        typed="$(ask '  And which key? (a single letter or digit)' 'M')"
        if printf '%s' "$typed" | grep -Eq '^[A-Za-z0-9]$'; then
            key="$typed"
        else
            warn '  One letter or digit please.'
        fi
    done

    upper="${key^^}"
    lower="${key,,}"

    # Same combination, three notations.
    case "$mods" in
        1) hypr_mod='SUPER';       sway_mod='Mod4';          human='Super' ;;
        2) hypr_mod='SUPER SHIFT'; sway_mod='Mod4+Shift';    human='Super+Shift' ;;
        3) hypr_mod='ALT';         sway_mod='Mod1';          human='Alt' ;;
        4) hypr_mod='CTRL ALT';    sway_mod='Control+Mod1';  human='Ctrl+Alt' ;;
        *) hypr_mod='SUPER SHIFT'; sway_mod='Mod4+Shift';    human='Super+Shift' ;;
    esac

    marker='# --- Mirrik ---'
    snippet=''
    config=''

    case "$wm" in
        1)
            config="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
            # Wayland compositors place windows themselves, so the rules matter as much
            # as the binding: without them the window lands wherever the compositor
            # feels like, tiled in with everything else.
            snippet="$marker
bind = $hypr_mod, $upper, exec, $bindir/mirrik-gui
# Hyprland before 0.49 spells the next two 'windowrulev2'.
windowrule = float, class:^(mirrik)\$
windowrule = center, class:^(mirrik)\$
# --- end Mirrik ---"
            ;;
        2)
            config="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"
            snippet="$marker
bindsym $sway_mod+$lower exec $bindir/mirrik-gui
for_window [app_id=\"mirrik\"] floating enable, move position center
# --- end Mirrik ---"
            ;;
        3)
            config="${XDG_CONFIG_HOME:-$HOME/.config}/i3/config"
            snippet="$marker
bindsym $sway_mod+$lower exec --no-startup-id $bindir/mirrik-gui
for_window [class=\"mirrik\"] floating enable, move position center
# --- end Mirrik ---"
            ;;
        *)
            say ''
            dim '  Every desktop environment has this somewhere under Settings, usually'
            dim '  "Keyboard" and then "Custom Shortcuts". Two things to put in:'
            say ''
            say "    Shortcut:  $human+$upper"
            say "    Command:   $bindir/mirrik-gui"
            say ''
            dim '  On GNOME:  Settings > Keyboard > View and Customise Shortcuts >'
            dim '             Custom Shortcuts > +'
            dim '  On KDE:    System Settings > Shortcuts > Add Command'
            ;;
    esac

    if [ -n "$snippet" ]; then
        say ''
        dim '  These are the lines for your setup:'
        say ''
        printf '%s\n' "$snippet" | sed 's/^/    /'
        say ''

        dim '  How do you keep that config file?'
        say '    1) I edit it by hand'
        say '    2) It is generated for me (Nix, Home Manager, a dotfile templater, ...)'
        kind="$(ask '  Choice' '1')"

        if [ "$kind" = 1 ]; then
            if [ -f "$config" ] && grep -qF "$marker" "$config"; then
                warn "  $config already has a Mirrik block. Leaving it alone."
                dim '  Remove the old block by hand first if you want to change the key.'
            elif confirm "  Append them to $config?"; then
                mkdir -p "$(dirname "$config")"
                printf '\n%s\n' "$snippet" >> "$config"
                ok "  Appended. Reload your compositor and $human+$upper opens the window."
                dim "  To undo: delete the block between the two '# --- Mirrik ---' lines."
            else
                dim '  Not written. Copy them in whenever you like.'
            fi
        else
            dim '  Then this script will not touch it — a generated file would overwrite'
            dim '  whatever it appended on the next rebuild. Put the lines above into'
            dim '  whatever generates it.'
        fi
    fi
fi

# ---------------------------------------------------------------- 5. does it work

heading '5. Checking it actually works'

if ! devices="$("$bindir/mirrik" devices 2>&1)"; then
    err '  Mirrik could not list your output devices:'
    printf '%s\n' "$devices" | sed 's/^/    /'
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
dim '  To undo all of this:'
say "    rm $bindir/mirrik $bindir/mirrik-gui"
say "    rm ${XDG_DATA_HOME:-$HOME/.local/share}/applications/mirrik.desktop"
dim "    and delete the '# --- Mirrik ---' block from your compositor config"
say ''
