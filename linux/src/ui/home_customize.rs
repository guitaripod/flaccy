//! Customize Home: the six sections in the person's order, each with a switch.
//! Reordering is by drag or Alt+Up / Alt+Down; every change is saved and Home
//! rebuilds behind the dialog at once.

use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::home::{Layout, Section};
use flaccy_shared::home_copy;
use gtk::{gdk, glib};
use std::cell::RefCell;
use std::rc::Rc;

struct Editor {
    ui: Rc<Ui>,
    list: gtk::ListBox,
    layout: RefCell<Layout>,
}

pub fn present(ui: &Rc<Ui>) {
    let layout = Layout::decode(Some(&ui.core.config.borrow().home_layout));
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    list.add_css_class("home-customize-list");
    let editor = Rc::new(Editor {
        ui: Rc::clone(ui),
        list: list.clone(),
        layout: RefCell::new(layout),
    });
    editor.fill();

    {
        let editor = Rc::clone(&editor);
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if !modifiers.contains(gdk::ModifierType::ALT_MASK) {
                return glib::Propagation::Proceed;
            }
            let step = match key {
                gdk::Key::Up => -1,
                gdk::Key::Down => 1,
                _ => return glib::Propagation::Proceed,
            };
            editor.move_focused(step);
            glib::Propagation::Stop
        });
        list.add_controller(keys);
    }

    let intro = gtk::Label::builder()
        .label(home_copy::CUSTOMIZE_INTRO)
        .wrap(true)
        .xalign(0.0)
        .build();
    intro.add_css_class("dim");
    let footer = gtk::Label::builder()
        .label(home_copy::CUSTOMIZE_FOOTER)
        .wrap(true)
        .xalign(0.0)
        .build();
    footer.add_css_class("dim");
    footer.add_css_class("caption");
    let restore = gtk::Button::with_label(home_copy::RESTORE_DEFAULT);
    restore.add_css_class("pill");
    restore.set_halign(gtk::Align::Center);
    {
        let editor = Rc::clone(&editor);
        restore.connect_clicked(move |_| editor.apply(Layout::standard(), None));
    }

    let content = gtk::Box::new(gtk::Orientation::Vertical, 16);
    content.set_margin_top(12);
    content.set_margin_bottom(24);
    content.set_margin_start(20);
    content.set_margin_end(20);
    content.append(&intro);
    content.append(&list);
    content.append(&footer);
    content.append(&restore);

    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&content)
        .build();
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&adw::WindowTitle::new(home_copy::CUSTOMIZE_TITLE, "")));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&scroller));

    let dialog = adw::Dialog::builder()
        .title(home_copy::CUSTOMIZE_TITLE)
        .content_width(480)
        .content_height(640)
        .child(&toolbar)
        .build();
    dialog.present(Some(&ui.window));
}

impl Editor {
    fn fill(self: &Rc<Self>) {
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        let layout = self.layout.borrow().clone();
        for (position, section) in layout.order().iter().copied().enumerate() {
            self.list.append(&self.row(position, section, &layout));
        }
    }

    fn row(self: &Rc<Self>, position: usize, section: Section, layout: &Layout) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .title(home_copy::section_title(section))
            .subtitle(home_copy::section_subtitle(section))
            .build();
        let handle = gtk::Image::from_icon_name("list-drag-handle-symbolic");
        handle.add_css_class("dim");
        handle.set_tooltip_text(Some("Drag to reorder"));
        row.add_prefix(&handle);
        let switch = gtk::Switch::builder()
            .active(layout.is_visible(section))
            .valign(gtk::Align::Center)
            .build();
        switch.update_property(&[gtk::accessible::Property::Label(&format!(
            "Show {}",
            home_copy::section_title(section)
        ))]);
        {
            let editor = Rc::downgrade(self);
            switch.connect_active_notify(move |switch| {
                if let Some(editor) = editor.upgrade() {
                    let layout = editor.layout.borrow().setting(section, switch.is_active());
                    editor.apply(layout, Some(position));
                }
            });
        }
        row.add_suffix(&switch);
        row.set_activatable_widget(Some(&switch));

        let source = gtk::DragSource::new();
        source.set_actions(gdk::DragAction::MOVE);
        source.connect_prepare(move |_, _, _| {
            Some(gdk::ContentProvider::for_value(
                &(position as u32).to_value(),
            ))
        });
        row.add_controller(source);
        let target = gtk::DropTarget::new(glib::Type::U32, gdk::DragAction::MOVE);
        {
            let editor = Rc::downgrade(self);
            target.connect_drop(move |_, value, _, _| {
                let (Some(editor), Ok(from)) = (editor.upgrade(), value.get::<u32>()) else {
                    return false;
                };
                let layout = editor
                    .layout
                    .borrow()
                    .moving(from as usize, position as isize);
                editor.apply(layout, Some(position));
                true
            });
        }
        row.add_controller(target);
        row
    }

    /// Alt+Up / Alt+Down moves the section holding the focus one place.
    fn move_focused(self: &Rc<Self>, step: isize) {
        let Some(row) = self
            .list
            .focus_child()
            .and_then(|child| child.downcast::<gtk::ListBoxRow>().ok())
        else {
            return;
        };
        let from = row.index().max(0) as usize;
        let to = (from as isize + step).clamp(0, 5);
        if to as usize == from {
            return;
        }
        let layout = self.layout.borrow().moving(from, to);
        self.apply(layout, Some(to as usize));
    }

    /// Saves `layout`, redraws the rows with the focus on `focus`, and tells
    /// Home to rebuild.
    fn apply(self: &Rc<Self>, layout: Layout, focus: Option<usize>) {
        if *self.layout.borrow() == layout {
            return;
        }
        {
            let mut config = self.ui.core.config.borrow_mut();
            config.home_layout = if layout.is_standard() {
                String::new()
            } else {
                layout.encoded()
            };
        }
        self.ui.core.save_config();
        *self.layout.borrow_mut() = layout;
        self.fill();
        if let Some(row) = focus.and_then(|index| self.list.row_at_index(index as i32)) {
            row.grab_focus();
        }
        self.ui.core.hub.emit(&AppEvent::HomeChanged);
    }
}
