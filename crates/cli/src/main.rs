//! Command line interface.
//!
//! Built before the graphical one on purpose: this is where it is decided whether the
//! feature works at all. A picker on top of broken mechanics helps nobody.
//!
//! Script friendliness is a design goal, not an afterthought:
//!   * every subcommand that reports something accepts `--json`
//!   * `status --quiet` exits 0 while mirroring and 1 otherwise, so it can drive an `if`
//!   * all human-readable output goes to stdout, all errors to stderr
//!   * exit code 1 means failure, always

use anyhow::Result;
use mirrik_core::{find_device, Device, MirrorBackend, Transport, VOLUME_MAX};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "mirrik",
    about = "Play the same audio on your current output device and one or more others",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List output devices
    Devices {
        /// Machine-readable output
        #[arg(long)]
        json: bool,
    },
    /// Start mirroring to one or more devices, replacing any current selection
    On {
        /// Device names; a unique part of the name is enough, e.g. "airpods"
        #[arg(required = true)]
        targets: Vec<String>,
        #[arg(long)]
        json: bool,
    },
    /// Add one more destination to a running mirror
    Add {
        target: String,
        #[arg(long)]
        json: bool,
    },
    /// Remove one destination, keeping the others
    Remove {
        target: String,
        #[arg(long)]
        json: bool,
    },
    /// Stop mirroring entirely
    Off,
    /// Show what is running
    Status {
        #[arg(long)]
        json: bool,
        /// Print nothing; exit 0 if mirroring, 1 if not
        #[arg(long, short)]
        quiet: bool,
    },
    /// Read or set the volume of a device (0-100)
    Volume {
        device: String,
        percent: Option<u32>,
        #[arg(long)]
        json: bool,
    },
    /// Add the device if absent, remove it if present
    Toggle {
        target: String,
        #[arg(long)]
        json: bool,
    },
    /// Internal: keep one destination alive. Started by `on`/`add`, never typed by hand.
    ///
    /// This process *is* the mirror — killing it is how a destination goes away, which is
    /// the same guarantee the PipeWire module gives by dying with its owner.
    #[cfg(target_os = "windows")]
    #[command(hide = true)]
    Hold { target: String },
}

#[cfg(target_os = "linux")]
fn backend() -> Result<impl MirrorBackend> {
    mirrik_backend_linux::PipeWireBackend::new()
}

#[cfg(target_os = "windows")]
fn backend() -> Result<impl MirrorBackend> {
    mirrik_backend_windows::WasapiBackend::new()
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("no backend for this operating system yet (see windows-portierung.md)");

/// Was this started by double-clicking the file rather than from a shell?
///
/// Windows gives a double-clicked console program a console of its very own, and this
/// program is then the only thing attached to it. Started from an existing shell, that
/// shell is attached too, so the count is at least two.
///
/// Worth the check because the alternative is a black window that flashes up and vanishes
/// with a usage message nobody can read — a rotten first impression for someone who just
/// downloaded the thing and picked the file without the `-gui` in its name.
#[cfg(target_os = "windows")]
fn launched_from_explorer() -> bool {
    use windows::Win32::System::Console::GetConsoleProcessList;
    let mut pids = [0u32; 2];
    unsafe { GetConsoleProcessList(&mut pids) == 1 }
}

/// The window binary next door, if it is there at all.
#[cfg(target_os = "windows")]
fn gui_beside_us() -> Option<std::path::PathBuf> {
    let gui = std::env::current_exe()
        .ok()?
        .with_file_name("mirrik-gui.exe");
    gui.is_file().then_some(gui)
}

/// Drops the console window Windows handed us on the way in.
///
/// It cannot be prevented outright — a console program gets its console before any of this
/// code runs, so a brief flash remains. Avoiding even that would mean building as a GUI
/// subsystem binary and re-attaching to the parent console when run from a shell, which
/// buys a few milliseconds at the price of a command line that no longer behaves like one.
#[cfg(target_os = "windows")]
fn drop_the_console() {
    use windows::Win32::System::Console::GetConsoleWindow;
    use windows::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_HIDE};

    unsafe {
        let console = GetConsoleWindow();
        if !console.is_invalid() {
            let _ = ShowWindow(console, SW_HIDE);
        }
    }
}

/// Hands over to the window next door, so the double-click does something useful.
#[cfg(target_os = "windows")]
fn open_the_window(gui: std::path::PathBuf) -> Result<()> {
    use anyhow::Context;
    // Console first: the window takes a moment to appear, and until then this black box
    // would be the only thing on screen.
    drop_the_console();
    std::process::Command::new(&gui)
        .spawn()
        .with_context(|| format!("cannot start {}", gui.display()))?;
    Ok(())
}

fn json_device(d: &Device) -> serde_json::Value {
    serde_json::json!({
        "id": d.id.0,
        "name": d.name,
        "is_default": d.is_default,
        "volume_percent": (d.volume * 100.0).round() as u32,
        "volume_scope": format!("{:?}", d.volume_scope),
        "transport": d.transport.label(),
    })
}

fn main() -> Result<()> {
    // Someone who downloaded this and double-clicked the file without `-gui` in its name
    // gets the window instead of a black box. Only with no arguments at all: `hold` and
    // every real command must keep working exactly as before.
    //
    // The GUI is looked up before the console is touched — if there is none, the usage
    // message stays readable rather than being hidden along with the window.
    #[cfg(target_os = "windows")]
    if std::env::args_os().len() == 1 && launched_from_explorer() {
        if let Some(gui) = gui_beside_us() {
            open_the_window(gui)?;
            return Ok(());
        }
    }

    let cli = Cli::parse();

    // Handled before the backend exists: the holder owns no shared state and must not
    // run the cleanup below, which would tidy away the very mirror it is about to open.
    #[cfg(target_os = "windows")]
    if let Command::Hold { target } = &cli.command {
        // Never set — the loop ends when the process is terminated, and that is the
        // point: the mirror lives exactly as long as this process does.
        let stop = std::sync::atomic::AtomicBool::new(false);
        return mirrik_backend_windows::mirror::run(target, &stop);
    }

    let mut b = backend()?;

    // Safety net before every command: clear leftovers of a crashed run instead of
    // stacking a second mirror next to the first.
    b.cleanup_stale()?;
    // And pick up destinations that came back while nothing was running.
    b.reconcile()?;

    match cli.command {
        Command::Devices { json } => {
            let devices = b.devices()?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "devices": devices.iter().map(json_device).collect::<Vec<_>>()
                    }))?
                );
            } else {
                for d in &devices {
                    let mark = if d.is_default { "*" } else { " " };
                    println!("{mark} {}  [{}]\n    {}", d.name, d.transport.label(), d.id);
                }
            }
        }

        Command::On { targets, json } => {
            let devices = b.devices()?;
            // Resolve every name first: failing halfway through would leave a partial
            // mirror that the user did not ask for.
            let ids: Vec<_> = targets
                .iter()
                .map(|t| find_device(&devices, t).map(|d| d.id.clone()))
                .collect::<Result<_>>()?;
            b.stop_all()?;
            for id in &ids {
                b.add_target(id)?;
            }
            report(&mut b, json)?;
        }

        Command::Add { target, json } => {
            let devices = b.devices()?;
            let id = find_device(&devices, &target)?.id.clone();
            b.add_target(&id)?;
            report(&mut b, json)?;
        }

        Command::Remove { target, json } => {
            // A destination whose device is gone cannot be looked up in the device list —
            // and that is precisely when someone wants to remove it. The running mirror
            // knows it by id and by the name written down when it was switched on, so ask
            // there before giving up.
            let devices = b.devices()?;
            let id = match find_device(&devices, &target) {
                Ok(d) => d.id.clone(),
                Err(e) => {
                    let needle = target.to_lowercase();
                    b.status()?
                        .into_iter()
                        .flat_map(|m| m.targets)
                        .find(|t| {
                            t.device.0.to_lowercase().contains(&needle)
                                || t.label().to_lowercase().contains(&needle)
                        })
                        .map(|t| t.device)
                        .ok_or(e)?
                }
            };
            b.remove_target(&id)?;
            report(&mut b, json)?;
        }

        Command::Off => {
            let was_running = b.status()?.is_some();
            b.stop_all()?;
            println!(
                "{}",
                if was_running {
                    "Mirroring stopped."
                } else {
                    "Nothing was mirroring."
                }
            );
        }

        Command::Status { json, quiet } => {
            let running = b.status()?.is_some();
            if quiet {
                std::process::exit(if running { 0 } else { 1 });
            }
            report(&mut b, json)?;
        }

        Command::Volume {
            device,
            percent,
            json,
        } => {
            let devices = b.devices()?;
            let d = find_device(&devices, &device)?.clone();
            if let Some(p) = percent {
                let v = (p as f32 / 100.0).clamp(0.0, VOLUME_MAX);
                b.set_volume(&d.id, v)?;
            }
            // Read back rather than echo what we sent: the device decides.
            let after = b.devices()?;
            let d = find_device(&after, &d.id.0)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&json_device(d))?);
            } else {
                println!("{}  {} %", d.name, (d.volume * 100.0).round() as u32);
            }
        }

        Command::Toggle { target, json } => {
            let devices = b.devices()?;
            let id = find_device(&devices, &target)?.id.clone();
            let active = b.status()?.map(|m| m.has_target(&id)).unwrap_or(false);
            if active {
                b.remove_target(&id)?;
            } else {
                b.add_target(&id)?;
            }
            report(&mut b, json)?;
        }

        // Already handled above, before the backend was built.
        #[cfg(target_os = "windows")]
        Command::Hold { .. } => unreachable!(),
    }

    Ok(())
}

/// Single place that prints "what is running now", so every command agrees.
fn report(b: &mut impl MirrorBackend, json: bool) -> Result<()> {
    let mirror = b.status()?;
    let devices = b.devices()?;
    let name = |id: &mirrik_core::DeviceId| {
        devices
            .iter()
            .find(|d| d.id == *id)
            .map(|d| d.name.clone())
            .unwrap_or_else(|| id.0.clone())
    };

    match mirror {
        None => {
            if json {
                println!("{}", serde_json::json!({ "mirroring": false }));
            } else {
                println!("Not mirroring.");
            }
        }
        Some(m) => {
            let targets: Vec<_> = m
                .targets
                .iter()
                .map(|t| {
                    let d = devices.iter().find(|d| d.id == t.device);
                    // A destination that is not in the device list right now is not gone
                    // for good: the holder survives, and the mirror picks up again by
                    // itself when the device comes back. What must not happen is claiming
                    // a latency for a device nobody can measure — that used to print
                    // "~0 ms" for the very Bluetooth headphones that add 200.
                    let latency = d.map(|d| b.target_latency_ms(d)).transpose()?;
                    Ok(serde_json::json!({
                        "id": t.device.0,
                        // The name written down when it was switched on, so an absent
                        // device is still recognisable.
                        "name": d.map(|d| d.name.clone()).unwrap_or_else(|| t.label().to_string()),
                        "present": d.is_some(),
                        "transport": d.map(|d| d.transport.label()),
                        "latency_ms": latency,
                        "holder_pid": t.holder_pid,
                    }))
                })
                .collect::<Result<_>>()?;

            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "mirroring": true,
                        "source": { "id": m.source.0, "name": name(&m.source) },
                        "targets": targets,
                    }))?
                );
            } else {
                println!("Mirroring from: {}", name(&m.source));
                for t in &targets {
                    let label = t["name"].as_str().unwrap_or("");
                    match t["latency_ms"].as_u64() {
                        Some(ms) => println!("  -> {label}  (~{ms} ms behind)"),
                        // Device currently away. Saying "waiting" rather than printing a
                        // number nobody measured, and rather than dropping the line, which
                        // would suggest the destination had been forgotten.
                        None => println!("  -> {label}  (waiting for the device)"),
                    }
                    if t["transport"].as_str() == Some(Transport::Bluetooth.label()) {
                        println!("     note: Bluetooth adds buffering; the offset is an estimate");
                    }
                }
            }
        }
    }
    Ok(())
}
