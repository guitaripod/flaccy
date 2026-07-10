use crate::db::Db;
use crate::events::AppEvent;
use crate::library::Track;
use crate::suggested::{self, SuggestedPlaylist};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// "Made for you" shelf on the Albums page: Heavy Rotation / On Repeat /
/// Rediscover cards computed off-main from local scrobbles.
pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let shelf = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .margin_top(20)
        .margin_start(24)
        .margin_end(24)
        .build();
    shelf.set_visible(false);

    let title = gtk::Label::builder().label("MADE FOR YOU").xalign(0.0).build();
    title.add_css_class("stat-caption");
    shelf.append(&title);

    let cards = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .homogeneous(true)
        .build();
    shelf.append(&cards);

    let computing = Rc::new(Cell::new(false));
    let rerun_wanted = Rc::new(Cell::new(false));
    let recompute: Rc<RefCell<Option<Rc<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    let recompute_impl = {
        let ui = Rc::clone(ui);
        let shelf = shelf.clone();
        let cards = cards.clone();
        let computing = Rc::clone(&computing);
        let rerun_wanted = Rc::clone(&rerun_wanted);
        let recompute = Rc::clone(&recompute);
        Rc::new(move || {
            if computing.replace(true) {
                rerun_wanted.set(true);
                return;
            }
            let library = ui.core.library.borrow().clone();
            let pool = library.tracks.clone();
            let db_path = ui.core.db_path.clone();
            let (tx, rx) = async_channel::bounded::<Vec<SuggestedPlaylist>>(1);
            std::thread::Builder::new()
                .name("flaccy-suggested".into())
                .spawn(move || {
                    let playlists = Db::open(&db_path)
                        .map(|db| {
                            let rows = db.fetch_all_scrobble_rows();
                            suggested::build(&pool, &rows, chrono::Utc::now().timestamp())
                        })
                        .unwrap_or_default();
                    let _ = tx.send_blocking(playlists);
                })
                .ok();
            let ui = Rc::clone(&ui);
            let shelf = shelf.clone();
            let cards = cards.clone();
            let computing = Rc::clone(&computing);
            let rerun_wanted = Rc::clone(&rerun_wanted);
            let recompute = Rc::clone(&recompute);
            glib::spawn_future_local(async move {
                let playlists = rx.recv().await.unwrap_or_default();
                computing.set(false);
                if rerun_wanted.replace(false) {
                    if let Some(recompute) = recompute.borrow().clone() {
                        recompute();
                    }
                }
                while let Some(child) = cards.first_child() {
                    cards.remove(&child);
                }
                if playlists.is_empty() {
                    shelf.set_visible(false);
                    return;
                }
                for playlist in &playlists {
                    cards.append(&card(&ui, playlist));
                }
                shelf.set_visible(true);
            });
        })
    };
    *recompute.borrow_mut() = Some(recompute_impl);
    let run_recompute = {
        let recompute = Rc::clone(&recompute);
        Rc::new(move || {
            if let Some(recompute) = recompute.borrow().clone() {
                recompute();
            }
        })
    };
    run_recompute();

    {
        let run_recompute = Rc::clone(&run_recompute);
        ui.core.hub.subscribe_widget(&shelf, move |_, event| match event {
            AppEvent::LibraryReloaded => run_recompute(),
            AppEvent::HistoryImport { done: true, .. } => run_recompute(),
            _ => {}
        });
    }

    shelf.upcast()
}

fn card(ui: &Rc<Ui>, playlist: &SuggestedPlaylist) -> gtk::Widget {
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    card.add_css_class("suggested-card");

    let artwork = gtk::Picture::builder()
        .width_request(56)
        .height_request(56)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Center)
        .build();
    artwork.set_overflow(gtk::Overflow::Hidden);
    artwork.add_css_class("cover");
    if let Some(first) = playlist.tracks.first() {
        artwork.set_paintable(Some(
            &ui.core
                .artwork
                .placeholder(&format!("{}|{}", first.album, first.artist)),
        ));
        let weak = artwork.downgrade();
        ui.core
            .artwork
            .request(&first.album, &first.artist, 56, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    card.append(&artwork);

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
    text_box.set_hexpand(true);
    text_box.set_valign(gtk::Align::Center);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header.append(&gtk::Image::from_icon_name(playlist.icon_name));
    let name = gtk::Label::builder().label(&playlist.title).xalign(0.0).build();
    name.add_css_class("album-title");
    header.append(&name);
    text_box.append(&header);
    let subtitle = gtk::Label::builder()
        .label(format!("{} · {} songs", playlist.subtitle, playlist.tracks.len()))
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    text_box.append(&subtitle);
    card.append(&text_box);

    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.set_valign(gtk::Align::Center);
    play.set_tooltip_text(Some(&format!("Play {}", playlist.title)));
    {
        let ui = Rc::clone(ui);
        let tracks: Vec<Track> = playlist.tracks.clone();
        let title = playlist.title.clone();
        play.connect_clicked(move |_| {
            crate::logger::info("ui", &format!("suggested playlist play: {title}"));
            ui.core.play_tracks(tracks.clone(), 0);
        });
    }
    card.append(&play);

    let shuffle = gtk::Button::from_icon_name("media-playlist-shuffle-symbolic");
    shuffle.add_css_class("circular");
    shuffle.set_valign(gtk::Align::Center);
    shuffle.set_tooltip_text(Some(&format!("Shuffle {}", playlist.title)));
    {
        let ui = Rc::clone(ui);
        let tracks: Vec<Track> = playlist.tracks.clone();
        shuffle.connect_clicked(move |_| {
            if !ui.core.player.shuffle_enabled() {
                ui.core.player.toggle_shuffle();
            }
            let start = (crate::palette::fnv1a_64(&format!(
                "suggested{}",
                chrono::Utc::now().timestamp_micros()
            )) % tracks.len().max(1) as u64) as usize;
            ui.core.play_tracks(tracks.clone(), start);
        });
    }
    card.append(&shuffle);

    card.upcast()
}
