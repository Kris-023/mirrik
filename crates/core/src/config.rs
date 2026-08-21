//! Optional settings file.
//!
//! Mirrik works with no configuration at all, and that is the normal case. This module
//! only exists so that the day a setting is genuinely needed, it can be added without
//! also having to invent where settings live, how they are parsed and what happens when
//! the file is broken.
//!
//! Three rules hold it together, and each one is load-bearing:
//!
//! 1. **Absent means default.** No file is not an error and not a warning. Someone who
//!    never writes one should never learn that the mechanism is here.
//! 2. **Mirrik never writes it.** The file belongs to whoever created it. That is what
//!    keeps it out of the uninstall list for everybody else, and it is why `install.sh`
//!    names it separately and only when it is really there.
//! 3. **Unknown keys are ignored.** A config written for a later version has to keep
//!    working on an earlier one, or downgrading silently breaks the program.
//!
//! A broken file is the one case that speaks up: it warns on stderr and carries on with
//! defaults, because refusing to start over a settings file would be a worse failure
//! than ignoring it.
//!
//! ## Adding the first setting
//!
//! Give [`Config`] a field with `#[serde(default)]` and a matching entry in
//! [`Default`]. Nothing else changes — parsing, discovery and the fallback path already
//! behave.
//!
//! ```ignore
//! pub struct Config {
//!     #[serde(default)]
//!     pub some_setting: bool,
//! }
//! ```

use std::path::PathBuf;

use serde::Deserialize;

/// File name inside the config directory.
///
/// Kept next to [`Config::path`] rather than inlined, because `install.sh` prints this
/// exact path in its removal block and the two have to agree.
pub const FILE_NAME: &str = "config.toml";

/// Settings read from `config.toml`, or the defaults when there is no such file.
///
/// Deliberately empty for now — see the module docs. `serde` ignores keys it does not
/// know, so a file written for a later version parses here without complaint.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Config {}

impl Config {
    /// Where the file is looked for.
    ///
    /// Follows the XDG base directory spec on Linux (`$XDG_CONFIG_HOME`, falling back to
    /// `~/.config`) and `%APPDATA%` on Windows. Returns `None` only when neither the
    /// config directory nor a home directory can be determined at all, which in practice
    /// means an environment with no `HOME` — there is nothing sensible to guess there.
    pub fn path() -> Option<PathBuf> {
        Self::dir().map(|d| d.join(FILE_NAME))
    }

    /// The directory the file lives in, without appending the file name.
    pub fn dir() -> Option<PathBuf> {
        #[cfg(windows)]
        let base = std::env::var_os("APPDATA").map(PathBuf::from);

        #[cfg(not(windows))]
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")));

        base.map(|b| b.join("mirrik"))
    }

    /// Reads the file if it is there, otherwise returns the defaults.
    ///
    /// Never fails: a missing file is the normal case, and a broken one warns on stderr
    /// and yields defaults rather than stopping the program.
    pub fn load() -> Self {
        match Self::path() {
            Some(p) => Self::load_from(&p),
            None => Self::default(),
        }
    }

    /// [`Config::load`] against one specific path. Exists so tests can point it
    /// somewhere that is not the caller's real home directory.
    pub fn load_from(path: &std::path::Path) -> Self {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            // Not found is the normal case and stays silent. Anything else - unreadable,
            // a directory where a file was expected - is worth one line, because the
            // person who put a file there deserves to know it was not used.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Self::default(),
            Err(e) => {
                eprintln!(
                    "mirrik: cannot read {}: {e}. Using defaults.",
                    path.display()
                );
                return Self::default();
            }
        };
        Self::parse(&text, &path.display().to_string())
    }

    /// Parses config text. `origin` only ever appears in the warning.
    pub fn parse(text: &str, origin: &str) -> Self {
        match toml::from_str(text) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("mirrik: {origin} is not valid TOML: {e}. Using defaults.");
                Self::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_is_not_an_error() {
        let dir = std::env::temp_dir().join("mirrik-cfg-missing");
        assert_eq!(Config::load_from(&dir.join("nope.toml")), Config::default());
    }

    #[test]
    fn empty_file_is_the_default() {
        assert_eq!(Config::parse("", "test"), Config::default());
    }

    #[test]
    fn unknown_keys_are_ignored() {
        // The forward-compatibility promise: a file written by a later version must not
        // stop an earlier one from starting.
        let from_the_future = "shiny_new_setting = true\n[section]\nnested = \"yes\"\n";
        assert_eq!(Config::parse(from_the_future, "test"), Config::default());
    }

    #[test]
    fn broken_file_falls_back_instead_of_failing() {
        assert_eq!(
            Config::parse("this is not = = toml", "test"),
            Config::default()
        );
    }

    #[test]
    #[cfg(not(windows))]
    fn xdg_config_home_wins_over_home() {
        // Both are read from the process environment, so this test cannot run in
        // parallel with another that touches them - it sets both itself and asserts the
        // precedence in one go.
        let old_xdg = std::env::var_os("XDG_CONFIG_HOME");
        let old_home = std::env::var_os("HOME");

        // Both stand-ins are deliberately outside any real home directory: this only
        // ever checks how the path is assembled, so pointing at somebody's actual home
        // would add nothing and put a personal path in a public repository.
        let fake_home = "/nonexistent/mirrik-test-home";
        unsafe {
            std::env::set_var("HOME", fake_home);
            std::env::set_var("XDG_CONFIG_HOME", "/nonexistent/mirrik-test-xdg");
        }
        assert_eq!(
            Config::dir(),
            Some(PathBuf::from("/nonexistent/mirrik-test-xdg/mirrik"))
        );

        // A relative XDG_CONFIG_HOME is invalid per the spec and has to be ignored,
        // otherwise the path lands wherever the program happens to be running.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", "relative/path") }
        assert_eq!(
            Config::dir(),
            Some(PathBuf::from(fake_home).join(".config").join("mirrik"))
        );

        unsafe {
            std::env::remove_var("XDG_CONFIG_HOME");
            match old_xdg {
                Some(v) => std::env::set_var("XDG_CONFIG_HOME", v),
                None => std::env::remove_var("XDG_CONFIG_HOME"),
            }
            match old_home {
                Some(v) => std::env::set_var("HOME", v),
                None => std::env::remove_var("HOME"),
            }
        }
    }

    #[test]
    fn the_file_name_matches_what_the_installer_prints() {
        // install.sh names ~/.config/mirrik/config.toml in its removal block. If this
        // ever changes, that line has to change with it.
        assert_eq!(FILE_NAME, "config.toml");
    }
}
