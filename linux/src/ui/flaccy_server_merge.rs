use crate::server_sync::{copy, Service};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_library::server_sync::MergeReport;
use gtk::glib;
use std::rc::Rc;

/// The one summary sheet of a first connect with data on both sides, with Undo for each line. Does nothing when the connect combined nothing.
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
        let row = line_row(&copy::merge_playlists_line(&names));
        wire_undo(&row, ui, &service, &report, Undo::Playlists);
        group.add(&row.row);
    }
    if !report.loves.is_empty() {
        let row = line_row(&copy::merge_loves_line(report.loves.len()));
        wire_undo(&row, ui, &service, &report, Undo::Loves);
        group.add(&row.row);
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
        .title(glib::markup_escape_text(&service.name()))
        .content_width(460)
        .child(&toolbar)
        .build();
    {
        let dialog = dialog.downgrade();
        ok.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.close();
            }
        });
    }
    dialog.present(Some(&ui.window));
}

enum Undo {
    Playlists,
    Loves,
}

struct Line {
    row: adw::ActionRow,
    undo: gtk::Button,
}

fn line_row(text: &str) -> Line {
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(text))
        .build();
    let undo = gtk::Button::with_label(copy::UNDO_BUTTON);
    undo.set_valign(gtk::Align::Center);
    row.add_suffix(&undo);
    Line { row, undo }
}

fn wire_undo(line: &Line, ui: &Rc<Ui>, service: &Rc<Service>, report: &MergeReport, kind: Undo) {
    let (ui, service, report) = (Rc::clone(ui), Rc::clone(service), report.clone());
    let (row, button) = (line.row.downgrade(), line.undo.clone());
    line.undo.connect_clicked(move |_| {
        button.set_sensitive(false);
        let (ui, service, report) = (Rc::clone(&ui), Rc::clone(&service), report.clone());
        let (row, button) = (row.clone(), button.clone());
        let playlists = matches!(kind, Undo::Playlists);
        glib::spawn_future_local(async move {
            let result = if playlists {
                undo_playlists(&service, &report).await
            } else {
                service.undo_loves(report.loves.clone()).await
            };
            match result {
                Ok(()) => {
                    button.set_visible(false);
                    if let Some(row) = row.upgrade() {
                        row.set_title(&glib::markup_escape_text(copy::UNDONE));
                    }
                }
                Err(message) => {
                    button.set_sensitive(true);
                    ui.core.toast(&message);
                }
            }
        });
    });
}

async fn undo_playlists(service: &Rc<Service>, report: &MergeReport) -> Result<(), String> {
    for merged in &report.playlists {
        service.undo_playlist(merged.clone()).await?;
    }
    Ok(())
}
