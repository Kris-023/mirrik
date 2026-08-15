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

## Install — Windows

There is a guided setup script. It copies the two programs somewhere permanent, offers to
put them on your `PATH`, and offers to create a Start menu shortcut with a keyboard
shortcut of your choosing. It asks before every step and needs no administrator rights.

Open PowerShell in the folder you unpacked or cloned into, and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The `-ExecutionPolicy Bypass` is not a workaround for anything shady — Windows refuses to
run *any* unsigned `.ps1` by default, including ones you wrote yourself five minutes ago.

<details>
<summary>Or do it by hand</summary>

1. Put `mirrik.exe` and `mirrik-gui.exe` somewhere permanent, for example
   `%LOCALAPPDATA%\Programs\Mirrik`.
2. **Double-click `mirrik-gui.exe`.** That is the window with the device list — it is the one
   you want. `mirrik.exe` (without `-gui`) is the command line version; double-clicking it
   opens the window as well, so picking the wrong file is not a problem.
3. For a keyboard shortcut: right-click `mirrik-gui.exe` → *Show more options* → *Create
   shortcut*, move the shortcut into your Start menu, then right-click it → *Properties* →
   click the *Shortcut key* field and press your combination. Windows only allows
   `Ctrl+Alt+<key>` here, and the hotkey only works while the shortcut lives in the Start
   menu or on the Desktop.

</details>

### About that SmartScreen warning

The first time you run Mirrik, Windows may well say this:

> **Windows protected your PC**
> Microsoft Defender SmartScreen prevented an unrecognised app from starting.

There is no *Run* button on that dialog. The way through is **More info → Run anyway**.

Here is what is actually happening, without the hand-waving:

- Mirrik is not signed with a code signing certificate. Those cost a few hundred euros a
  year, and this is a free tool.
- SmartScreen's warning means *"Microsoft has not seen this program often"*, not *"this
  program is dangerous"*. It says the same thing about every new build of every unsigned
  program, including ones from people you would trust.
- It is also exactly the dialog real malware needs you to click through. The reason to
  trust this one is not that you dismissed a warning — it is that the source is right here
  and you can build it yourself.

Two practical notes:

- The warning is attached to the **download**, not to the program. Windows marks anything
  that came from a browser and passes the mark along to copies. `install.ps1` strips that
  mark from the files it installs, which is why you usually will not see the dialog at all
  after running it. By hand, the equivalent is right-click → *Properties* → tick *Unblock*,
  or `Unblock-File .\mirrik-gui.exe` in PowerShell.
- If you build from source with `cargo build --release`, there is no mark and no warning —
  the files never came from the internet.

## Install — Linux

Requires **PipeWire** (with `pipewire-pulse`). Check with:

```sh
pactl info | grep 'Server Name'      # should mention PipeWire
```

There is a guided setup script. It installs the two binaries, adds a desktop entry, and
works out the exact key-binding line for your compositor — Hyprland, Sway and i3 by name,
with instructions for everything else. It shows you the lines before writing anything, and
leaves generated configs (Nix, Home Manager) alone.

```sh
./install.sh
```

<details>
<summary>Or do it by hand</summary>

```sh
cargo build --release --manifest-path code/mirrik/Cargo.toml

install -Dm755 code/mirrik/target/release/mirrik     ~/.local/bin/mirrik
install -Dm755 code/mirrik/target/release/mirrik-gui ~/.local/bin/mirrik-gui
```

Bind the window to a key in your compositor — this is the intended way to use it. Hyprland,
as an example:

```
bind = SUPER SHIFT, M, exec, mirrik-gui
```

Wayland compositors decide window placement themselves, so the window also wants a rule
that floats and centres it (Hyprland; before 0.49 these were called `windowrulev2`):

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

MIT. Do what you like with it.

The window is set in [Archivo](https://github.com/Omnibus-Type/Archivo) and
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), both under the SIL Open Font
Licence; the licences ship next to the fonts in `code/mirrik/gui/assets/`.
