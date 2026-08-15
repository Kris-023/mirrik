//! The Mirrik skin: one palette per system theme, plus the handful of things the design
//! needs that egui has no widget for.
//!
//! Two grounds, picked from whatever the operating system prefers — the light "Creative"
//! panel and the OLED black. They are the *same* layout in two colour sets, not two
//! designs: same rules, same spacing, same rhythm.
//!
//! Everything here is drawn from primitives: filled rectangles at radius 0, 2px rules,
//! one accent colour. No gradients, no shadows, no rounded corners. That is why the
//! fader and the device row are painted by hand instead of being an `egui::Slider` and a
//! `Button` — those insist on rounded ends, a circular grab and a centred caption, three
//! things this design does not have.
//!
//! Colours are opaque on purpose. The design specifies them as ink at 50 %, 22 %, 7 % and
//! so on; they are pre-blended against their ground here so nothing depends on what
//! happens to be painted underneath.

use eframe::egui::{
    self, text::LayoutJob, Color32, CornerRadius, FontFamily, FontId, Rect, Response, Sense,
    Stroke, StrokeKind, TextFormat, Ui,
};
use std::sync::Arc;

/// Archivo SemiBold, for headings and anything that has to carry weight.
///
/// A named family rather than a bold flag because egui has no weight axis: a second
/// weight is a second font file, full stop.
fn strong_family() -> FontFamily {
    FontFamily::Name("strong".into())
}

/// Installs Archivo and JetBrains Mono, the two typefaces the design is set in.
///
/// Embedded rather than looked up on the system: neither ships with Windows or with a
/// typical Linux install, and a design that silently falls back to whatever is around is
/// not the design.
pub fn install_fonts(ctx: &egui::Context) {
    let mut f = egui::FontDefinitions::empty();
    for (name, bytes) in [
        (
            "archivo",
            &include_bytes!("../assets/Archivo-Regular.ttf")[..],
        ),
        (
            "archivo-semibold",
            &include_bytes!("../assets/Archivo-SemiBold.ttf")[..],
        ),
        (
            "jetbrains-mono",
            &include_bytes!("../assets/JetBrainsMono-Regular.ttf")[..],
        ),
    ] {
        f.font_data
            .insert(name.to_owned(), Arc::new(egui::FontData::from_static(bytes)));
    }
    // JetBrains Mono trails every family as the fallback: it covers far more of Unicode
    // than Archivo, and device names come from the operating system, not from us.
    f.families.insert(
        FontFamily::Proportional,
        vec!["archivo".into(), "jetbrains-mono".into()],
    );
    f.families
        .insert(FontFamily::Monospace, vec!["jetbrains-mono".into()]);
    f.families.insert(
        strong_family(),
        vec!["archivo-semibold".into(), "jetbrains-mono".into()],
    );
    ctx.set_fonts(f);
}

/// Every colour the interface is allowed to use, for one of the two grounds.
#[derive(Clone, Copy)]
pub struct Palette {
    /// The ground the whole window sits on.
    pub bg: Color32,
    /// The 2px section rules and the window border.
    pub rule: Color32,
    pub text: Color32,
    /// Secondary copy: the source's transport, a fader's scope hint.
    pub dim: Color32,
    /// Micro-labels and the names of devices that are off.
    pub faint: Color32,
    /// The quietest thing still meant to be read: row meta, the counter, the key line.
    pub ghost: Color32,
    pub accent: Color32,
    /// Ground of an active device row. On OLED this stays black — the rail does the work.
    pub accent_tint: Color32,
    /// The unfilled part of a fader.
    pub track: Color32,
    pub value_bg: Color32,
    pub value_border: Color32,
    /// Left rail of a device row that is off.
    pub rail_off: Color32,
    /// Border of the OFF tag.
    pub tag_border: Color32,
    /// Text on a filled accent tag.
    pub on_accent: Color32,
    /// OLED sets the whole interface in monospace; the light skin only the numbers.
    pub mono_ui: bool,
}

/// The light ground, straight from the design's `--color-*` tokens.
const LIGHT: Palette = Palette {
    bg: Color32::from_rgb(0xf3, 0xf2, 0xf2),
    rule: Color32::from_rgb(0x20, 0x1e, 0x1d),
    text: Color32::from_rgb(0x20, 0x1e, 0x1d),
    dim: Color32::from_rgb(116, 115, 114),
    faint: Color32::from_rgb(138, 136, 136),
    ghost: Color32::from_rgb(159, 157, 157),
    accent: Color32::from_rgb(0xec, 0x30, 0x13),
    accent_tint: Color32::from_rgb(242, 227, 224),
    track: Color32::from_rgb(197, 195, 195),
    value_bg: Color32::from_rgb(228, 227, 227),
    value_border: Color32::from_rgb(205, 204, 204),
    rail_off: Color32::from_rgb(211, 210, 210),
    tag_border: Color32::from_rgb(201, 200, 199),
    on_accent: Color32::WHITE,
    mono_ui: false,
};

/// The OLED ground: true black throughout, so unlit pixels stay unlit.
///
/// The accent is not the light theme's red. The design dims it —
/// `color-mix(in oklch, #ec3013 58%, #9e9490)` — because full-chroma red on true black
/// glares. Mixed out in OKLCH, that lands on #d06a4d.
const OLED: Palette = Palette {
    bg: Color32::BLACK,
    rule: Color32::from_rgb(0x2a, 0x2a, 0x2a),
    text: Color32::from_rgb(0xe8, 0xe8, 0xe8),
    dim: Color32::from_rgb(0x8a, 0x8a, 0x8a),
    faint: Color32::from_rgb(0x6e, 0x6e, 0x6e),
    ghost: Color32::from_rgb(0x5a, 0x5a, 0x5a),
    accent: Color32::from_rgb(0xd0, 0x6a, 0x4d),
    accent_tint: Color32::BLACK,
    track: Color32::from_rgb(0x2a, 0x2a, 0x2a),
    value_bg: Color32::BLACK,
    value_border: Color32::from_rgb(0x33, 0x33, 0x33),
    rail_off: Color32::BLACK,
    tag_border: Color32::from_rgb(0x33, 0x33, 0x33),
    on_accent: Color32::from_rgb(0x0d, 0x0d, 0x0d),
    mono_ui: true,
};

impl Palette {
    /// Whatever the operating system asked for.
    pub fn of(theme: egui::Theme) -> Self {
        match theme {
            egui::Theme::Light => LIGHT,
            egui::Theme::Dark => OLED,
        }
    }

    /// Body copy.
    pub fn body(&self, size: f32) -> FontId {
        FontId::new(size, self.ui_family())
    }

    /// Headings, device names, the wordmark.
    ///
    /// OLED has no second weight and does not want one — the skin is monospace and reads
    /// as a terminal, where weight is not how emphasis is done.
    pub fn strong(&self, size: f32) -> FontId {
        FontId::new(
            size,
            if self.mono_ui {
                FontFamily::Monospace
            } else {
                strong_family()
            },
        )
    }

    /// Numbers and machine output. Monospace on both grounds — digits have to line up.
    pub fn mono(&self, size: f32) -> FontId {
        FontId::monospace(size)
    }

    fn ui_family(&self) -> FontFamily {
        if self.mono_ui {
            FontFamily::Monospace
        } else {
            FontFamily::Proportional
        }
    }

    /// Monospace runs wider at the same nominal size, so the OLED skin shrinks the two
    /// roles where that would otherwise blow the 430px card apart.
    pub fn head_size(&self) -> f32 {
        if self.mono_ui {
            22.0
        } else {
            25.0
        }
    }

    pub fn row_size(&self) -> f32 {
        if self.mono_ui {
            12.0
        } else {
            13.0
        }
    }
}

/// egui's own styling, reduced to not fighting the paint code above it.
///
/// Almost every pixel in this window is painted by hand; what is left is `ui.label`,
/// which always gets an explicit colour, and the scroll bar.
pub fn visuals(p: &Palette) -> egui::Visuals {
    let mut v = if p.mono_ui {
        egui::Visuals::dark()
    } else {
        egui::Visuals::light()
    };
    v.panel_fill = p.bg;
    v.window_fill = p.bg;
    v.extreme_bg_color = p.bg;
    v.selection.bg_fill = p.accent;
    v.selection.stroke = Stroke::new(1.0, p.on_accent);
    for w in [
        &mut v.widgets.noninteractive,
        &mut v.widgets.inactive,
        &mut v.widgets.hovered,
        &mut v.widgets.active,
        &mut v.widgets.open,
    ] {
        w.corner_radius = CornerRadius::ZERO;
    }
    // The scroll bar only appears when a window manager refuses to resize us, but when it
    // does it must not arrive in egui grey.
    v.widgets.inactive.bg_fill = p.track;
    v.widgets.hovered.bg_fill = p.faint;
    v.widgets.active.bg_fill = p.text;
    v
}

/// One run of text with an explicit letter spacing.
///
/// `RichText` cannot express spacing, and the design leans on wide-tracked uppercase
/// micro-labels; set solid they read as shouting rather than as labels.
pub fn text(s: impl Into<String>, font: FontId, color: Color32, spacing: f32) -> LayoutJob {
    LayoutJob::single_section(
        s.into(),
        TextFormat {
            font_id: font,
            color,
            extra_letter_spacing: spacing,
            ..Default::default()
        },
    )
}

/// Keeps a run on one line, ending it in an ellipsis rather than letting it push the
/// layout around. Device names come from the system and can be arbitrarily long.
pub fn clip_to(job: &mut LayoutJob, width: f32) {
    job.wrap.max_width = width;
    job.wrap.max_rows = 1;
    job.wrap.break_anywhere = true;
    job.wrap.overflow_character = Some('…');
}

fn galley(ui: &Ui, job: LayoutJob) -> Arc<egui::Galley> {
    ui.fonts_mut(|f| f.layout_job(job))
}

/// The wide-tracked uppercase label that opens every section.
pub fn kicker(ui: &mut Ui, p: &Palette, label: &str) {
    ui.label(text(
        label.to_uppercase(),
        p.body(9.5),
        p.faint,
        9.5 * 0.16,
    ));
}

/// A 2px rule across the full width of the window.
///
/// Full bleed on purpose: the dividers run edge to edge while the content stays inset, so
/// this has to be called outside the sections' padding, never inside it.
pub fn rule(ui: &mut Ui, p: &Palette) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 2.0), Sense::hover());
    ui.painter().rect_filled(rect, 0, p.rule);
}

/// The state marker next to the headline: a 12px square, not a circle, filled while
/// mirroring and hollow when not.
pub fn status_square(ui: &mut Ui, p: &Palette, on: bool) {
    let (rect, _) = ui.allocate_exact_size(egui::Vec2::splat(12.0), Sense::hover());
    ui.painter()
        .rect_filled(rect, 0, if on { p.accent } else { p.bg });
    ui.painter().rect_stroke(
        rect,
        0,
        Stroke::new(2.0, if p.mono_ui { p.accent } else { p.rule }),
        StrokeKind::Inside,
    );
}

/// One line of the mixer.
pub struct FaderRow<'a> {
    pub name: &'a str,
    /// What this fader actually moves — the backend's own words.
    pub hint: &'a str,
    pub name_colour: Color32,
    pub hint_colour: Color32,
    /// Colour of the filled part of the track and, on OLED, of the handle.
    pub bar: Color32,
    /// 0.0 … 1.0.
    pub value: f32,
}

/// One volume fader: a label line with a boxed readout, then a 2px track with a
/// rectangular handle.
///
/// Every measurement in here is taken from the width the row was given and the text is
/// clipped to fit, rather than laid out with `ui.horizontal` and hoped for. Monospace
/// runs roughly a third wider than Archivo at the same size, and a row balanced by hand
/// in one skin overflows in the other.
///
/// Returns the value after this frame's interaction; `response.changed()` says whether
/// the user moved it, `response.drag_stopped()` whether they let go.
pub fn fader(ui: &mut Ui, p: &Palette, row: &FaderRow<'_>) -> (f32, Response) {
    let full = ui.available_width();

    let readout = galley(
        ui,
        text(
            format!("{:.0} %", row.value * 100.0),
            p.mono(if p.mono_ui { 12.5 } else { 13.0 }),
            p.text,
            0.0,
        ),
    );
    let box_size = egui::vec2(66.0, readout.size().y + 10.0);

    // Everything left of the readout, and the name may claim at most half of it.
    let room = (full - box_size.x - 12.0).max(40.0);
    let mut name_job = text(
        row.name,
        p.strong(if p.mono_ui { 12.5 } else { 13.5 }),
        row.name_colour,
        0.0,
    );
    clip_to(&mut name_job, room * 0.55);
    let name = galley(ui, name_job);
    let mut hint_job = text(
        row.hint,
        p.body(if p.mono_ui { 10.0 } else { 10.5 }),
        row.hint_colour,
        0.0,
    );
    clip_to(&mut hint_job, (room - name.size().x - 8.0).max(10.0));
    let hint = galley(ui, hint_job);

    let (label, _) = ui.allocate_exact_size(
        egui::vec2(full, box_size.y.max(name.size().y)),
        Sense::hover(),
    );
    let painter = ui.painter();
    // Baselines: the hint sits on the name's, the readout is centred in its box.
    let base = label.center().y;
    painter.galley(
        egui::pos2(label.left(), base - name.size().y * 0.5),
        name.clone(),
        p.text,
    );
    painter.galley(
        egui::pos2(
            label.left() + name.size().x + 8.0,
            base - hint.size().y * 0.5,
        ),
        hint,
        p.text,
    );
    let value_rect = Rect::from_min_size(
        egui::pos2(label.right() - box_size.x, base - box_size.y * 0.5),
        box_size,
    );
    painter.rect_filled(value_rect, 0, p.value_bg);
    painter.rect_stroke(
        value_rect,
        0,
        Stroke::new(1.0, p.value_border),
        StrokeKind::Inside,
    );
    // Right-aligned: these are read down a column, not across as prose.
    let readout_size = readout.size();
    painter.galley(
        egui::pos2(
            value_rect.right() - 7.0 - readout_size.x,
            value_rect.center().y - readout_size.y * 0.5,
        ),
        readout,
        p.text,
    );

    ui.add_space(2.0);
    let (rect, mut response) =
        ui.allocate_exact_size(egui::vec2(full, 18.0), Sense::click_and_drag());
    let (value, bar) = (row.value, row.bar);

    // The handle is 10px wide; holding its centre 5px inside either end keeps it from
    // hanging off the track at 0 % and 100 %.
    let left = rect.left() + 5.0;
    let span = (rect.width() - 10.0).max(1.0);

    let mut value = value;
    if response.is_pointer_button_down_on() {
        if let Some(pos) = response.interact_pointer_pos() {
            let v = ((pos.x - left) / span).clamp(0.0, 1.0);
            if v != value {
                value = v;
                response.mark_changed();
            }
        }
    }

    let y = rect.top() + 8.0;
    let painter = ui.painter();
    painter.rect_filled(
        Rect::from_min_size(egui::pos2(rect.left(), y), egui::vec2(rect.width(), 2.0)),
        0,
        p.track,
    );
    painter.rect_filled(
        Rect::from_min_size(
            egui::pos2(rect.left(), y),
            egui::vec2(rect.width() * value, 2.0),
        ),
        0,
        bar,
    );
    let handle = Rect::from_min_size(
        egui::pos2(left + span * value - 5.0, rect.top() + 2.0),
        egui::vec2(10.0, 14.0),
    );
    painter.rect_filled(handle, 0, p.bg);
    painter.rect_stroke(
        handle,
        0,
        Stroke::new(2.0, if p.mono_ui { bar } else { p.rule }),
        StrokeKind::Inside,
    );
    (value, response)
}

/// One entry in the destination list.
pub struct Row<'a> {
    /// The digit that toggles this device from the keyboard.
    pub num: usize,
    pub name: &'a str,
    /// Latency and volume while on, a single word while off.
    pub meta: &'a str,
    pub on: bool,
    pub focused: bool,
}

/// Paints a destination row and reports whether it was clicked.
pub fn device_row(ui: &mut Ui, p: &Palette, row: &Row<'_>) -> Response {
    let full = ui.available_width();

    let num = galley(
        ui,
        text(
            row.num.to_string(),
            p.mono(12.0),
            if row.on { p.accent } else { p.ghost },
            0.0,
        ),
    );
    let tag = galley(
        ui,
        text(
            if row.on { "ON" } else { "OFF" },
            p.strong(9.5),
            if row.on { p.on_accent } else { p.faint },
            9.5 * 0.12,
        ),
    );
    let tag_size = tag.size() + egui::vec2(16.0, 10.0);

    // 10 padding | 22 number | 12 gap | name | 12 gap | tag | 10 padding
    let name_width = (full - 66.0 - tag_size.x).max(40.0);
    let mut name_job = text(
        row.name,
        p.strong(p.row_size()),
        if row.on { p.text } else { p.faint },
        0.0,
    );
    clip_to(&mut name_job, name_width);
    let name = galley(ui, name_job);
    let mut meta_job = text(row.meta, p.mono(10.5), p.ghost, 0.0);
    clip_to(&mut meta_job, name_width);
    let meta = galley(ui, meta_job);

    let (name_h, meta_h) = (name.size().y, meta.size().y);
    let (rect, response) =
        ui.allocate_exact_size(egui::vec2(full, 9.0 + name_h + 2.0 + meta_h + 9.0), Sense::click());

    let painter = ui.painter();
    if row.on {
        painter.rect_filled(rect, 0, p.accent_tint);
    }
    // The 3px rail is what carries "this one is live" on OLED, where the row itself stays
    // pure black and the tint has nothing to say.
    painter.rect_filled(
        Rect::from_min_size(rect.min, egui::vec2(3.0, rect.height())),
        0,
        if row.on { p.accent } else { p.rail_off },
    );

    let x = rect.left() + 10.0;
    painter.galley(
        egui::pos2(x, rect.center().y - num.size().y * 0.5),
        num,
        p.text,
    );
    painter.galley(egui::pos2(x + 34.0, rect.top() + 9.0), name, p.text);
    painter.galley(
        egui::pos2(x + 34.0, rect.top() + 9.0 + name_h + 2.0),
        meta,
        p.text,
    );

    let tag_rect = Rect::from_min_size(
        egui::pos2(
            rect.right() - 10.0 - tag_size.x,
            rect.center().y - tag_size.y * 0.5,
        ),
        tag_size,
    );
    painter.rect_filled(tag_rect, 0, if row.on { p.accent } else { p.bg });
    painter.rect_stroke(
        tag_rect,
        0,
        Stroke::new(1.0, if row.on { p.accent } else { p.tag_border }),
        StrokeKind::Inside,
    );
    painter.galley(tag_rect.center() - tag.size() * 0.5, tag, p.text);

    if row.focused {
        focus_ring(ui, p, rect);
    }
    response
}

/// The keyboard focus marker: a 2px accent outline, the one focus style the design system
/// specifies. Nothing else in the window has a 2px accent edge, so it cannot be misread.
pub fn focus_ring(ui: &Ui, p: &Palette, rect: Rect) {
    ui.painter()
        .rect_stroke(rect, 0, Stroke::new(2.0, p.accent), StrokeKind::Inside);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one thing in here with arithmetic in it: the fader maps a pointer position to
    /// a value and back to a handle position, and getting either end wrong is invisible
    /// until someone drags to a stop and the handle sits somewhere else.
    #[test]
    fn fader_handle_stays_on_the_track() {
        let rect = Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(300.0, 18.0));
        let left = rect.left() + 5.0;
        let span = rect.width() - 10.0;

        for (pointer_x, expected) in [(-50.0, 0.0), (5.0, 0.0), (150.0, 0.5), (295.0, 1.0), (999.0, 1.0)] {
            let v = ((pointer_x - left) / span).clamp(0.0, 1.0);
            assert!((v - expected).abs() < 0.01, "{pointer_x} gave {v}, wanted {expected}");
        }

        // …and the handle, 10px wide, never pokes out of either end.
        for v in [0.0, 0.5, 1.0] {
            let centre = left + span * v;
            assert!(centre - 5.0 >= rect.left(), "handle hangs off the left at {v}");
            assert!(centre + 5.0 <= rect.right(), "handle hangs off the right at {v}");
        }
    }
}
