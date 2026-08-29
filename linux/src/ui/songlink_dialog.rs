use crate::songlink::{self, PlatformLink, SonglinkResult};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::rc::Rc;

/// The Share sheet iOS opens after a song.link lookup, in libadwaita shape:
/// the universal link with Copy, then every platform the page resolved, each
/// opening in the browser with a Copy on the row.
pub fn share(ui: &Rc<Ui>, title: String, artist: String, album: bool) {
    ui.core.toast("Finding links…");
    let ui_ref = Rc::clone(ui);
    songlink::lookup(
        &ui.core,
        title,
        artist,
        album,
        move |core, result| match result {
            Ok(found) => present(&ui_ref, &found),
            Err(_) => core.toast(songlink::failure_message(album)),
        },
    );
}

fn present(ui: &Rc<Ui>, result: &SonglinkResult) {
    let dialog = adw::Dialog::builder()
        .title("Share")
        .content_width(420)
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());

    let page = adw::PreferencesPage::new();

    let header = adw::PreferencesGroup::new();
    let heading = gtk::Box::new(gtk::Orientation::Vertical, 2);
    let title = gtk::Label::builder()
        .label(&result.title)
        .xalign(0.0)
        .wrap(true)
        .build();
    title.add_css_class("title-2");
    let artist = gtk::Label::builder()
        .label(&result.artist)
        .xalign(0.0)
        .wrap(true)
        .build();
    artist.add_css_class("dim-label");
    heading.append(&title);
    heading.append(&artist);
    header.add(&heading);
    page.add(&header);

    let universal = adw::PreferencesGroup::builder()
        .title("Universal Link")
        .build();
    universal.add(&link_row(
        ui,
        &dialog,
        "song.link",
        &result.page_url,
        "emblem-shared-symbolic",
    ));
    page.add(&universal);

    if !result.links.is_empty() {
        let platforms = adw::PreferencesGroup::builder().title("Listen On").build();
        for link in &result.links {
            platforms.add(&platform_row(ui, &dialog, link));
        }
        page.add(&platforms);
    }

    toolbar.set_content(Some(&page));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(&ui.window));
}

fn platform_row(ui: &Rc<Ui>, dialog: &adw::Dialog, link: &PlatformLink) -> adw::ActionRow {
    link_row(
        ui,
        dialog,
        &link.display_name,
        &link.url,
        "media-playback-start-symbolic",
    )
}

/// Activating opens the link; the trailing button copies it. Both toast so the
/// reader knows something happened before the browser steals focus.
fn link_row(
    ui: &Rc<Ui>,
    dialog: &adw::Dialog,
    name: &str,
    url: &str,
    icon: &str,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(name)
        .subtitle(glib::markup_escape_text(url).as_str())
        .activatable(true)
        .build();
    row.add_prefix(&gtk::Image::from_icon_name(icon));
    let copy = gtk::Button::from_icon_name("edit-copy-symbolic");
    copy.add_css_class("flat");
    copy.set_valign(gtk::Align::Center);
    copy.set_tooltip_text(Some("Copy link"));
    {
        let ui = Rc::clone(ui);
        let url = url.to_string();
        copy.connect_clicked(move |_| {
            songlink::copy_to_clipboard(&url);
            ui.core.toast("Link copied");
        });
    }
    row.add_suffix(&copy);
    {
        let url = url.to_string();
        let window = ui.window.clone();
        let dialog = dialog.clone();
        row.connect_activated(move |_| {
            gtk::UriLauncher::new(&url).launch(
                Some(&window),
                None::<&gtk::gio::Cancellable>,
                |result| {
                    if let Err(err) = result {
                        crate::logger::warn("songlink", &format!("open failed: {err}"));
                    }
                },
            );
            dialog.close();
        });
    }
    row
}
