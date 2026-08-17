//! One window at a time.
//!
//! Mirrik registers no hotkey and keeps nothing running in the background, so a second
//! press of the key combination starts a second program that knows nothing about the
//! first — and the windows stack up. This module is the smallest thing that prevents
//! that: whoever starts first claims a name, everyone else finds it taken and leaves.
//!
//! It deliberately does **not** raise the running window. That would need a way to talk
//! to it, which means something listening, which means a background process — the one
//! thing this tool does not have.
//!
//! # Leaves nothing behind
//!
//! The claim is an abstract unix socket, not a file: it exists only as long as the
//! process holds it, and the kernel releases it on exit — including `kill -9`, a panic
//! and a session that ends underneath it. There is no stale lock file to clean up and no
//! liveness check to get wrong, which is the trap this project has already paid for once
//! with holder processes.

use anyhow::Result;

/// Held for as long as this process wants to be the only one. Dropping it frees the name.
pub struct Claim {
    #[cfg(target_os = "linux")]
    _socket: std::os::unix::net::UnixListener,
}

/// Try to become the only running instance under `name`.
///
/// `Ok(Some(claim))` — the name is ours, keep the claim alive.
/// `Ok(None)` — somebody else has it; this process should exit quietly.
///
/// An error means the question could not be answered. Callers are expected to carry on:
/// a second window is a nuisance, no window at all is a failure.
#[cfg(target_os = "linux")]
pub fn claim(name: &str) -> Result<Option<Claim>> {
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::net::{SocketAddr, UnixListener};

    // The abstract namespace is shared by every user in the network namespace, so the uid
    // has to be part of the name — otherwise the first user to open a window would lock
    // out the second. Read from /proc rather than through libc, which is not a dependency
    // here and would not earn its place for one number.
    let uid = std::fs::metadata("/proc/self")?.uid();
    let addr = SocketAddr::from_abstract_name(format!("mirrik.{uid}.{name}"))?;

    match UnixListener::bind_addr(&addr) {
        Ok(socket) => Ok(Some(Claim { _socket: socket })),
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// No guard on this platform yet, so every start is allowed.
///
/// Windows would use a named mutex (`CreateMutexW`, then `GetLastError() ==
/// ERROR_ALREADY_EXISTS`), which behaves the same way: held by the process, released by
/// the kernel. Not written here because it cannot be tested from this side, and an
/// untested claim that wrongly reports "already running" would stop the window opening
/// at all.
#[cfg(not(target_os = "linux"))]
pub fn claim(_name: &str) -> Result<Option<Claim>> {
    Ok(Some(Claim {}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "linux")]
    fn second_claim_is_refused_and_the_name_comes_back() {
        // Unique per run: tests share a process, and the namespace outlives nothing.
        let name = format!("test.{}", std::process::id());

        let first = claim(&name).unwrap().expect("first claim must succeed");
        assert!(
            claim(&name).unwrap().is_none(),
            "a second claim on a held name must be refused"
        );

        drop(first);
        assert!(
            claim(&name).unwrap().is_some(),
            "the name must be free again once the claim is dropped"
        );
    }
}
