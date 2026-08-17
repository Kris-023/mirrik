# Mirrik

**Play the same sound on two or more output devices at once — on Windows and Linux.**

Your speakers *and* your headphones. Your headset *and* your partner's. Without a virtual
cable, without a driver install, and without leaving anything behind when you switch it off.

![The Mirrik window, mirroring to two devices](screenshots/gui-light.png)

---

## What problem this solves

Neither Windows nor Linux lets you send audio to two outputs at the same time. You pick one
device, and everything else stays silent. The usual workarounds — virtual audio cables,
Voicemeeter, `combine-sink` — all create a fake device you then have to select, keep around,
and remember to undo.

Mirrik takes the other route. It listens to whatever your current output is already playing
and copies that stream to the devices you choose. **No virtual device is ever created**,
your default output is never touched, and running programs notice nothing. When you turn it
off, there is nothing left to clean up.

Useful when you want to *watch a film together on two headsets*, *keep speakers and
headphones live at the same time*, *share game audio with someone next to you*, or *send
sound to a second room over HDMI*.

<sub>Keywords: play audio on two devices at once · dual audio output · mirror sound to
multiple outputs · Windows WASAPI loopback · Linux PipeWire loopback · share audio with two
headphones · simultaneous playback · second audio output · no virtual audio cable ·
alternative to Voicemeeter / VB-CABLE / Audio Router</sub>

## Two skins, picked for you

Mirrik reads your system's light/dark setting when it opens and dresses accordingly. Light is
ink on paper; dark is true black — every unlit pixel stays off, which is the point on an
OLED panel.

| Light | OLED |
|---|---|
| ![Light](screenshots/gui-light.png) | ![OLED](screenshots/gui-oled.png) |

There is no setting for this and no theme picker. Your desktop already knows which one you
want.

> On Windows the choice is made when the window opens. Flipping your desktop to dark while
> the window is up will not repaint it — Windows only tells a program its theme once per
> launch. Close it and open it again. For a window you summon with a key and dismiss with
> `Esc`, that is the same thing in practice.

## Compatibility

| | Supported | Notes |
|---|---|---|
| **Windows 11 / 10** | yes | Uses WASAPI loopback. Nothing to install, no driver, no admin rights |
| **Linux (PipeWire)** | yes | Uses `module-loopback`. PipeWire is required — see below |
| **Linux (PulseAudio only)** | no | Mirrik refuses and says why. On plain PulseAudio a crash would leave a loopback behind for good |
| **macOS** | no | No backend written for it |

Any number of destinations. Analog, USB, HDMI and Bluetooth outputs all work; sample rates
may differ between them and are converted for you.

## Features

- **Mirror to as many devices as you like** — add and remove them one at a time while
  everything keeps playing.
- **Nothing is left behind.** Off means off: no leftover device, no changed default, no
  service running in the background.
- **Independent volume per device.** Each listener sets their own level without affecting
  anyone else's.
- **Different sample rates are fine.** A 192 kHz output can mirror to a 48 kHz headset.
- **Low delay**, computed rather than guessed and shown per destination (typically 30 ms on
  Windows, 42 ms on Linux). Bluetooth destinations add roughly 200 ms and are labelled as
  such.
- **Survives device changes.** Switch your main output and the mirror follows it; unplug a
  destination and it ends cleanly.
- **Follows your system theme**, light or OLED black.
- **Keyboard-driven window**, plus a scriptable command line with `--json` on everything.

## Install

Two routes, same result. The **guided script** asks before every step, needs no
administrator rights and can undo itself. **By hand** is a copy and a key binding — the
script only does it for you and checks the traps first.

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1               # set up
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall    # take it all back
```

> `-ExecutionPolicy Bypass` is nothing shady: Windows refuses to run *any* unsigned `.ps1`,
> including one you wrote yourself five minutes ago.

It checks the machine first — Windows version, architecture, and a real display driver,
because the window is OpenGL and will not open over Remote Desktop (the command line will).
Then it copies both programs, puts them on your `PATH`, and offers a Start menu shortcut
carrying a hotkey.

That hotkey gets checked twice: against shortcuts that already claim the combination —
Windows gives it to whichever it finds first and never says so — and against your keyboard
layout, because Windows delivers AltGr as Ctrl+Alt. On a German layout `Ctrl+Alt+Q` would
cost you `@` for as long as it exists.

`-Uninstall` lists what it found — the programs, the `PATH` entry, the shortcut, the state
folder — and removes all of it after one confirmation. A running mirror is stopped first,
because Windows will not delete a running `.exe`; say no and even that is left alone.

<details>
<summary><b>By hand instead</b></summary>

1. Put `mirrik.exe` and `mirrik-gui.exe` somewhere permanent, e.g.
   `%LOCALAPPDATA%\Programs\Mirrik`.
2. **Double-click `mirrik-gui.exe`** — that is the window with the device list. `mirrik.exe`
   is the command line version and opens the window too, so the wrong file is not a problem.
3. Hotkey: right-click `mirrik-gui.exe` → *Show more options* → *Create shortcut*, move it
   into your Start menu, then *Properties* → *Shortcut key* → press your combination.
   Windows allows only `Ctrl+Alt+<key>`, so avoid keys your layout reaches with AltGr, and
   leave the shortcut in the Start menu or on the Desktop — elsewhere the hotkey stops
   working.

</details>

<details>
<summary><b>About that SmartScreen warning</b></summary>

> **Windows protected your PC** — Microsoft Defender SmartScreen prevented an unrecognised
> app from starting.

There is no *Run* button on it. The way through is **More info → Run anyway**.

What it actually means is *"Microsoft has not seen this program often"*, not *"this program
is dangerous"* — Mirrik carries no code signing certificate, since those cost a few hundred
euros a year. It is also the exact dialog real malware needs you to click through, so the
reason to trust this one is not that you dismissed it: the source is right here and you can
build it yourself.

The mark comes from the **download**, not from the program. `install.ps1` strips it, which
is why you will usually not see the dialog after running it; by hand it is right-click →
*Properties* → *Unblock*, or `Unblock-File .\mirrik-gui.exe`. Built from source there is no
mark at all.

</details>

### Linux

Needs **PipeWire** and four of its command line tools — `pactl`, `pw-cli`, `pw-dump`,
`pw-metadata`. Mirrik drives PipeWire through those instead of linking `libpipewire`, and
several distributions package the daemon and the tools separately, so a system can run
PipeWire perfectly and still be missing `pw-cli`.

```sh
pactl info | grep 'Server Name'      # should say PipeWire
./install.sh
```

If a tool is missing it names the exact package command for your distribution (Debian,
Ubuntu, Fedora — including the image-based ones on `rpm-ostree` — Arch, openSUSE, Alpine,
Void, Gentoo, NixOS). Then it installs both binaries, adds a desktop entry, and works out
the key binding for your desktop:

| | |
|---|---|
| **Hyprland, Sway, i3, river, bspwm/sxhkd, awesome** | the exact config lines, offered for appending |
| **GNOME, Cinnamon, XFCE** | set for you via `gsettings` / `xfconf-query`, if you say yes |
| **niri, KDE Plasma** | the lines to paste yourself — both rewrite their own config |

Every line is shown before anything is written, what it adds is marked so you can find it
again, the same block is never written twice, and generated configs (Nix, Home Manager,
chezmoi) are left alone — appending to those lasts until the next rebuild.

There is no `--uninstall` here, because everything it does is three lines to undo, and it
prints them when it finishes:

```sh
rm ~/.local/bin/mirrik ~/.local/bin/mirrik-gui
rm ~/.local/share/applications/mirrik.desktop
# and delete the '# --- Mirrik ---' block from your compositor config
```

<details>
<summary><b>By hand instead</b></summary>

```sh
cargo build --release --manifest-path Cargo.toml

install -Dm755 target/release/mirrik     ~/.local/bin/mirrik
install -Dm755 target/release/mirrik-gui ~/.local/bin/mirrik-gui
```

Bind the window to a key — this is the intended way to use it. Hyprland, as an example:

```
bind = SUPER SHIFT, M, exec, mirrik-gui
```

Wayland compositors place windows themselves, so it also wants a rule that floats and
centres it (Hyprland; before 0.49 these were `windowrulev2`):

```
windowrule = float, class:^(mirrik)$
windowrule = center, class:^(mirrik)$
```

</details>

## Usage

### The window

Open it, and it tells you the state first: whether something is being mirrored and where to.
Below that is the source, then one fader per active device, then the list of devices you can
add.

![The window with nothing mirroring](screenshots/gui-idle.png)

| Key | Does |
|---|---|
| `↓` `↑` or `j` `k` | move the focus (faders and devices are one chain) |
| `→` `←` or `l` `h` | adjust the focused fader in 5 % steps |
| `1` … `9` | switch that device on or off directly |
| `Enter` | on a device: add it, or remove it if already active |
| `x` | stop mirroring entirely |
| `Esc` or `q` | close the window, leaving the mirror running |

Closing the window does **not** stop the mirror — that is what `x` is for.

### The command line

```sh
mirrik devices                  # list outputs, * marks the current one
mirrik on airpods               # start mirroring to one device
mirrik on airpods hdmi          # ... or several at once
mirrik add speakers             # add one more while running
mirrik remove hdmi              # drop one, keep the rest
mirrik toggle airpods           # add if absent, remove if present
mirrik status                   # what is running
mirrik off                      # stop everything
mirrik volume airpods 60        # read or set a device's volume, 0-100
```

Any unique part of a device name works — `airpods` is enough, the full name is not needed.
If it matches several devices, Mirrik says so instead of guessing.

Everything that reports accepts `--json`, and `status --quiet` exits `0` while mirroring and
`1` otherwise, so it can drive a shell condition:

```sh
if mirrik status --quiet; then notify-send "still mirroring"; fi
```

## Worth knowing

**How it works.** On Windows a WASAPI loopback client captures what the default output is
playing and a render client pushes it to each destination, with the audio engine converting
between sample rates. On Linux `module-loopback` taps the monitor of the current sink. Both
sides deliberately avoid creating a device of their own.

**One process per destination.** Each mirrored device is held open by its own small
background process. That is the guarantee behind "off means gone" — if the process dies, for
any reason at all, that destination disappears with it. Nothing can outlive a crash.

**Volume behaves per device.** Faders are applied after the point where the copy is taken,
so each device's level is its own. Turning your speakers down does not quieten the
headphones. Where a driver applies gain *before* that point, the fader says so in the
window rather than pretending otherwise.

**Nothing is remembered.** After a reboot, sound plays to one device again. Mirroring is a
deliberate act for the moment someone is listening along, not a state to restore.

**Delay.** A mirrored device runs slightly behind the original — around 30 ms on Windows,
42 ms on Linux. In practice this is not noticeable unless two devices are in the same room
and you listen for it. Bluetooth is a different matter: its own buffering adds roughly
200 ms, which *is* audible, so those destinations are marked in the interface.

**Over a long session** the two devices' clocks drift apart by a tiny amount. Mirrik absorbs
this continuously; you may hear an occasional faint tick after hours of use.

## Licence

[MIT](LICENSE). Do what you like with it.

The window is set in [Archivo](https://github.com/Omnibus-Type/Archivo) and
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), both under the SIL Open Font
Licence — which covers the two font files only, not the rest of the project. Those licences
ship next to the fonts in `gui/assets/`.
