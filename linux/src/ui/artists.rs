use crate::events::AppEvent;
use crate::library::Album;
use crate::ui::{albums, Ui};
use adw::prelude::*;
use gtk::pango;
use std::cell::RefCell;
use std::rc::Rc;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .margin_top(18)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .valign(gtk::Align::Start)
        .build();
    list.add_css_class("boxed-list");

    let names: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));

    {
        let query = Rc::clone(&ui.query);
        let names = Rc::clone(&names);
        list.set_filter_func(move |row| {
            let query = query.borrow();
            if query.is_empty() {
                return true;
            }
            names
                .borrow()
                .get(row.index().max(0) as usize)
                .map(|name| name.to_lowercase().contains(&query.to_lowercase()))
                .unwrap_or(true)
        });
    }

    {
        let ui = Rc::clone(ui);
        let names = Rc::clone(&names);
        list.connect_row_activated(move |_, row| {
            let name = names.borrow().get(row.index().max(0) as usize).cloned();
            if let Some(name) = name {
                push_artist_page(&ui, &name);
            }
        });
    }

    let empty = adw::StatusPage::builder()
        .icon_name("system-users-symbolic")
        .title("No Artists")
        .description("Artists appear here once your library has music.")
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(760).child(&list).build())
        .build();

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("list"));

    let rebuild = {
        let list = list.clone();
        let stack = stack.clone();
        let names = Rc::clone(&names);
        let ui = Rc::clone(ui);
        move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            let library = ui.core.library.borrow().clone();
            let mut collected = Vec::new();
            for artist in &library.artists {
                collected.push(artist.name.clone());
                let row_box = gtk::Box::builder()
                    .orientation(gtk::Orientation::Horizontal)
                    .spacing(14)
                    .margin_top(8)
                    .margin_bottom(8)
                    .margin_start(10)
                    .margin_end(10)
                    .build();
                let avatar = adw::Avatar::new(44, Some(&artist.name), true);
                row_box.append(&avatar);
                let text_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
                let name = gtk::Label::builder()
                    .label(&artist.name)
                    .xalign(0.0)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build();
                name.add_css_class("album-title");
                text_box.append(&name);
                let counts = gtk::Label::builder()
                    .label(format!(
                        "{} album{} · {} track{}",
                        artist.album_count,
                        if artist.album_count == 1 { "" } else { "s" },
                        artist.track_count,
                        if artist.track_count == 1 { "" } else { "s" }
                    ))
                    .xalign(0.0)
                    .build();
                counts.add_css_class("dim");
                counts.add_css_class("caption");
                text_box.append(&counts);
                row_box.append(&text_box);
                list.append(&gtk::ListBoxRow::builder().child(&row_box).build());
            }
            *names.borrow_mut() = collected;
            stack.set_visible_child_name(if library.artists.is_empty() {
                "empty"
            } else {
                "list"
            });
        }
    };
    rebuild();

    {
        let list = list.clone();
        let rebuild = rebuild.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::LibraryReloaded => rebuild(),
            AppEvent::SearchChanged(_) => list.invalidate_filter(),
            _ => {}
        });
    }

    stack.upcast()
}

pub fn push_artist_page(ui: &Rc<Ui>, artist: &str) {
    let library = ui.core.library.borrow().clone();
    let albums: Vec<Album> = library
        .albums
        .iter()
        .filter(|album| album.artist == artist)
        .cloned()
        .collect();

    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .column_spacing(18)
        .row_spacing(24)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .min_children_per_line(2)
        .max_children_per_line(10)
        .valign(gtk::Align::Start)
        .activate_on_single_click(true)
        .build();
    for album in &albums {
        flow.append(&album_cell_for_artist(ui, album));
    }
    {
        let ui = Rc::clone(ui);
        let albums = albums.clone();
        flow.connect_child_activated(move |_, child| {
            if let Some(album) = albums.get(child.index().max(0) as usize) {
                albums::push_album_detail(&ui, album);
            }
        });
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(18)
        .margin_top(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    let avatar = adw::Avatar::new(72, Some(artist), true);
    header.append(&avatar);
    let title_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    title_box.set_valign(gtk::Align::Center);
    let title = gtk::Label::builder().label(artist).xalign(0.0).build();
    title.add_css_class("title-1");
    title_box.append(&title);
    let station = gtk::Button::builder().label("Start Station").build();
    station.add_css_class("pill");
    station.add_css_class("suggested-action");
    station.set_halign(gtk::Align::Start);
    station.set_action_name(Some("win.artist-station"));
    station.set_action_target_value(Some(&artist.to_variant()));
    title_box.append(&station);
    header.append(&title_box);

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&header);
    if let Some(bio) = ui.core.db.artist_bio(artist).filter(|b| !b.is_empty()) {
        let bio_label = gtk::Label::builder()
            .label(&bio)
            .xalign(0.0)
            .wrap(true)
            .margin_top(14)
            .margin_start(24)
            .margin_end(24)
            .build();
        bio_label.add_css_class("dim");
        content.append(&bio_label);
    }
    content.append(&flow);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&content)
        .build();

    let page = adw::NavigationPage::builder()
        .title(artist)
        .child(&scroll)
        .build();
    ui.nav.push(&page);
}

fn album_cell_for_artist(ui: &Rc<Ui>, album: &Album) -> gtk::FlowBoxChild {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(168)
        .build();
    let picture = gtk::Picture::builder()
        .width_request(168)
        .height_request(168)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        ui.core
            .artwork
            .request(&album.title, &album.artist, 168, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    cell.append(&picture);
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);
    if let Some(year) = album.year.as_ref().filter(|y| !y.is_empty()) {
        let year_label = gtk::Label::builder().label(year).xalign(0.0).build();
        year_label.add_css_class("dim");
        year_label.add_css_class("caption");
        cell.append(&year_label);
    }
    let child = gtk::FlowBoxChild::builder().child(&cell).build();
    crate::ui::context::attach_album_context_menu(&child, album.key());
    child
}
