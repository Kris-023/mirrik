# mirrik

**Play the same sound on two or more output devices at once — on Windows and Linux.**

Your speakers *and* your headphones. Your headset *and* your partner's. Without a virtual
cable, without a driver install, and without leaving anything behind when you switch it off.

![The control window with two destinations active](screenshots/gui-zwei-ziele.png)

---

## What problem this solves

Neither Windows nor Linux lets you send audio to two outputs at the same time. You pick one
device, and everything else stays silent. The usual workarounds — virtual audio cables,
Voicemeeter, `combine-sink` — all create a fake device you then have to select, keep around,
and remember to undo.

This tool takes the other route. It listens to whatever your current output is already
playing and copies that stream to the devices you choose. **No virtual device is ever
created**, your default output is never touched, and running programs notice nothing. When
you turn it off, there is nothing left to clean up.

Useful when you want to *watch a film together on two headsets*, *keep speakers and
headphones live at the same time*, *share game audio with someone next to you*, or *send
sound to a second room over HDMI*.

<sub>Keywords: play audio on two devices at once · dual audio output · mirror sound to
multiple outputs · Windows WASAPI loopback · Linux PipeWire loopback · share audio with two
headphones · simultaneous playback · second audio output · no virtual audio cable ·
alternative to Voicemeeter / VB-CABLE / Audio Router</sub>

## Compatibility

| | Supported | Notes |
|---|---|---|
| **Windows 11 / 10** | yes | Uses WASAPI loopback. Nothing to install, no driver, no admin rights |
| **Linux (PipeWire)** | yes | Uses `module-loopback`. PipeWire is required — see below |
| **Linux (PulseAudio only)** | no | The tool refuses and says why. On plain PulseAudio a crash would leave a loopback behind for good |
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
- **Keyboard-driven window**, plus a scriptable command line with `--json` on everything.

## Install — Windows

1. Download the latest release and unzip it somewhere you will find it again, for example
   `C:\Programs\mirrik`.
2. **Double-click `mirrik-gui.exe`.** That is the window with the device list — it is
   the one you want.
3. Nothing else. No installer, no driver, no administrator rights.

> `mirrik.exe` (without `-gui`) is the command line version, meant to be typed rather
> than clicked — see [Usage](#usage). Double-clicking it opens the window as well, so
> picking the wrong file is not a problem.

**Optional — open it with a keyboard shortcut:** right-click `mirrik-gui.exe` →
*Show more options* → *Create shortcut*, then right-click the new shortcut → *Properties* →
click the *Shortcut key* field and press your combination. Windows only allows
`Ctrl+Alt+<key>` here, and it starts the program fresh each time rather than raising an
already-open window.

## Install — Linux

Requires **PipeWire** (`pipewire-pulse` included) and Rust if you build it yourself.

```sh
git clone <repository-url>
cd mirrik/code/mirrik
cargo build --release

# put both binaries somewhere on your PATH
install -Dm755 target/release/mirrik     ~/.local/bin/mirrik
install -Dm755 target/release/mirrik-gui ~/.local/bin/mirrik-gui
```

Check that PipeWire is actually the server in use:

```sh
pactl info | grep 'Server Name'      # should mention PipeWire
```

**Bind the window to a key** in your compositor or desktop settings — this is the intended
way to use it. Hyprland, as an example:

```
bind = SUPER SHIFT, A, exec, mirrik-gui
```

Wayland compositors decide window placement themselves. A rule like this one centres it and
keeps it floating (Hyprland):

```
windowrulev2 = float, class:^(mirrik)$
windowrulev2 = center, class:^(mirrik)$
```

## Usage

### The window

Open it, and it tells you the current state first: whether something is being mirrored and
where to. Below that is one volume slider per active device, and below that the list of
devices you can add.

| Key | Does |
|---|---|
| `↓` `↑` or `j` `k` | move the focus (sliders and devices are one chain) |
| `→` `←` or `l` `h` | adjust the focused volume slider in 5 % steps |
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
If it matches several devices, the tool says so instead of guessing.

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

**Volume behaves per device.** Sliders are applied after the point where the copy is taken,
so each device's level is its own. Turning your speakers down does not quieten the
headphones.

**Nothing is remembered.** After a reboot, sound plays to one device again. Mirroring is a
deliberate act for the moment someone is listening along, not a state to restore.

**Delay.** A mirrored device runs slightly behind the original — around 30 ms on Windows,
42 ms on Linux. In practice this is not noticeable unless two devices are in the same room
and you listen for it. Bluetooth is a different matter: its own buffering adds roughly
200 ms, which *is* audible, so those destinations are marked in the interface.

**Over a long session** the two devices' clocks drift apart by a tiny amount. The tool
absorbs this continuously; you may hear an occasional faint tick after hours of use.

## Licence

MIT. Do what you like with it.
