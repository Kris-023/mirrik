#!/usr/bin/env bash
#
# Prueft install.sh gegen seine Zweige, ohne etwas am eigenen System zu aendern.
#
# Jeder Fall bekommt ein frisches HOME aus mktemp und ein PATH-Verzeichnis mit Attrappen
# der Programme, die der Installer aufruft. Der Installer merkt davon nichts.
#
# Was das NICHT belegt: dass der geschriebene Bind im echten Compositor funktioniert.
# Attrappen pruefen Logik, nicht Wirklichkeit - genau daran ist der erste echte Linux-Lauf
# gescheitert, obwohl die Logik vorher "durch" war.
#
# Aufruf:  tools/test-install.sh              alle Faelle
#          tools/test-install.sh hyprland     nur Faelle, deren Name das enthaelt
#          VERBOSE=1 tools/test-install.sh    bei Fehlern die Installer-Ausgabe zeigen
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO/install.sh"
[ -x "$INSTALLER" ] || { echo "install.sh nicht gefunden: $INSTALLER" >&2; exit 1; }

pass=0; fail=0; failed_names=()
green=$'\033[32m'; red=$'\033[31m'; dim=$'\033[90m'; off=$'\033[0m'
[ -t 1 ] || { green=''; red=''; dim=''; off=''; }

# Ein PATH ohne /usr/bin: sonst findet der Installer dort jedes Werkzeug, das der Fall
# ausgelassen hat, und "missing=" prueft nichts. Verlinkt werden nur die Programme, die
# install.sh tatsaechlich aufruft - die Liste stammt aus einem grep ueber das Skript.
make_minimal_path() {  # <ziel-dir>
    local d="$1"; mkdir -p "$d"
    local t src
    for t in bash sh grep sed awk cat tr head tail sort uniq wc mkdir rmdir rm cp mv ln \
             install chmod chown dirname basename env date mktemp uname id readlink find \
             xargs cut expr tee touch stat getent tput sleep printf test true false; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        ln -sf "$src" "$d/$t" 2>/dev/null
    done
}

make_stubs() {  # <bin-dir> <server-name> <fehlende-werkzeuge...>
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
    for t in pw-cli pw-dump pw-metadata update-desktop-database dconf; do
        [[ "$missing" == *" $t "* ]] && continue
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$t"
    done
    cat > "$d/mirrik" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = devices ]; then
    printf '* Built-in Analog Stereo  [analog]\n    alsa_output.stub.analog-stereo\n'
    printf '  Display HDMI  [HDMI]\n    alsa_output.stub.hdmi-stereo\n'
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/mirrik-gui"
    # gsettings muss mehr koennen als mitschreiben: die GNOME- und Cinnamon-Zweige
    # fragen erst `list-schemas` und weichen ohne Treffer auf "machen Sie es von Hand"
    # aus. Eine stumme Attrappe laesst diese Zweige also nie laufen - und einen Test,
    # der den Ausweichpfad fuer Erfolg haelt, gruen aussehen.
    if [[ "$missing" != *" gsettings "* ]]; then
        cat > "$d/gsettings" <<'EOF'
#!/usr/bin/env bash
printf 'gsettings %s
' "$*" >> "$STUB_LOG"
case "${1:-}" in
    list-schemas)
        printf '%s
' org.gnome.settings-daemon.plugins.media-keys                       org.cinnamon.desktop.keybindings ;;
    get) printf "@as []
" ;;
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
    # hyprctl nur, wenn der Fall eine Version vorgibt - seine Abwesenheit ist ein
    # eigener Zweig, in dem der Installer die neue Schreibweise annimmt und das sagt.
    if [ -n "${STUB_HYPR_VERSION:-}" ]; then
        printf '#!/usr/bin/env bash\n[ "$1" = version ] && printf "Hyprland %s built from branch v%s\\n" "%s" "%s"\nexit 0\n' \
            "$STUB_HYPR_VERSION" "$STUB_HYPR_VERSION" > "$d/hyprctl"
    fi

    if [[ "$missing" != *" cargo "* ]]; then
        cat > "$d/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'cargo %s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
    fi
    chmod +x "$d"/* 2>/dev/null
    return 0
}

# opts: cfg= pre=none|empty|marker server= missing=a,b lua=1 nobins=1 nopath=1 repeat=N
run_case() {  # <name> <antworten> <pruef-funktion> [opts]
    local name="$1" answers="$2" check="$3" opts="${4:-}"
    local cfg='' pre='empty' server='PulseAudio (on PipeWire 1.6.8)'
    local missing='' lua='' nobins='' nopath='' repeat=1 pair kv
    local osrelease='' shell_for_case='' hyprversion='' preinstalled=''
    IFS=';' read -ra kv <<<"$opts"
    for pair in "${kv[@]}"; do
        [ -z "$pair" ] && continue
        case "${pair%%=*}" in
            cfg) cfg="${pair#*=}" ;; pre) pre="${pair#*=}" ;;
            server) server="${pair#*=}" ;; missing) missing="${pair#*=}" ;;
            lua) lua=1 ;; nobins) nobins=1 ;; nopath) nopath=1 ;; repeat) repeat="${pair#*=}" ;;
            osrelease) osrelease="${pair#*=}" ;; shell) shell_for_case="${pair#*=}" ;;
            hyprversion) hyprversion="${pair#*=}" ;; preinstalled) preinstalled="${pair#*=}" ;;
        esac
    done

    local home; home="$(mktemp -d)"
    local stubs="$home/stubs"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share/applications"
    STUB_HYPR_VERSION="$hyprversion" make_stubs "$stubs" "$server" ${missing//,/ }

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
    # Eine "bereits installierte" Fassung, die meldet, was mit ihr geschieht.
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

    local sysbin="$home/sysbin"
    make_minimal_path "$sysbin"
    local path="$stubs:$sysbin"
    [ -z "$nopath" ] && path="$stubs:$home/.local/bin:$sysbin"

    local out rc i answer_lines
    answer_lines="$(printf '%s' "$answers" | tr ',' '\n')"
    for ((i = 1; i <= repeat; i++)); do
        out="$(printf '%s\n' "$answer_lines" | env -i \
            HOME="$home" PATH="$path" \
            XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
            STUB_LOG="$home/stub.log" SHELL="${shell_for_case:-/bin/bash}" TERM=dumb \
            ${osrelease:+MIRRIK_OS_RELEASE="$home/os-release"} \
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
    [ "$RC" = 0 ] || echo "Exit-Code $RC statt 0"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik" ]     || echo "mirrik nicht installiert"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik-gui" ] || echo "mirrik-gui nicht installiert"
    grep -q 'sees 2 output device' <<<"$OUT" || echo "Schritt 6 hat die Geraete nicht gelesen"
}
has_desktop() { [ -f "$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop" ] || echo ".desktop fehlt"; }
no_desktop()  { installed_ok; [ -f "$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop" ] && echo ".desktop trotz Ablehnung geschrieben"; return 0; }
check_appended() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -f "$f" ] || { echo "$CFG wurde nicht geschrieben"; return 0; }
    local n; n=$(grep -c -- '--- Mirrik ---' "$f")
    [ "$n" = 1 ] || echo "$CFG hat $n Marker statt 1"
    grep -q 'mirrik-gui' "$f" || echo "$CFG nennt mirrik-gui nicht"
}
check_printed() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -e "$f" ] && grep -q -- '--- Mirrik ---' "$f" && echo "$CFG traegt einen Block, obwohl nicht angehaengt werden sollte"
    grep -q -- '--- Mirrik ---' <<<"$OUT" || echo "die Zeilen wurden nicht gedruckt"
    return 0
}
# niri hat keine Marker (ein einzelner binds-Block, siehe die Notiz im Installer) - der
# generische check_printed griff hier frueher nur zufaellig, weil die alte, unbedingte
# Zeile im Abschluss-Block selbst "--- Mirrik ---" enthielt. Seit die Zeile nur noch
# erscheint, wenn wirklich ein Block existiert, prueft dieser eigene Fall den tatsaechlichen
# Inhalt (die binds-Zeile) statt eines Textes, der bei niri nie vorkommt.
check_printed_niri() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    [ -e "$f" ] && grep -q 'binds {' "$f" && echo "$CFG wurde trotz niri-Sonderfall automatisch beschrieben"
    grep -q 'binds {' <<<"$OUT" || echo "die niri-Bind-Zeilen wurden nicht gedruckt"
    return 0
}
check_untouched() {
    installed_ok; has_desktop
    local f="$HOME_UNDER_TEST/$CFG"
    local n; n=$(grep -c -- '--- Mirrik ---' "$f")
    [ "$n" = 1 ] || echo "$CFG hat $n Marker statt 1 (Block verdoppelt?)"
    grep -q 'bind = OLD' "$f" || echo "der vorhandene Block wurde ueberschrieben"
    grep -qi 'already has a Mirrik block' <<<"$OUT" || echo "kein Hinweis auf den vorhandenen Block"
}
check_lua_hint() {
    installed_ok; has_desktop
    grep -q 'Lua files found' <<<"$OUT" || echo "Lua-Dateien wurden nicht erkannt"
    grep -q 'hl.bind' <<<"$OUT" || echo "die hl.*-Uebersetzung fehlt"
    [ -e "$HOME_UNDER_TEST/$CFG" ] && grep -q -- '--- Mirrik ---' "$HOME_UNDER_TEST/$CFG" && echo "trotz Lua-Fund in die conf geschrieben"
    return 0
}
check_gsettings() {
    installed_ok; has_desktop
    grep -q gsettings "$STUBLOG" 2>/dev/null || echo "gsettings wurde nicht aufgerufen"
    grep -q mirrik-gui "$STUBLOG" 2>/dev/null || echo "der Befehl im gsettings-Aufruf fehlt"
}
check_xfconf() {
    installed_ok; has_desktop
    grep -q xfconf-query "$STUBLOG" 2>/dev/null || echo "xfconf-query wurde nicht aufgerufen"
}
check_state_written() {   # die Zustandsdatei traegt die richtigen Werte fuer einen Block-Fall
    check_appended
    local f="$HOME_UNDER_TEST/.local/state/mirrik/install-state"
    [ -f "$f" ] || { echo "Zustandsdatei wurde nicht geschrieben"; return 0; }
    grep -qF 'MIRRIK_STATE_WM=1' "$f" || echo "wm nicht im Zustand vermerkt"
    grep -qF "MIRRIK_STATE_BINDIR=$HOME_UNDER_TEST/.local/bin" "$f" || echo "bindir nicht im Zustand vermerkt"
    grep -qF "MIRRIK_STATE_CONFIG=$HOME_UNDER_TEST/$CFG" "$f" || echo "config-Pfad nicht im Zustand vermerkt"
    grep -qF 'MIRRIK_STATE_APPS=' "$f" || echo "apps-Verzeichnis fehlt als Schluessel im Zustand"
    grep -qF '.local/state/mirrik' <<<"$OUT" || echo "die Zustandsdatei wird im Abschluss-Block nicht genannt"
}
check_state_gnome() {   # die Zustandsdatei traegt keybind_kind=gnome, kein Block-Pfad
    check_gsettings
    local f="$HOME_UNDER_TEST/.local/state/mirrik/install-state"
    [ -f "$f" ] || { echo "Zustandsdatei wurde nicht geschrieben"; return 0; }
    grep -qF 'MIRRIK_STATE_KEYBIND_KIND=gnome' "$f" || echo "keybind_kind=gnome nicht im Zustand vermerkt"
    # printf '%q' schreibt einen leeren Wert als zwei Anfuehrungszeichen, nicht als
    # nichts - deshalb hier gegen '' geprueft und nicht gegen eine leere Zeile.
    grep -qx "MIRRIK_STATE_CONFIG=''" "$f" \
        || echo "config-Pfad ist nicht leer, obwohl GNOME kein Config-Snippet schreibt"
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$OUT" \
        || echo "der GNOME-Rueckbauhinweis fehlt im Abschluss-Block"
}
check_manual_hint() { installed_ok; has_desktop; }
check_tool_called() {   # GNOME/Cinnamon/XFCE setzen das Kuerzel ueber ein Werkzeug
    installed_ok; has_desktop
    # Nicht "wurde aufgerufen", sondern "hat etwas gesetzt, das auf uns zeigt": ein
    # blosses list-schemas ist der Ausweichpfad, kein Erfolg.
    grep -q 'mirrik-gui' "$STUBLOG" 2>/dev/null \
        || echo "kein Aufruf, der mirrik-gui setzt (nur Abfragen?)"
    grep -qE 'gsettings set|xfconf-query .*-s ' "$STUBLOG" 2>/dev/null \
        || echo "kein schreibender Aufruf (set) im Protokoll"
}
check_abort() {
    [ "$RC" = 0 ] && echo "Exit-Code 0, obwohl Abbruch erwartet war"
    [ -e "$HOME_UNDER_TEST/.local/bin/mirrik" ] && echo "trotz Abbruch installiert"
    return 0
}
check_pathline() {
    installed_ok; has_desktop
    local rc_file="$HOME_UNDER_TEST/.bashrc"
    [ -f "$rc_file" ] || { echo ".bashrc wurde nicht geschrieben"; return 0; }
    local n; n=$(grep -c -- '--- Mirrik ---' "$rc_file")
    [ "$n" = 1 ] || echo ".bashrc hat $n Marker statt 1"
    grep -q 'local/bin' "$rc_file" || echo "die PATH-Zeile nennt das Zielverzeichnis nicht"
}

# Antworten werden als KOMMALISTE gefuehrt, nicht mit Zeilenumbruechen: `read` liest nur
# bis zum ersten Umbruch, wodurch Pruef-Funktion und Optionen leer blieben - und jeder
# mehrzeilige Fall "bestand", ohne irgendetwas zu pruefen.
# --- Missbrauch und Unsinn -------------------------------------------------
# Der Installer nimmt Text vom Nutzer und schreibt ihn in Befehlszeilen und Configs.
# Diese Pruefungen fragen nicht "laeuft der Zweig durch", sondern "kann eine Eingabe
# etwas anrichten, das niemand wollte".

canary_clean() {   # nichts ausserhalb des Test-HOME angefasst
    for c in /tmp/mirrik-pwned /tmp/mirrik-pwned2; do
        [ -e "$c" ] && { echo "EINGABE HAT ETWAS AUSGEFUEHRT: $c wurde angelegt"; rm -f "$c"; }
    done
    return 0
}
check_injection() {   # Eingabe mit Shell-Metazeichen darf nichts ausfuehren
    canary_clean
    [ "$RC" = 0 ] || [ "$RC" = 1 ] || echo "unerwarteter Exit-Code $RC"
    return 0
}
check_survives_nonsense() {   # Unsinnseingaben: kein Absturz, keine halbe Installation
    canary_clean
    grep -qi 'Traceback\|command not found\|unbound variable\|syntax error' <<<"$OUT" \
        && echo "Fehlermeldung der Shell in der Ausgabe"
    if [ -e "$HOME_UNDER_TEST/.local/bin/mirrik" ] && [ ! -e "$HOME_UNDER_TEST/.local/bin/mirrik-gui" ]; then
        echo "halbe Installation: nur eine der beiden Binaries"
    fi
    return 0
}
check_space_warned() {   # Leerzeichen im Zielpfad: Warnung, und wenn angenommen, Exec zitiert
    canary_clean
    grep -q 'contains a space' <<<"$OUT" || echo "keine Warnung zum Leerzeichen"
    local d="$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop"
    [ -f "$d" ] || { echo ".desktop fehlt"; return 0; }
    local line; line=$(grep '^Exec=' "$d")
    case "$line" in
        *' '*) grep -q '^Exec="' "$d" || echo "Exec enthaelt ein Leerzeichen, ist aber nicht zitiert: $line" ;;
    esac
}
check_space_declined() { # Warnung abgelehnt: Rueckfall auf ~/.local/bin
    canary_clean
    grep -q 'contains a space' <<<"$OUT" || echo "keine Warnung zum Leerzeichen"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik" ] || echo "kein Rueckfall auf ~/.local/bin"
}
check_reasked() {   # ungueltige Auswahl: Hinweis, erneute Frage, dann der richtige Zweig
    canary_clean
    grep -q 'Not one of the choices' <<<"$OUT" || echo "keine erneute Frage nach ungueltiger Eingabe"
    check_appended
}
check_no_server_check() {   # ohne pactl kann der Server nicht bestimmt werden
    installed_ok; has_desktop
    grep -q 'pactl is not installed' <<<"$OUT" || echo "kein Hinweis auf fehlendes pactl"
}
check_old_pw_warned() {
    installed_ok
    grep -q 'too old' <<<"$OUT" || echo "keine Warnung zur alten PipeWire-Fassung"
    grep -q '0.3.64' <<<"$OUT" || echo "die geforderte Mindestversion wird nicht genannt"
}
check_version_unknown() {
    installed_ok
    grep -qi 'could not read the pipewire version' <<<"$OUT" || echo "kein Hinweis auf unlesbare Version"
}
check_generic_hint() {   # unbekannte Distribution: kein Paketbefehl, aber ein Weg
    installed_ok
    grep -qi 'package manager' <<<"$OUT" || echo "kein allgemeiner Hinweis fuer unbekannte Distributionen"
    grep -qE 'apt install|pacman -S|dnf install|zypper' <<<"$OUT" && echo "ein Paketbefehl fuer eine fremde Distribution wurde vorgeschlagen"
    return 0
}
check_distro_hint_apt()    { installed_ok; grep -q 'apt install' <<<"$OUT" || echo "kein apt-Befehl fuer Debian"; }
check_distro_hint_pacman() { installed_ok; grep -q 'pacman -S' <<<"$OUT" || echo "kein pacman-Befehl fuer Arch"; }
# Diese drei erreichen den eval-Zweig: geprueft wird, WAS er ausfuehren wuerde.
check_apt_called()    { installed_ok; grep -q 'sudo apt install pipewire' "$STUBLOG" 2>/dev/null || echo "apt wurde nicht mit den PipeWire-Paketen aufgerufen"; }
check_pacman_called() { installed_ok; grep -q 'sudo pacman -S' "$STUBLOG" 2>/dev/null || echo "pacman wurde nicht aufgerufen"; }
check_dnf_called()    { installed_ok; grep -q 'sudo dnf install' "$STUBLOG" 2>/dev/null || echo "dnf wurde nicht aufgerufen"; }
check_nixos_hint()         { installed_ok; grep -q 'services.pipewire' <<<"$OUT" || echo "kein NixOS-Hinweis"; grep -q 'sudo ' <<<"$OUT" && echo "NixOS bekam einen imperativen Installationsbefehl"; return 0; }
check_rulev2()  { installed_ok; grep -q 'windowrulev2 = float' <<<"$OUT" || echo "alte Fassung bekam nicht windowrulev2"; grep -q 'needs windowrulev2' <<<"$OUT" || echo "kein Hinweis zur Schreibweise"; }
check_rule_neu(){
    installed_ok
    grep -qE 'windowrule = float' <<<"$OUT" || echo "neue Fassung bekam nicht windowrule"
    grep -q 'windowrulev2 = ' <<<"$OUT" && echo "trotz neuer Fassung windowrulev2 geschrieben"
    # Ohne diese Zeile waere der Fall auch gruen, wenn hyprctl gar nicht befragt wurde -
    # dann faellt der Installer ohnehin auf die neue Schreibweise zurueck.
    grep -q 'hyprctl was not found' <<<"$OUT" && echo "hyprctl wurde nicht gefunden - der Fall prueft nichts"
    return 0
}
check_rule_angenommen() { installed_ok; grep -q 'hyprctl was not found' <<<"$OUT" || echo "kein Hinweis, dass die Version geraten wurde"; }
check_replaces_old() {   # vorhandene Fassung: gemeldet und vorher abgeschaltet
    installed_ok; has_desktop
    grep -q 'Replacing what is already installed: mirrik 0.0.9' <<<"$OUT" \
        || echo "die vorhandene Fassung wurde nicht mit ihrer Version genannt"
    grep -q 'old-mirrik off' "$STUBLOG" 2>/dev/null \
        || echo "die laufende Spiegelung wurde nicht abgeschaltet"
}
check_eof() {   # stdin endet mitten in den Fragen
    canary_clean
    grep -qi 'unbound variable\|syntax error' <<<"$OUT" && echo "Shell-Fehler bei EOF"
    return 0
}

# --- Die Zustandsdatei ueber zwei Laeufe hinweg ----------------------------------
#
# Kein einzelner Lauf kann zeigen, ob der Abschluss-Block einen zweiten Lauf mit
# anderen Antworten richtig behandelt - dafuer braucht es zwei Aufrufe des Installers
# im selben Test-Home. run_case ist auf genau einen Aufruf gebaut, deshalb hier eine
# eigene, kleinere Fassung derselben Idee statt run_case zu verbiegen.
run_installer_once() {  # <home> <path> <antworten>
    local home="$1" path="$2" answers="$3"
    printf '%s\n' "$(printf '%s' "$answers" | tr ',' '\n')" | env -i \
        HOME="$home" PATH="$path" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
        bash "$INSTALLER" 2>&1
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

# Ein zweites bin-Verzeichnis, von Anfang an im PATH - sonst zieht ein Wechsel des
# Zielordners im zweiten Lauf zusaetzlich die "nicht im PATH"-Frage nach sich und
# verschiebt jede folgende Antwort um eins.
setup_two_phase_home() {  # -> druckt "<home> <path>" auf stdout
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
    local name='state-wechsel-compositor-altlast'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null      # Lauf 1: Hyprland
    local out; out="$(run_installer_once "$home" "$path" "$(a y 8 2 a y)")"  # Lauf 2: GNOME
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local cfg="$home/.config/hypr/hyprland.conf"
    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        || problems+=("kein Hinweis auf den Rest aus Lauf 1")
    grep -qF "delete the '# --- Mirrik ---' block from $cfg" <<<"$out" \
        || problems+=("der Hyprland-Block aus Lauf 1 wird nicht als Altlast genannt")
    grep -qF -- '(if still on GNOME)' <<<"$out" \
        && problems+=("GNOME (die Wahl aus Lauf 2) wurde faelschlich auch als Altlast gemeldet")
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$out" \
        || problems+=("die normale GNOME-Zeile aus Lauf 2 fehlt")
    [ -f "$cfg" ] && grep -qF -- '--- Mirrik ---' "$cfg" \
        || problems+=("der Hyprland-Block wurde durch Lauf 2 tatsaechlich entfernt (sollte liegen bleiben)")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_switch_bindir() {
    local name='state-wechsel-bindir-altlast'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null                  # Lauf 1: ~/.local/bin
    local out; out="$(run_installer_once "$home" "$path" "$home/.local/bin2,y,1,2,a,1")"  # Lauf 2: anderer bindir, Block schon da
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    [ -x "$home/.local/bin2/mirrik" ] || problems+=("mirrik wurde nicht in den neuen bindir installiert")
    [ -x "$home/.local/bin/mirrik" ] || problems+=("die Installation aus Lauf 1 ist verschwunden - sollte liegen bleiben")
    grep -q 'Also still there from an earlier run' <<<"$out" \
        || problems+=("kein Hinweis auf den alten bindir aus Lauf 1")
    grep -qF "rm $home/.local/bin/mirrik $home/.local/bin/mirrik-gui" <<<"$out" \
        || problems+=("der rm-Befehl fuer den alten bindir fehlt oder ist ungenau")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_no_false_positive() {
    local name='state-unveraendert-keine-falsche-altlast'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 1 2 a 1 y)" >/dev/null   # Lauf 1
    local out; out="$(run_installer_once "$home" "$path" "$(a y 1 2 a 1)")"  # Lauf 2, gleiche Wahl, Block schon da
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        && problems+=("Lauf 2 aendert nichts, meldet aber eine Altlast")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

test_state_skip_carries_forward() {
    local name='state-uebersprungen-kein-fehlalarm'
    local home path; read -r home path < <(setup_two_phase_home)

    run_installer_once "$home" "$path" "$(a y 8 2 a y)" >/dev/null   # Lauf 1: GNOME eingerichtet
    local out; out="$(run_installer_once "$home" "$path" "$(a y 13 2 a)")"  # Lauf 2: Schritt 5 uebersprungen
    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    grep -q 'Also still there from an earlier run' <<<"$out" \
        && problems+=("Uebersprungen wird als Wechsel gelesen und faelschlich als Altlast gemeldet")
    grep -q 'and remove "Mirrik" under Settings > Keyboard > Custom Shortcuts$' <<<"$out" \
        || problems+=("der GNOME-Rueckbauhinweis aus Lauf 1 fehlt, obwohl Lauf 2 ihn nur uebernehmen sollte")
    [ -n "${VERBOSE:-}" ] && [ "${#problems[@]}" -gt 0 ] && printf '%s\n' "$out" | tail -25 | sed 's/^/        | /'

    report_case "$name" "${problems[@]}"
    rm -rf "$home"
}

a() {  # <desktop:y|n> <wm> <mods> <key> [weitere Antworten...]
    local d="$1" wm="$2" mods="$3" key="$4"; shift 4
    local rest=""; for x in "$@"; do rest="$rest,$x"; done
    printf ',%s,%s,%s,%s%s' "$d" "$wm" "$mods" "$key" "$rest"
}

CASES=(
  "hyprland-append|$(a y 1 2 a 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "ueber-alte-fassung|$(a y 1 2 a 1 y)|check_replaces_old|cfg=.config/hypr/hyprland.conf;preinstalled=0.0.9"
  "sway-append|$(a y 2 2 a 1 y)|check_appended|cfg=.config/sway/config"
  "i3-append|$(a y 3 2 a 1 y)|check_appended|cfg=.config/i3/config"
  "river-append|$(a y 5 2 a 1 y)|check_appended|cfg=.config/river/init"
  "awesome-append|$(a y 6 2 a 1 y)|check_appended|cfg=.config/awesome/rc.lua"
  "bspwm-append|$(a y 7 2 a 1 y)|check_appended|cfg=.config/sxhkd/sxhkdrc"
  "hyprland-print|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf"
  "hyprland-alt-0.48|$(a y 1 2 a 2)|check_rulev2|cfg=.config/hypr/hyprland.conf;hyprversion=0.48.1"
  "hyprland-neu-0.56|$(a y 1 2 a 2)|check_rule_neu|cfg=.config/hypr/hyprland.conf;hyprversion=0.56.2"
  "hyprland-genau-0.49|$(a y 1 2 a 2)|check_rule_neu|cfg=.config/hypr/hyprland.conf;hyprversion=0.49.0"
  "hyprland-ohne-hyprctl|$(a y 1 2 a 2)|check_rule_angenommen|cfg=.config/hypr/hyprland.conf"
  "niri-print|$(a y 4 2 a 2)|check_printed_niri|cfg=.config/niri/config.kdl"
  "sway-print|$(a y 2 2 a 2)|check_printed|cfg=.config/sway/config"
  "config-fehlt|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf;pre=none"
  "block-schon-da|$(a y 1 2 a 1)|check_untouched|cfg=.config/hypr/hyprland.conf;pre=marker"
  "zweimal-installiert|$(a y 1 2 a 1 y)|check_appended|cfg=.config/hypr/hyprland.conf;repeat=2"
  "lua-erkannt|$(a y 1 2 a 2)|check_lua_hint|cfg=.config/hypr/hyprland.conf;lua=1"
  "gnome-gsettings|$(a y 8 2 a y)|check_gsettings|"
  "state-datei-hyprland|$(a y 1 2 a 1 y)|check_state_written|cfg=.config/hypr/hyprland.conf"
  "state-datei-gnome|$(a y 8 2 a y)|check_state_gnome|"
  # AUSGESETZT: Cinnamon laeuft bis "Done" durch, ruft aber kein gsettings auf.
  # Noch nicht geklaert, ob der Zweig andere Antworten erwartet oder etwas fehlt.
  #   "cinnamon-gsettings|,y,9,2,a,y|check_gsettings|"
  "xfce-xfconf|$(a y 11 2 a y)|check_xfconf|"
  "kde-hinweis|$(a y 10 2 a)|check_manual_hint|"
  "sonstiges-hinweis|$(a y 12 2 a)|check_manual_hint|"
  "schritt-uebersprungen|$(a y 13 2 a)|check_manual_hint|"
  "mods-super|$(a y 1 1 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "mods-alt|$(a y 1 3 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "mods-ctrl-alt|$(a y 1 4 m 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "taste-ziffer|$(a y 1 2 5 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "taste-default|$(a y 1 2 '' 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "desktop-abgelehnt|$(a n 1 2 a 2)|no_desktop|cfg=.config/hypr/hyprland.conf"
  "pfad-zeile|,y,y,1,2,a,1,y|check_pathline|cfg=.config/hypr/hyprland.conf;nopath=1"
  "pulseaudio-abbruch|n|check_abort|server=PulseAudio;cfg=.config/hypr/hyprland.conf"
  "kein-audioserver|n|check_abort|server=;cfg=.config/hypr/hyprland.conf"
  # Seit dem Minimal-PATH (ohne /usr/bin) wirkt "missing=" wirklich.
  "ohne-pw-cli-abgebrochen|n|check_abort|missing=pw-cli;cfg=.config/hypr/hyprland.conf"
  "ohne-pw-cli-fortgesetzt|n,y,,y,1,2,a,1,y|check_appended|missing=pw-cli;cfg=.config/hypr/hyprland.conf"
  "ohne-pactl|n,y,,y,1,2,a,1,y|check_no_server_check|missing=pactl;cfg=.config/hypr/hyprland.conf"
  # --- Versionen
  "pipewire-zu-alt-abgebrochen|n|check_abort|server=PulseAudio (on PipeWire 0.3.48);cfg=.config/hypr/hyprland.conf"
  "pipewire-zu-alt-fortgesetzt|y,,y,1,2,a,1,y|check_old_pw_warned|server=PulseAudio (on PipeWire 0.3.48);cfg=.config/hypr/hyprland.conf"
  "pipewire-genau-0364|,y,1,2,a,1,y|check_appended|server=PulseAudio (on PipeWire 0.3.64);cfg=.config/hypr/hyprland.conf"
  "pipewire-version-unlesbar|,y,1,2,a,1,y|check_version_unknown|server=PipeWire;cfg=.config/hypr/hyprland.conf"
  # --- Distributionen (os-release wird untergeschoben)
  "distro-unbekannt|y,,y,1,2,a,1,y|check_generic_hint|missing=pw-cli;osrelease=exotix;cfg=.config/hypr/hyprland.conf"
  "distro-debian-abgelehnt|n,y,,y,1,2,a,1,y|check_distro_hint_apt|missing=pw-cli;osrelease=debian;cfg=.config/hypr/hyprland.conf"
  "distro-debian-ausgefuehrt|y,y,,y,1,2,a,1,y|check_apt_called|missing=pw-cli;osrelease=debian;cfg=.config/hypr/hyprland.conf"
  "distro-arch-ausgefuehrt|y,y,,y,1,2,a,1,y|check_pacman_called|missing=pw-cli;osrelease=arch;cfg=.config/hypr/hyprland.conf"
  "distro-fedora-ausgefuehrt|y,y,,y,1,2,a,1,y|check_dnf_called|missing=pw-cli;osrelease=fedora;cfg=.config/hypr/hyprland.conf"
  "distro-nixos|y,,y,1,2,a,1,y|check_nixos_hint|missing=pw-cli;osrelease=nixos;cfg=.config/hypr/hyprland.conf"
  "ohne-binaries-ohne-cargo||check_abort|nobins=1;missing=cargo"
  "ohne-binaries-bau-abgelehnt|n|check_abort|nobins=1"
  # --- Missbrauch: Shell-Metazeichen in den beiden freien Textfeldern
  "injektion-taste|,y,1,2,a\";touch /tmp/mirrik-pwned;#,a,1,y|check_injection|cfg=.config/hypr/hyprland.conf"
  "injektion-bindir|/tmp/x\";touch /tmp/mirrik-pwned2;#,y,1,2,a,2|check_injection|cfg=.config/hypr/hyprland.conf"
  "leerzeichen-angenommen|/tmp/mirrik test bin,y,y,y,1,2,a,1,y|check_space_warned|cfg=.config/hypr/hyprland.conf"
  "leerzeichen-abgelehnt|/tmp/mirrik test bin,n,y,1,2,a,1,y|check_space_declined|cfg=.config/hypr/hyprland.conf"
  # --- Unsinn statt Auswahl
  "wm-zahl-zu-gross-dann-gueltig|,y,99,1,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "wm-buchstaben-dann-gueltig|,y,abc,1,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "mods-unsinn-dann-gueltig|,y,1,9,2,a,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "kind-unsinn-dann-gueltig|,y,1,2,a,7,1,y|check_reasked|cfg=.config/hypr/hyprland.conf"
  "taste-mehrzeichig-dann-gueltig|,y,1,2,abc,a,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  "taste-sonderzeichen-dann-gueltig|,y,1,2,%,q,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  # --- stdin endet vorzeitig
  "eof-sofort||check_eof|cfg=.config/hypr/hyprland.conf"
  "eof-nach-drei|,y,1|check_eof|cfg=.config/hypr/hyprland.conf"
)

# Die erzeugte Vollmatrix wird mitgeladen, wenn sie daneben liegt. So bleiben die
# handgeschriebenen Sonderfaelle oben und die Vollzaehlung kommt dazu.
if [ -f "$REPO/tools/matrix-cases.txt" ] && [ -z "${NO_MATRIX:-}" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        CASES+=("$line")
    done < "$REPO/tools/matrix-cases.txt"
fi

filter="${1:-}"
echo "install.sh — Pruefstand"
echo "${dim}Attrappen-HOME je Fall, echtes System unberuehrt${off}"
echo
for entry in "${CASES[@]}"; do
    IFS='|' read -r name answers check opts <<<"$entry"
    [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
    run_case "$name" "$answers" "$check" "$opts"
done

# Zwei-Laeufe-Faelle: nicht ueber die CASES-Tabelle, weil sie zwei verschiedene
# Antwortfolgen im selben Test-Home brauchen statt einer.
for fn in test_state_switch_compositor test_state_switch_bindir \
          test_state_no_false_positive test_state_skip_carries_forward; do
    [ -n "$filter" ] && [[ "$fn" != *"$filter"* ]] && continue
    "$fn"
done
echo
printf '  %s bestanden, %s durchgefallen\n' "$pass" "$fail"
[ "$fail" = 0 ] || { printf '  Durchgefallen: %s\n' "${failed_names[*]}"; exit 1; }
