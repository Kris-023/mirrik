//! Does sound actually come out of the second device?
//!
//! Every other test in this project checks the bookkeeping: the state file, the holder
//! process, the device list, the latency it reports. None of them would notice if the
//! mirror ran perfectly and moved no audio at all. This one watches the target's own peak
//! meter and answers that question directly.
//!
//! It is an A/B, not a measurement: the same sound plays throughout, and the only thing
//! that changes is whether the mirror is running. A target that reads silence with the
//! mirror off and signal with it on can only be getting that signal from us.
//!
//! # Why it is ignored by default
//!
//! It plays a sound out loud, starts a real mirror on real hardware and needs
//! `target/release/mirrik.exe` to exist. That is not something a plain `cargo test`
//! should do to you. Run it deliberately:
//!
//! ```text
//! cargo build --release -p mirrik-cli
//! cargo test -p mirrik-backend-windows --test level -- --ignored --nocapture
//! ```
//!
//! It does not skip itself when something is missing - it fails and says what. A test
//! that quietly passes because it did nothing is worse than no test.

#![cfg(windows)]

use std::process::{Child, Command};
use std::time::{Duration, Instant};

use mirrik_backend_windows::WasapiBackend;
use mirrik_core::MirrorBackend;
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::Endpoints::IAudioMeterInformation;
use windows::Win32::Media::Audio::{IMMDevice, IMMDeviceEnumerator, MMDeviceEnumerator};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
};

/// A sound Windows ships with itself, so there is nothing to fetch or generate.
const SOUND: &str = r"C:\Windows\Media\Alarm01.wav";

/// Below this a reading is just the noise floor of an idle endpoint.
const SILENCE: f32 = 0.001;

/// Peaks are not steady - a wav has quiet passages - so the run has to be long enough to
/// contain a loud one, and the check is on the loudest sample seen.
const WATCH: Duration = Duration::from_secs(3);

fn release_cli() -> std::path::PathBuf {
    // tests/ sits two levels under the workspace root.
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/release/mirrik.exe")
        .canonicalize()
        .expect(
            "target/release/mirrik.exe is missing - build it first: \
             cargo build --release -p mirrik-cli",
        )
}

/// Runs the real command line, the way a user would.
///
/// `status`, not `output`: `mirrik on` leaves a holder process behind, and that holder
/// inherits whatever stdout it was given. Capturing here means the pipe stays open for as
/// long as the mirror runs, and the call does not come back until the mirror ends - which
/// is the deadlock this test hit on its first run, four minutes of waiting for something
/// that had already worked.
fn mirrik(cli: &std::path::Path, args: &[&str]) {
    let status = Command::new(cli)
        .args(args)
        .status()
        .unwrap_or_else(|e| panic!("cannot run mirrik {}: {e}", args.join(" ")));
    assert!(
        status.success(),
        "mirrik {} failed ({status})",
        args.join(" ")
    );
}

/// Plays the sound on the default output until the child is killed.
///
/// Through PowerShell rather than an audio API of our own: this only has to make noise on
/// whatever device Windows currently plays to, which is exactly what SoundPlayer does.
fn play_forever() -> Child {
    Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "$p = New-Object Media.SoundPlayer '{SOUND}'; $p.PlayLooping(); Start-Sleep 120"
            ),
        ])
        .spawn()
        .expect("cannot start playback through PowerShell")
}

/// The loudest thing this endpoint has seen while we watched it.
///
/// `IAudioMeterInformation` reads the peak the audio engine measured for the device
/// itself, which is what a listener would hear - independent of whose stream produced it.
fn peak_over(device: &IMMDevice, how_long: Duration) -> f32 {
    let meter: IAudioMeterInformation = unsafe { device.Activate(CLSCTX_ALL, None) }
        .expect("cannot read the peak meter of that device");
    let until = Instant::now() + how_long;
    let mut loudest = 0.0f32;
    while Instant::now() < until {
        let now = unsafe { meter.GetPeakValue() }.expect("cannot read a peak value");
        loudest = loudest.max(now);
        std::thread::sleep(Duration::from_millis(20));
    }
    loudest
}

fn endpoint(enumerator: &IMMDeviceEnumerator, id: &str) -> IMMDevice {
    let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe { enumerator.GetDevice(PCWSTR(wide.as_ptr())) }.expect("no endpoint with that id")
}

#[test]
#[ignore = "plays a sound out loud and starts a real mirror; run with --ignored"]
fn the_mirror_actually_carries_audio_to_the_target() {
    let cli = release_cli();

    let backend = WasapiBackend::new().expect("cannot open WASAPI");
    let source = backend.default_device().expect("no default output device");
    let devices = backend.devices().expect("cannot list devices");
    let target = devices
        .iter()
        .find(|d| d.id != source.id)
        .expect("this test needs a second output device - mirroring needs somewhere to go");

    println!("source: {}\ntarget: {}", source.name, target.name);

    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
        .ok()
        .expect("cannot initialise COM");
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
            .expect("cannot create the device enumerator");
    let source_endpoint = endpoint(&enumerator, &source.id.0);
    let target_endpoint = endpoint(&enumerator, &target.id.0);

    // Leave nothing running behind us, whichever way this ends.
    let mut sound = play_forever();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        std::thread::sleep(Duration::from_millis(700));

        // A. Sound is playing and the mirror is off. Two readings, and both matter: the
        //    source proves there is something to mirror at all, the target proves it is
        //    not already getting it from somewhere else.
        let playing = peak_over(&source_endpoint, Duration::from_secs(1));
        let quiet = peak_over(&target_endpoint, WATCH);

        // B. Same sound, mirror on. Anything that shows up now came through us.
        mirrik(&cli, &["on", &target.id.0]);
        std::thread::sleep(Duration::from_millis(700));
        let loud = peak_over(&target_endpoint, WATCH);

        mirrik(&cli, &["off"]);
        (playing, quiet, loud)
    }));

    let _ = sound.kill();
    let _ = sound.wait();
    let _ = Command::new(&cli).arg("off").status();

    let (playing, quiet, loud) = result.unwrap_or_else(|e| std::panic::resume_unwind(e));
    println!(
        "peak on the source:      {playing:.4}\n\
         peak on the target, off: {quiet:.4}\n\
         peak on the target, on:  {loud:.4}"
    );

    // Checked first, because it is the one failure that says "this test is broken", not
    // "the mirror is broken".
    assert!(
        playing > SILENCE,
        "nothing is playing on the default output ({playing:.4}) - muted, at zero volume, \
         or the sound never started. There is nothing here for the mirror to carry"
    );
    assert!(
        quiet < SILENCE,
        "the target was already making noise before the mirror started ({quiet:.4}) - \
         something else is playing to it, so this test cannot tell who fed it"
    );
    assert!(
        loud > SILENCE * 5.0,
        "the mirror ran but the target stayed silent ({loud:.4}) - the bookkeeping said \
         'mirroring' and no audio arrived. If the default output is muted or at zero \
         volume, that is the first thing to check"
    );
}
