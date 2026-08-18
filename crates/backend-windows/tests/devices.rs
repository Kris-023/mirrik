//! Checks the device model against whatever hardware this machine has.
//!
//! Deliberately not mocked. The whole point of stage 1 is to find out what real endpoints
//! report — a fake enumerator would only confirm the assumptions that need checking.
//!
//! Doubles as the measurement tool for stage 2:
//!
//! ```text
//! cargo test -p mirrik-backend-windows -- --nocapture
//! ```
//!
//! prints the mix format of every output, which is what decides whether a captured
//! stream can be handed to a target unchanged.

use mirrik_backend_windows::WasapiBackend;
use mirrik_core::MirrorBackend;

#[test]
fn describes_the_machines_outputs() {
    let b = match WasapiBackend::new() {
        Ok(b) => b,
        // A machine without an audio stack is not a failing test, it is a machine
        // this test cannot say anything about.
        Err(e) => {
            eprintln!("no WASAPI available, skipping: {e}");
            return;
        }
    };

    let devices = b.devices().expect("enumerating outputs must not fail");
    if devices.is_empty() {
        eprintln!("no active output devices, skipping");
        return;
    }

    // Exactly one default: zero means the CLI cannot tell the user where sound goes,
    // more than one means the comparison against the default id is broken.
    let defaults = devices.iter().filter(|d| d.is_default).count();
    assert_eq!(defaults, 1, "expected exactly one default output");

    for d in &devices {
        assert!(!d.name.is_empty(), "every device needs a display name");
        assert!(
            d.id.0.contains('{'),
            "endpoint id looks malformed: {}",
            d.id
        );
        assert!(
            (0.0..=1.0).contains(&d.volume),
            "volume out of range on {}: {}",
            d.name,
            d.volume
        );
    }

    let caps = b.capabilities().expect("capabilities must not fail");
    assert!(
        caps.base_latency_ms > 0,
        "base latency is computed from the device period and cannot be zero"
    );
    // The loopback approach never materialises a device — if this ever flips, the
    // interface would be promising something the backend no longer delivers.
    assert!(!caps.creates_virtual_device);
    assert!(!caps.changes_default_device);

    println!(
        "\nbase latency: {} ms (2 x device period)",
        caps.base_latency_ms
    );
    println!("{:<46} {:>7}  {:>5}  transport", "device", "rate", "bits");
    for d in &devices {
        let fmt = match b.mix_format(&d.id) {
            Ok((rate, bits, ch)) => format!("{rate:>7} {bits:>5}  {ch}ch"),
            Err(e) => format!("unavailable: {e}"),
        };
        let mark = if d.is_default { '*' } else { ' ' };
        println!("{mark}{:<45} {fmt}  {}", d.name, d.transport.label());
    }
}
