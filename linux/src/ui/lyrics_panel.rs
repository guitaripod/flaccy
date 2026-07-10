use crate::events::AppEvent;
use crate::library::Track;
use crate::lyrics::Lyrics;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let header = gtk::Label::builder()
        .label("Lyrics")
        .xalign(0.0)
        .margin_top(16)
        .margin_start(16)
        .build();
    header.add_css_class("title-4");
    let subtitle = gtk::Label::builder()
        .label("")
        .xalign(0.0)
        .margin_start(16)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .margin_top(8)
        .margin_bottom(120)
        .margin_start(12)
        .margin_end(12)
        .build();
    list.add_css_class("background");

    let plain_view = gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .margin_top(8)
        .margin_bottom(24)
        .margin_start(16)
        .margin_end(16)
        .selectable(true)
        .build();
    plain_view.add_css_class("lyric-line");

    let status = adw::StatusPage::builder()
        .icon_name("format-justify-center-symbolic")
        .title("No Lyrics")
        .description("Play a track to look up lyrics on lrclib.net.")
        .build();

    let synced_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&list)
        .vexpand(true)
        .build();
    let plain_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&plain_view)
        .vexpand(true)
        .build();

    let stack = gtk::Stack::new();
    stack.add_named(&status, Some("status"));
    stack.add_named(&synced_scroll, Some("synced"));
    stack.add_named(&plain_scroll, Some("plain"));
    stack.set_vexpand(true);

    let panel = gtk::Box::new(gtk::Orientation::Vertical, 4);
    panel.append(&header);
    panel.append(&subtitle);
    panel.append(&stack);

    let state: Rc<RefCell<PanelState>> = Rc::new(RefCell::new(PanelState::default()));
    let visible = Rc::new(Cell::new(false));
    let last_user_scroll: Rc<Cell<Option<Instant>>> = Rc::new(Cell::new(None));

    {
        let last_user_scroll = Rc::clone(&last_user_scroll);
        let scroll_controller =
            gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        scroll_controller.connect_scroll(move |_, _, _| {
            last_user_scroll.set(Some(Instant::now()));
            glib::Propagation::Proceed
        });
        synced_scroll.add_controller(scroll_controller);
    }

    {
        let ui = Rc::clone(ui);
        let state = Rc::clone(&state);
        list.connect_row_activated(move |_, row| {
            let index = row.index().max(0) as usize;
            let time = state.borrow().lyrics.synced.get(index).map(|(t, _)| *t);
            if let Some(time) = time {
                ui.core.player.seek(time);
            }
        });
    }

    let apply_lyrics = {
        let list = list.clone();
        let stack = stack.clone();
        let plain_view = plain_view.clone();
        let status = status.clone();
        let state = Rc::clone(&state);
        Rc::new(move |lyrics: &Lyrics| {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            state.borrow_mut().current_line = None;
            if lyrics.instrumental {
                status.set_title("Instrumental");
                status.set_description(Some("This track has no lyrics."));
                stack.set_visible_child_name("status");
            } else if !lyrics.synced.is_empty() {
                for (_, text) in &lyrics.synced {
                    let label = gtk::Label::builder()
                        .label(if text.is_empty() { "♪" } else { text })
                        .xalign(0.0)
                        .wrap(true)
                        .build();
                    label.add_css_class("lyric-line");
                    let row = gtk::ListBoxRow::builder().child(&label).build();
                    list.append(&row);
                }
                stack.set_visible_child_name("synced");
            } else if let Some(plain) = lyrics.plain.as_deref().filter(|p| !p.trim().is_empty()) {
                plain_view.set_label(plain);
                stack.set_visible_child_name("plain");
            } else {
                status.set_title("No Lyrics Found");
                status.set_description(Some("lrclib.net has no lyrics for this track."));
                stack.set_visible_child_name("status");
            }
        })
    };

    let fetch_for = {
        let ui = Rc::clone(ui);
        let state = Rc::clone(&state);
        let apply_lyrics = Rc::clone(&apply_lyrics);
        let subtitle = subtitle.clone();
        let status = status.clone();
        let stack = stack.clone();
        Rc::new(move |track: &Track| {
            let generation = {
                let mut state = state.borrow_mut();
                state.generation += 1;
                state.generation
            };
            subtitle.set_label(&format!("{} — {}", track.title, track.artist));
            status.set_title("Looking Up Lyrics…");
            status.set_description(Some(""));
            stack.set_visible_child_name("status");

            let (tx, rx) = async_channel::bounded::<Lyrics>(1);
            let db_path = ui.core.db_path.clone();
            let title = track.title.clone();
            let artist = track.artist.clone();
            let album = track.album.clone();
            std::thread::spawn(move || {
                let lyrics = crate::lyrics::fetch_blocking(&db_path, &title, &artist, &album);
                let _ = tx.send_blocking(lyrics);
            });
            let state = Rc::clone(&state);
            let apply_lyrics = Rc::clone(&apply_lyrics);
            glib::spawn_future_local(async move {
                let Ok(lyrics) = rx.recv().await else { return };
                if state.borrow().generation != generation {
                    return;
                }
                state.borrow_mut().lyrics = lyrics.clone();
                apply_lyrics(&lyrics);
            });
        })
    };

    {
        let ui_ref = Rc::clone(ui);
        let state = Rc::clone(&state);
        let visible = Rc::clone(&visible);
        let fetch_for = Rc::clone(&fetch_for);
        let list = list.clone();
        let synced_scroll = synced_scroll.clone();
        let last_user_scroll = Rc::clone(&last_user_scroll);
        ui.core.hub.subscribe_widget(&panel, move |_, event| match event {
            AppEvent::TrackChanged(track) => {
                state.borrow_mut().track = track.clone();
                if visible.get() {
                    if let Some(track) = track {
                        fetch_for(track);
                    }
                }
            }
            AppEvent::LyricsToggled(shown) => {
                visible.set(*shown);
                if *shown {
                    let track = state.borrow().track.clone();
                    match track {
                        Some(track) => fetch_for(&track),
                        None => {
                            let current = ui_ref.core.player.current_track();
                            state.borrow_mut().track = current.clone();
                            if let Some(track) = current {
                                fetch_for(&track);
                            }
                        }
                    }
                }
            }
            AppEvent::Tick { position, .. } => {
                if !visible.get() {
                    return;
                }
                let target = {
                    let state = state.borrow();
                    if state.lyrics.synced.is_empty() {
                        return;
                    }
                    let mut index = None;
                    for (i, (time, _)) in state.lyrics.synced.iter().enumerate() {
                        if *time <= *position {
                            index = Some(i);
                        } else {
                            break;
                        }
                    }
                    if state.current_line == index {
                        return;
                    }
                    index
                };
                let previous = state.borrow().current_line;
                state.borrow_mut().current_line = target;
                if let Some(previous) = previous {
                    if let Some(row) = list.row_at_index(previous as i32) {
                        if let Some(label) = row.child() {
                            label.remove_css_class("lyric-line-current");
                            label.add_css_class("lyric-line");
                        }
                    }
                }
                if let Some(current) = target {
                    if let Some(row) = list.row_at_index(current as i32) {
                        if let Some(label) = row.child() {
                            label.remove_css_class("lyric-line");
                            label.add_css_class("lyric-line-current");
                        }
                        let user_recent = last_user_scroll
                            .get()
                            .map(|t| t.elapsed().as_secs_f64() < 3.0)
                            .unwrap_or(false);
                        if !user_recent {
                            let total = state.borrow().lyrics.synced.len();
                            scroll_to_fraction(&synced_scroll, current, total);
                        }
                    }
                }
            }
            _ => {}
        });
    }

    panel.upcast()
}

#[derive(Default)]
struct PanelState {
    track: Option<Track>,
    lyrics: Lyrics,
    generation: u64,
    current_line: Option<usize>,
}

fn scroll_to_fraction(scroll: &gtk::ScrolledWindow, index: usize, total: usize) {
    if total == 0 {
        return;
    }
    let adjustment = scroll.vadjustment();
    let fraction = index as f64 / total as f64;
    let target = adjustment.upper() * fraction - adjustment.page_size() * 0.35;
    let max = (adjustment.upper() - adjustment.page_size()).max(0.0);
    adjustment.set_value(target.clamp(0.0, max));
}
