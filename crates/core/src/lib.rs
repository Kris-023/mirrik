//! Platform-independent core.
//!
//! Everything that is identical on Linux and Windows lives here: the device model, the
//! state of a running mirror, and the contract a backend has to fulfil. Audio calls have
//! no business in this crate — the moment a `pactl` or an `IAudioClient` shows up here,
//! the separation is broken.
//!
//! One rule worth spelling out: **the core never hardcodes platform behaviour**. Whether
//! a volume slider affects the mirrored copy depends on where the driver applies gain,
//! which differs per device and per operating system. The backend answers that question
//! ([`MirrorBackend::volume_hint`]); the user interface only renders the answer.

use anyhow::Result;
use serde::{Deserialize, Serialize};

pub mod config;
pub mod instance;
pub mod state;

/// Read once, so the poll below does not look at the environment several times a second.
static TRACE_ON: std::sync::LazyLock<bool> =
    std::sync::LazyLock::new(|| std::env::var_os("MIRRIK_LOG").is_some());

/// One timestamped line on stderr, but only with `MIRRIK_LOG` set.
///
/// Deliberately not a logging crate: there is exactly one question this has to answer —
/// how long the step from "the device is back" to "the mirror runs again" takes, and
/// which part of it is slow. Silent by default, so nothing changes for anyone who does
/// not go looking. Redirect it where you want it: `MIRRIK_LOG=1 mirrik-gui 2>/tmp/m.log`.
///
/// The stamp is seconds since the epoch, not seconds since this process started: the
/// interesting number lives *between* two witnesses — this log and whatever is watching
/// the sound server from outside — and only a shared clock lets them be merged. Ugly to
/// read on its own, exact when sorted together with someone else's `date +%s.%N`.
pub fn trace(msg: impl std::fmt::Display) {
    if *TRACE_ON {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        eprintln!("{}.{:03} mirrik {msg}", now.as_secs(), now.subsec_millis());
    }
}

/// Stable identifier of an output device.
///
/// On Linux this is the PipeWire `node.name` (`alsa_output.…`), on Windows the endpoint
/// id of the `IMMDevice`. Both survive a reboot but are not human readable — that is what
/// [`Device::name`] is for.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeviceId(pub String);

impl std::fmt::Display for DeviceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// How a device is attached. Only interesting because it predicts latency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Transport {
    Analog,
    Usb,
    Hdmi,
    Bluetooth,
    Other,
}

impl Transport {
    /// Extra delay this transport adds on top of the tap itself, in milliseconds.
    ///
    /// Bluetooth A2DP buffers deeply and negotiates a codec; 150–250 ms is the usual
    /// range. The number is an estimate, not a measurement — it exists so the interface
    /// can warn instead of letting the user wonder why one listener is behind.
    pub fn extra_latency_ms(self) -> u32 {
        match self {
            Transport::Bluetooth => 200,
            _ => 0,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Transport::Analog => "analog",
            Transport::Usb => "USB",
            Transport::Hdmi => "HDMI",
            Transport::Bluetooth => "Bluetooth",
            Transport::Other => "other",
        }
    }
}

/// Where the volume control of a device is applied — and therefore whether it changes
/// what mirrored devices receive.
///
/// This is measured per device, not assumed. On the machine this tool was built on, the
/// analog output and the USB headphones apply volume in hardware (mirror unaffected)
/// while the HDMI output applies it in software (mirror follows). Same tool, same
/// operating system, opposite behaviour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VolumeScope {
    /// Applied in the device's hardware, behind the tap: affects only this device.
    DeviceOnly,
    /// Applied in software, before the tap: also changes every mirrored copy.
    AffectsMirror,
    /// Could not be determined.
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: DeviceId,
    /// Display name, e.g. "AirPods Max USB Audio Analog Stereo".
    pub name: String,
    pub is_default: bool,
    /// 1.0 = 100 %.
    pub volume: f32,
    pub volume_scope: VolumeScope,
    pub transport: Transport,
    /// Whether the system currently reports this device at all.
    ///
    /// A backend only ever lists devices that are there, so it always sets this to `true`.
    /// The interface uses it for the one case the backend cannot describe: a destination
    /// that is still being mirrored to while the device itself has gone away — headphones
    /// switched off, cable pulled. The mirror survives that and resumes by itself, so the
    /// destination must stay visible and switchable, but nothing about it may be presented
    /// as measured: no volume, no latency, no transport.
    #[serde(default = "yes")]
    pub present: bool,
}

fn yes() -> bool {
    true
}

/// Upper bound for the volume sliders.
///
/// 100 %, not more: devices that control volume in hardware are at their maximum here,
/// and anything above would be software gain applied to a signal the device already
/// outputs at full scale — a control range that can only clip.
pub const VOLUME_MAX: f32 = 1.0;

/// One mirrored destination and the process keeping it alive.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MirrorTarget {
    pub device: DeviceId,
    /// Human-readable name, written down when the destination was switched on.
    ///
    /// A device that is currently gone — headphones switched off, cable pulled — is no
    /// longer in the device list, so its name cannot be looked up any more. Without this,
    /// both interfaces fell back to printing the raw node id at exactly the moment the
    /// user most needs to recognise which device they are waiting for.
    ///
    /// `default` so a state file written by an older version still loads; an empty name
    /// means "unknown", and the id is the only thing left to show.
    #[serde(default)]
    pub name: String,
    /// Process holding this target. When it dies, this target disappears — that is the
    /// whole trick behind "off means gone".
    pub holder_pid: u32,
    /// What cleanup searches for, so a recycled PID cannot hit the wrong process.
    pub holder_pattern: String,
}

impl MirrorTarget {
    /// What to call this destination: its name, or the raw id if none was recorded.
    pub fn label(&self) -> &str {
        if self.name.is_empty() {
            &self.device.0
        } else {
            &self.name
        }
    }
}

/// A running mirror: one source, one or more destinations.
///
/// Stored in the state directory, deliberately not in the config directory: mirroring is
/// a state for the moment and is **not** restored after a reboot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Mirror {
    pub source: DeviceId,
    pub targets: Vec<MirrorTarget>,
}

impl Mirror {
    pub fn has_target(&self, d: &DeviceId) -> bool {
        self.targets.iter().any(|t| t.device == *d)
    }
}

/// What a backend promises about itself.
///
/// Exists so the interface cannot lie when platforms differ: a virtual-sink
/// implementation changes the default device and moves streams, a tap-based one does
/// neither.
#[derive(Debug, Clone, Copy)]
pub struct Capabilities {
    pub creates_virtual_device: bool,
    pub changes_default_device: bool,
    pub moves_streams: bool,
    /// Delay every mirrored device inherits from the tap itself, in milliseconds.
    /// Computed from the audio server's current buffer settings, never hardcoded.
    pub base_latency_ms: u32,
    /// 0 means "no fixed limit".
    pub max_targets: usize,
}

pub trait MirrorBackend {
    fn devices(&self) -> Result<Vec<Device>>;
    fn default_device(&self) -> Result<Device>;

    /// Adds one destination. Starting a mirror is just adding the first one.
    fn add_target(&mut self, target: &DeviceId) -> Result<()>;

    /// Removes one destination. Removing the last one ends the mirror.
    fn remove_target(&mut self, target: &DeviceId) -> Result<()>;

    /// Ends the mirror completely. Not mirroring is not an error.
    fn stop_all(&mut self) -> Result<()>;

    fn set_volume(&mut self, device: &DeviceId, value: f32) -> Result<()>;

    fn status(&self) -> Result<Option<Mirror>>;

    /// Brings the running mirror back in line with the devices that are actually there.
    ///
    /// Exists because this tool keeps nothing in the background: nobody notices a
    /// destination coming back, so the check happens whenever an interface runs anyway —
    /// on every command, and on every poll of the open window.
    ///
    /// The default does nothing, for backends where a destination cannot fall away
    /// without ending its holder.
    fn reconcile(&mut self) -> Result<()> {
        Ok(())
    }

    /// Clears leftovers of a crashed run.
    ///
    /// Deliberately part of the contract rather than a Linux detail: otherwise the safety
    /// net is missing from the next backend, and that is exactly where it will be noticed.
    fn cleanup_stale(&mut self) -> Result<()>;

    fn capabilities(&self) -> Result<Capabilities>;

    /// One short line explaining what this device's volume slider actually does.
    ///
    /// Lives in the backend on purpose. The honest answer depends on where the driver
    /// applies gain, which the core cannot know and the user interface must not guess.
    fn volume_hint(&self, device: &Device, mirroring: bool) -> String {
        match (device.volume_scope, mirroring) {
            (_, false) => "current output device".to_string(),
            (VolumeScope::DeviceOnly, true) => "this device only".to_string(),
            (VolumeScope::AffectsMirror, true) => "this device and every mirrored copy".to_string(),
            (VolumeScope::Unknown, true) => "effect on mirrored copies unknown".to_string(),
        }
    }

    /// Expected delay of a given destination relative to the source, in milliseconds.
    fn target_latency_ms(&self, device: &Device) -> Result<u32> {
        Ok(self.capabilities()?.base_latency_ms + device.transport.extra_latency_ms())
    }
}

/// Resolves a user-typed name: exact id first, then a unique case-insensitive substring.
///
/// Substring matching because ids carry serial numbers
/// (`…AirPods_Max_USB_Audio_XXXXXXXXXX-03…`) that nobody types.
pub fn find_device<'a>(devices: &'a [Device], input: &str) -> Result<&'a Device> {
    if let Some(d) = devices.iter().find(|d| d.id.0 == input) {
        return Ok(d);
    }

    let needle = input.to_lowercase();
    let hits: Vec<&Device> = devices
        .iter()
        .filter(|d| {
            d.name.to_lowercase().contains(&needle) || d.id.0.to_lowercase().contains(&needle)
        })
        .collect();

    let list = |ds: &[&Device]| {
        ds.iter()
            .map(|d| format!("  {}  ({})", d.name, d.id))
            .collect::<Vec<_>>()
            .join("\n")
    };

    match hits.len() {
        1 => Ok(hits[0]),
        0 => anyhow::bail!(
            "no output device matches \"{input}\". Available:\n{}",
            list(&devices.iter().collect::<Vec<_>>())
        ),
        // Guessing would be the real mistake here.
        _ => anyhow::bail!("\"{input}\" is ambiguous, it matches:\n{}", list(&hits)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(id: &str, name: &str, default: bool) -> Device {
        Device {
            id: DeviceId(id.into()),
            name: name.into(),
            is_default: default,
            volume: 0.8,
            volume_scope: VolumeScope::DeviceOnly,
            transport: Transport::Other,
            present: true,
        }
    }

    fn sample() -> Vec<Device> {
        vec![
            dev(
                "alsa_output.pci-0000_75_00.6.analog-stereo",
                "Ryzen HD Audio Controller Analog Stereo",
                true,
            ),
            dev(
                "alsa_output.usb-Apple_Inc._AirPods_Max_USB_Audio_XXXXXXXXXX-03.analog-stereo",
                "AirPods Max USB Audio Analog Stereo",
                false,
            ),
            dev(
                "alsa_output.pci-0000_01_00.1.hdmi-stereo",
                "AD103 High Definition Audio Controller Digital Stereo (HDMI)",
                false,
            ),
        ]
    }

    #[test]
    fn a_destination_keeps_its_name_when_the_device_is_gone() {
        let t = MirrorTarget {
            device: DeviceId("bluez_output.00_11_22_33_44_55.1".into()),
            name: "WH-1000XM3".into(),
            holder_pid: 1,
            holder_pattern: "mirrik.out.dead".into(),
        };
        assert_eq!(t.label(), "WH-1000XM3");
    }

    #[test]
    fn a_state_file_from_an_older_version_still_loads() {
        // Written before destinations recorded their name, and before devices carried a
        // presence flag. Both have to keep working: the fallback is the raw id, and
        // anything a backend lists is present by definition.
        let old = r#"{"source":"analog","targets":[
            {"device":"hdmi","holder_pid":7,"holder_pattern":"mirrik.out.abc"}]}"#;
        let m: Mirror = serde_json::from_str(old).expect("old state file must still parse");
        assert_eq!(m.targets[0].name, "");
        assert_eq!(m.targets[0].label(), "hdmi");

        let old_device = r#"{"id":"hdmi","name":"HDMI","is_default":false,"volume":1.0,
            "volume_scope":"DeviceOnly","transport":"Hdmi"}"#;
        let d: Device = serde_json::from_str(old_device).expect("old device must still parse");
        assert!(d.present, "a device without the flag counts as present");
    }

    #[test]
    fn finds_by_substring() {
        let d = sample();
        assert!(find_device(&d, "airpods").unwrap().id.0.contains("AirPods"));
    }

    #[test]
    fn finds_by_exact_id() {
        let d = sample();
        assert!(find_device(&d, "alsa_output.pci-0000_01_00.1.hdmi-stereo")
            .unwrap()
            .name
            .contains("HDMI"));
    }

    #[test]
    fn reports_ambiguity_instead_of_guessing() {
        // "stereo" is in all three names.
        assert!(find_device(&sample(), "stereo").is_err());
    }

    #[test]
    fn reports_when_nothing_matches() {
        assert!(find_device(&sample(), "bluetooth").is_err());
    }

    #[test]
    fn bluetooth_is_the_only_transport_with_extra_latency() {
        assert_eq!(Transport::Bluetooth.extra_latency_ms(), 200);
        for t in [
            Transport::Analog,
            Transport::Usb,
            Transport::Hdmi,
            Transport::Other,
        ] {
            assert_eq!(t.extra_latency_ms(), 0);
        }
    }

    #[test]
    fn mirror_knows_its_targets() {
        let m = Mirror {
            source: DeviceId("a".into()),
            targets: vec![MirrorTarget {
                device: DeviceId("b".into()),
                name: "B".into(),
                holder_pid: 1,
                holder_pattern: "x".into(),
            }],
        };
        assert!(m.has_target(&DeviceId("b".into())));
        assert!(!m.has_target(&DeviceId("c".into())));
    }
}
