//! The preset deck: every preset always in view beside the curve, instead of
//! behind a menu. Pointing at one plays it (a preview that nothing saves,
//! level-matched by its own preamp) and draws its curve over the one in
//! force; clicking keeps it. Moving down the list is scrubbing through the
//! presets, and leaving the deck puts back what was playing.

use super::curve::plot_accent;
use super::presets::{sections, subtitle, thumbnail_curve};
use super::{import, render, Screen};
use crate::ui::controls::{build_equalizer_indicator, drive_equalizer};
use adw::prelude::*;
use flaccy_shared::equalizer::profile::EqualizerProfile;
use gtk::{gio, glib};
use std::cell::RefCell;
use std::rc::{Rc, Weak};
use std::time::Duration;

const THUMBNAIL_SIZE: (i32, i32) = (56, 26);
/// How long the pointer rests on a preset before it plays, so crossing the
/// deck to reach something else does not stutter through everything between.
const DWELL_MS: u64 = 90;
/// How long a pointer that has left the deck is forgiven before the preview ends.
const LEAVE_GRACE_MS: u64 = 160;

struct RowParts {
    id: String,
    row: gtk::ListBoxRow,
    thumbnail: gtk::DrawingArea,
    indicator: gtk::DrawingArea,
    tick: gtk::Image,
}

pub struct Deck {
    pub widget: gtk::Box,
    list: gtk::ListBox,
    scroll: gtk::ScrolledWindow,
    hint: gtk::Label,
    hover_toggle: gtk::ToggleButton,
    rows: RefCell<Vec<RowParts>>,
    signature: RefCell<String>,
    current: RefCell<String>,
    hearing: RefCell<Option<String>>,
}

fn thumbnail(curve: Vec<f64>) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(THUMBNAIL_SIZE.0)
        .content_height(THUMBNAIL_SIZE.1)
        .valign(gtk::Align::Center)
        .build();
    area.add_css_class("eq-deck-thumb");
    area.set_draw_func(move |area, cr, width, height| {
        let dark = adw::StyleManager::default().is_dark();
        let ink = if dark { (1.0, 1.0, 1.0) } else { (0.09, 0.09, 0.13) };
        let lit = area.has_css_class("lit");
        let (color, alpha) = if lit { (plot_accent(dark), 1.0) } else { (ink, 0.62) };
        render::draw_thumbnail(cr, width as f64, height as f64, &curve, color, alpha, false, ink);
    });
    area
}

fn section_row(title: &str) -> gtk::ListBoxRow {
    let label = gtk::Label::builder().label(title).xalign(0.0).build();
    label.add_css_class("eq-caption");
    label.add_css_class("eq-section");
    let row = gtk::ListBoxRow::new();
    row.set_child(Some(&label));
    row.set_activatable(false);
    row.set_selectable(false);
    row.set_focusable(false);
    row
}

fn more_menu(profile: &EqualizerProfile) -> gtk::MenuButton {
    let menu = gio::Menu::new();
    for (title, action) in [
        ("Rename…", "eqw.rename"),
        ("Export as Text…", "eqw.export"),
        ("Copy as Text", "eqw.copy"),
        ("Delete", "eqw.delete"),
    ] {
        let item = gio::MenuItem::new(Some(title), None);
        item.set_action_and_target_value(Some(action), Some(&profile.id.to_variant()));
        menu.append_item(&item);
    }
    let more = gtk::MenuButton::builder()
        .icon_name("flaccy-more-symbolic")
        .menu_model(&menu)
        .valign(gtk::Align::Center)
        .build();
    more.add_css_class("flat");
    more.add_css_class("circular");
    more.add_css_class("eq-deck-more");
    more.update_property(&[gtk::accessible::Property::Label(&format!("More for {}", profile.name))]);
    more
}

fn profile_row(profile: &EqualizerProfile, weak: &Weak<Screen>) -> RowParts {
    let names = gtk::Box::new(gtk::Orientation::Vertical, 0);
    names.set_hexpand(true);
    names.set_valign(gtk::Align::Center);
    let name = gtk::Label::builder()
        .label(&profile.name)
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    name.add_css_class("eq-preset-name");
    let note = gtk::Label::builder()
        .label(subtitle(profile))
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    note.add_css_class("eq-preset-note");
    names.append(&name);
    names.append(&note);

    let thumbnail = thumbnail(thumbnail_curve(profile));
    let indicator = build_equalizer_indicator();
    indicator.set_visible(false);
    indicator.set_valign(gtk::Align::Center);
    let tick = gtk::Image::from_icon_name("flaccy-check-symbolic");
    tick.add_css_class("eq-preset-tick");
    tick.set_visible(false);

    let content = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    content.add_css_class("eq-deck-content");
    content.append(&thumbnail);
    content.append(&names);
    content.append(&indicator);
    content.append(&tick);
    if !profile.is_built_in() {
        content.append(&more_menu(profile));
    }

    let row = gtk::ListBoxRow::new();
    row.add_css_class("eq-deck-row");
    row.set_child(Some(&content));
    row.update_property(&[gtk::accessible::Property::Label(&profile.name)]);

    let id = profile.id.clone();
    let motion = gtk::EventControllerMotion::new();
    {
        let (weak, id) = (weak.clone(), id.clone());
        motion.connect_enter(move |_, _, _| {
            if let Some(screen) = weak.upgrade() {
                screen.deck_pointed_at(&id);
            }
        });
    }
    {
        let weak = weak.clone();
        motion.connect_leave(move |_| {
            if let Some(screen) = weak.upgrade() {
                screen.deck_left();
            }
        });
    }
    row.add_controller(motion);

    let focus = gtk::EventControllerFocus::new();
    {
        let (weak, id) = (weak.clone(), id.clone());
        focus.connect_enter(move |_| {
            if let Some(screen) = weak.upgrade() {
                screen.deck_pointed_at(&id);
            }
        });
    }
    {
        let weak = weak.clone();
        focus.connect_leave(move |_| {
            if let Some(screen) = weak.upgrade() {
                screen.deck_left();
            }
        });
    }
    row.add_controller(focus);

    RowParts { id, row, thumbnail, indicator, tick }
}

impl Deck {
    pub fn build(weak: Weak<Screen>, hover_preview: bool) -> Rc<Deck> {
        let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
        list.add_css_class("eq-deck-list");
        list.update_property(&[gtk::accessible::Property::Label("Presets")]);
        {
            let weak = weak.clone();
            list.connect_row_activated(move |_, row| {
                let Some(screen) = weak.upgrade() else { return };
                let id = screen.deck.id_of(row);
                if let Some(id) = id {
                    screen.choose_profile(&id);
                }
            });
        }
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();

        let caption = gtk::Label::builder().label("PRESETS").xalign(0.0).hexpand(true).build();
        caption.add_css_class("eq-caption");
        let hover_toggle = gtk::ToggleButton::builder()
            .icon_name("flaccy-headphones-symbolic")
            .active(hover_preview)
            .valign(gtk::Align::Center)
            .tooltip_text("Hover a preset to hear it")
            .build();
        hover_toggle.add_css_class("flat");
        hover_toggle.add_css_class("circular");
        hover_toggle.add_css_class("eq-hover-toggle");
        hover_toggle.update_property(&[gtk::accessible::Property::Label("Hover to preview")]);
        {
            let weak = weak.clone();
            hover_toggle.connect_toggled(move |toggle| {
                if let Some(screen) = weak.upgrade() {
                    screen.hover_preview_toggled(toggle.is_active());
                }
            });
        }
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        header.add_css_class("eq-deck-header");
        header.append(&caption);
        header.append(&hover_toggle);

        let hint = gtk::Label::builder().xalign(0.0).wrap(true).build();
        hint.add_css_class("eq-deck-hint");

        let import_button = gtk::Button::with_label("Import…");
        import_button.add_css_class("flat");
        import_button.set_hexpand(true);
        if let Some(label) = import_button.child().and_then(|child| child.downcast::<gtk::Label>().ok()) {
            label.set_xalign(0.0);
        }
        {
            let weak = weak.clone();
            import_button.connect_clicked(move |_| {
                if let Some(screen) = weak.upgrade() {
                    import::present(&screen, None);
                }
            });
        }
        let menu = gio::Menu::new();
        for (title, action) in [
            ("Export as Text…", "eqw.export-current"),
            ("Copy as Text", "eqw.copy-current"),
            ("Find Headphones on AutoEq", "eqw.autoeq"),
        ] {
            menu.append(Some(title), Some(action));
        }
        let more = gtk::MenuButton::builder()
            .icon_name("flaccy-more-symbolic")
            .menu_model(&menu)
            .valign(gtk::Align::Center)
            .tooltip_text("More")
            .build();
        more.add_css_class("flat");
        more.add_css_class("circular");
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        footer.add_css_class("eq-deck-footer");
        footer.append(&import_button);
        footer.append(&more);

        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.add_css_class("eq-card");
        widget.add_css_class("eq-deck");
        widget.set_size_request(236, -1);
        widget.set_hexpand(false);
        widget.append(&header);
        widget.append(&hint);
        widget.append(&scroll);
        widget.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        widget.append(&footer);

        let keys = gtk::EventControllerKey::new();
        {
            let weak = weak.clone();
            keys.connect_key_pressed(move |_, key, _, _| {
                if key == gtk::gdk::Key::Escape {
                    if let Some(screen) = weak.upgrade() {
                        screen.end_audition();
                        screen.curve.area.grab_focus();
                    }
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
        }
        widget.add_controller(keys);

        let deck = Rc::new(Deck {
            widget,
            list,
            scroll,
            hint,
            hover_toggle,
            rows: RefCell::new(Vec::new()),
            signature: RefCell::new(String::new()),
            current: RefCell::new(String::new()),
            hearing: RefCell::new(None),
        });
        deck.set_hover_hint(hover_preview);
        deck
    }

    fn id_of(&self, row: &gtk::ListBoxRow) -> Option<String> {
        self.rows.borrow().iter().find(|parts| &parts.row == row).map(|parts| parts.id.clone())
    }

    pub fn set_hover_hint(&self, hover_preview: bool) {
        self.hint.set_text(if hover_preview {
            "Hover to hear it · click to keep it"
        } else {
            "Click a preset to hear it"
        });
        if self.hover_toggle.is_active() != hover_preview {
            self.hover_toggle.set_active(hover_preview);
        }
    }

    /// Brings the list in line with the profiles that exist and the one in
    /// force. The rows are only rebuilt when a name or a profile changed, so a
    /// refresh never pulls the row under the pointer out from under it.
    pub fn sync(&self, screen: &Screen, weak: &Weak<Screen>) {
        let current = screen.profile().id;
        let user = screen.engine.state().user_profiles;
        let signature = user.iter().map(|profile| format!("{}:{}", profile.id, profile.name)).collect::<Vec<_>>().join("|");
        if *self.signature.borrow() != signature || self.rows.borrow().is_empty() {
            self.rebuild(&user, weak);
            *self.signature.borrow_mut() = signature;
        }
        *self.current.borrow_mut() = current;
        self.paint_states();
    }

    fn rebuild(&self, user: &[EqualizerProfile], weak: &Weak<Screen>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let mut rows = Vec::new();
        for (title, profiles) in sections(user) {
            self.list.append(&section_row(title));
            for profile in profiles {
                let parts = profile_row(&profile, weak);
                self.list.append(&parts.row);
                rows.push(parts);
            }
        }
        *self.rows.borrow_mut() = rows;
    }

    pub fn set_hearing(&self, id: Option<&str>) {
        *self.hearing.borrow_mut() = id.map(str::to_string);
        self.paint_states();
    }

    fn paint_states(&self) {
        let current = self.current.borrow().clone();
        let hearing = self.hearing.borrow().clone();
        for parts in self.rows.borrow().iter() {
            let is_current = parts.id == current;
            let is_hearing = hearing.as_deref() == Some(parts.id.as_str());
            toggle_class(&parts.row, "current", is_current);
            toggle_class(&parts.row, "hearing", is_hearing);
            toggle_class(&parts.thumbnail, "lit", is_current || is_hearing);
            parts.thumbnail.queue_draw();
            parts.tick.set_visible(is_current && !is_hearing);
            parts.indicator.set_visible(is_hearing);
            drive_equalizer(&parts.indicator, is_hearing);
            parts.indicator.set_tooltip_text(None);
        }
    }

    /// Puts keyboard focus on a preset, which previews it the way pointing does.
    pub fn focus_preset(&self, id: &str) {
        if let Some(parts) = self.rows.borrow().iter().find(|parts| parts.id == id) {
            parts.row.grab_focus();
        }
    }

    /// Scrolls so the preset in force is on screen, for when the window opens.
    pub fn reveal_current(&self) {
        let current = self.current.borrow().clone();
        let target = self.rows.borrow().iter().find(|parts| parts.id == current).map(|parts| parts.row.clone());
        let Some(row) = target else { return };
        let scroll = self.scroll.clone();
        glib::idle_add_local_once(move || {
            let Some(bounds) = row.compute_bounds(&scroll.child().unwrap_or_else(|| row.clone().upcast())) else {
                return;
            };
            let adjustment = scroll.vadjustment();
            let (top, bottom) = (bounds.y() as f64, (bounds.y() + bounds.height()) as f64);
            let (view_top, view_bottom) = (adjustment.value(), adjustment.value() + adjustment.page_size());
            if top < view_top {
                adjustment.set_value(top - 8.0);
            } else if bottom > view_bottom {
                adjustment.set_value(bottom - adjustment.page_size() + 8.0);
            }
        });
    }
}

fn toggle_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    if on {
        widget.add_css_class(class);
    } else {
        widget.remove_css_class(class);
    }
}

impl Screen {
    pub(super) fn hover_preview_on(&self) -> bool {
        self.ui.core.config.borrow().eq_hover_preview
    }

    pub(super) fn hover_preview_toggled(self: &Rc<Self>, on: bool) {
        {
            let mut config = self.ui.core.config.borrow_mut();
            if config.eq_hover_preview == on {
                return;
            }
            config.eq_hover_preview = on;
        }
        self.ui.core.save_config();
        self.deck.set_hover_hint(on);
        if !on {
            self.end_audition();
        }
    }

    /// The pointer (or keyboard focus) has come to a preset. While something
    /// is already playing as a preview the switch is at once, so a sweep down
    /// the list plays each in turn; otherwise the pointer has to rest a moment.
    pub(super) fn deck_pointed_at(self: &Rc<Self>, id: &str) {
        if !self.hover_preview_on() {
            return;
        }
        let generation = self.audition_generation.get() + 1;
        self.audition_generation.set(generation);
        if self.audition_id.borrow().is_some() {
            self.begin_audition(id);
            return;
        }
        let (weak, id) = (Rc::downgrade(self), id.to_string());
        glib::timeout_add_local_once(Duration::from_millis(DWELL_MS), move || {
            if let Some(screen) = weak.upgrade() {
                if screen.audition_generation.get() == generation {
                    screen.begin_audition(&id);
                }
            }
        });
    }

    pub(super) fn deck_left(self: &Rc<Self>) {
        let generation = self.audition_generation.get() + 1;
        self.audition_generation.set(generation);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(LEAVE_GRACE_MS), move || {
            if let Some(screen) = weak.upgrade() {
                if screen.audition_generation.get() == generation {
                    screen.end_audition();
                }
            }
        });
    }

    pub(super) fn begin_audition(self: &Rc<Self>, id: &str) {
        let Some(profile) = self.engine.all_profiles().into_iter().find(|profile| profile.id == id) else {
            return;
        };
        if self.audition_id.borrow().as_deref() == Some(id) {
            return;
        }
        self.engine.begin_audition(profile.clone());
        *self.audition_id.borrow_mut() = Some(id.to_string());
        self.curve.set_preview(Some(profile.resolved_bands()));
        self.deck.set_hearing(Some(id));
        self.show_preview_pill(Some(&profile));
    }

    pub(super) fn end_audition(&self) {
        self.audition_generation.set(self.audition_generation.get() + 1);
        if self.audition_id.borrow_mut().take().is_none() {
            return;
        }
        self.engine.end_audition();
        self.curve.set_preview(None);
        self.deck.set_hearing(None);
        self.show_preview_pill(None);
    }

    fn show_preview_pill(&self, profile: Option<&EqualizerProfile>) {
        match profile {
            Some(profile) => {
                self.pill_label.set_text(&format!("Hearing {}", profile.name));
                self.preview_pill.set_reveal_child(true);
            }
            None => self.preview_pill.set_reveal_child(false),
        }
    }

    /// Picks a profile from the deck: the preview becomes the sound, and the
    /// equalizer turns on, as choosing one asks to hear it.
    pub(super) fn choose_profile(self: &Rc<Self>, id: &str) {
        self.end_audition();
        self.begin_gesture();
        self.engine.select(id);
        self.finish_gesture();
        self.refresh(false);
    }
}
