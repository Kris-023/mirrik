//! Control window.
//!
//! The window shows **state first** and possibilities second. At a glance the user has to
//! see whether a mirror is running, where to, and what will happen on the next keystroke.
//!
//! Destinations are a multi-selection: Enter adds a device, Enter on an active device
//! removes it. Every active destination gets its own volume slider.
//!
//! # Keyboard contract
//!
//! The focus walks over *everything*, sliders included — an interface where parts are
//! reachable only with the mouse is not one.
//!
//!   Down / Up, or j / k    move focus (sliders and devices in one chain)
//!   Right / Left, or l / h  adjust the focused slider in 5 % steps
//!   1 … 9                  toggle that device directly
//!   Enter                  on a device: add it, or remove it if already active
//!   x                      stop mirroring entirely
//!   Esc / q                close without changing anything
//!
//! # Window placement
//!
//! Two paths, because the platforms genuinely differ:
//!   * **Windows and X11** — the window centres itself on the monitor it opened on.
//!   * **Wayland** — clients may not position themselves, by design. The request is
//!     skipped explicitly (checked via `WAYLAND_DISPLAY`) and a compositor rule does the
//!     job; rules for the common compositors belong in the README. Verified on Hyprland:
//!     the rule centres on the *focused* monitor, which is the better behaviour on a
//!     multi-head setup anyway.
//!
//! No text in this file may rely on glyphs beyond ASCII plus what the bundled font
//! actually has: arrows and filled circles render as empty boxes. Status dots are painted.

use mirrik_core::{
    Capabilities, Device, DeviceId, MirrorBackend, Transport, VolumeScope, VOLUME_MAX,
};
use eframe::egui;
use std::time::{Duration, Instant};

/// How often state is re-read from the system while the window is open.
///
/// Volume can change from outside — from a panel applet, from `pactl`, or from a hardware
/// dial such as the Digital Crown on AirPods Max. Without this the window would show the
/// values it saw when it opened.
const TICK: Duration = Duration::from_millis(600);

/// Step size when adjusting a slider from the keyboard.
const STEP: f32 = 0.05;

/// Fixed window width. The height follows the content, see the resize block in `ui()`.
const WIDTH: f32 = 500.0;

const GREEN: egui::Color32 = egui::Color32::from_rgb(80, 190, 120);
const FOCUS: egui::Color32 = egui::Color32::from_rgb(120, 170, 255);
const AMBER: egui::Color32 = egui::Color32::from_rgb(230, 170, 70);
const RED: egui::Color32 = egui::Color32::from_rgb(220, 80, 80);

/// Paints a status dot instead of setting one as text.
///
/// The bundled egui font has neither a filled circle nor arrows; they show up as empty
/// boxes. Anything painted is independent of the font.
fn dot(ui: &mut egui::Ui, colour: egui::Color32, filled: bool) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(14.0, 14.0), egui::Sense::hover());
    if filled {
        ui.painter().circle_filled(rect.center(), 5.0, colour);
    } else {
        ui.painter()
            .circle_stroke(rect.center(), 5.0, egui::Stroke::new(1.5, colour));
    }
}

/// What the keyboard currently points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Focus {
    /// Slider of the source device.
    Source,
    /// Slider of the nth active destination.
    Target(usize),
    /// Entry n in the device list.
    Device(usize),
}

#[cfg(target_os = "linux")]
fn backend() -> anyhow::Result<impl MirrorBackend> {
    mirrik_backend_linux::PipeWireBackend::new()
}

#[cfg(target_os = "windows")]
fn backend() -> anyhow::Result<impl MirrorBackend> {
    mirrik_backend_windows::WasapiBackend::new()
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("no backend for this operating system yet (see windows-portierung.md)");

fn main() -> eframe::Result<()> {
    let mut b = match backend() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{e:#}");
            std::process::exit(1);
        }
    };

    if let Err(e) = b.cleanup_stale() {
        eprintln!("cleanup failed: {e:#}");
    }

    let app = match Window::new(b) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e:#}");
            std::process::exit(1);
        }
    };

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([WIDTH, app.initial_height()])
            // Must stay resizable: with `false` the window manager also rejects the
            // program's own `InnerSize` request, and the window keeps the height it had
            // when it opened — so adding a destination pushed the list off the bottom.
            // Nobody is expected to drag this window; the height is driven from the code.
            .with_resizable(true)
            .with_decorations(false)
            .with_always_on_top()
            // Read by window rules as `class` (Wayland/X11) and used as the window class
            // on Windows.
            .with_app_id("mirrik"),
        ..Default::default()
    };

    eframe::run_native(
        "mirrik",
        options,
        Box::new(move |_cc| Ok(Box::new(app))),
    )
}

struct Window<B: MirrorBackend> {
    backend: B,
    devices: Vec<Device>,
    source: DeviceId,
    /// Active destinations, in the order they were added.
    targets: Vec<DeviceId>,
    caps: Capabilities,
    focus: Focus,
    error: Option<String>,
    last_poll: Instant,
    /// Self-centring is attempted once; on Wayland it is skipped entirely.
    centred: bool,
    /// Height last requested from the window manager, to avoid asking every frame.
    height: f32,
    /// Set whenever the focus moves, so the next frame scrolls it into view.
    reveal_focus: bool,
}

impl<B: MirrorBackend> Window<B> {
    fn new(backend: B) -> anyhow::Result<Self> {
        let caps = backend.capabilities()?;
        let mut w = Self {
            backend,
            devices: Vec::new(),
            source: DeviceId(String::new()),
            targets: Vec::new(),
            caps,
            // Deliberately not starting on a device: a highlighted entry while nothing is
            // mirroring reads as if something were already active there.
            focus: Focus::Source,
            error: None,
            last_poll: Instant::now(),
            centred: false,
            height: 0.0,
            reveal_focus: false,
        };
        w.refresh()?;
        if w.selectable().is_empty() {
            anyhow::bail!("only one output device — nothing to mirror to");
        }
        Ok(w)
    }

    fn refresh(&mut self) -> anyhow::Result<()> {
        self.devices = self.backend.devices()?;
        self.source = self.backend.default_device()?.id;
        self.targets = self
            .backend
            .status()?
            .map(|m| m.targets.into_iter().map(|t| t.device).collect())
            .unwrap_or_default();
        self.last_poll = Instant::now();
        let chain = self.focus_chain();
        if !chain.contains(&self.focus) {
            self.focus = Focus::Source;
        }
        Ok(())
    }

    /// The source never appears as a destination — mirroring onto itself is a loop.
    fn selectable(&self) -> Vec<&Device> {
        self.devices
            .iter()
            .filter(|d| d.id != self.source)
            .collect()
    }

    fn device(&self, id: &DeviceId) -> Option<&Device> {
        self.devices.iter().find(|d| d.id == *id)
    }

    fn mirroring(&self) -> bool {
        !self.targets.is_empty()
    }

    fn focus_chain(&self) -> Vec<Focus> {
        let mut c = vec![Focus::Source];
        c.extend((0..self.targets.len()).map(Focus::Target));
        c.extend((0..self.selectable().len()).map(Focus::Device));
        c
    }

    fn move_focus(&mut self, delta: i32) {
        let chain = self.focus_chain();
        let i = chain.iter().position(|f| *f == self.focus).unwrap_or(0) as i32;
        let n = chain.len() as i32;
        self.focus = chain[(((i + delta) % n + n) % n) as usize];
        self.reveal_focus = true;
    }

    fn focused_device(&self) -> Option<DeviceId> {
        match self.focus {
            Focus::Source => Some(self.source.clone()),
            Focus::Target(i) => self.targets.get(i).cloned(),
            Focus::Device(_) => None,
        }
    }

    fn nudge_volume(&mut self, delta: f32) {
        let Some(id) = self.focused_device() else {
            return;
        };
        let Some(old) = self.device(&id).map(|d| d.volume) else {
            return;
        };
        self.set_volume(&id, (old + delta).clamp(0.0, VOLUME_MAX));
    }

    fn set_volume(&mut self, id: &DeviceId, value: f32) {
        match self.backend.set_volume(id, value) {
            Ok(()) => {
                if let Some(d) = self.devices.iter_mut().find(|d| d.id == *id) {
                    d.volume = value;
                }
                self.error = None;
            }
            Err(e) => self.error = Some(format!("{e:#}")),
        }
    }

    /// Enter or click on a list entry: add the destination, or remove it if active.
    fn toggle(&mut self, n: usize) {
        let Some(id) = self.selectable().get(n).map(|d| d.id.clone()) else {
            return;
        };
        let result = if self.targets.contains(&id) {
            self.backend.remove_target(&id)
        } else {
            self.backend.add_target(&id)
        };
        self.apply(result);
    }

    fn stop(&mut self) {
        if !self.mirroring() {
            return;
        }
        let r = self.backend.stop_all();
        self.apply(r);
    }

    fn apply(&mut self, r: anyhow::Result<()>) {
        match r {
            Ok(()) => {
                self.error = None;
                if let Err(e) = self.refresh() {
                    self.error = Some(format!("{e:#}"));
                }
            }
            Err(e) => self.error = Some(format!("{e:#}")),
        }
    }

    /// Height the window is created with.
    ///
    /// Sized for the current state **plus one more destination**, because on compositors
    /// that ignore resize requests this is the only chance to get it right, and adding one
    /// device is by far the most common thing to do in an open window. Sizing for the full
    /// worst case was tried first and left roughly half the window empty while idle;
    /// sizing for the exact current state made the list scroll as soon as anything was
    /// added. Anything beyond one extra device is caught by the scroll area.
    fn initial_height(&self) -> f32 {
        let list = self.selectable().len() as f32;
        let assumed = (self.targets.len() as f32 + 1.0).min(list);
        let sliders = 1.0 + assumed;
        let head = 64.0 + 18.0 * assumed;
        head + 56.0 * sliders + 32.0 * list + 80.0
    }

    /// One slider with its label. Returns true when the user let go of it.
    fn slider(&mut self, ui: &mut egui::Ui, id: &DeviceId, focused: bool) -> bool {
        let Some(d) = self.device(id).cloned() else {
            return false;
        };
        let mut value = d.volume;

        // The explanation comes from the backend, never from this file: whether a slider
        // also changes mirrored copies depends on where the driver applies gain, and that
        // differs per device and per platform.
        let hint = self.backend.volume_hint(&d, self.mirroring());
        // Three words: two truncate "AD103 High Definition" to "AD103 High", which reads
        // like a typo. The full name would not fit next to the hint.
        let title = d
            .name
            .split_whitespace()
            .take(3)
            .collect::<Vec<_>>()
            .join(" ");

        ui.horizontal(|ui| {
            let t = egui::RichText::new(title).strong();
            // Focus is shown through colour, not a marker character.
            ui.label(if focused { t.color(FOCUS) } else { t });
            let h = egui::RichText::new(format!("— {hint}")).weak().small();
            ui.label(
                if d.volume_scope == VolumeScope::AffectsMirror && self.mirroring() {
                    h.color(AMBER)
                } else {
                    h
                },
            );
        });

        let response = ui.add(
            egui::Slider::new(&mut value, 0.0..=VOLUME_MAX)
                .custom_formatter(|v, _| format!("{:.0} %", v * 100.0))
                .show_value(true),
        );
        if response.changed() {
            self.set_volume(id, value);
        }
        if focused && self.reveal_focus {
            response.scroll_to_me(None);
            self.reveal_focus = false;
        }
        response.drag_stopped()
    }
}

impl<B: MirrorBackend> eframe::App for Window<B> {
    // eframe 0.36 hands the app a ready-made `Ui` instead of a `Context`.
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();

        let mut toggle: Option<usize> = None;
        let mut stop = false;
        let mut close = false;
        let mut step = 0i32;
        let mut louder = 0.0f32;

        // NOTE: no ctx call that locks the context again may appear inside this closure.
        // `ctx.input()` holds the input lock, and a `ctx.send_viewport_cmd()` in here
        // freezes the window — the first version deadlocked exactly like that on Esc.
        // Only intentions are recorded here; they are carried out afterwards.
        ctx.input(|i| {
            if i.key_pressed(egui::Key::Escape) || i.key_pressed(egui::Key::Q) {
                close = true;
            }
            if i.key_pressed(egui::Key::ArrowDown) || i.key_pressed(egui::Key::J) {
                step += 1;
            }
            if i.key_pressed(egui::Key::ArrowUp) || i.key_pressed(egui::Key::K) {
                step -= 1;
            }
            if i.key_pressed(egui::Key::ArrowRight) || i.key_pressed(egui::Key::L) {
                louder += STEP;
            }
            if i.key_pressed(egui::Key::ArrowLeft) || i.key_pressed(egui::Key::H) {
                louder -= STEP;
            }
            for (n, key) in [
                egui::Key::Num1,
                egui::Key::Num2,
                egui::Key::Num3,
                egui::Key::Num4,
                egui::Key::Num5,
                egui::Key::Num6,
                egui::Key::Num7,
                egui::Key::Num8,
                egui::Key::Num9,
            ]
            .into_iter()
            .enumerate()
            {
                if i.key_pressed(key) {
                    toggle = Some(n);
                }
            }
            if i.key_pressed(egui::Key::Enter) {
                if let Focus::Device(n) = self.focus {
                    toggle = Some(n);
                }
            }
            if i.key_pressed(egui::Key::X) {
                stop = true;
            }
        });

        if close {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }

        // Centre once, on the platforms where a client is allowed to.
        //
        // Wayland forbids clients from positioning themselves, so the request is skipped
        // explicitly rather than relying on it being ignored — that keeps the behaviour
        // the same across compositors instead of depending on what each one reports.
        // Verified on Hyprland: the compositor rule places the window centred on the
        // focused monitor, which is what we want anyway on a multi-head setup.
        if !self.centred && std::env::var_os("WAYLAND_DISPLAY").is_some() {
            self.centred = true;
        }
        if !self.centred {
            let (monitor, outer) =
                ctx.input(|i| (i.viewport().monitor_size, i.viewport().outer_rect));
            if let (Some(m), Some(o)) = (monitor, outer) {
                let pos = egui::pos2((m.x - o.width()) * 0.5, (m.y - o.height()) * 0.5);
                ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(pos));
                self.centred = true;
            }
        }

        if step != 0 {
            self.move_focus(step);
        }
        if louder != 0.0 {
            self.nudge_volume(louder);
        }

        // Pick up changes made outside this window. Not while a slider is being dragged,
        // or the poll fights the mouse.
        if self.last_poll.elapsed() >= TICK && ctx.dragged_id().is_none() {
            if let Err(e) = self.refresh() {
                self.error = Some(format!("{e:#}"));
            }
        }
        // Without this egui goes to sleep and only notices outside changes on the next click.
        ctx.request_repaint_after(TICK);

        // Scrollable, because the window cannot be trusted to grow.
        //
        // The height is fixed when the window is created. Adding a destination adds a
        // slider, so the content gets taller than the window and the list used to run off
        // the bottom edge. The obvious fix — asking for a new size — does not work
        // everywhere: verified on Hyprland/Wayland, even a request for 700 px is ignored
        // (the window stayed at its initial 278). The request below is still sent because
        // X11 and Windows do honour it and then no scrollbar ever appears; but nothing
        // depends on it succeeding.
        let width = ui.available_width() - 28.0;
        let mut content = 0.0;
        egui::ScrollArea::vertical()
            .auto_shrink([false; 2])
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.add_space(14.0);
                    ui.vertical(|ui| {
                        ui.set_max_width(width);
                        self.body(ui);
                        content = ui.min_rect().height();
                    });
                });
            });

        let wanted = content + 24.0;
        if (wanted - self.height).abs() > 1.0 {
            self.height = wanted;
            ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(WIDTH, wanted)));
        }

        // Actions last: they change the state the frame was drawn from.
        if let Some(n) = toggle {
            if n < self.selectable().len() {
                self.focus = Focus::Device(n);
                self.toggle(n);
            }
        } else if stop {
            self.stop();
        }
    }
}

impl<B: MirrorBackend> Window<B> {
    fn body(&mut self, ui: &mut egui::Ui) {
        ui.add_space(10.0);
        let source_name = self
            .device(&self.source)
            .map(|d| d.name.clone())
            .unwrap_or_else(|| self.source.0.clone());

        // ---- header: the state, always first ----
        if self.mirroring() {
            ui.horizontal(|ui| {
                dot(ui, GREEN, true);
                let n = self.targets.len();
                let text = if n == 1 {
                    "Mirroring".to_string()
                } else {
                    format!("Mirroring to {n} devices")
                };
                ui.label(egui::RichText::new(text).strong().size(16.0).color(GREEN));
            });
            ui.add_space(4.0);
            ui.label(egui::RichText::new(format!("from   {source_name}")).small());
            for id in self.targets.clone() {
                let d = self.device(&id).cloned();
                let name = d
                    .as_ref()
                    .map(|d| d.name.clone())
                    .unwrap_or_else(|| id.0.clone());
                let latency = d
                    .as_ref()
                    .and_then(|d| self.backend.target_latency_ms(d).ok())
                    .unwrap_or(self.caps.base_latency_ms);
                let bluetooth = d
                    .map(|d| d.transport == Transport::Bluetooth)
                    .unwrap_or(false);
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(format!("to     {name}")).small());
                    let note = if bluetooth {
                        egui::RichText::new(format!("~{latency} ms, Bluetooth buffering"))
                            .small()
                            .color(AMBER)
                    } else {
                        egui::RichText::new(format!("~{latency} ms")).small().weak()
                    };
                    ui.label(note);
                });
            }
        } else {
            ui.horizontal(|ui| {
                dot(ui, ui.visuals().weak_text_color(), false);
                ui.label(
                    egui::RichText::new("Not mirroring")
                        .strong()
                        .size(16.0)
                        .weak(),
                );
            });
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new(format!("Audio plays only on: {source_name}"))
                    .weak()
                    .small(),
            );
        }

        ui.add_space(10.0);
        ui.separator();
        ui.add_space(6.0);

        // ---- volume ----
        let source = self.source.clone();
        let mut reread = self.slider(ui, &source, self.focus == Focus::Source);
        for (i, id) in self.targets.clone().iter().enumerate() {
            ui.add_space(4.0);
            reread |= self.slider(ui, id, self.focus == Focus::Target(i));
        }

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(6.0);

        // ---- device list ----
        ui.label(
            egui::RichText::new(if self.mirroring() {
                "Add or remove destinations"
            } else {
                "Mirror to"
            })
            .weak()
            .small(),
        );
        ui.add_space(4.0);

        let targets = self.targets.clone();
        let focus = self.focus;
        let reveal = self.reveal_focus;
        let mut clicked: Option<usize> = None;

        for (n, d) in self.selectable().iter().enumerate() {
            let active = targets.contains(&d.id);
            let suffix = match (active, d.transport) {
                (true, Transport::Bluetooth) => "   - on, Bluetooth",
                (true, _) => "   - on",
                (false, Transport::Bluetooth) => "   (Bluetooth)",
                (false, _) => "",
            };
            let label = format!("{}   {}{}", n + 1, d.name, suffix);
            let text = if active {
                egui::RichText::new(label).color(GREEN)
            } else {
                egui::RichText::new(label)
            };
            // Atom::grow() after the text pushes it left; without it egui centres the
            // caption inside the button and the list looks ragged.
            let response = ui.add_sized(
                [ui.available_width(), 26.0],
                egui::Button::selectable(focus == Focus::Device(n), (text, egui::Atom::grow())),
            );
            // Keyboard navigation must never move the focus somewhere invisible.
            if focus == Focus::Device(n) && reveal {
                response.scroll_to_me(None);
            }
            if response.clicked() {
                clicked = Some(n);
            }
        }

        if let Some(e) = &self.error {
            ui.add_space(6.0);
            ui.colored_label(RED, e);
        }

        ui.add_space(8.0);
        ui.label(
            egui::RichText::new(match self.focus {
                Focus::Source | Focus::Target(_) => {
                    "up/down focus · left/right volume · 1-9 toggle device · Esc close"
                }
                Focus::Device(_) if self.mirroring() => {
                    "up/down focus · Enter add or remove · x stop all · Esc close"
                }
                Focus::Device(_) => "up/down focus · Enter mirror here · 1-9 direct · Esc close",
            })
            .weak()
            .small(),
        );

        self.reveal_focus = false;

        if let Some(n) = clicked {
            self.focus = Focus::Device(n);
            self.toggle(n);
        } else if reread {
            // After releasing a slider read once more: that shows what the system really
            // set, not what we asked for.
            if let Err(e) = self.refresh() {
                self.error = Some(format!("{e:#}"));
            }
        }
    }
}
