use crate::server_sync::copy;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::rc::Rc;

/// The one summary sheet of a first connect with data on both sides: what was combined, and a single OK. Does nothing when the connect combined nothing.
pub fn present(ui: &Rc<Ui>) {
    let Some(service) = ui.core.server_sync.get().cloned() else {
        return;
    };
    let Some(report) = service.merge().filter(|report| !report.is_empty()) else {
        return;
    };
    let group = adw::PreferencesGroup::new();
    if !report.playlists.is_empty() {
        let names: Vec<String> = report.playlists.iter().map(|merged| merged.name.clone()).collect();
        group.add(&line_row(&copy::merge_playlists_line(&names)));
    }
    if !report.loves.is_empty() {
        group.add(&line_row(&copy::merge_loves_line(report.loves.len())));
    }
    let ok = gtk::Button::with_label(copy::OK_BUTTON);
    ok.add_css_class("suggested-action");
    ok.add_css_class("pill");
    ok.set_halign(gtk::Align::Center);
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(16)
        .margin_top(12)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    body.append(&group);
    body.append(&ok);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&body));
    let dialog = adw::Dialog::builder()
        .title(copy::GROUP_TITLE)
        .content_width(460)
        .child(&toolbar)
        .build();
    let weak = dialog.downgrade();
    ok.connect_clicked(move |_| {
        if let Some(dialog) = weak.upgrade() {
            dialog.close();
        }
    });
    dialog.present(Some(&ui.window));
}

fn line_row(text: &str) -> adw::ActionRow {
    adw::ActionRow::builder()
        .title(glib::markup_escape_text(text))
        .build()
}
