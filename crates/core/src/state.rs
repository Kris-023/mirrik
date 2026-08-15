//! Where a running mirror is recorded.
//!
//! `$XDG_STATE_HOME/mirrik/mirror.json` (default `~/.local/state/mirrik/`),
//! on Windows `%LOCALAPPDATA%\mirrik\`. Deliberately **not** in the config
//! directory: this is runtime bookkeeping and is cleaned up rather than restored.

use crate::Mirror;
use anyhow::{Context, Result};
use std::path::PathBuf;

pub fn path() -> Result<PathBuf> {
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
    Ok(base.join("mirrik").join("mirror.json"))
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
        .with_context(|| format!("cannot write {}", p.display()))
}

pub fn clear() -> Result<()> {
    let p = path()?;
    match std::fs::remove_file(&p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("cannot remove {}", p.display())),
    }
}
