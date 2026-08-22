//! Does sound actually come out of the mirrored target on Linux?
//!
//! Same idea as `backend-windows/tests/level.rs`, adapted to PipeWire: an A/B, not a
//! measurement. The same tone plays throughout, and the only thing that changes is
//! whether the mirror is running. A target that reads silence with the mirror off and
//! signal with it on can only be getting that signal from us.
//!
//! Unlike the Windows version, this test does not need a second real output device - it
//! loads its own throwaway `module-null-sink` as the target and unloads it again when
//! done, so it runs the same way on any machine with PipeWire and something playing to
//! its default output.
//!
//! # Why it is ignored by default
//!
//! It plays a tone out loud, starts a real mirror, and needs `target/release/mirrik` to
//! exist. Run it deliberately:
//!
//! ```text
//! cargo build --release -p mirrik-cli
//! cargo test -p mirrik-backend-linux --test level -- --ignored --nocapture
//! ```
//!
//! It does not skip itself when something is missing - it fails and says what. A test
//! that quietly passes because it did nothing is worse than no test.

#![cfg(target_os = "linux")]

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use mirrik_backend_linux::PipeWireBackend;
use mirrik_core::MirrorBackend;

/// Below this a reading is just the noise floor of an idle monitor.
const SILENCE: f32 = 0.02;

/// A null sink this test owns start to finish - the name it looks for in `devices()`,
/// and the `sink_name` handed to `pactl load-module`.
const TARGET_SINK: &str = "mirrik_test_target";

fn release_cli() -> PathBuf {
    // tests/ sits two levels under the workspace root.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/release/mirrik")
        .canonicalize()
        .expect(
            "target/release/mirrik is missing - build it first: \
             cargo build --release -p mirrik-cli",
        )
}

/// Runs the real command line, the way a user would.
fn mirrik(cli: &Path, args: &[&str]) {
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

/// Loads a throwaway null sink so the test has a target it fully controls. Returns the
/// module id `pactl` assigned, needed to unload it again.
fn load_null_sink() -> String {
    let out = Command::new("pactl")
        .args([
            "load-module",
            "module-null-sink",
            &format!("sink_name={TARGET_SINK}"),
            "sink_properties=device.description=Mirrik_Test_Target",
        ])
        .output()
        .expect("cannot run pactl load-module - is PipeWire's pulse bridge running?");
    assert!(
        out.status.success(),
        "pactl load-module module-null-sink failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn unload_null_sink(module_id: &str) {
    // Best-effort: this runs during cleanup, where panicking would hide the real failure.
    let _ = Command::new("pactl")
        .args(["unload-module", module_id])
        .status();
}

/// Plays a steady tone on the default output until the child is killed.
///
/// Through `ffmpeg`'s own PulseAudio sink rather than an audio API of our own: this only
/// has to make noise on whatever device is currently default, which is exactly what a
/// plain `-f pulse` output does.
fn play_forever() -> Child {
    Command::new("ffmpeg")
        .args([
            "-nostdin",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:sample_rate=48000",
            "-f",
            "pulse",
            "-ac",
            "1",
            "-ar",
            "48000",
            "mirrik-level-test-tone",
        ])
        .stdin(Stdio::null())
        .spawn()
        .expect("cannot start ffmpeg - needed to generate the test tone")
}

/// Records `how_much` audio from a monitor and returns the loudest sample seen,
/// normalised to roughly 0.0-1.0.
///
/// Through a temp file rather than a piped stdout: `parecord` is stopped once it has
/// enough, and reading a file back afterwards is simpler than draining a pipe from a
/// process that might still be flushing.
///
/// We wait for the samples, not for the clock. `parecord` writes nothing at all for its
/// first two seconds or so - PipeWire client negotiation, then its own block buffer - so
/// "sleep two seconds, then kill it" leaves an empty file even while a tone is playing
/// loudly, and the reading comes back 0.0. Measured here at 48 kHz mono: first bytes land
/// at 2.0s, whatever the window. Polling the file makes the reading independent of that
/// lag instead of racing it.
fn peak_over(monitor: &str, how_much: Duration) -> f32 {
    const BYTES_PER_SECOND: f32 = 48_000.0 * 2.0; // s16le, one channel
    let want = (how_much.as_secs_f32() * BYTES_PER_SECOND) as u64;
    // The first block alone costs about two seconds, and a busy graph stretches that.
    let deadline = Instant::now() + how_much + Duration::from_secs(10);

    let out_path =
        std::env::temp_dir().join(format!("mirrik-level-{}-{monitor}.raw", std::process::id()));
    let mut rec = Command::new("parecord")
        .args([
            &format!("--device={monitor}"),
            "--format=s16le",
            "--rate=48000",
            "--channels=1",
            "--file-format=raw",
        ])
        .arg(&out_path)
        .spawn()
        .expect("cannot start parecord");
    while std::fs::metadata(&out_path).map(|m| m.len()).unwrap_or(0) < want {
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = rec.kill();
    let _ = rec.wait();

    let mut data = Vec::new();
    std::fs::File::open(&out_path)
        .and_then(|mut f| f.read_to_end(&mut data))
        .expect("parecord left no readable output");
    let _ = std::fs::remove_file(&out_path);

    // A short file is not a quiet reading, it is no reading at all - and it would look
    // exactly like silence further down. Say so instead.
    assert!(
        data.len() as u64 >= want,
        "parecord gave us {} of the {want} bytes asked for from {monitor} - that monitor \
         delivered (almost) no samples, so any peak from it would be a false negative",
        data.len()
    );

    data.chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]).unsigned_abs())
        .max()
        .map(|peak| peak as f32 / i16::MAX as f32)
        .unwrap_or(0.0)
}

#[test]
#[ignore = "plays a sound out loud and starts a real mirror; run with --ignored"]
fn the_mirror_actually_carries_audio_to_the_target() {
    let cli = release_cli();
    let module_id = load_null_sink();

    // Leave nothing running behind us, whichever way this ends - the null sink and the
    // tone both need cleanup even if an assertion below panics.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let backend = PipeWireBackend::new().expect("cannot reach PipeWire");
        let source = backend.default_device().expect("no default output device");
        let devices = backend.devices().expect("cannot list devices");
        let target = devices
            .iter()
            .find(|d| d.id.0 == TARGET_SINK)
            .expect("the null sink this test just loaded is not visible via pw-dump yet");

        let source_monitor = format!("{}.monitor", source.id.0);
        let target_monitor = format!("{}.monitor", target.id.0);
        let target_id = target.id.0.clone();

        let mut tone = play_forever();
        let ab = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // ffmpeg's PulseAudio sink takes noticeably longer than the mirror itself to
            // actually start emitting - 700ms left the source read racing an empty pipe.
            std::thread::sleep(Duration::from_millis(1500));

            // A. Tone is playing and the mirror is off. Two readings, and both matter:
            //    the source proves there is something to mirror at all, the target
            //    proves it is not already getting it from somewhere else.
            // The durations are seconds of audio wanted, not seconds of wall clock -
            // peak_over waits for the samples to actually land (see there).
            let playing = peak_over(&source_monitor, Duration::from_secs(2));
            let quiet = peak_over(&target_monitor, Duration::from_secs(2));

            // B. Same tone, mirror on. Anything that shows up now came through us.
            mirrik(&cli, &["on", &target_id]);
            std::thread::sleep(Duration::from_millis(700));
            let loud = peak_over(&target_monitor, Duration::from_secs(2));

            mirrik(&cli, &["off"]);
            (playing, quiet, loud)
        }));
        let _ = tone.kill();
        let _ = tone.wait();
        ab.unwrap_or_else(|e| std::panic::resume_unwind(e))
    }));

    let _ = Command::new(&cli).arg("off").status();
    unload_null_sink(&module_id);

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
         or the tone never started. There is nothing here for the mirror to carry"
    );
    assert!(
        quiet < SILENCE,
        "the target was already making noise before the mirror started ({quiet:.4}) - \
         something else is playing to it, so this test cannot tell who fed it"
    );
    assert!(
        loud > SILENCE * 2.0,
        "the mirror ran but the target stayed silent ({loud:.4}) - the bookkeeping said \
         'mirroring' and no audio arrived"
    );
}
