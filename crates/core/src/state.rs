//! Where a running mirror is recorded.
//!
//! `$XDG_STATE_HOME/mirrik/mirror.json` (default `~/.local/state/mirrik/`),
//! on Windows `%LOCALAPPDATA%\mirrik\`. Deliberately **not** in the config
//! directory: this is runtime bookkeeping and is cleaned up rather than restored.
//!
//! Next to it lives `last.json`, the set of destinations that was last switched on.
//! Same directory for the same reason — it is bookkeeping, not settings, and the config
//! file stays a file this program never writes.

use crate::{DeviceId, Mirror, MirrorTarget};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// One destination as it was last switched on.
///
/// The name is written down for the same reason [`MirrorTarget`] writes it down: once a
/// device is unplugged, its name goes with it, and offering
/// "bluez_output.00_11_22_33_44_55.1" helps nobody.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Remembered {
    pub device: DeviceId,
    pub name: String,
}

fn dir() -> Result<PathBuf> {
    let base = if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .context("LOCALAPPDATA is not set")?
    } else if let Some(x) = std::env::var_os("XDG_STATE_HOME") {
        PathBuf::from(x)
    } else {
        let home = std::env::var_os("HOME").context("HOME is not set")?;
        PathBuf::from(home).join(".local/state")
    };
    Ok(base.join("mirrik"))
}

pub fn path() -> Result<PathBuf> {
    Ok(dir()?.join("mirror.json"))
}

/// The set that was last switched on. Survives stopping — that is the whole point.
pub fn last_path() -> Result<PathBuf> {
    Ok(dir()?.join("last.json"))
}

pub fn load() -> Result<Option<Mirror>> {
    let p = path()?;
    match std::fs::read_to_string(&p) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(m) => Ok(Some(m)),
            // A corrupt file describes a state that no longer exists anyway; throwing it
            // away is the right move, blocking the tool over it is not.
            Err(_) => {
                let _ = std::fs::remove_file(&p);
                Ok(None)
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("cannot read {}", p.display())),
    }
}

pub fn save(m: &Mirror) -> Result<()> {
    let p = path()?;
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).with_context(|| format!("cannot create {}", d.display()))?;
    }
    std::fs::write(&p, serde_json::to_string_pretty(m)?)
        .with_context(|| format!("cannot write {}", p.display()))?;
    // Every change to a running mirror goes through here, on both platforms and from both
    // programs, so this is the one place that has to remember anything.
    if let Ok(l) = last_path() {
        remember_to(&l, &m.targets);
    }
    Ok(())
}

/// Removes the record of the running mirror. **Leaves `last.json` alone** — "what you had
/// on last time" has to survive stopping, otherwise there is never anything to offer.
pub fn clear() -> Result<()> {
    let p = path()?;
    match std::fs::remove_file(&p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("cannot remove {}", p.display())),
    }
}

/// The last set, or nothing when there was none or the file is unreadable.
pub fn last() -> Vec<Remembered> {
    match last_path() {
        Ok(p) => last_from(&p),
        Err(_) => Vec::new(),
    }
}

/// Takes the path so a test does not have to move the caller's real home directory.
pub fn last_from(p: &Path) -> Vec<Remembered> {
    match std::fs::read_to_string(p) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// Best effort on purpose: failing to write this down is no reason to fail switching a
/// device on. An empty set is not written, so stopping does not erase what to offer.
///
/// ponytail: hangs off `save`, so a set that `status` pruned after a crash is remembered
/// in its pruned form. Move the call into the add/remove paths of both backends if that
/// ever actually bites.
fn remember_to(p: &Path, targets: &[MirrorTarget]) {
    if targets.is_empty() {
        return;
    }
    let list: Vec<Remembered> = targets
        .iter()
        .map(|t| Remembered {
            device: t.device.clone(),
            name: t.label().to_string(),
        })
        .collect();
    if let Ok(text) = serde_json::to_string_pretty(&list) {
        let _ = std::fs::write(p, text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(id: &str, name: &str) -> MirrorTarget {
        MirrorTarget {
            device: DeviceId(id.to_string()),
            name: name.to_string(),
            holder_pid: 1,
            holder_pattern: "mirrik.out.test".to_string(),
        }
    }

    #[test]
    fn a_remembered_set_comes_back_in_order_and_with_its_names() {
        let p = std::env::temp_dir().join("mirrik-last-roundtrip.json");
        let _ = std::fs::remove_file(&p);

        remember_to(
            &p,
            &[target("alsa.hdmi", "HDMI"), target("bt.1", "AirPods")],
        );
        let back = last_from(&p);

        assert_eq!(back.len(), 2);
        assert_eq!(back[0].device.0, "alsa.hdmi");
        // The name matters as much as the id: an absent device can only be offered by name.
        assert_eq!(back[1].name, "AirPods");

        // An empty set must not overwrite it, or stopping would erase what to offer.
        remember_to(&p, &[]);
        assert_eq!(last_from(&p).len(), 2);

        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn the_two_files_are_not_the_same_file() {
        // `clear` removes the first one only. If these ever collide, stopping the mirror
        // would take the last set with it.
        assert_ne!(
            path()
                .ok()
                .and_then(|p| p.file_name().map(|f| f.to_owned())),
            last_path()
                .ok()
                .and_then(|p| p.file_name().map(|f| f.to_owned())),
        );
    }
}
