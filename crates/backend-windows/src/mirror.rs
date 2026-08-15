//! The audio engine: loopback capture on the source, render on one target.
//!
//! This is the Windows answer to `module-loopback`. The shape is the same as on Linux —
//! tap what the current output is already playing and push it to a second device — but
//! here the tap has to be pumped by hand instead of by the audio server.
//!
//! Three things about loopback capture decide the design:
//!
//!   * **Silence produces nothing.** When the source plays nothing, the capture client
//!     simply returns no packets — not zeroed ones. A render client fed only from those
//!     packets would starve and glitch on the next sound, so this loop always tops the
//!     render buffer up with zeros.
//!   * **Event notification is unreliable in loopback mode** for the same reason: no data,
//!     no event. Polling is therefore not laziness here, it is the working option.
//!   * **Devices come and go underneath a running stream.** Both clients are rebuilt when
//!     the source changes rather than being held for the life of the process.

use anyhow::{bail, Context, Result};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IAudioRenderClient, IMMDevice,
    IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_E_DEVICE_INVALIDATED,
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_LOOPBACK,
    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, WAVEFORMATEX,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED,
};

/// How much audio may sit in the hand-over buffer before frames start being dropped.
///
/// Every buffered frame is delay the listener hears, so this is kept tight. Generous
/// buffering was the first version's mistake: 200 ms here plus a render buffer filled to
/// the brim came out as a third of a second of lag, clearly audible against the source.
const MAX_BUFFERED_MS: u32 = 20;

/// How deep the target's own buffer is kept.
///
/// Deep enough to survive a missed poll, shallow enough not to be heard. This is the
/// dominant term in the delay, which is why it is a named constant and not "whatever
/// happens to be free".
pub const TARGET_FILL_MS: u32 = 20;

/// Poll interval. Half the usual engine period, so a poll cannot be skipped entirely.
const POLL_MS: u64 = 5;

/// How often the default output is re-checked, in polls (~500 ms).
///
/// `IMMNotificationClient` would report this immediately, but it means implementing and
/// registering a COM callback to learn something one comparison answers just as well.
/// Half a second late is imperceptible for a device the user just switched by hand.
const DEFAULT_CHECK_EVERY: u32 = 100;

/// Engine buffer for the tap, in 100 ns units (100 ms). Only has to hold what piles up
/// between polls, so it costs nothing to be roomy here.
const CAPTURE_BUFFER_HNS: i64 = 1_000_000;

/// Engine buffer for playback (60 ms) — comfortably above [`TARGET_FILL_MS`], because the
/// fill level is what the loop steers, not the buffer size.
const RENDER_BUFFER_HNS: i64 = 600_000;

/// `AUDCLNT_BUFFERFLAGS_SILENT`: the pointer holds stale memory and means silence.
const BUFFERFLAGS_SILENT: u32 = 0x2;

/// Why the inner loop returned.
enum Outcome {
    /// The holder was asked to stop, or the process is going away.
    Stopped,
    /// The source is gone or is no longer the device the user listens to. Both clients
    /// are stale; the caller rebuilds them against the new default.
    SourceChanged,
}

struct Format {
    rate: u32,
    channels: u16,
}

/// Owns a `WAVEFORMATEX` that came from `GetMixFormat` and frees it again.
struct MixFormat(*mut WAVEFORMATEX);

impl MixFormat {
    unsafe fn of(client: &IAudioClient) -> Result<Self> {
        let p = client
            .GetMixFormat()
            .context("cannot read the mix format")?;
        if p.is_null() {
            bail!("device reported an empty mix format");
        }
        Ok(Self(p))
    }

    unsafe fn describe(&self) -> Format {
        Format {
            rate: (*self.0).nSamplesPerSec,
            channels: (*self.0).nChannels,
        }
    }
}

impl Drop for MixFormat {
    fn drop(&mut self) {
        unsafe { CoTaskMemFree(Some(self.0 as *const _)) }
    }
}

/// A device that was pulled out from under a running stream, as opposed to a real fault.
fn is_gone(e: &windows::core::Error) -> bool {
    e.code() == AUDCLNT_E_DEVICE_INVALIDATED
}

unsafe fn endpoint_id(d: &IMMDevice) -> Result<String> {
    let raw = d.GetId().context("cannot read the device id")?;
    let s = raw.to_string().context("device id is not valid UTF-16")?;
    CoTaskMemFree(Some(raw.0 as *const _));
    Ok(s)
}

/// Mirrors the current default output to `target_id` until `stop` is set.
///
/// Returns only when the mirror is meant to end: on request, or because the target itself
/// disappeared. A changed source is not an ending — the stream is rebuilt around it, so
/// switching your main output does not silently leave the mirror on the old device.
pub fn run(target_id: &str, stop: &AtomicBool) -> Result<()> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .context("cannot create the WASAPI device enumerator")?;

        loop {
            match mirror_once(&enumerator, target_id, stop)? {
                Outcome::Stopped => return Ok(()),
                Outcome::SourceChanged => {
                    // Let the new default settle before grabbing it; a device that has
                    // just been switched is not always ready to be opened.
                    std::thread::sleep(std::time::Duration::from_millis(200));
                }
            }
        }
    }
}

unsafe fn mirror_once(
    enumerator: &IMMDeviceEnumerator,
    target_id: &str,
    stop: &AtomicBool,
) -> Result<Outcome> {
    // The source is whatever Windows currently plays to, resolved here and not passed in:
    // the holder should mirror the device the user hears, not the one that happened to be
    // default when the command was typed.
    let source = enumerator
        .GetDefaultAudioEndpoint(eRender, eConsole)
        .context("no default output device")?;
    let source_id = endpoint_id(&source)?;

    // Mirroring a device onto itself would feed the tap with its own output.
    if source_id == target_id {
        bail!("that device is now the default output - there is nothing left to mirror to");
    }

    let wide: Vec<u16> = target_id.encode_utf16().chain(std::iter::once(0)).collect();
    let target = enumerator
        .GetDevice(PCWSTR(wide.as_ptr()))
        .with_context(|| format!("no such output device: {target_id}"))?;

    let capture_client: IAudioClient = source
        .Activate(CLSCTX_ALL, None)
        .context("cannot open the source audio client")?;
    let render_client: IAudioClient = target
        .Activate(CLSCTX_ALL, None)
        .context("cannot open the target audio client")?;

    let cap_fmt = MixFormat::of(&capture_client)?;
    let cap = cap_fmt.describe();

    capture_client
        .Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK,
            CAPTURE_BUFFER_HNS,
            0,
            cap_fmt.0,
            None,
        )
        .context("cannot start loopback capture on the source device")?;

    // The target is opened in the *source's* format, not its own, and the engine is told
    // to convert. Devices disagree far more often than the Linux side suggested — 192 kHz
    // on one output against 48 kHz on the next is an ordinary desktop, not an exotic one —
    // and a tool that refused those pairs would be useless to most people.
    //
    // Letting the audio engine resample is not a shortcut around writing one: shared mode
    // already runs every stream through that converter, it is anti-aliased, and it costs
    // no dependency and no drift of its own.
    render_client
        .Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            RENDER_BUFFER_HNS,
            0,
            cap_fmt.0,
            None,
        )
        .context("cannot open the target device for playback")?;

    let capture: IAudioCaptureClient = capture_client
        .GetService()
        .context("cannot get the capture service")?;
    let render: IAudioRenderClient = render_client
        .GetService()
        .context("cannot get the render service")?;

    // Everything downstream counts in source frames, because that is the format both
    // clients were opened with — the conversion happens behind the render client.
    let render_frames = render_client
        .GetBufferSize()
        .context("cannot read the target buffer size")?;
    let channels = cap.channels as usize;
    let max_samples = (MAX_BUFFERED_MS as usize * cap.rate as usize / 1000) * channels;
    let target_fill = (TARGET_FILL_MS * cap.rate / 1000).min(render_frames);

    capture_client.Start().context("cannot start the capture")?;
    render_client.Start().context("cannot start playback")?;

    let mut buffer: VecDeque<f32> = VecDeque::with_capacity(max_samples);
    let mut since_default_check = 0u32;
    let outcome;

    loop {
        if stop.load(Ordering::Relaxed) {
            outcome = Outcome::Stopped;
            break;
        }

        // Did the user switch their main output? Comparing ids is enough and costs one
        // call twice a second.
        since_default_check += 1;
        if since_default_check >= DEFAULT_CHECK_EVERY {
            since_default_check = 0;
            let still = enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .ok()
                .and_then(|d| endpoint_id(&d).ok());
            if still.as_deref() != Some(source_id.as_str()) {
                outcome = Outcome::SourceChanged;
                break;
            }
        }

        // Drain everything the tap has, then feed the target. Order matters: filling the
        // target first would hand it samples that are one poll interval stale.
        let mut source_lost = false;
        loop {
            let available = match capture.GetNextPacketSize() {
                Ok(v) => v,
                Err(e) if is_gone(&e) => {
                    source_lost = true;
                    break;
                }
                Err(e) => return Err(e).context("cannot query the capture packet size"),
            };
            if available == 0 {
                break;
            }

            let mut data: *mut u8 = std::ptr::null_mut();
            let mut frames: u32 = 0;
            let mut flags: u32 = 0;
            match capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None) {
                Ok(()) => {}
                Err(e) if is_gone(&e) => {
                    source_lost = true;
                    break;
                }
                Err(e) => return Err(e).context("cannot read from the tap"),
            }

            if frames > 0 {
                let count = frames as usize * channels;
                if flags & BUFFERFLAGS_SILENT != 0 {
                    buffer.extend(std::iter::repeat_n(0.0, count));
                } else {
                    buffer.extend(std::slice::from_raw_parts(data as *const f32, count));
                }
            }
            capture
                .ReleaseBuffer(frames)
                .context("cannot release the tap buffer")?;

            // Drift correction. The two devices run on separate clocks, so over time the
            // buffer creeps towards one end. Dropping a single frame per pass absorbs
            // that as a run of inaudible nudges; trimming the whole excess at once, as an
            // earlier version did, is one audible jump instead.
            if buffer.len() > max_samples {
                buffer.drain(..channels);
            }
            // Emergency brake for a real burst — a long stall, not clock drift.
            if buffer.len() > max_samples * 3 {
                let excess = buffer.len() - max_samples;
                buffer.drain(..excess);
            }
        }

        if source_lost {
            outcome = Outcome::SourceChanged;
            break;
        }

        let padding = match render_client.GetCurrentPadding() {
            Ok(v) => v,
            // The target is what vanished, and that ends the mirror rather than
            // rebuilding it: the device the user picked is simply not there any more.
            Err(e) if is_gone(&e) => bail!("the target device was disconnected"),
            Err(e) => return Err(e).context("cannot read the target buffer fill level"),
        };

        // Top up to a fixed shallow level instead of filling everything that is free.
        // Writing into all the free space would push a full buffer's worth of audio ahead
        // of the listener, and that delay never recovers — it is heard for as long as the
        // mirror runs.
        let want = target_fill
            .saturating_sub(padding)
            .min(render_frames - padding);

        if want > 0 {
            let slot = match render.GetBuffer(want) {
                Ok(p) => p,
                Err(e) if is_gone(&e) => bail!("the target device was disconnected"),
                Err(e) => return Err(e).context("cannot claim the target buffer"),
            };
            let out = std::slice::from_raw_parts_mut(slot as *mut f32, want as usize * channels);

            // Anything the tap did not deliver becomes silence rather than a gap. This is
            // the line that keeps the render client from starving while the source is
            // quiet.
            for sample in out.iter_mut() {
                *sample = buffer.pop_front().unwrap_or(0.0);
            }
            render
                .ReleaseBuffer(want, 0)
                .context("cannot hand the target buffer back")?;
        }

        std::thread::sleep(std::time::Duration::from_millis(POLL_MS));
    }

    // Best effort: if the device is already gone these fail, and that is not a problem
    // worth reporting over the reason we are leaving in the first place.
    let _ = capture_client.Stop();
    let _ = render_client.Stop();
    Ok(outcome)
}
