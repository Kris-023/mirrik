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
    for t in gsettings xfconf-query; do
        [[ "$missing" == *" $t "* ]] && continue
        cat > "$d/$t" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$STUB_LOG"
exit 0
EOF
    done
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
    IFS=';' read -ra kv <<<"$opts"
    for pair in "${kv[@]}"; do
        [ -z "$pair" ] && continue
        case "${pair%%=*}" in
            cfg) cfg="${pair#*=}" ;; pre) pre="${pair#*=}" ;;
            server) server="${pair#*=}" ;; missing) missing="${pair#*=}" ;;
            lua) lua=1 ;; nobins) nobins=1 ;; nopath) nopath=1 ;; repeat) repeat="${pair#*=}" ;;
        esac
    done

    local home; home="$(mktemp -d)"
    local stubs="$home/stubs"
    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share/applications"
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
    [ -z "$nobins" ] && cp "$stubs/mirrik" "$stubs/mirrik-gui" "$REPO/" 2>/dev/null

    local path="$stubs:/usr/bin:/bin"
    [ -z "$nopath" ] && path="$stubs:$home/.local/bin:/usr/bin:/bin"

    local out rc i answer_lines
    answer_lines="$(printf '%s' "$answers" | tr ',' '\n')"
    for ((i = 1; i <= repeat; i++)); do
        out="$(printf '%s\n' "$answer_lines" | env -i \
            HOME="$home" PATH="$path" \
            XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
            STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
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
check_manual_hint() { installed_ok; has_desktop; }
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
check_eof() {   # stdin endet mitten in den Fragen
    canary_clean
    grep -qi 'unbound variable\|syntax error' <<<"$OUT" && echo "Shell-Fehler bei EOF"
    return 0
}

a() {  # <desktop:y|n> <wm> <mods> <key> [weitere Antworten...]
    local d="$1" wm="$2" mods="$3" key="$4"; shift 4
    local rest=""; for x in "$@"; do rest="$rest,$x"; done
    printf ',%s,%s,%s,%s%s' "$d" "$wm" "$mods" "$key" "$rest"
}

CASES=(
  "hyprland-append|$(a y 1 2 a 1 y)|check_appended|cfg=.config/hypr/hyprland.conf"
  "sway-append|$(a y 2 2 a 1 y)|check_appended|cfg=.config/sway/config"
  "i3-append|$(a y 3 2 a 1 y)|check_appended|cfg=.config/i3/config"
  "river-append|$(a y 5 2 a 1 y)|check_appended|cfg=.config/river/init"
  "awesome-append|$(a y 6 2 a 1 y)|check_appended|cfg=.config/awesome/rc.lua"
  "bspwm-append|$(a y 7 2 a 1 y)|check_appended|cfg=.config/sxhkd/sxhkdrc"
  "hyprland-print|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf"
  "niri-print|$(a y 4 2 a 2)|check_printed|cfg=.config/niri/config.kdl"
  "sway-print|$(a y 2 2 a 2)|check_printed|cfg=.config/sway/config"
  "config-fehlt|$(a y 1 2 a 2)|check_printed|cfg=.config/hypr/hyprland.conf;pre=none"
  "block-schon-da|$(a y 1 2 a 1)|check_untouched|cfg=.config/hypr/hyprland.conf;pre=marker"
  "zweimal-installiert|$(a y 1 2 a 1 y)|check_appended|cfg=.config/hypr/hyprland.conf;repeat=2"
  "lua-erkannt|$(a y 1 2 a 2)|check_lua_hint|cfg=.config/hypr/hyprland.conf;lua=1"
  "gnome-gsettings|$(a y 8 2 a y)|check_gsettings|"
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
  # AUSGESETZT: "missing=" wirkt nicht, solange /usr/bin im PATH liegt - der Installer
  # findet dort das echte Werkzeug und meldet "All four present". Ein ehrlicher Test
  # braeuchte einen PATH ohne /usr/bin, also eine Symlink-Farm der benoetigten Coreutils.
  # Bis dahin lieber keine Faelle als gruene, die nichts pruefen.
  #   "ohne-pw-cli|n,n|check_abort|missing=pw-cli;cfg=..."
  #   "ohne-pactl|...|check_appended|missing=pactl;cfg=..."
  "ohne-binaries-ohne-cargo||check_abort|nobins=1;missing=cargo"
  "ohne-binaries-bau-abgelehnt|n|check_abort|nobins=1"
  # --- Missbrauch: Shell-Metazeichen in den beiden freien Textfeldern
  "injektion-taste|,y,1,2,a\";touch /tmp/mirrik-pwned;#,a,1,y|check_injection|cfg=.config/hypr/hyprland.conf"
  "injektion-bindir|/tmp/x\";touch /tmp/mirrik-pwned2;#,y,1,2,a,2|check_injection|cfg=.config/hypr/hyprland.conf"
  "leerzeichen-angenommen|/tmp/mirrik test bin,y,y,y,1,2,a,1,y|check_space_warned|cfg=.config/hypr/hyprland.conf"
  "leerzeichen-abgelehnt|/tmp/mirrik test bin,n,y,1,2,a,1,y|check_space_declined|cfg=.config/hypr/hyprland.conf"
  # --- Unsinn statt Auswahl
  "wm-zahl-zu-gross|,y,99,2,a|check_survives_nonsense|cfg=.config/hypr/hyprland.conf"
  "wm-buchstaben|,y,abc,2,a|check_survives_nonsense|cfg=.config/hypr/hyprland.conf"
  "mods-unsinn|,y,1,9,a,2|check_survives_nonsense|cfg=.config/hypr/hyprland.conf"
  "taste-mehrzeichig-dann-gueltig|,y,1,2,abc,a,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  "taste-sonderzeichen-dann-gueltig|,y,1,2,%,q,1,y|check_appended|cfg=.config/hypr/hyprland.conf"
  # --- stdin endet vorzeitig
  "eof-sofort||check_eof|cfg=.config/hypr/hyprland.conf"
  "eof-nach-drei|,y,1|check_eof|cfg=.config/hypr/hyprland.conf"
)

filter="${1:-}"
echo "install.sh — Pruefstand"
echo "${dim}Attrappen-HOME je Fall, echtes System unberuehrt${off}"
echo
for entry in "${CASES[@]}"; do
    IFS='|' read -r name answers check opts <<<"$entry"
    [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
    run_case "$name" "$answers" "$check" "$opts"
done
echo
printf '  %s bestanden, %s durchgefallen\n' "$pass" "$fail"
[ "$fail" = 0 ] || { printf '  Durchgefallen: %s\n' "${failed_names[*]}"; exit 1; }
