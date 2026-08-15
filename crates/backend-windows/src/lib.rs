//! WASAPI backend.
//!
//! Stage 1: enumerate, describe and control the volume of output devices. Mirroring
//! itself is not here yet — planned separately.
//!
//! Why this order: on Linux the backend was built on top of `pactl` first and only then
//! moved to a native binding, so that a bug was obviously in the tool and not in the
//! binding. The same reasoning applies here — get the device model right against real
//! hardware before an audio engine starts pushing samples through it.

pub mod mirror;

use anyhow::{anyhow, bail, Context, Result};
use mirrik_core::{
    state, Capabilities, Device, DeviceId, Mirror, MirrorBackend, MirrorTarget, Transport,
    VolumeScope,
};
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use windows::core::{GUID, PCWSTR};
use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
use windows::Win32::Foundation::PROPERTYKEY;
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioClient, IMMDevice, IMMDeviceEnumerator, MMDeviceEnumerator,
    DEVICE_STATE_ACTIVE,
};
use windows::Win32::System::Com::StructuredStorage::{
    PropVariantToStringAlloc, PropVariantToUInt32,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, TerminateProcess, PROCESS_NAME_FORMAT,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};

/// Which bus the device hangs off ("USB", "HDAUDIO", "BTHENUM", …).
///
/// Not exported by the windows crate, so spelled out here. This is what tells a USB
/// headset apart from an analog jack — the endpoint id does not carry that information.
const PKEY_DEVICE_ENUMERATOR_NAME: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
    pid: 24,
};

/// Speakers / headphones / HDMI display / … as an `EndpointFormFactor` value.
const PKEY_AUDIOENDPOINT_FORM_FACTOR: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0x1da5d803_d492_4edd_8c23_e0c0ffee7f0e),
    pid: 0,
};

/// `EndpointFormFactor::DigitalAudioDisplayDevice` — an HDMI or DisplayPort sink.
const FORM_FACTOR_DIGITAL_DISPLAY: u32 = 9;

pub struct WasapiBackend {
    enumerator: IMMDeviceEnumerator,
}

impl WasapiBackend {
    pub fn new() -> Result<Self> {
        unsafe {
            // A second call from the same thread returns RPC_E_CHANGED_MODE or S_FALSE.
            // Neither matters here: COM is already up and the apartment we would have
            // asked for is compatible with what this backend does.
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                    .context("cannot create the WASAPI device enumerator")?;

            Ok(Self { enumerator })
        }
    }

    fn default_id(&self) -> Result<String> {
        unsafe {
            let d = self
                .enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .context("no default output device")?;
            device_id(&d)
        }
    }

    fn find(&self, id: &DeviceId) -> Result<IMMDevice> {
        unsafe {
            let wide: Vec<u16> = id.0.encode_utf16().chain(std::iter::once(0)).collect();
            self.enumerator
                .GetDevice(PCWSTR(wide.as_ptr()))
                .with_context(|| format!("no such output device: {}", id.0))
        }
    }

    unsafe fn describe(&self, d: &IMMDevice, default_id: &str) -> Result<Device> {
        let id = device_id(d)?;
        let name = prop_string(d, &PKEY_Device_FriendlyName)
            .unwrap_or_else(|| "unnamed output device".to_string());

        // A device without a volume control is unusual but not an error — report full
        // scale rather than refusing to list it.
        let volume = endpoint_volume(d)
            .and_then(|v| v.GetMasterVolumeLevelScalar().context("volume unreadable"))
            .unwrap_or(1.0);

        Ok(Device {
            is_default: id == default_id,
            id: DeviceId(id),
            name,
            volume,
            // Measured 2026-08-15 with real hardware: a mirrored AirPods Max keeps its
            // own level, unaffected by the source device's slider — the same answer
            // Linux gives, and the opposite of what was expected here.
            //
            // It also follows from the signal chain rather than from the device: the
            // endpoint volume is applied *after* the render client that feeds it, so a
            // slider can only ever move its own device. Where the driver puts the gain
            // (chip or software) changes nothing about that ordering.
            volume_scope: VolumeScope::DeviceOnly,
            transport: transport_of(d),
        })
    }

    /// Sample rate, bit depth and channel count the engine currently runs a device at.
    ///
    /// Stage 2 needs this to decide whether a captured stream can be handed to a target
    /// unchanged. On the machine this was written for the answer is no: the analog output
    /// sits at 192 kHz while everything else runs at 48 kHz.
    pub fn mix_format(&self, device: &DeviceId) -> Result<(u32, u16, u16)> {
        unsafe {
            let d = self.find(device)?;
            let client: IAudioClient = d
                .Activate(CLSCTX_ALL, None)
                .context("cannot open the audio client")?;
            let fmt = client
                .GetMixFormat()
                .context("cannot read the mix format")?;
            let f = fmt.as_ref().ok_or_else(|| anyhow!("empty mix format"))?;
            let out = (f.nSamplesPerSec, f.wBitsPerSample, f.nChannels);
            CoTaskMemFree(Some(fmt as *const _));
            Ok(out)
        }
    }
}

/// Endpoint id, e.g. `{0.0.0.00000000}.{683c55a5-…}`. Survives reboots, which is why
/// [`DeviceId`] is built from it rather than from the display name.
unsafe fn device_id(d: &IMMDevice) -> Result<String> {
    let raw = d.GetId().context("cannot read the device id")?;
    let s = raw.to_string().context("device id is not valid UTF-16")?;
    CoTaskMemFree(Some(raw.0 as *const _));
    Ok(s)
}

unsafe fn prop_string(d: &IMMDevice, key: &PROPERTYKEY) -> Option<String> {
    let store = d.OpenPropertyStore(STGM_READ).ok()?;
    let value = store.GetValue(key).ok()?;
    let raw = PropVariantToStringAlloc(&value).ok()?;
    let s = raw.to_string().ok();
    CoTaskMemFree(Some(raw.0 as *const _));
    s
}

unsafe fn prop_u32(d: &IMMDevice, key: &PROPERTYKEY) -> Option<u32> {
    let store = d.OpenPropertyStore(STGM_READ).ok()?;
    let value = store.GetValue(key).ok()?;
    PropVariantToUInt32(&value).ok()
}

/// Bus and form factor together decide the transport — one alone is not enough.
/// An HDMI sink sits on the HDAUDIO bus just like the analog jack does, and only the
/// form factor separates them.
unsafe fn transport_of(d: &IMMDevice) -> Transport {
    if prop_u32(d, &PKEY_AUDIOENDPOINT_FORM_FACTOR) == Some(FORM_FACTOR_DIGITAL_DISPLAY) {
        return Transport::Hdmi;
    }
    match prop_string(d, &PKEY_DEVICE_ENUMERATOR_NAME).as_deref() {
        Some("USB") => Transport::Usb,
        Some("BTHENUM") | Some("BTHHFENUM") | Some("BTHLEENUM") => Transport::Bluetooth,
        Some("HDAUDIO") => Transport::Analog,
        _ => Transport::Other,
    }
}

unsafe fn endpoint_volume(d: &IMMDevice) -> Result<IAudioEndpointVolume> {
    d.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
        .context("device does not expose a volume control")
}

/// Start the holder without a console window of its own.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The executable that holds a mirror open — always the command line tool.
///
/// Not `current_exe()`: started from the graphical front-end that would be the window
/// binary, which has no `hold` command. It would open a second window, sit there looking
/// alive, and the mirror would report success while playing nothing at all.
pub fn holder_exe() -> Result<std::path::PathBuf> {
    const CLI: &str = "mirrik.exe";

    let me = std::env::current_exe().context("cannot locate own executable")?;
    if me
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.eq_ignore_ascii_case(CLI))
    {
        return Ok(me);
    }

    let cli = me.with_file_name(CLI);
    if cli.is_file() {
        Ok(cli)
    } else {
        bail!(
            "{CLI} is missing next to {} - it is what keeps a mirror alive",
            me.display()
        )
    }
}

/// Full path of the executable behind a pid, if it can still be read.
///
/// This is what makes [`MirrorTarget::holder_pattern`] worth storing: Windows recycles
/// pids, and terminating a stranger that happens to have inherited one would be a far
/// worse bug than leaving a stale entry behind.
fn holder_image(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 260];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            windows::core::PWSTR(buf.as_mut_ptr()),
            &mut len,
        );
        let _ = windows::Win32::Foundation::CloseHandle(handle);
        ok.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// True only if the pid is still running *our* holder, not just any live process.
pub fn holder_alive(t: &MirrorTarget) -> bool {
    match holder_image(t.holder_pid) {
        Some(path) => path.eq_ignore_ascii_case(&t.holder_pattern),
        None => false,
    }
}

/// Ends one holder. Killing it outright is not brutality but the contract: on Linux the
/// module dies with its process even under `kill -9`, and Windows tears down the audio
/// clients of a dead process just the same.
fn stop_holder(t: &MirrorTarget) {
    if !holder_alive(t) {
        return;
    }
    unsafe {
        if let Ok(handle) = OpenProcess(PROCESS_TERMINATE, false, t.holder_pid) {
            let _ = TerminateProcess(handle, 0);
            let _ = windows::Win32::Foundation::CloseHandle(handle);
        }
    }
}

impl MirrorBackend for WasapiBackend {
    fn devices(&self) -> Result<Vec<Device>> {
        unsafe {
            let default_id = self.default_id().unwrap_or_default();
            let collection = self
                .enumerator
                .EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
                .context("cannot enumerate output devices")?;

            let count = collection
                .GetCount()
                .context("cannot count output devices")?;
            let mut out = Vec::with_capacity(count as usize);
            for i in 0..count {
                let d = collection.Item(i)?;
                out.push(self.describe(&d, &default_id)?);
            }
            Ok(out)
        }
    }

    fn default_device(&self) -> Result<Device> {
        unsafe {
            let d = self
                .enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .context("no default output device")?;
            let id = device_id(&d)?;
            self.describe(&d, &id)
        }
    }

    fn add_target(&mut self, target: &DeviceId) -> Result<()> {
        // Fail before spawning anything if the device is gone.
        self.find(target)?;

        let source = DeviceId(self.default_id()?);
        if *target == source {
            bail!("that device is already the output everything plays to");
        }

        let mut m = match state::load()? {
            // A mirror whose source is no longer the default describes a world that
            // ended; start over rather than mixing two sources.
            Some(m) if m.source == source => m,
            Some(m) => {
                for t in &m.targets {
                    stop_holder(t);
                }
                Mirror {
                    source: source.clone(),
                    targets: Vec::new(),
                }
            }
            None => Mirror {
                source: source.clone(),
                targets: Vec::new(),
            },
        };

        if m.has_target(target) {
            return Ok(());
        }

        let exe = holder_exe()?;
        let image = exe.to_string_lossy().to_string();
        let mut child = Command::new(&exe)
            .arg("hold")
            .arg(&target.0)
            .creation_flags(CREATE_NO_WINDOW)
            .stderr(Stdio::piped())
            .spawn()
            .context("cannot start the holder process")?;

        // A format mismatch or a device in exclusive use shows up immediately. Reporting
        // "mirroring" for a holder that already died would be the worst possible answer,
        // so wait long enough to catch that and pass the real reason on.
        std::thread::sleep(std::time::Duration::from_millis(500));
        if let Some(status) = child.try_wait().context("cannot check on the holder")? {
            let mut why = String::new();
            if let Some(mut err) = child.stderr.take() {
                use std::io::Read;
                let _ = err.read_to_string(&mut why);
            }
            // The holder already formatted its own failure through anyhow, so strip the
            // prefix rather than printing "Error: Error:".
            let why = why.trim();
            let why = why.strip_prefix("Error: ").unwrap_or(why);
            if why.is_empty() {
                bail!("the mirror stopped immediately ({status})");
            }
            bail!("{why}");
        }

        m.targets.push(MirrorTarget {
            device: target.clone(),
            holder_pid: child.id(),
            holder_pattern: image,
        });
        state::save(&m)
    }

    fn remove_target(&mut self, target: &DeviceId) -> Result<()> {
        let Some(mut m) = state::load()? else {
            return Ok(());
        };
        for t in m.targets.iter().filter(|t| t.device == *target) {
            stop_holder(t);
        }
        m.targets.retain(|t| t.device != *target);

        // No targets left is not a mirror any more — leaving an empty record behind would
        // make `status` claim something is running.
        if m.targets.is_empty() {
            state::clear()
        } else {
            state::save(&m)
        }
    }

    fn stop_all(&mut self) -> Result<()> {
        if let Some(m) = state::load()? {
            for t in &m.targets {
                stop_holder(t);
            }
        }
        state::clear()
    }

    fn set_volume(&mut self, device: &DeviceId, value: f32) -> Result<()> {
        unsafe {
            let d = self.find(device)?;
            endpoint_volume(&d)?
                .SetMasterVolumeLevelScalar(value.clamp(0.0, 1.0), std::ptr::null())
                .with_context(|| format!("cannot set the volume of {}", device.0))
        }
    }

    fn status(&self) -> Result<Option<Mirror>> {
        state::load()
    }

    fn cleanup_stale(&mut self) -> Result<()> {
        let Some(mut m) = state::load()? else {
            return Ok(());
        };

        // A holder that is gone took its audio with it, so the record is the only thing
        // left to clean up. This is what keeps a crash from making `status` lie.
        let before = m.targets.len();
        m.targets.retain(holder_alive);
        if m.targets.len() == before {
            return Ok(());
        }
        if m.targets.is_empty() {
            state::clear()
        } else {
            state::save(&m)
        }
    }

    fn capabilities(&self) -> Result<Capabilities> {
        unsafe {
            let d = self
                .enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .context("no default output device")?;
            let client: IAudioClient = d
                .Activate(CLSCTX_ALL, None)
                .context("cannot open the audio client of the default device")?;

            // Measured, never hardcoded — same rule as the Linux side, which derives its
            // 42 ms from the current quantum instead of writing the number down.
            let mut default_period: i64 = 0;
            client
                .GetDevicePeriod(Some(&mut default_period), None)
                .context("cannot read the device period")?;

            let period_ms = (default_period as f64 / 10_000.0).ceil() as u32;

            Ok(Capabilities {
                // The whole point of the loopback approach: nothing is ever created.
                creates_virtual_device: false,
                changes_default_device: false,
                moves_streams: false,
                // One period to notice the audio, plus however deep the engine keeps the
                // target buffer. Reporting two periods was wrong: it described the
                // hardware and ignored what the mirror loop itself adds, which is the
                // larger half and the part a listener actually hears.
                base_latency_ms: period_ms + mirror::TARGET_FILL_MS,
                max_targets: 0,
            })
        }
    }
}
