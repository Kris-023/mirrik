#!/usr/bin/env bash
#
# Prueft install.sh gegen alle Compositor-Zweige, ohne etwas am eigenen System zu aendern.
#
# Wie das geht: jeder Fall bekommt ein frisches HOME aus mktemp und ein PATH-Verzeichnis
# mit Attrappen der Programme, die der Installer aufruft. Der Installer merkt davon nichts -
# er sieht ein System, das genau so antwortet, wie der Fall es vorgibt.
#
# Was das NICHT belegt: dass der geschriebene Bind im echten Compositor funktioniert.
# Attrappen pruefen Logik, nicht Wirklichkeit. Genau daran ist der erste echte Linux-Lauf
# gescheitert, obwohl die Logik vorher "durch" war.
#
# Aufruf:  tools/test-install.sh            alle Faelle
#          tools/test-install.sh 1 4 9      nur diese
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO/install.sh"
[ -x "$INSTALLER" ] || { echo "install.sh nicht gefunden: $INSTALLER" >&2; exit 1; }

pass=0; fail=0; failed_names=()
green=$'\033[32m'; red=$'\033[31m'; dim=$'\033[90m'; off=$'\033[0m'
[ -t 1 ] || { green=''; red=''; dim=''; off=''; }

# ---------------------------------------------------------------- Attrappen

make_stubs() {  # make_stubs <bin-dir> <pactl-server-name>
    local d="$1" server="$2"
    mkdir -p "$d"

    cat > "$d/pactl" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = info ] && printf 'Server Name: %s\n' "$server"
exit 0
EOF
    # Die drei pw-Werkzeuge muessen nur existieren und 0 liefern.
    for t in pw-cli pw-dump pw-metadata update-desktop-database dconf; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$t"
    done

    # Schritt 6 liest die Geraeteliste. Format wie das echte `mirrik devices`:
    # Namenszeilen beginnen mit "* " oder zwei Leerzeichen, Ids darunter mit vier.
    cat > "$d/mirrik" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = devices ]; then
    printf '* Built-in Analog Stereo  [analog]\n    alsa_output.stub.analog-stereo\n'
    printf '  Display HDMI  [HDMI]\n    alsa_output.stub.hdmi-stereo\n'
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/mirrik-gui"

    # gsettings/xfconf-query schreiben in echte Konfigurationen - hier nur mitschreiben.
    for t in gsettings xfconf-query; do
        cat > "$d/$t" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$STUB_LOG"
exit 0
EOF
    done
    chmod +x "$d"/*
}

# ---------------------------------------------------------------- ein Fall

# Das Zielverzeichnis liegt im PATH: sonst fragt der Installer zusaetzlich, ob er die
# PATH-Zeile in die Shell-rc schreiben soll, und jede folgende Antwort rutscht um eine
# Frage weiter - der Compositor-Zweig war dann der Auffangzweig statt Hyprland.
run_case() {  # run_case <name> <antworten> <appended|printed> <config-pfad> [server]
    local name="$1" answers="$2" mode="$3" cfg="$4"
    local server="${5:-PulseAudio (on PipeWire 1.6.8)}"
    local home; home="$(mktemp -d)"
    local stubs="$home/stubs"

    mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share/applications"
    make_stubs "$stubs" "$server"

    # Eine vorhandene Konfigurationsdatei ist der Normalfall - und seit 2026-08-17
    # entscheidet ihre Existenz die Vorauswahl im Installer. PRECREATE=leer stellt
    # den anderen Fall her: die Datei fehlt.
    if [ -n "${PRECREATE:-}" ]; then
        mkdir -p "$home/$(dirname "$PRECREATE")"
        printf '# existing config\n' > "$home/$PRECREATE"
    fi

    # Binaries neben dem Skript, damit der Bauzweig nicht anspringt: der Installer
    # prueft nur auf -x, der Inhalt ist ihm gleich.
    cp "$stubs/mirrik" "$stubs/mirrik-gui" "$REPO/" 2>/dev/null

    # REPEAT=2 laeuft den Installer zweimal im selben HOME. Das ist kein Kunstfall:
    # ein doppelt angehaengter Block war schon einmal ein echter Fehler.
    local out rc i
    for ((i = 1; i <= ${REPEAT:-1}; i++)); do
    out="$(printf '%s\n' "$answers" | env -i \
        HOME="$home" PATH="$stubs:$home/.local/bin:/usr/bin:/bin" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        STUB_LOG="$home/stub.log" SHELL=/bin/bash TERM=dumb \
        bash "$INSTALLER" 2>&1)"
    rc=$?
    done

    rm -f "$REPO/mirrik" "$REPO/mirrik-gui"

    local problems=()
    # Die Pruefungen bekommen alles ueber die Umgebung und melden Probleme auf stdout.
    mapfile -t problems < <(
        export HOME_UNDER_TEST="$home" OUT="$out" RC="$rc" CFG="$cfg"
        if [ "$mode" = appended ]; then check_appended; else check_printed; fi
    )

    if [ ${#problems[@]} -eq 0 ]; then
        printf '  %s✓%s %s\n' "$green" "$off" "$name"
        pass=$((pass + 1))
    else
        printf '  %s✗%s %s\n' "$red" "$off" "$name"
        printf '      %s\n' "${problems[@]}"
        fail=$((fail + 1)); failed_names+=("$name")
    fi
    rm -rf "$home"
}

# ---------------------------------------------------------------- Pruefungen

# Gemeinsame Grundlage: Installation gelungen, nichts ausserhalb des Test-HOME.
check_common() {
    [ "$RC" = 0 ] || echo "Exit-Code $RC statt 0"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik" ]     || echo "mirrik nicht installiert"
    [ -x "$HOME_UNDER_TEST/.local/bin/mirrik-gui" ] || echo "mirrik-gui nicht installiert"
    [ -f "$HOME_UNDER_TEST/.local/share/applications/mirrik.desktop" ] \
        || echo ".desktop fehlt"
    grep -q 'sees 2 output device' <<<"$OUT" || echo "Schritt 6 hat die Geraete nicht gelesen"
}

check_appended() {   # Config existiert und traegt genau einen Block
    check_common
    local f="$HOME_UNDER_TEST/$CFG"
    [ -f "$f" ] || { echo "$CFG wurde nicht geschrieben"; return; }
    local n; n=$(grep -c -- '--- Mirrik ---' "$f")
    [ "$n" = 1 ] || echo "$CFG hat $n Marker statt 1"
    grep -q 'mirrik-gui' "$f" || echo "$CFG nennt mirrik-gui nicht"
}

check_printed() {  # kein Block in der Datei, Zeilen aber gedruckt
    check_common
    local f="$HOME_UNDER_TEST/$CFG"
    [ -e "$f" ] && grep -q -- '--- Mirrik ---' "$f" \
        && echo "$CFG traegt einen Block, obwohl 'nur drucken' gewaehlt war"
    grep -q -- '--- Mirrik ---' <<<"$OUT" || echo "die Zeilen wurden nicht gedruckt"
}

# ---------------------------------------------------------------- Faelle

# Antwortreihenfolge im Normalfall:
#   bindir · .desktop · Compositor · Modifier · Taste · [Config-Umgang]
answers() {  # answers <compositor-nr> <modus>
    # bindir · .desktop · Compositor · Modifier · Taste, dann je nach Modus:
    #   appended: "1" (anhaengen) und das y aus append_block
    #   printed:  "2" (nur drucken)
    if [ "$2" = appended ]; then
        printf '%s\n' '' 'y' "$1" '2' 'a' '1' 'y'
    else
        printf '%s\n' '' 'y' "$1" '2' 'a' '2'
    fi
}

# Name = <compositor-nr>|<config-pfad>|<modus>[|<precreate>]
# Fehlt das vierte Feld, wird die Config vorher angelegt (Normalfall).
declare -A CASES=(
  [hyprland-append]="1|.config/hypr/hyprland.conf|appended"
  [hyprland-print]="1|.config/hypr/hyprland.conf|printed"
  [hyprland-ohne-config]="1|.config/hypr/hyprland.conf|printed|none"
  [sway-append]="2|.config/sway/config|appended"
  [i3-append]="3|.config/i3/config|appended"
  [niri-print]="4|.config/niri/config.kdl|printed"
  [river-append]="5|.config/river/init|appended"
  [awesome-append]="6|.config/awesome/rc.lua|appended"
  [bspwm-append]="7|.config/sxhkd/sxhkdrc|appended"
  [hyprland-zweimal]="1|.config/hypr/hyprland.conf|appended"
)

echo "install.sh — Pruefstand"
echo "${dim}Attrappen-HOME je Fall, echtes System unberuehrt${off}"
echo

for name in $(printf '%s\n' "${!CASES[@]}" | sort); do
    IFS='|' read -r wm cfg mode pre <<<"${CASES[$name]}"
    # read setzt fehlende Felder auf leer, nicht auf unset - deshalb ein ausdrueckliches
    # "none" statt eines leeren Feldes fuer "Konfigurationsdatei existiert nicht".
    [ "$pre" = none ] && pre='' || pre="$cfg"
    reps=1; [[ "$name" == *zweimal* ]] && reps=2
    PRECREATE="$pre" REPEAT="$reps" run_case "$name" "$(answers "$wm" "$mode")" "$mode" "$cfg"
done

echo
printf '  %s bestanden, %s durchgefallen\n' "$pass" "$fail"
[ "$fail" = 0 ] || { printf '  Durchgefallen: %s\n' "${failed_names[*]}"; exit 1; }
