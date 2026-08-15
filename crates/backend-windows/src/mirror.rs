//! The audio engine: loopback capture on the source, render on one target.
//!
//! This is the Windows answer to `module-loopback`. The shape is the same as on Linux —
//! tap what the current output is already playing and push it to a second device — but
//! here the tap has to be pumped by hand instead of by the audio server.
//!
//! Two things about loopback capture decide the design:
//!
//!   * **Silence produces nothing.** When the source plays nothing, the capture client
//!     simply returns no packets — not zeroed ones. A render client fed only from those
//!     packets would starve and glitch on the next sound, so this loop always tops the
//!     render buffer up with zeros.
//!   * **Event notification is unreliable in loopback mode** for the same reason: no data,
//!     no event. Polling is therefore not laziness here, it is the working option.

use anyhow::{bail, Context, Result};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IAudioRenderClient, IMMDeviceEnumerator,
    MMDeviceEnumerator, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED,
};

/// How much audio the engine is willing to hold before dropping the oldest.
///
/// ponytail: fixed cap instead of drift compensation. Two clocks run here — the source
/// device and the target device — and nothing keeps them in step, so over a long session
/// the buffer creeps towards one end and gets trimmed. Audible as a rare tick, not as a
/// dropout. Proper rate adjustment is stage 4.
const MAX_BUFFERED_MS: u32 = 200;

/// Engine buffer handed to WASAPI, in 100 ns units (100 ms).
const CLIENT_BUFFER_HNS: i64 = 1_000_000;

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

/// Mirrors the current default output to `target_id` until `stop` is set.
///
/// Runs on the calling thread and does not return early on its own — a mirror that ends
/// by itself would be exactly the surprise the Linux side went out of its way to avoid.
pub fn run(target_id: &str, stop: &AtomicBool) -> Result<()> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .context("cannot create the WASAPI device enumerator")?;

        // The source is whatever Windows currently plays to. Deliberately resolved here
        // and not passed in: the holder process should mirror the device the user hears,
        // not one that was default when the command was typed.
        let source = enumerator
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .context("no default output device")?;

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
        let ren_fmt = MixFormat::of(&render_client)?;
        let cap = cap_fmt.describe();
        let ren = ren_fmt.describe();

        // Shared mode hands both sides float32, so the only thing that can differ is the
        // rate and the channel count. Refusing loudly beats mirroring at the wrong speed:
        // a 4:1 rate mismatch does not sound broken, it sounds like a different recording.
        if cap.rate != ren.rate || cap.channels != ren.channels {
            bail!(
                "source runs at {} Hz / {} ch, target at {} Hz / {} ch. \
                 Set both to the same format in Sound settings (resampling is stage 4).",
                cap.rate,
                cap.channels,
                ren.rate,
                ren.channels
            );
        }

        capture_client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_LOOPBACK,
                CLIENT_BUFFER_HNS,
                0,
                cap_fmt.0,
                None,
            )
            .context("cannot start loopback capture on the source device")?;
        render_client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                0,
                CLIENT_BUFFER_HNS,
                0,
                ren_fmt.0,
                None,
            )
            .context("cannot open the target device for playback")?;

        let capture: IAudioCaptureClient = capture_client
            .GetService()
            .context("cannot get the capture service")?;
        let render: IAudioRenderClient = render_client
            .GetService()
            .context("cannot get the render service")?;

        let render_frames = render_client
            .GetBufferSize()
            .context("cannot read the target buffer size")?;
        let channels = ren.channels as usize;
        let max_samples = (MAX_BUFFERED_MS as usize * ren.rate as usize / 1000) * channels;

        capture_client.Start().context("cannot start the capture")?;
        render_client.Start().context("cannot start playback")?;

        let mut buffer: VecDeque<f32> = VecDeque::with_capacity(max_samples);
        let mut result = Ok(());

        while !stop.load(Ordering::Relaxed) {
            // Drain everything the tap has, then feed the target. Order matters: filling
            // the target first would hand it samples that are one poll interval stale.
            loop {
                let available = capture
                    .GetNextPacketSize()
                    .context("cannot query the capture packet size")?;
                if available == 0 {
                    break;
                }

                let mut data: *mut u8 = std::ptr::null_mut();
                let mut frames: u32 = 0;
                let mut flags: u32 = 0;
                capture
                    .GetBuffer(&mut data, &mut frames, &mut flags, None, None)
                    .context("cannot read from the tap")?;

                if frames > 0 {
                    let count = frames as usize * channels;
                    // AUDCLNT_BUFFERFLAGS_SILENT (0x2) means the pointer holds whatever
                    // was there before and must be treated as silence, not copied.
                    if flags & 0x2 != 0 {
                        buffer.extend(std::iter::repeat(0.0).take(count));
                    } else {
                        buffer.extend(std::slice::from_raw_parts(data as *const f32, count));
                    }
                }
                capture
                    .ReleaseBuffer(frames)
                    .context("cannot release the tap buffer")?;

                while buffer.len() > max_samples {
                    buffer.pop_front();
                }
            }

            let padding = render_client
                .GetCurrentPadding()
                .context("cannot read the target buffer fill level")?;
            let free_frames = render_frames.saturating_sub(padding);

            if free_frames > 0 {
                let slot = render
                    .GetBuffer(free_frames)
                    .context("cannot claim the target buffer")?;
                let wanted = free_frames as usize * channels;
                let out = std::slice::from_raw_parts_mut(slot as *mut f32, wanted);

                // Anything the tap did not deliver becomes silence rather than a gap.
                // This is the line that keeps the render client from starving while the
                // source is quiet.
                for sample in out.iter_mut() {
                    *sample = buffer.pop_front().unwrap_or(0.0);
                }
                render
                    .ReleaseBuffer(free_frames, 0)
                    .context("cannot hand the target buffer back")?;
            }

            // Half a poll of the engine period: often enough not to run dry, rarely
            // enough not to spin a core.
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        if let Err(e) = capture_client.Stop() {
            result = Err(e).context("capture did not stop cleanly");
        }
        if let Err(e) = render_client.Stop() {
            result = Err(e).context("playback did not stop cleanly");
        }
        result
    }
}
