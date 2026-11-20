//! The card under the curve. Simple mode shows ten cells, one per ISO centre,
//! each with a typed gain and a pair of steppers; Advanced shows a table of
//! the filters with every value editable. Both only report what the person
//! asked for; the screen decides what that does to the profile.

use super::copy;
use super::render;
use adw::prelude::*;
use flaccy_shared::equalizer::biquad::FilterType;
use flaccy_shared::equalizer::graphic::GraphicSolver;
use flaccy_shared::equalizer::profile::EqualizerBand;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

#[derive(Clone, Debug, PartialEq)]
pub enum BandEvent {
    Select(usize),
    Reset(usize),
    Step { index: usize, delta: f64 },
    SetTarget { index: usize, value: f64 },
    Enable { index: usize, on: bool },
    SetType { index: usize, filter_type: FilterType },
    SetFrequency { index: usize, hertz: f64 },
    SetGain { index: usize, decibels: f64 },
    SetQ { index: usize, q: f64 },
    Add,
    Remove,
}

pub type BandHandler = Rc<dyn Fn(BandEvent)>;

/// Tells when an entry is being typed in, so a refresh never overwrites it.
fn track_editing(entry: &gtk::Entry) -> Rc<Cell<bool>> {
    let editing = Rc::new(Cell::new(false));
    let focus = gtk::EventControllerFocus::new();
    {
        let editing = Rc::clone(&editing);
        focus.connect_enter(move |_| editing.set(true));
    }
    {
        let editing = Rc::clone(&editing);
        focus.connect_leave(move |_| editing.set(false));
    }
    entry.add_controller(focus);
    editing
}

/// Calls `commit` with the entry's text when Enter is pressed or focus leaves,
/// and puts `restore()`'s text back if the commit did not take.
fn on_commit(entry: &gtk::Entry, commit: impl Fn(&str) -> bool + 'static, restore: impl Fn() -> String + 'static) {
    let commit = Rc::new(commit);
    let restore = Rc::new(restore);
    let finish = {
        let commit = Rc::clone(&commit);
        let restore = Rc::clone(&restore);
        move |entry: &gtk::Entry| {
            if !commit(entry.text().as_str()) {
                entry.set_text(&restore());
            }
        }
    };
    {
        let finish = finish.clone();
        entry.connect_activate(move |entry| finish(entry));
    }
    let focus = gtk::EventControllerFocus::new();
    {
        let entry = entry.downgrade();
        focus.connect_leave(move |_| {
            if let Some(entry) = entry.upgrade() {
                finish(&entry);
            }
        });
    }
    entry.add_controller(focus);
}

struct Cell10 {
    root: gtk::Box,
    frequency: gtk::Button,
    entry: gtk::Entry,
    editing: Rc<Cell<bool>>,
}

pub struct SimpleStrip {
    pub widget: gtk::Box,
    cells: Vec<Cell10>,
    shown: Rc<RefCell<Vec<f64>>>,
}

impl SimpleStrip {
    pub fn new(handler: BandHandler) -> Self {
        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .homogeneous(true)
            .margin_top(10)
            .margin_bottom(10)
            .margin_start(14)
            .margin_end(14)
            .build();
        let shown = Rc::new(RefCell::new(vec![0.0; GraphicSolver::CENTRES.len()]));
        let mut cells = Vec::new();
        for (index, &centre) in GraphicSolver::CENTRES.iter().enumerate() {
            let root = gtk::Box::builder()
                .orientation(gtk::Orientation::Vertical)
                .spacing(6)
                .halign(gtk::Align::Center)
                .build();
            root.add_css_class("eq-cell");

            let frequency = gtk::Button::with_label(&copy::hertz(centre));
            frequency.add_css_class("flat");
            frequency.add_css_class("eq-cell-frequency");
            frequency.set_tooltip_text(Some("Resets this band"));
            {
                let handler = Rc::clone(&handler);
                frequency.connect_clicked(move |_| handler(BandEvent::Reset(index)));
            }

            let entry = gtk::Entry::builder()
                .width_chars(6)
                .max_width_chars(6)
                .xalign(0.5)
                .halign(gtk::Align::Center)
                .build();
            entry.add_css_class("eq-value");
            entry.update_property(&[gtk::accessible::Property::Label(&format!(
                "Gain at {}",
                copy::hertz(centre)
            ))]);
            let editing = track_editing(&entry);
            {
                let handler = Rc::clone(&handler);
                let shown = Rc::clone(&shown);
                on_commit(
                    &entry,
                    {
                        let handler = Rc::clone(&handler);
                        move |text| match copy::parse_number(text) {
                            Some(value) => {
                                handler(BandEvent::SetTarget { index, value });
                                true
                            }
                            None => false,
                        }
                    },
                    move || copy::decibels(shown.borrow()[index]),
                );
            }
            {
                let handler = Rc::clone(&handler);
                let focus = gtk::EventControllerFocus::new();
                focus.connect_enter(move |_| handler(BandEvent::Select(index)));
                entry.add_controller(focus);
            }

            let up = stepper("flaccy-chevron-up-symbolic", "Raise 0.5 dB");
            let down = stepper("flaccy-chevron-down-symbolic", "Lower 0.5 dB");
            {
                let handler = Rc::clone(&handler);
                up.connect_clicked(move |_| handler(BandEvent::Step { index, delta: 0.5 }));
            }
            {
                let handler = Rc::clone(&handler);
                down.connect_clicked(move |_| handler(BandEvent::Step { index, delta: -0.5 }));
            }
            let steppers = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            steppers.add_css_class("linked");
            steppers.append(&up);
            steppers.append(&down);
            steppers.set_halign(gtk::Align::Center);

            root.append(&frequency);
            root.append(&entry);
            root.append(&steppers);

            let click = gtk::GestureClick::new();
            {
                let handler = Rc::clone(&handler);
                click.connect_pressed(move |_, _, _, _| handler(BandEvent::Select(index)));
            }
            root.add_controller(click);

            widget.append(&root);
            cells.push(Cell10 { root, frequency, entry, editing });
        }
        Self { widget, cells, shown }
    }

    pub fn configure(&self, targets: &[f64], selected: usize) {
        *self.shown.borrow_mut() = (0..self.cells.len())
            .map(|index| targets.get(index).copied().unwrap_or(0.0))
            .collect();
        for (index, cell) in self.cells.iter().enumerate() {
            let value = self.shown.borrow()[index];
            if !cell.editing.get() {
                cell.entry.set_text(&copy::decibels(value));
            }
            if index == selected {
                cell.root.add_css_class("eq-cell-selected");
                cell.frequency.add_css_class("selected");
            } else {
                cell.root.remove_css_class("eq-cell-selected");
                cell.frequency.remove_css_class("selected");
            }
        }
    }
}

fn stepper(icon: &str, label: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.set_tooltip_text(Some(label));
    button.update_property(&[gtk::accessible::Property::Label(label)]);
    button.add_css_class("eq-stepper");
    button
}

const COLUMNS: [(&str, i32); 6] = [
    ("Band", 56),
    ("On", 44),
    ("Type", 128),
    ("Frequency", 112),
    ("Gain", 96),
    ("Q", 80),
];

struct TableRow {
    row: gtk::ListBoxRow,
    check: gtk::CheckButton,
    dropdown: gtk::DropDown,
    frequency: gtk::Entry,
    frequency_editing: Rc<Cell<bool>>,
    gain: gtk::Entry,
    gain_editing: Rc<Cell<bool>>,
    q: gtk::Entry,
    q_editing: Rc<Cell<bool>>,
    index_label: gtk::Label,
}

pub struct BandTable {
    pub widget: gtk::Box,
    list: gtk::ListBox,
    rows: RefCell<Vec<TableRow>>,
    shown: Rc<RefCell<Vec<EqualizerBand>>>,
    handler: BandHandler,
    updating: Rc<Cell<bool>>,
    add: gtk::Button,
    remove: gtk::Button,
}

impl BandTable {
    pub fn new(handler: BandHandler) -> Rc<Self> {
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::Single)
            .build();
        list.add_css_class("eq-table");
        list.update_property(&[gtk::accessible::Property::Label("Equalizer bands")]);

        let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        header.add_css_class("eq-table-header");
        for (title, width) in COLUMNS {
            let label = gtk::Label::builder()
                .label(title)
                .xalign(0.0)
                .width_request(width)
                .build();
            label.add_css_class("eq-caption");
            header.append(&label);
        }

        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .min_content_height(188)
            .vexpand(true)
            .hexpand(true)
            .child(&list)
            .build();
        let table = gtk::Box::new(gtk::Orientation::Vertical, 2);
        table.set_hexpand(true);
        table.append(&header);
        table.append(&scroll);

        let add = gtk::Button::from_icon_name("flaccy-add-symbolic");
        add.set_tooltip_text(Some("Add band"));
        add.update_property(&[gtk::accessible::Property::Label("Add band")]);
        let remove = gtk::Button::from_icon_name("flaccy-remove-symbolic");
        remove.set_tooltip_text(Some("Remove band"));
        remove.update_property(&[gtk::accessible::Property::Label("Remove band")]);
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        buttons.add_css_class("linked");
        buttons.set_valign(gtk::Align::Start);
        buttons.append(&add);
        buttons.append(&remove);
        {
            let handler = Rc::clone(&handler);
            add.connect_clicked(move |_| handler(BandEvent::Add));
        }
        {
            let handler = Rc::clone(&handler);
            remove.connect_clicked(move |_| handler(BandEvent::Remove));
        }

        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(10)
            .margin_top(10)
            .margin_bottom(8)
            .margin_start(16)
            .margin_end(14)
            .build();
        widget.append(&table);
        widget.append(&buttons);

        let table = Rc::new(Self {
            widget,
            list,
            rows: RefCell::new(Vec::new()),
            shown: Rc::new(RefCell::new(Vec::new())),
            handler,
            updating: Rc::new(Cell::new(false)),
            add,
            remove,
        });
        {
            let weak = Rc::downgrade(&table);
            table.list.connect_row_selected(move |_, row| {
                let Some(table) = weak.upgrade() else { return };
                if table.updating.get() {
                    return;
                }
                if let Some(row) = row {
                    (table.handler)(BandEvent::Select(row.index() as usize));
                }
            });
        }
        table
    }

    pub fn configure(&self, bands: &[EqualizerBand], selected: usize) {
        self.updating.set(true);
        *self.shown.borrow_mut() = bands.to_vec();
        if self.rows.borrow().len() != bands.len() {
            self.rebuild(bands.len());
        }
        for (index, (row, band)) in self.rows.borrow().iter().zip(bands).enumerate() {
            Self::fill(row, band, index);
        }
        if let Some(row) = self.rows.borrow().get(selected) {
            self.list.select_row(Some(&row.row));
        } else {
            self.list.unselect_all();
        }
        self.add.set_sensitive(bands.len() < EqualizerBand::MAXIMUM_PER_PROFILE);
        self.remove.set_sensitive(bands.len() > 1);
        self.updating.set(false);
    }

    fn rebuild(&self, count: usize) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let mut rows = Vec::new();
        for index in 0..count {
            let row = self.build_row(index);
            self.list.append(&row.row);
            rows.push(row);
        }
        *self.rows.borrow_mut() = rows;
    }

    fn fill(row: &TableRow, band: &EqualizerBand, index: usize) {
        row.index_label.set_markup(&format!(
            "<span foreground=\"{}\" weight=\"bold\">{}</span>",
            render::band_color_css(index),
            index + 1
        ));
        row.check.set_active(band.is_enabled);
        let position = copy::FILTER_TYPES
            .iter()
            .position(|candidate| *candidate == band.filter_type)
            .unwrap_or(0) as u32;
        if row.dropdown.selected() != position {
            row.dropdown.set_selected(position);
        }
        if !row.frequency_editing.get() {
            row.frequency.set_text(&copy::hertz(band.frequency));
        }
        let has_gain = band.filter_type.has_gain();
        if !row.gain_editing.get() {
            row.gain.set_text(&if has_gain {
                format!("{} dB", copy::decibels(band.gain))
            } else {
                "\u{2014}".to_string()
            });
        }
        row.gain.set_sensitive(has_gain);
        if !row.q_editing.get() {
            row.q.set_text(&copy::q(band.q));
        }
    }

    fn field(&self, width: i32, label: &str) -> (gtk::Entry, Rc<Cell<bool>>) {
        let entry = gtk::Entry::builder()
            .width_chars(1)
            .max_width_chars(1)
            .has_frame(false)
            .hexpand(false)
            .halign(gtk::Align::Start)
            .build();
        entry.add_css_class("eq-field");
        entry.set_size_request(width, -1);
        entry.update_property(&[gtk::accessible::Property::Label(label)]);
        let editing = track_editing(&entry);
        (entry, editing)
    }

    fn build_row(&self, index: usize) -> TableRow {
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        content.add_css_class("eq-table-row");

        let index_label = gtk::Label::builder().xalign(0.0).width_request(COLUMNS[0].1).build();
        index_label.add_css_class("eq-index");

        let check = gtk::CheckButton::new();
        check.set_halign(gtk::Align::Start);
        check.set_size_request(COLUMNS[1].1, -1);
        check.update_property(&[gtk::accessible::Property::Label(&format!("Band {} on", index + 1))]);
        {
            let handler = Rc::clone(&self.handler);
            let updating = Rc::clone(&self.updating);
            check.connect_toggled(move |check| {
                if !updating.get() {
                    handler(BandEvent::Enable { index, on: check.is_active() });
                }
            });
        }

        let names: Vec<&str> = copy::FILTER_TYPES.iter().map(|t| copy::type_name(*t)).collect();
        let dropdown = gtk::DropDown::from_strings(&names);
        dropdown.set_size_request(COLUMNS[2].1 - 8, -1);
        dropdown.set_halign(gtk::Align::Start);
        dropdown.add_css_class("eq-type");
        dropdown.update_property(&[gtk::accessible::Property::Label(&format!("Band {} type", index + 1))]);
        {
            let handler = Rc::clone(&self.handler);
            let updating = Rc::clone(&self.updating);
            dropdown.connect_selected_notify(move |dropdown| {
                if updating.get() {
                    return;
                }
                if let Some(filter_type) = copy::FILTER_TYPES.get(dropdown.selected() as usize) {
                    handler(BandEvent::SetType { index, filter_type: *filter_type });
                }
            });
        }
        let dropdown_slot = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        dropdown_slot.set_size_request(COLUMNS[2].1, -1);
        dropdown_slot.append(&dropdown);

        let (frequency, frequency_editing) = self.field(COLUMNS[3].1, &format!("Band {} frequency", index + 1));
        let (gain, gain_editing) = self.field(COLUMNS[4].1, &format!("Band {} gain", index + 1));
        let (q, q_editing) = self.field(COLUMNS[5].1, &format!("Band {} Q", index + 1));

        let shown = Rc::clone(&self.shown);
        let handler = Rc::clone(&self.handler);
        on_commit(
            &frequency,
            {
                let handler = Rc::clone(&handler);
                move |text| match copy::parse_frequency(text) {
                    Some(hertz) => {
                        handler(BandEvent::SetFrequency { index, hertz });
                        true
                    }
                    None => false,
                }
            },
            {
                let shown = Rc::clone(&shown);
                move || shown.borrow().get(index).map(|b| copy::hertz(b.frequency)).unwrap_or_default()
            },
        );
        on_commit(
            &gain,
            {
                let handler = Rc::clone(&handler);
                move |text| match copy::parse_number(text) {
                    Some(decibels) => {
                        handler(BandEvent::SetGain { index, decibels });
                        true
                    }
                    None => false,
                }
            },
            {
                let shown = Rc::clone(&shown);
                move || {
                    shown
                        .borrow()
                        .get(index)
                        .map(|b| {
                            if b.filter_type.has_gain() {
                                format!("{} dB", copy::decibels(b.gain))
                            } else {
                                "\u{2014}".to_string()
                            }
                        })
                        .unwrap_or_default()
                }
            },
        );
        on_commit(
            &q,
            {
                let handler = Rc::clone(&handler);
                move |text| match copy::parse_number(text) {
                    Some(q) => {
                        handler(BandEvent::SetQ { index, q });
                        true
                    }
                    None => false,
                }
            },
            {
                let shown = Rc::clone(&shown);
                move || shown.borrow().get(index).map(|b| copy::q(b.q)).unwrap_or_default()
            },
        );

        for widget in [
            index_label.upcast_ref::<gtk::Widget>(),
            check.upcast_ref(),
            dropdown_slot.upcast_ref(),
            frequency.upcast_ref(),
            gain.upcast_ref(),
            q.upcast_ref(),
        ] {
            content.append(widget);
        }
        let row = gtk::ListBoxRow::new();
        row.set_child(Some(&content));
        TableRow {
            row,
            check,
            dropdown,
            frequency,
            frequency_editing,
            gain,
            gain_editing,
            q,
            q_editing,
            index_label,
        }
    }
}
