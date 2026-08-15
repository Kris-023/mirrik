//! "Off means gone" rests entirely on recognising a live holder, so that check gets its
//! own test.
//!
//! Windows reuses process ids. If liveness were decided by the pid alone, a stale record
//! could point at some unrelated program that inherited the number — and `off` would then
//! terminate a stranger. Storing the holder's executable path is what prevents that, and
//! this is the test that keeps it honest.

use mirrik_backend_windows::{holder_alive, holder_exe};
use mirrik_core::{DeviceId, MirrorTarget};

fn target(pid: u32, image: &str) -> MirrorTarget {
    MirrorTarget {
        device: DeviceId("{0.0.0.00000000}.{test}".into()),
        holder_pid: pid,
        holder_pattern: image.into(),
    }
}

#[test]
fn liveness_needs_both_the_pid_and_the_executable() {
    let me = std::process::id();
    let my_image = std::env::current_exe()
        .expect("a test binary knows its own path")
        .to_string_lossy()
        .to_string();

    assert!(
        holder_alive(&target(me, &my_image)),
        "a running process with a matching image must count as alive"
    );

    // The whole point: same pid, different program. Terminating this would kill a
    // stranger that merely inherited the number.
    assert!(
        !holder_alive(&target(me, r"C:\Windows\System32\notepad.exe")),
        "a recycled pid must not be mistaken for our holder"
    );

    // Nothing can be running here, and asking about it must not panic either.
    assert!(
        !holder_alive(&target(u32::MAX, &my_image)),
        "a pid that cannot be opened is not alive"
    );
}

/// Whoever asks for a mirror, the process that holds it open is the command line tool.
///
/// This caught a real bug: started from the graphical front-end, `current_exe()` is the
/// window binary. It has no `hold` command, so it opened a second window, looked alive to
/// the liveness check, and the mirror reported success while playing nothing.
#[test]
fn the_holder_is_never_just_whatever_is_running() {
    let me = std::env::current_exe().expect("a test binary knows its own path");

    match holder_exe() {
        // Never the caller — a test runner is not a mirror holder.
        Ok(p) => assert_ne!(
            p, me,
            "holder_exe picked the calling binary instead of the CLI"
        ),
        // No CLI next to the test binary is the normal case here, and saying so out loud
        // is exactly the behaviour that was missing before.
        Err(e) => assert!(
            e.to_string().contains("mirrik.exe"),
            "the error should name what is missing, got: {e}"
        ),
    }
}
