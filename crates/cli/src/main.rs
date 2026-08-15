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
    let cli = Cli::parse();
    let mut b = backend()?;

    // Safety net before every command: clear leftovers of a crashed run instead of
    // stacking a second mirror next to the first.
    b.cleanup_stale()?;

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
            let devices = b.devices()?;
            let id = find_device(&devices, &target)?.id.clone();
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
                    let latency = d.map(|d| b.target_latency_ms(d)).transpose()?.unwrap_or(0);
                    Ok(serde_json::json!({
                        "id": t.device.0,
                        "name": name(&t.device),
                        "transport": d.map(|d| d.transport.label()).unwrap_or("other"),
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
                    let ms = t["latency_ms"].as_u64().unwrap_or(0);
                    println!(
                        "  -> {}  (~{ms} ms behind)",
                        t["name"].as_str().unwrap_or("")
                    );
                    if t["transport"].as_str() == Some(Transport::Bluetooth.label()) {
                        println!("     note: Bluetooth adds buffering; the offset is an estimate");
                    }
                }
            }
        }
    }
    Ok(())
}
