//! The equalizer window: a non-modal window beside the library, the way
//! Music's equalizer window sits, that stays open while music plays. It is the
//! Linux counterpart of `MacEqualizerViewController` and edits through the
//! same `EqEngine` surface; the curve is the shared plot model and interaction
//! drawn with Cairo, and every gesture is one undo step.

mod bands;
mod copy;
mod curve;
mod deck;
pub mod demo;
mod edit;
mod import;
mod meter;
mod output;
mod presets;
mod refresh;
mod render;
mod undo;

use crate::eq::output::Output;
use crate::eq::EqEngine;
use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use bands::{BandEvent, BandTable, SimpleStrip};
use curve::{CurveEvent, CurveView};
use deck::Deck;
use flaccy_shared::equalizer::state::EqualizerState;
use gtk::{gdk, gio, glib};
use meter::MeterBar;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use undo::UndoStack;

const DEFAULT_SELECTION: usize = 5;
const PREAMP_UNDO_DELAY_MS: u64 = 500;

pub struct Screen {
    ui: Rc<Ui>,
    engine: Rc<EqEngine>,
    window: adw::Window,
    toasts: adw::ToastOverlay,
    curve: Rc<CurveView>,
    enable_switch: gtk::Switch,
    enable_label: gtk::Label,
    weak: Weak<Screen>,
    deck: Rc<Deck>,
    profile_label: gtk::Label,
    preview_pill: gtk::Revealer,
    pill_label: gtk::Label,
    audition_id: RefCell<Option<String>>,
    audition_generation: Cell<u64>,
    output_button: gtk::MenuButton,
    output_icon: gtk::Image,
    output_label: gtk::Label,
    output_signature: RefCell<String>,
    actions: gio::SimpleActionGroup,
    remember_action: gio::SimpleAction,
    compare_button: gtk::Button,
    mode_group: adw::ToggleGroup,
    preamp_scale: gtk::Scale,
    preamp_value: gtk::Label,
    auto_button: gtk::ToggleButton,
    peak_label: gtk::Label,
    meter_left: Rc<MeterBar>,
    meter_right: Rc<MeterBar>,
    hint_label: gtk::Label,
    status_icon: gtk::Image,
    status_label: gtk::Label,
    lower: gtk::Stack,
    strip: SimpleStrip,
    table: Rc<BandTable>,
    selected: Cell<usize>,
    undo: RefCell<UndoStack<EqualizerState>>,
    syncing: Cell<bool>,
    refresh_queued: Cell<bool>,
    finish_generation: Cell<u64>,
    guard_active: Cell<bool>,
    preamp_active: Cell<bool>,
    last_peak_text: RefCell<String>,
    analysis_on: Cell<bool>,
    comparing_with_space: Cell<bool>,
    demo_output: RefCell<Option<Output>>,
}

thread_local! {
    static SCREEN: RefCell<Option<Rc<Screen>>> = const { RefCell::new(None) };
}

fn screen(ui: &Rc<Ui>) -> Rc<Screen> {
    if let Some(existing) = SCREEN.with(|slot| slot.borrow().clone()) {
        return existing;
    }
    let built = Screen::build(ui);
    SCREEN.with(|slot| *slot.borrow_mut() = Some(Rc::clone(&built)));
    built
}

/// Opens the equalizer window, or brings it forward when it is already open.
pub fn present(ui: &Rc<Ui>) {
    let screen = screen(ui);
    screen.window.present();
    screen.curve.area.grab_focus();
}

/// Ctrl+E: hides the window while it is the one in front, shows it otherwise.
pub fn toggle(ui: &Rc<Ui>) {
    let screen = screen(ui);
    if screen.window.is_visible() && screen.window.is_active() {
        crate::logger::info("equalizer", "window hidden by toggle");
        screen.window.set_visible(false);
    } else {
        crate::logger::info("equalizer", "window shown by toggle");
        present(ui);
    }
}

/// Watches for the output changing so the person is told what the equalizer
/// switched to, the way the Apple clients announce it.
pub fn install(ui: &Rc<Ui>) {
    let core = Rc::clone(&ui.core);
    ui.core.hub.subscribe(move |event| {
        if let AppEvent::EqualizerOutputChanged { output_name, profile_name: Some(profile) } = event {
            core.toast(&format!("{output_name} · {profile}"));
        }
        true
    });
}

/// The capsule in the transport that opens the window, filled with the accent
/// while the equalizer is shaping the sound.
pub fn capsule_button(ui: &Rc<Ui>) -> gtk::Button {
    let button = gtk::Button::from_icon_name("flaccy-equalizer-symbolic");
    button.add_css_class("eq-capsule");
    button.set_valign(gtk::Align::Center);
    button.update_property(&[gtk::accessible::Property::Label("Equalizer")]);
    {
        let ui = Rc::clone(ui);
        button.connect_clicked(move |_| present(&ui));
    }
    let update = {
        let engine = Rc::clone(&ui.core.eq);
        let button = button.downgrade();
        move || {
            let Some(button) = button.upgrade() else { return };
            let running = engine.running_profile();
            if running.is_some() {
                button.add_css_class("running");
            } else {
                button.remove_css_class("running");
            }
            button.set_tooltip_text(Some(&match running {
                Some(profile) => format!("Equalizer · {}", profile.name),
                None => "Equalizer · Off".to_string(),
            }));
        }
    };
    update();
    ui.core.hub.subscribe_widget(&button, move |_, event| {
        if matches!(event, AppEvent::EqualizerChanged) {
            update();
        }
    });
    button
}

fn caption(text: &str) -> gtk::Label {
    let label = gtk::Label::builder().label(text).xalign(0.0).build();
    label.add_css_class("eq-caption");
    label
}

fn card(child: &impl IsA<gtk::Widget>) -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.add_css_class("eq-card");
    card.append(child);
    card
}

impl Screen {
    fn build(ui: &Rc<Ui>) -> Rc<Screen> {
        let screen = Rc::new_cyclic(|weak| Self::assemble(ui, weak.clone()));
        screen.wire();
        screen
    }

    fn assemble(ui: &Rc<Ui>, weak: Weak<Screen>) -> Screen {
        let engine = Rc::clone(&ui.core.eq);
        let (width, height) = {
            let config = ui.core.config.borrow();
            (config.eq_window_width.max(980), config.eq_window_height.max(640))
        };
        let window = adw::Window::builder()
            .title(copy::TITLE)
            .default_width(width)
            .default_height(height)
            .hide_on_close(true)
            .build();
        if let Some(application) = ui.window.application() {
            window.set_application(Some(&application));
        }
        window.set_size_request(980, 640);
        window.add_css_class("flaccy-window");
        window.add_css_class("eq-window");

        let actions = gio::SimpleActionGroup::new();
        window.insert_action_group("eqw", Some(&actions));

        let enable_switch = gtk::Switch::builder().valign(gtk::Align::Center).build();
        enable_switch.update_property(&[gtk::accessible::Property::Label("Equalizer on")]);
        let enable_label = gtk::Label::new(Some("Off"));
        enable_label.add_css_class("eq-enable-label");
        {
            let weak = weak.clone();
            enable_switch.connect_active_notify(move |switch| {
                if let Some(screen) = weak.upgrade() {
                    if !screen.syncing.get() {
                        screen.enable_toggled(switch.is_active());
                    }
                }
            });
        }

        let deck = Deck::build(weak.clone(), ui.core.config.borrow().eq_hover_preview);

        let save_button = gtk::Button::with_label("Save…");
        {
            let weak = weak.clone();
            save_button.connect_clicked(move |_| {
                if let Some(screen) = weak.upgrade() {
                    presets::prompt_save(&screen);
                }
            });
        }

        let output_icon = gtk::Image::from_icon_name("flaccy-speaker-symbolic");
        let output_label = gtk::Label::builder()
            .label("Output")
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .max_width_chars(22)
            .build();
        let output_content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        output_content.append(&output_icon);
        output_content.append(&output_label);
        let output_button = gtk::MenuButton::builder().child(&output_content).build();
        output_button.update_property(&[gtk::accessible::Property::Description(
            "Choose the profile for this output",
        )]);

        let compare_button = gtk::Button::with_label("Hold to compare");
        compare_button.set_tooltip_text(Some("Hold to hear the original without the equalizer"));
        {
            let press = gtk::GestureClick::new();
            press.set_button(gdk::BUTTON_PRIMARY);
            press.set_propagation_phase(gtk::PropagationPhase::Capture);
            let began = weak.clone();
            press.connect_pressed(move |_, _, _, _| {
                if let Some(screen) = began.upgrade() {
                    screen.begin_compare();
                }
            });
            let ended = weak.clone();
            press.connect_released(move |_, _, _, _| {
                if let Some(screen) = ended.upgrade() {
                    screen.end_compare();
                }
            });
            let cancelled = weak.clone();
            press.connect_cancel(move |_, _| {
                if let Some(screen) = cancelled.upgrade() {
                    screen.end_compare();
                }
            });
            compare_button.add_controller(press);

            let keys = gtk::EventControllerKey::new();
            let down = weak.clone();
            keys.connect_key_pressed(move |_, key, _, _| {
                if matches!(key, gdk::Key::space | gdk::Key::Return | gdk::Key::KP_Enter) {
                    if let Some(screen) = down.upgrade() {
                        screen.begin_compare();
                    }
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
            let up = weak.clone();
            keys.connect_key_released(move |_, key, _, _| {
                if matches!(key, gdk::Key::space | gdk::Key::Return | gdk::Key::KP_Enter) {
                    if let Some(screen) = up.upgrade() {
                        screen.end_compare();
                    }
                }
            });
            compare_button.add_controller(keys);
        }

        let mode_group = adw::ToggleGroup::new();
        mode_group.add(adw::Toggle::builder().name("simple").label("Simple").build());
        mode_group.add(adw::Toggle::builder().name("advanced").label("Advanced").build());
        mode_group.add_css_class("eq-mode");
        {
            let weak = weak.clone();
            mode_group.connect_active_notify(move |group| {
                if let Some(screen) = weak.upgrade() {
                    if !screen.syncing.get() {
                        screen.mode_chosen(group.active() == 1);
                    }
                }
            });
        }

        let spacer = gtk::Box::builder().hexpand(true).build();
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        for widget in [
            enable_switch.upcast_ref::<gtk::Widget>(),
            enable_label.upcast_ref(),
            output_button.upcast_ref(),
            save_button.upcast_ref(),
            spacer.upcast_ref(),
            compare_button.upcast_ref(),
            mode_group.upcast_ref(),
        ] {
            top.append(widget);
        }

        let preamp_value = gtk::Label::new(None);
        preamp_value.add_css_class("eq-preamp-value");
        let preamp_scale = gtk::Scale::with_range(gtk::Orientation::Vertical, -24.0, 6.0, 0.5);
        preamp_scale.set_inverted(true);
        preamp_scale.set_draw_value(false);
        preamp_scale.set_round_digits(1);
        preamp_scale.set_vexpand(true);
        preamp_scale.set_size_request(-1, 170);
        preamp_scale.update_property(&[gtk::accessible::Property::Label("Preamp")]);
        {
            let weak = weak.clone();
            preamp_scale.connect_change_value(move |_, _, value| {
                if let Some(screen) = weak.upgrade() {
                    screen.preamp_moved(value);
                }
                glib::Propagation::Proceed
            });
        }
        let meter_left = MeterBar::new();
        let meter_right = MeterBar::new();
        let meters = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        meters.append(&meter_left.area);
        meters.append(&meter_right.area);
        let fader_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        fader_row.set_vexpand(true);
        fader_row.append(&preamp_scale);
        fader_row.append(&meters);
        let peak_label = gtk::Label::new(Some("\u{2014}"));
        peak_label.add_css_class("eq-peak");
        let auto_button = gtk::ToggleButton::with_label("Auto");
        auto_button.add_css_class("eq-auto");
        {
            let weak = weak.clone();
            auto_button.connect_toggled(move |_| {
                if let Some(screen) = weak.upgrade() {
                    if !screen.syncing.get() {
                        screen.toggle_auto_preamp();
                    }
                }
            });
        }
        let rail = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .halign(gtk::Align::Center)
            .margin_top(14)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .build();
        rail.append(&caption("PREAMP"));
        rail.append(&preamp_value);
        rail.append(&fader_row);
        rail.append(&peak_label);
        rail.append(&auto_button);
        let rail_card = card(&rail);
        rail_card.set_size_request(104, -1);
        rail_card.set_hexpand(false);

        let curve = CurveView::new();
        {
            let weak = weak.clone();
            curve.set_handler(move |event| {
                if let Some(screen) = weak.upgrade() {
                    screen.curve_event(event);
                }
            });
        }
        let hint_label = gtk::Label::builder().halign(gtk::Align::Center).margin_bottom(10).build();
        hint_label.add_css_class("eq-hint");
        let profile_label = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        profile_label.add_css_class("eq-profile-name");
        let pill_label = gtk::Label::new(None);
        let pill_bars = crate::ui::controls::build_equalizer_indicator();
        crate::ui::controls::drive_equalizer(&pill_bars, true);
        pill_bars.set_tooltip_text(None);
        let pill = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        pill.add_css_class("eq-preview-pill");
        pill.append(&pill_bars);
        pill.append(&pill_label);
        let preview_pill = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::Crossfade)
            .transition_duration(140)
            .child(&pill)
            .halign(gtk::Align::End)
            .build();
        let title_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        title_row.add_css_class("eq-title-row");
        title_row.append(&profile_label);
        title_row.append(&preview_pill);
        let curve_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
        curve_box.append(&title_row);
        curve_box.append(&curve.area);
        curve_box.append(&hint_label);
        let curve_card = card(&curve_box);
        curve_card.set_hexpand(true);

        let middle = gtk::Box::new(gtk::Orientation::Horizontal, 16);
        middle.set_vexpand(true);
        middle.append(&rail_card);
        middle.append(&curve_card);

        let band_handler: bands::BandHandler = {
            let weak = weak.clone();
            Rc::new(move |event| {
                if let Some(screen) = weak.upgrade() {
                    screen.band_event(event);
                }
            })
        };
        let strip = SimpleStrip::new(Rc::clone(&band_handler));
        let table = BandTable::new(band_handler);
        let lower = gtk::Stack::builder().vhomogeneous(false).hhomogeneous(true).build();
        lower.add_named(&strip.widget, Some("simple"));
        lower.add_named(&table.widget, Some("advanced"));
        let lower_card = card(&lower);
        lower_card.set_vexpand(false);
        lower.set_vexpand(false);

        let status_icon = gtk::Image::from_icon_name("flaccy-check-circle-symbolic");
        let status_label = gtk::Label::new(None);
        status_label.add_css_class("eq-status");
        let keys_label = gtk::Label::builder()
            .label(copy::KEYS_HINT)
            .hexpand(true)
            .halign(gtk::Align::End)
            .xalign(1.0)
            .ellipsize(gtk::pango::EllipsizeMode::Start)
            .build();
        keys_label.add_css_class("eq-keys");
        let status = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        status.append(&status_icon);
        status.append(&status_label);
        status.append(&keys_label);

        let workspace = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(14)
            .hexpand(true)
            .build();
        for widget in [top.upcast_ref::<gtk::Widget>(), middle.upcast_ref(), lower_card.upcast_ref(), status.upcast_ref()] {
            workspace.append(widget);
        }
        deck.widget.set_margin_bottom(0);
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .margin_start(20)
            .margin_end(24)
            .margin_top(6)
            .margin_bottom(12)
            .build();
        root.append(&deck.widget);
        root.append(&workspace);

        let header = adw::HeaderBar::builder()
            .title_widget(&adw::WindowTitle::new(copy::TITLE, ""))
            .build();
        header.add_css_class("flat");
        let toolbar = adw::ToolbarView::new();
        toolbar.set_top_bar_style(adw::ToolbarStyle::Flat);
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&root));
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&toolbar));
        window.set_content(Some(&toasts));

        let remember_action = gio::SimpleAction::new_stateful("remember", None, &false.to_variant());
        actions.add_action(&remember_action);

        Screen {
            ui: Rc::clone(ui),
            engine,
            window,
            toasts,
            curve,
            enable_switch,
            enable_label,
            weak,
            deck,
            profile_label,
            preview_pill,
            pill_label,
            audition_id: RefCell::new(None),
            audition_generation: Cell::new(0),
            output_button,
            output_icon,
            output_label,
            output_signature: RefCell::new(String::new()),
            actions,
            remember_action,
            compare_button,
            mode_group,
            preamp_scale,
            preamp_value,
            auto_button,
            peak_label,
            meter_left,
            meter_right,
            hint_label,
            status_icon,
            status_label,
            lower,
            strip,
            table,
            selected: Cell::new(DEFAULT_SELECTION),
            undo: RefCell::new(UndoStack::new()),
            syncing: Cell::new(false),
            refresh_queued: Cell::new(false),
            finish_generation: Cell::new(0),
            guard_active: Cell::new(false),
            preamp_active: Cell::new(false),
            last_peak_text: RefCell::new(String::new()),
            analysis_on: Cell::new(false),
            comparing_with_space: Cell::new(false),
            demo_output: RefCell::new(None),
        }
    }

    /// Hooks the window to the engine, the frame clock and the keyboard once
    /// the screen exists as an `Rc`.
    fn wire(self: &Rc<Self>) {
        output::install_actions(self);
        presets::install_actions(self);

        let weak = Rc::downgrade(self);
        self.ui.core.hub.subscribe_widget(&self.window, {
            let weak = weak.clone();
            move |_, event| {
                if matches!(event, AppEvent::EqualizerChanged) {
                    if let Some(screen) = weak.upgrade() {
                        screen.schedule_refresh();
                    }
                }
            }
        });

        let spectrum_engine = Rc::clone(&self.engine);
        self.curve.set_spectrum_source(Some(Rc::new(move || {
            if demo::is_active() {
                Some(demo::spectrum_for(&spectrum_engine))
            } else {
                spectrum_engine.spectrum()
            }
        })));

        self.window.connect_map({
            let weak = weak.clone();
            move |_| {
                if let Some(screen) = weak.upgrade() {
                    screen.shown();
                }
            }
        });
        self.window.connect_is_active_notify({
            let weak = weak.clone();
            move |window| {
                if !window.is_active() {
                    if let Some(screen) = weak.upgrade() {
                        screen.end_audition();
                    }
                }
            }
        });
        self.window.connect_unmap({
            let weak = weak.clone();
            move |_| {
                if let Some(screen) = weak.upgrade() {
                    screen.hidden();
                }
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        {
            let weak = weak.clone();
            keys.connect_key_pressed(move |_, key, _, state| {
                let handled = weak.upgrade().is_some_and(|screen| screen.window_key_pressed(key, state));
                if handled {
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            });
        }
        {
            let weak = weak.clone();
            keys.connect_key_released(move |_, key, _, _| {
                if let Some(screen) = weak.upgrade() {
                    screen.window_key_released(key);
                }
            });
        }
        self.window.add_controller(keys);

        self.refresh(false);
    }

    fn shown(self: &Rc<Self>) {
        if !self.analysis_on.replace(true) {
            self.engine.begin_analysis();
        }
        let weak = Rc::downgrade(self);
        self.curve.start_frames(move || {
            if let Some(screen) = weak.upgrade() {
                screen.update_meter();
            }
        });
        self.refresh(false);
        self.deck.reveal_current();
    }

    fn hidden(&self) {
        self.remember_size();
        if self.analysis_on.replace(false) {
            self.engine.end_analysis();
        }
        self.curve.stop_frames();
        self.end_audition();
        self.engine.end_compare();
        self.comparing_with_space.set(false);
    }

    fn remember_size(&self) {
        let (width, height) = (self.window.width(), self.window.height());
        if width < 100 || height < 100 {
            return;
        }
        {
            let mut config = self.ui.core.config.borrow_mut();
            config.eq_window_width = width;
            config.eq_window_height = height;
        }
        self.ui.core.save_config();
    }

    fn toast(&self, message: &str) {
        let toast = adw::Toast::new(message);
        toast.set_timeout(2);
        self.toasts.add_toast(toast);
    }

    fn focus_is_text(&self) -> bool {
        gtk::prelude::GtkWindowExt::focus(&self.window)
            .is_some_and(|widget| widget.is::<gtk::Text>() || widget.is::<gtk::TextView>())
    }

    fn focus_takes_space(&self) -> bool {
        gtk::prelude::GtkWindowExt::focus(&self.window).is_some_and(|widget| {
            widget.is::<gtk::Text>()
                || widget.is::<gtk::TextView>()
                || widget.is::<gtk::Button>()
                || widget.is::<gtk::CheckButton>()
                || widget.is::<gtk::Switch>()
                || widget.is::<gtk::Range>()
                || widget.is::<gtk::ListBoxRow>()
        })
    }

    /// Ctrl+Z, Ctrl+Shift+Z and Space-to-compare, for whichever widget has focus
    /// as long as it is not one that wants those keys for itself.
    fn window_key_pressed(&self, key: gdk::Key, state: gdk::ModifierType) -> bool {
        let control = state.contains(gdk::ModifierType::CONTROL_MASK);
        let shift = state.contains(gdk::ModifierType::SHIFT_MASK);
        if control && matches!(key, gdk::Key::z | gdk::Key::Z) {
            if self.focus_is_text() {
                return false;
            }
            if shift {
                self.redo();
            } else {
                self.undo();
            }
            return true;
        }
        if control && matches!(key, gdk::Key::y | gdk::Key::Y) && !self.focus_is_text() {
            self.redo();
            return true;
        }
        if key == gdk::Key::space
            && !state.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK)
            && !self.focus_takes_space()
        {
            if !self.comparing_with_space.replace(true) {
                self.begin_compare();
            }
            return true;
        }
        false
    }

    fn window_key_released(&self, key: gdk::Key) {
        if key == gdk::Key::space && self.comparing_with_space.replace(false) {
            self.end_compare();
        }
    }

    fn band_event(&self, event: BandEvent) {
        self.handle_band_event(event);
    }

    fn curve_event(&self, event: CurveEvent) {
        self.handle_curve_event(event);
    }
}
