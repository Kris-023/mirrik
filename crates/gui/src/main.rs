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
//! # Look
//!
//! The skin lives in [`theme`] and comes in two grounds — a light panel and an OLED
//! black — chosen from the operating system's own light/dark setting. This file decides
//! *what* is on screen; `theme.rs` decides what it looks like.
//!
//! Fonts are embedded, so any glyph either typeface has is safe here. Arrows and filled
//! circles are still avoided: the design asks for none, and painted shapes beat glyphs
//! for anything that has to be a specific size.

mod theme;

use eframe::egui;
use mirrik_core::{
    Capabilities, Device, DeviceId, MirrorBackend, Transport, VolumeScope, VOLUME_MAX,
};
use std::time::{Duration, Instant};
use theme::Palette;

/// How often state is re-read from the system while the window is open.
///
/// Volume can change from outside — from a panel applet, from `pactl`, or from a hardware
/// dial such as the Digital Crown on AirPods Max. Without this the window would show the
/// values it saw when it opened.
const TICK: Duration = Duration::from_millis(600);

/// Step size when adjusting a slider from the keyboard.
const STEP: f32 = 0.05;

/// Fixed window width, straight from the design's 430px card. The height follows the
/// content, see the resize block in `ui()`.
const WIDTH: f32 = 430.0;

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
            // Nothing is ever dropped onto this window, and asking for it is not free on
            // Windows: winit initialises COM as single-threaded to support it, while the
            // audio backend has already claimed this thread as multi-threaded — which is
            // what WASAPI wants. The two are incompatible and winit panics on the clash.
            .with_drag_and_drop(false)
            // Read by window rules as `class` (Wayland/X11) and used as the window class
            // on Windows.
            .with_app_id("mirrik"),
        ..Default::default()
    };

    eframe::run_native(
        "Mirrik",
        options,
        Box::new(move |cc| {
            theme::install_fonts(&cc.egui_ctx);
            Ok(Box::new(app))
        }),
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
    /// The colours in use, and the system setting they were derived from. Kept so a
    /// user flipping their desktop to dark repaints the window instead of the next
    /// restart doing it.
    palette: Palette,
    theme: Option<egui::Theme>,
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
            palette: Palette::of(egui::Theme::Light),
            theme: None,
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
        // Header, source block, the two headings, footer and the four rules between them
        // add up to a constant; each fader and each device row is a fixed block on top.
        // Measured against the real window at both extremes, not derived.
        280.0 + 62.0 * sliders + 47.0 * list
    }

    /// One fader with its label and boxed readout. Returns true when the user let go.
    fn fader(&mut self, ui: &mut egui::Ui, id: &DeviceId, focused: bool, master: bool) -> bool {
        let p = self.palette;
        let Some(d) = self.device(id).cloned() else {
            return false;
        };

        // The explanation comes from the backend, never from this file: whether a fader
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

        // The source fader is the one that can move every mirrored copy at once, so while
        // mirroring it is the one thing on screen the design lets wear the accent.
        let live_master = master && self.mirroring();
        let name_colour = if live_master { p.accent } else { p.text };
        // Same treatment for a destination whose gain sits in front of the tap — that is
        // a surprise worth one use of the accent.
        let hint_colour = if live_master || (d.volume_scope == VolumeScope::AffectsMirror
            && self.mirroring())
        {
            p.accent
        } else {
            p.faint
        };
        let bar = if live_master {
            p.accent
        } else if p.mono_ui {
            p.dim
        } else {
            p.text
        };

        let block = ui.scope(|ui| {
            let (value, response) = theme::fader(
                ui,
                &p,
                &theme::FaderRow {
                    name: &title,
                    hint: &format!("— {hint}"),
                    name_colour,
                    hint_colour,
                    bar,
                    value: d.volume,
                },
            );
            if response.changed() {
                self.set_volume(id, value);
            }
            response.drag_stopped()
        });

        if focused {
            theme::focus_ring(ui, &p, block.response.rect.expand(3.0));
            if self.reveal_focus {
                block.response.scroll_to_me(None);
                self.reveal_focus = false;
            }
        }
        block.inner
    }
}

impl<B: MirrorBackend> eframe::App for Window<B> {
    // The clear colour is what eframe paints before egui draws anything, and the default
    // is a dark grey that flashes for one frame on the light ground.
    fn clear_color(&self, visuals: &egui::Visuals) -> [f32; 4] {
        visuals.panel_fill.to_normalized_gamma_f32()
    }

    // eframe 0.36 hands the app a ready-made `Ui` instead of a `Context`.
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();

        // Follow the desktop's own light/dark setting. eframe leaves the preference on
        // `System`, so this is whatever the platform reports.
        //
        // Checked every frame rather than once, because it costs nothing and the answer
        // can change. On Windows 11 it does not: winit asks `uxtheme` ordinal 132, which
        // hands a process the same answer for its whole life, so a desktop flipped to
        // dark shows up the next time the window opens. For a window that opens on a
        // keystroke and closes on Esc that is the same thing in practice.
        let theme = ctx.theme();
        if self.theme != Some(theme) {
            self.theme = Some(theme);
            self.palette = Palette::of(theme);
            ctx.set_visuals(theme::visuals(&self.palette));
        }

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
        let mut content = 0.0;
        let width = ui.available_width();
        egui::ScrollArea::vertical()
            .auto_shrink([false; 2])
            .show(ui, |ui| {
                // Pin the width to the card. Without this a single label that does not
                // fit widens the scroll area, and every section below it reads that wider
                // number as "available" — one long device name in the mixer used to push
                // the whole destination list off the right edge.
                ui.set_max_width(width);
                self.body(ui);
                content = ui.min_rect().height();
            });

        // The 2px edge of the card. The window is undecorated, so this frame is the only
        // thing separating it from whatever it floats over — drawn on the foreground
        // layer so the scroll area cannot paint across it.
        ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::new("card-edge"),
        ))
        .rect_stroke(
            ctx.viewport_rect(),
            0,
            egui::Stroke::new(2.0, self.palette.rule),
            egui::StrokeKind::Inside,
        );

        let wanted = content;
        if (wanted - self.height).abs() > 1.0 {
            self.height = wanted;
            ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(WIDTH, wanted)));
            // The resize lands on the following frame, and with no input arriving egui
            // would not draw one for another TICK. Without this the window visibly
            // limps after the content it is supposed to fit.
            ctx.request_repaint();
        }

        // Actions last: they change the state the frame was drawn from.
        if let Some(n) = toggle {
            if n < self.selectable().len() {
                self.focus = Focus::Device(n);
                self.toggle(n);
            }
            // The state this frame was drawn from is now stale — redraw at once instead
            // of leaving the old picture up until the next poll.
            ctx.request_repaint();
        } else if stop {
            self.stop();
            ctx.request_repaint();
        }
    }
}

/// Padding of one block, in the design's own numbers. Rules are drawn between blocks and
/// run the full width of the card, so they must never be inside one of these.
fn block(top: i8, bottom: i8) -> egui::Frame {
    egui::Frame::NONE.inner_margin(egui::Margin {
        left: 20,
        right: 20,
        top,
        bottom,
    })
}

impl<B: MirrorBackend> Window<B> {
    fn body(&mut self, ui: &mut egui::Ui) {
        let p = self.palette;
        let source_name = self
            .device(&self.source)
            .map(|d| d.name.clone())
            .unwrap_or_else(|| self.source.0.clone());

        self.header(ui, &source_name);
        theme::rule(ui, &p);
        self.source_block(ui, &source_name);
        theme::rule(ui, &p);

        // ---- mixer ----
        let mut reread = false;
        block(14, 6).show(ui, |ui| {
            theme::kicker(ui, &p, "Mixer");
            ui.add_space(12.0);
            let source = self.source.clone();
            reread = self.fader(ui, &source, self.focus == Focus::Source, true);
            for (i, id) in self.targets.clone().iter().enumerate() {
                ui.add_space(14.0);
                reread |= self.fader(ui, id, self.focus == Focus::Target(i), false);
            }
        });
        theme::rule(ui, &p);

        let clicked = self.destinations(ui);

        if let Some(e) = self.error.clone() {
            block(10, 0).show(ui, |ui| {
                let mut job = theme::text(format!("! {e}"), p.body(11.0), p.accent, 0.0);
                theme::clip_to(&mut job, ui.available_width());
                ui.label(job);
            });
        }

        block(14, 0).show(ui, |ui| ui.add_space(0.0));
        theme::rule(ui, &p);
        block(11, 12).show(ui, |ui| {
            ui.label(theme::text(
                match self.focus {
                    Focus::Source | Focus::Target(_) => {
                        "up/down focus · left/right volume · 1-9 toggle · Esc close"
                    }
                    Focus::Device(_) if self.mirroring() => {
                        "up/down focus · Enter add or remove · x stop all · Esc close"
                    }
                    Focus::Device(_) => "up/down focus · Enter mirror here · 1-9 direct · Esc close",
                },
                p.mono(10.0),
                p.ghost,
                0.0,
            ));
        });

        self.reveal_focus = false;

        if let Some(n) = clicked {
            self.focus = Focus::Device(n);
            self.toggle(n);
        } else if reread {
            // After releasing a fader read once more: that shows what the system really
            // set, not what we asked for.
            if let Err(e) = self.refresh() {
                self.error = Some(format!("{e:#}"));
            }
        }
    }

    /// The state, always first and always in the same place: a square, a headline, and
    /// one line naming what is involved.
    fn header(&mut self, ui: &mut egui::Ui, source_name: &str) {
        let p = self.palette;
        let mirroring = self.mirroring();
        let title = match self.targets.len() {
            0 => "Not mirroring".to_string(),
            1 => "Mirroring".to_string(),
            n => format!("Mirroring to {n} devices"),
        };
        // While mirroring the subline names the destinations, because that is the thing
        // the user cannot see anywhere else at a glance; idle it names the one device
        // still making sound.
        let sub = if mirroring {
            self.targets
                .iter()
                .map(|id| {
                    self.device(id)
                        .map(|d| d.name.clone())
                        .unwrap_or_else(|| id.0.clone())
                })
                .collect::<Vec<_>>()
                .join("  ·  ")
        } else {
            source_name.to_string()
        };

        block(18, 14).show(ui, |ui| {
            // The wordmark sits on the right; everything else has to fit beside it, with
            // room for the square, the gaps egui puts between them, and the mark itself.
            let text_width = (ui.available_width() - 44.0 - 80.0).max(60.0);
            ui.horizontal_top(|ui| {
                ui.vertical(|ui| {
                    ui.add_space(7.0);
                    theme::status_square(ui, &p, mirroring);
                });
                ui.add_space(12.0);
                ui.vertical(|ui| {
                    let mut head =
                        theme::text(title, p.strong(p.head_size()), p.text, p.head_size() * -0.02);
                    theme::clip_to(&mut head, text_width);
                    ui.label(head);
                    ui.add_space(5.0);
                    let mut job = theme::text(sub.to_uppercase(), p.body(10.0), p.faint, 1.4);
                    theme::clip_to(&mut job, text_width);
                    ui.label(job);
                });
                ui.with_layout(egui::Layout::right_to_left(egui::Align::TOP), |ui| {
                    ui.add_space(0.0);
                    ui.label(theme::text(
                        "MIRRIK",
                        p.strong(11.0),
                        if p.mono_ui { p.accent } else { p.text },
                        11.0 * 0.22,
                    ));
                });
            });
        });
    }

    /// Where the sound comes from. Never a choice — it is whatever the system calls its
    /// default output — so it is stated, not offered.
    fn source_block(&mut self, ui: &mut egui::Ui, source_name: &str) {
        let p = self.palette;
        let transport = self
            .device(&self.source)
            .map(|d| d.transport.label())
            .unwrap_or("");
        block(14, 16).show(ui, |ui| {
            theme::kicker(ui, &p, "Source");
            ui.add_space(7.0);
            let mut name = theme::text(
                source_name,
                p.strong(if p.mono_ui { 14.0 } else { 15.0 }),
                p.text,
                0.0,
            );
            theme::clip_to(&mut name, ui.available_width());
            ui.label(name);
            ui.label(theme::text(transport, p.body(12.0), p.dim, 0.0));
        });
    }

    /// The device list. Returns the entry that was clicked, if any.
    fn destinations(&mut self, ui: &mut egui::Ui) -> Option<usize> {
        let p = self.palette;
        let counter = format!(
            "{} / {} active",
            self.targets.len(),
            self.selectable().len()
        );
        block(14, 0).show(ui, |ui| {
            ui.horizontal(|ui| {
                theme::kicker(ui, &p, "Destinations");
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(theme::text(counter, p.mono(10.5), p.ghost, 0.0));
                });
            });
        });

        let targets = self.targets.clone();
        let focus = self.focus;
        let reveal = self.reveal_focus;
        let base_latency = self.caps.base_latency_ms;
        let mut clicked = None;

        // Rows sit closer to the card edge than the rest, so their rail reads as part of
        // the frame rather than as a stray line in the middle of the panel.
        egui::Frame::NONE
            .inner_margin(egui::Margin {
                left: 10,
                right: 10,
                top: 10,
                bottom: 4,
            })
            .show(ui, |ui| {
                for (n, d) in self.selectable().iter().enumerate() {
                    let on = targets.contains(&d.id);
                    let latency = self
                        .backend
                        .target_latency_ms(d)
                        .unwrap_or(base_latency);
                    let mut meta = if on {
                        format!("~{latency} ms · {:.0} %", d.volume * 100.0)
                    } else {
                        "idle".to_string()
                    };
                    // Bluetooth is the one transport that adds delay worth warning about,
                    // and it is invisible in the device name.
                    if d.transport == Transport::Bluetooth {
                        meta.push_str(" · Bluetooth");
                    }
                    let response = theme::device_row(
                        ui,
                        &p,
                        &theme::Row {
                            num: n + 1,
                            name: &d.name,
                            meta: &meta,
                            on,
                            focused: focus == Focus::Device(n),
                        },
                    );
                    // Keyboard navigation must never move the focus somewhere invisible.
                    if focus == Focus::Device(n) && reveal {
                        response.scroll_to_me(None);
                    }
                    if response.clicked() {
                        clicked = Some(n);
                    }
                }
            });
        clicked
    }
}
