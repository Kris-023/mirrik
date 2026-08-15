//! Linux backend: monitor tap via `libpipewire-module-loopback`.
//!
//! The default sink stays the default, **no** virtual device is created, and running
//! applications notice nothing — audio is tapped from the monitor of the active output
//! and additionally played on each destination.
//!
//! Process model: one `pw-cli -m` per destination holds one loopback module. When the
//! process ends, that destination disappears. "Off means gone" is therefore not a
//! promise, it is the construction.
//!
//! # Why PipeWire only
//!
//! PulseAudio has `module-loopback` too, but its modules belong to the daemon, not to the
//! client that loaded them. A crashed tool would leave a permanent loopback behind — the
//! one thing this design exists to avoid. Refusing loudly beats shipping a second, worse
//! code path that cannot keep the core promise.
//!
//! # Reading state
//!
//! Device data comes from `pw-dump` (JSON), never from parsing `pactl list` output: that
//! output is localised (`Description:` vs `Beschreibung:`) and would break the tool on
//! every non-English system. `pactl` is used only for *setting* values, where the locale
//! plays no role.

use anyhow::{bail, Context, Result};
use mirrik_core::{
    state, Capabilities, Device, DeviceId, Mirror, MirrorBackend, MirrorTarget, Transport,
    VolumeScope, VOLUME_MAX,
};
use std::process::{Command, Stdio};

/// Prefix of the playback node name; the cleanup anchor.
///
/// A PID alone is not enough — it may long since have been reused. Only pattern **and**
/// PID together identify a holder process.
const HOLDER_PREFIX: &str = "mirrik.out.";

pub struct PipeWireBackend {
    /// Buffer size and sample rate of the audio server, read once at construction.
    quantum: u32,
    rate: u32,
    /// Holder processes started by *this* process, kept so they can be reaped.
    ///
    /// Without this a long-lived process — the GUI — collects a zombie for every
    /// destination it ever switched off: the child is dead but its `/proc` entry stays
    /// until someone waits on it.
    children: Vec<std::process::Child>,
}

impl PipeWireBackend {
    /// Fails on anything that is not PipeWire, and on a missing `pactl`.
    pub fn new() -> Result<Self> {
        which("pw-cli")?;
        which("pw-dump")?;
        which("pactl")?;

        // pw-metadata only exists on PipeWire and is the cheapest positive proof.
        let meta = run("pw-metadata", &["-n", "settings"]).context(
            "PipeWire not reachable. Mirrik requires PipeWire — on plain PulseAudio a \
             loopback module belongs to the daemon and would survive a crash of this tool, \
             which breaks its core promise that switching off leaves no trace.",
        )?;

        let get = |key: &str| -> Option<u32> {
            meta.lines()
                .find(|l| l.contains(&format!("key:'{key}'")))
                .and_then(|l| l.split("value:'").nth(1))
                .and_then(|r| r.split('\'').next())
                .and_then(|v| v.parse().ok())
        };

        // force-* wins when set; that is how Project 26 nails the quantum to 1024.
        let quantum = get("clock.force-quantum")
            .filter(|q| *q > 0)
            .or_else(|| get("clock.quantum"))
            .unwrap_or(1024);
        let rate = get("clock.force-rate")
            .filter(|r| *r > 0)
            .or_else(|| get("clock.rate"))
            .unwrap_or(48000);

        Ok(Self {
            quantum,
            rate,
            children: Vec::new(),
        })
    }

    /// Collects finished holder processes so they do not linger as zombies.
    fn reap(&mut self) {
        self.children
            .retain_mut(|c| !matches!(c.try_wait(), Ok(Some(_))));
    }

    fn holder_name(&self, target: &DeviceId) -> String {
        // Node names may not contain arbitrary characters; a stable digest of the id
        // keeps it short and unique enough for matching in /proc.
        let mut h: u64 = 1469598103934665603;
        for b in target.0.as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(1099511628211);
        }
        format!("{HOLDER_PREFIX}{h:x}")
    }
}

fn which(prog: &str) -> Result<()> {
    Command::new(prog)
        .arg("--help")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .with_context(|| format!("`{prog}` not found — it ships with PipeWire"))?;
    Ok(())
}

fn run(prog: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(prog)
        .args(args)
        // Defensive even though nothing here parses prose: never let the user's locale
        // decide whether the tool works.
        .env("LC_ALL", "C")
        .output()
        .with_context(|| format!("cannot run `{prog}`"))?;
    if !out.status.success() {
        bail!(
            "`{prog} {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Reads `/proc/<pid>/cmdline` and checks whether it really is one of our holders.
fn is_holder(pid: u32, pattern: &str) -> bool {
    let Ok(raw) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
        return false;
    };
    let line = String::from_utf8_lossy(&raw).replace('\0', " ");
    line.contains("pw-cli") && line.contains(pattern)
}

fn signal(pid: u32, sig: &str) -> Result<()> {
    Command::new("kill")
        .arg(sig)
        .arg(pid.to_string())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .with_context(|| format!("cannot run kill {sig} {pid}"))?;
    Ok(())
}

/// Waits until `pid` is no longer a live holder.
///
/// Deliberately **not** `!/proc/<pid>.exists()`: a child that has been killed but not yet
/// waited on stays in `/proc` as a zombie, and its directory would never disappear while
/// its parent lives. A zombie has an empty `cmdline`, so the holder check reports it as
/// gone — which it is, as far as audio is concerned. Getting this wrong produced two
/// misleading errors in a row ("does not react to SIGTERM", later "survived SIGKILL").
fn wait_gone(pid: u32, pattern: &str, ms: u64) -> bool {
    for _ in 0..(ms / 40) {
        if !is_holder(pid, pattern) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(40));
    }
    !is_holder(pid, pattern)
}

/// Ends a holder — politely first, firmly after.
///
/// `pw-cli -m` does not always react to SIGTERM: depending on its event loop it never
/// reaches the signal handler, which used to leave a mirror that could not be switched
/// off. SIGKILL is provably safe here — PipeWire unloads the module together with the
/// client connection, leaving neither sink nor link behind.
fn kill_holder(pid: u32, pattern: &str) -> Result<()> {
    signal(pid, "-TERM")?;
    if wait_gone(pid, pattern, 1200) {
        return Ok(());
    }
    signal(pid, "-KILL")?;
    if wait_gone(pid, pattern, 1200) {
        return Ok(());
    }
    bail!("holder process {pid} could not be stopped")
}

/// All PIDs that look like one of our holders.
fn all_holders() -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()))
        .filter(|pid| is_holder(*pid, HOLDER_PREFIX))
        .collect()
}

fn transport_of(node_name: &str, props: &serde_json::Value) -> Transport {
    let api = props
        .get("device.api")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if api == "bluez5" || node_name.starts_with("bluez_output") {
        return Transport::Bluetooth;
    }
    if node_name.contains("hdmi") || node_name.contains("displayport") {
        return Transport::Hdmi;
    }
    if node_name.contains(".usb-") {
        return Transport::Usb;
    }
    if node_name.contains("analog") {
        return Transport::Analog;
    }
    Transport::Other
}

/// Decides where a device applies its volume.
///
/// PipeWire reports both the requested gain (`channelVolumes`) and the part it applies
/// itself (`softVolumes`). If the software part is 1.0 while the requested gain is not,
/// the hardware is doing the work — and the tap, which sits before the hardware, never
/// sees it. Measured on the build machine: analog and USB headphones are hardware,
/// HDMI is software. Same tool, same OS, opposite behaviour — which is exactly why this
/// is detected rather than assumed.
fn volume_scope_of(channel: &[f64], soft: &[f64]) -> VolumeScope {
    if channel.is_empty() || soft.is_empty() {
        return VolumeScope::Unknown;
    }
    let requested = channel[0];
    let in_software = soft[0];
    // Both ends of the range are degenerate: at full volume every reading is 1.0, at zero
    // every reading is 0.0. Neither says where the gain is applied, so neither may be
    // turned into a claim in the user interface.
    if (requested - 1.0).abs() < 1e-6 || requested < 1e-3 {
        return VolumeScope::Unknown;
    }
    if (in_software - 1.0).abs() < 1e-3 {
        VolumeScope::DeviceOnly
    } else if (in_software - requested).abs() < 1e-3 {
        VolumeScope::AffectsMirror
    } else {
        // Hardware takes coarse steps, PipeWire applies the remainder in software.
        // Predominantly hardware, so the mirror is affected only marginally.
        VolumeScope::DeviceOnly
    }
}

impl MirrorBackend for PipeWireBackend {
    fn devices(&self) -> Result<Vec<Device>> {
        let default = run("pactl", &["get-default-sink"])?.trim().to_string();
        let dump: serde_json::Value = serde_json::from_str(&run("pw-dump", &[])?)
            .context("pw-dump did not return valid JSON")?;

        let mut devices = Vec::new();
        for obj in dump.as_array().into_iter().flatten() {
            let info = &obj["info"];
            let props = &info["props"];
            if props["media.class"].as_str() != Some("Audio/Sink") {
                continue;
            }
            let Some(name) = props["node.name"].as_str() else {
                continue;
            };
            // Our own loopback playback nodes are streams, not sinks, so they cannot show
            // up here — but a defensive skip costs nothing.
            if name.starts_with(HOLDER_PREFIX) {
                continue;
            }

            let numbers = |key: &str| -> Vec<f64> {
                info["params"]["Props"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find_map(|p| p.get(key).and_then(|v| v.as_array()))
                    .map(|a| a.iter().filter_map(|v| v.as_f64()).collect())
                    .unwrap_or_default()
            };
            let channel = numbers("channelVolumes");
            let soft = numbers("softVolumes");

            // PipeWire stores linear gain; the percentage every mixer shows is its cube
            // root. Matching that keeps our numbers identical to the rest of the system.
            let volume = channel.first().map_or(1.0, |v| v.cbrt() as f32);

            devices.push(Device {
                is_default: name == default,
                id: DeviceId(name.to_string()),
                name: props["node.description"]
                    .as_str()
                    .unwrap_or(name)
                    .to_string(),
                volume,
                volume_scope: volume_scope_of(&channel, &soft),
                transport: transport_of(name, props),
            });
        }

        if devices.is_empty() {
            bail!("PipeWire reports no output device at all");
        }
        Ok(devices)
    }

    fn default_device(&self) -> Result<Device> {
        self.devices()?
            .into_iter()
            .find(|d| d.is_default)
            .context("no default output device is set")
    }

    fn add_target(&mut self, target: &DeviceId) -> Result<()> {
        let devices = self.devices()?;
        if !devices.iter().any(|d| d.id == *target) {
            bail!("target device {target} does not exist (any more)");
        }

        let source = self.default_device()?;
        if source.id == *target {
            bail!("source and target are the same device ({target}) — that is a loop");
        }

        let mut mirror = self.status()?.unwrap_or(Mirror {
            source: source.id.clone(),
            targets: Vec::new(),
        });
        if mirror.has_target(target) {
            return Ok(()); // already mirrored there; adding twice is a no-op, not an error
        }
        // The source is fixed by the first target: mirroring from two different sources at
        // once would be a different feature with different failure modes.
        if mirror.source != source.id && !mirror.targets.is_empty() {
            bail!(
                "mirror is running from {}, but the default device is now {} — stop it first",
                mirror.source,
                source.id
            );
        }

        let node = self.holder_name(target);

        // Two properties decide between working and silence here, both paid for with a
        // failed attempt:
        //   target.object — NOT node.target (superseded in PipeWire 0.3.64; combined with
        //                   node.dont-reconnect the stream silently never connects)
        //   node.passive  — capture side only. On the playback side it stops a suspended
        //                   target device from ever waking up, so no sound at all.
        // No media.class on either side: that keeps both ends streams, so no sink appears.
        let args = format!(
            r#"{{
    node.description = "Mirrik"
    capture.props = {{
        stream.capture.sink = true
        target.object = "{source}"
        node.passive  = true
        node.name     = {node}.in
    }}
    playback.props = {{
        target.object = "{target}"
        node.name     = {node}
    }}
}}"#,
            source = mirror.source,
        );

        let child = Command::new("pw-cli")
            .arg("-m")
            .arg("load-module")
            .arg("libpipewire-module-loopback")
            .arg(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("cannot start pw-cli — it ships with PipeWire")?;

        let pid = child.id();

        // pw-cli connects asynchronously. Only surviving that means the target is really
        // there; dying immediately means the arguments were wrong.
        std::thread::sleep(std::time::Duration::from_millis(600));
        if !is_holder(pid, &node) {
            bail!("pw-cli exited immediately — the loopback module could not be loaded");
        }

        self.children.push(child);
        self.reap();

        mirror.targets.push(MirrorTarget {
            device: target.clone(),
            holder_pid: pid,
            holder_pattern: node,
        });
        state::save(&mirror)
    }

    fn remove_target(&mut self, target: &DeviceId) -> Result<()> {
        let Some(mut mirror) = self.status()? else {
            return Ok(());
        };
        let Some(i) = mirror.targets.iter().position(|t| t.device == *target) else {
            return Ok(());
        };
        let t = mirror.targets.remove(i);
        if is_holder(t.holder_pid, &t.holder_pattern) {
            kill_holder(t.holder_pid, &t.holder_pattern)?;
        }
        self.reap();
        if mirror.targets.is_empty() {
            state::clear()
        } else {
            state::save(&mirror)
        }
    }

    fn stop_all(&mut self) -> Result<()> {
        if let Some(mirror) = self.status()? {
            for t in &mirror.targets {
                if is_holder(t.holder_pid, &t.holder_pattern) {
                    kill_holder(t.holder_pid, &t.holder_pattern)?;
                }
            }
        }
        // Holders can also exist without state (crash before the file was written).
        for pid in all_holders() {
            kill_holder(pid, HOLDER_PREFIX)?;
        }
        self.reap();
        state::clear()
    }

    fn set_volume(&mut self, device: &DeviceId, value: f32) -> Result<()> {
        let percent = (value.clamp(0.0, VOLUME_MAX) * 100.0).round() as u32;
        run(
            "pactl",
            &["set-sink-volume", &device.0, &format!("{percent}%")],
        )?;
        Ok(())
    }

    fn status(&self) -> Result<Option<Mirror>> {
        let Some(mut mirror) = state::load()? else {
            return Ok(None);
        };
        let before = mirror.targets.len();
        mirror
            .targets
            .retain(|t| is_holder(t.holder_pid, &t.holder_pattern));

        if mirror.targets.is_empty() {
            state::clear()?;
            return Ok(None);
        }
        if mirror.targets.len() != before {
            state::save(&mirror)?;
        }
        Ok(Some(mirror))
    }

    fn cleanup_stale(&mut self) -> Result<()> {
        // status() already prunes dead entries; what remains are holders nobody knows about.
        let known: Vec<u32> = self
            .status()?
            .map(|m| m.targets.iter().map(|t| t.holder_pid).collect())
            .unwrap_or_default();
        for pid in all_holders() {
            if !known.contains(&pid) {
                kill_holder(pid, HOLDER_PREFIX)?;
            }
        }
        self.reap();
        Ok(())
    }

    fn capabilities(&self) -> Result<Capabilities> {
        Ok(Capabilities {
            creates_virtual_device: false,
            changes_default_device: false,
            moves_streams: false,
            // Capture and playback each run one graph cycle behind, so two quanta.
            // Computed, never hardcoded: at quantum 256 this is 10 ms, at 1024 it is 43.
            base_latency_ms: (2000 * self.quantum / self.rate.max(1)).max(1),
            max_targets: 0,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_hardware_volume_as_device_only() {
        // AirPods at 88 %: requested 0.681, nothing applied in software.
        assert_eq!(volume_scope_of(&[0.681], &[1.0]), VolumeScope::DeviceOnly);
    }

    #[test]
    fn detects_software_volume_as_affecting_the_mirror() {
        // HDMI: both readings identical means PipeWire does all the work.
        assert_eq!(
            volume_scope_of(&[0.754], &[0.754]),
            VolumeScope::AffectsMirror
        );
    }

    #[test]
    fn coarse_hardware_steps_still_count_as_device_only() {
        // Analog at 70 %: hardware takes most of it, 0.967 remains in software.
        assert_eq!(volume_scope_of(&[0.343], &[0.967]), VolumeScope::DeviceOnly);
    }

    #[test]
    fn full_volume_carries_no_information() {
        assert_eq!(volume_scope_of(&[1.0], &[1.0]), VolumeScope::Unknown);
    }

    #[test]
    fn zero_volume_carries_no_information() {
        // A muted device reads 0.0 on both counters; claiming "software" there would
        // mislabel a hardware device that simply happens to be turned down.
        assert_eq!(volume_scope_of(&[0.0], &[0.0]), VolumeScope::Unknown);
    }

    #[test]
    fn recognises_transports() {
        let none = serde_json::json!({});
        assert_eq!(
            transport_of("bluez_output.AA_BB.a2dp-sink", &none),
            Transport::Bluetooth
        );
        assert_eq!(
            transport_of("x", &serde_json::json!({"device.api": "bluez5"})),
            Transport::Bluetooth
        );
        assert_eq!(
            transport_of("alsa_output.pci-0000_01_00.1.hdmi-stereo", &none),
            Transport::Hdmi
        );
        assert_eq!(
            transport_of("alsa_output.usb-Apple_Inc._AirPods.analog-stereo", &none),
            Transport::Usb
        );
        assert_eq!(
            transport_of("alsa_output.pci-0000_75_00.6.analog-stereo", &none),
            Transport::Analog
        );
    }

    #[test]
    fn our_own_process_is_not_a_holder() {
        assert!(!is_holder(std::process::id(), HOLDER_PREFIX));
    }
}
