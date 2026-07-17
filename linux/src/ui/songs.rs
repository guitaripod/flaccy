use crate::events::AppEvent;
use crate::library::{format_time, Track};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::pango;
use gtk::{gdk, gio};
use std::cmp::Ordering;
use std::rc::Rc;

type MenuHandler = dyn Fn(&Track, &gtk::Widget, f64, f64);

/// Drop secondary columns as the songs table loses width so Title (and
/// eventually Artist) stay readable instead of crushing into ellipsis soup.
fn install_songs_column_adaptation(
    column_view: &gtk::ColumnView,
    album: &gtk::ColumnViewColumn,
    plays: &gtk::ColumnViewColumn,
    quality: &gtk::ColumnViewColumn,
    artist: &gtk::ColumnViewColumn,
    duration: &gtk::ColumnViewColumn,
    added: &gtk::ColumnViewColumn,
) {
    use std::cell::Cell;
    use std::rc::Rc;

    let last_width = Rc::new(Cell::new(0i32));
    let album = album.clone();
    let plays = plays.clone();
    let quality = quality.clone();
    let artist = artist.clone();
    let duration = duration.clone();
    let added = added.clone();
    column_view.connect_realize(move |view| {
        let last_width = Rc::clone(&last_width);
        let album = album.clone();
        let plays = plays.clone();
        let quality = quality.clone();
        let artist = artist.clone();
        let duration = duration.clone();
        let added = added.clone();
        view.add_tick_callback(move |view, _| {
            let width = view.width();
            if width == last_width.get() || width <= 1 {
                return gtk::glib::ControlFlow::Continue;
            }
            last_width.set(width);
            let wide = width >= 900;
            let medium = width >= 640;
            let compact = width >= 420;
            quality.set_visible(wide);
            plays.set_visible(wide);
            added.set_visible(wide);
            album.set_visible(medium);
            duration.set_visible(compact);
            artist.set_visible(compact);
            gtk::glib::ControlFlow::Continue
        });
    });
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let loved_only = Rc::new(std::cell::Cell::new(false));

    let filter = {
        let query = Rc::clone(&ui.query);
        let loved_only = Rc::clone(&loved_only);
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let track = boxed.borrow::<Track>();
            if loved_only.get() && !track.loved {
                return false;
            }
            let query = query.borrow();
            if query.is_empty() {
                return true;
            }
            let needle = query.to_lowercase();
            track.title.to_lowercase().contains(&needle)
                || track.artist.to_lowercase().contains(&needle)
                || track.album.to_lowercase().contains(&needle)
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));

    let column_view = gtk::ColumnView::builder()
        .reorderable(true)
        .show_row_separators(false)
        .build();
    column_view.add_css_class("data-table");

    let sort_model = gtk::SortListModel::new(Some(filter_model), column_view.sorter());
    let selection = gtk::MultiSelection::new(Some(sort_model));
    column_view.set_model(Some(&selection));

    let menu_handler: Rc<MenuHandler> = {
        let ui = Rc::clone(ui);
        let selection = selection.clone();
        Rc::new(move |track, anchor, x, y| {
            let selected = selected_tracks(&selection);
            let clicked_in_selection = selected.iter().any(|t| t.rel_path == track.rel_path);
            if selected.len() >= 2 && clicked_in_selection {
                let has_duplicates = !crate::hygiene::find_duplicate_groups(
                    &selected,
                    &ui.core.music_root(),
                )
                .is_empty();
                context::popup_menu_at(anchor, &bulk_menu(selected.len(), has_duplicates), x, y);
            } else {
                let menu = context::track_menu(&track.rel_path, track.loved);
                context::popup_menu_at(anchor, &menu, x, y);
            }
        })
    };
    install_bulk_actions(ui, &selection);

    column_view.append_column(&string_column(
        "Track #",
        false,
        |track| {
            if track.track_number > 0 {
                track.track_number.to_string()
            } else {
                String::new()
            }
        },
        |a, b| a.track_number.cmp(&b.track_number),
        None,
    ));
    let title_column = string_column(
        "Title",
        true,
        |track| track.title.clone(),
        |a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()),
        Some(Rc::clone(&menu_handler)),
    );
    column_view.append_column(&title_column);
    let artist_column = string_column(
        "Artist",
        true,
        |track| track.artist.clone(),
        |a, b| a.artist.to_lowercase().cmp(&b.artist.to_lowercase()),
        None,
    );
    column_view.append_column(&artist_column);
    let album_column = string_column(
        "Album",
        true,
        |track| track.album.clone(),
        |a, b| a.album.to_lowercase().cmp(&b.album.to_lowercase()),
        None,
    );
    column_view.append_column(&album_column);
    let duration_column = string_column(
        "Duration",
        false,
        |track| format_time(track.duration),
        |a, b| a.duration.partial_cmp(&b.duration).unwrap_or(Ordering::Equal),
        None,
    );
    column_view.append_column(&duration_column);
    let plays_column = string_column(
        "Plays",
        false,
        |track| {
            if track.play_count > 0 {
                track.play_count.to_string()
            } else {
                String::new()
            }
        },
        |a, b| a.play_count.cmp(&b.play_count),
        None,
    );
    column_view.append_column(&plays_column);
    let added_column = string_column(
        "Added",
        false,
        |track| format_date_added(track.date_added),
        |a, b| a.date_added.cmp(&b.date_added),
        None,
    );
    column_view.append_column(&added_column);
    let quality_column = string_column(
        "Quality",
        false,
        |track| track.quality_badge().unwrap_or_default(),
        |a, b| {
            let score = |t: &Track| {
                (t.bit_depth.unwrap_or(0) as i64) * 1_000_000 + t.sample_rate.unwrap_or(0) as i64
            };
            score(a).cmp(&score(b))
        },
        None,
    );
    column_view.append_column(&quality_column);

    column_view.sort_by_column(Some(&title_column), gtk::SortType::Ascending);
    install_songs_column_adaptation(
        &column_view,
        &album_column,
        &plays_column,
        &quality_column,
        &artist_column,
        &duration_column,
        &added_column,
    );

    {
        let ui = Rc::clone(ui);
        column_view.connect_activate(move |view, position| {
            let Some(model) = view.model() else { return };
            let tracks: Vec<Track> = (0..model.n_items())
                .filter_map(|i| {
                    model
                        .item(i)
                        .and_then(|o| o.downcast::<BoxedAnyObject>().ok())
                        .map(|b| b.borrow::<Track>().clone())
                })
                .collect();
            if (position as usize) < tracks.len() {
                ui.core.play_tracks(tracks, position as usize);
            }
        });
    }

    let chip_bar = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(10)
        .margin_bottom(4)
        .margin_start(12)
        .build();
    let loved_chip = gtk::ToggleButton::builder().label("Loved ♥").build();
    loved_chip.add_css_class("pill");
    loved_chip.add_css_class("chip");
    loved_chip.set_tooltip_text(Some("Show only loved tracks"));
    {
        let loved_only = Rc::clone(&loved_only);
        let filter = filter.clone();
        loved_chip.connect_toggled(move |chip| {
            loved_only.set(chip.is_active());
            filter.changed(gtk::FilterChange::Different);
        });
    }
    chip_bar.append(&loved_chip);

    let list_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    list_box.append(&chip_bar);
    let scroll = gtk::ScrolledWindow::builder().vexpand(true).child(&column_view).build();
    list_box.append(&scroll);
    ui.register_scroller(&scroll);
    install_sort_scroll_reset(&column_view, &scroll);

    let empty = adw::StatusPage::builder()
        .icon_name("audio-x-generic-symbolic")
        .title("No Songs")
        .description("Your library is empty. Add music to your music folder and rescan.")
        .build();

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&list_box, Some("list"));

    let rebuild = {
        let store = store.clone();
        let stack = stack.clone();
        let ui = Rc::clone(ui);
        let applied = std::cell::Cell::new(0u64);
        move || {
            let library = ui.core.library.borrow().clone();
            let fingerprint = tracks_fingerprint(&library.tracks);
            if applied.replace(fingerprint) != fingerprint {
                let items: Vec<BoxedAnyObject> = library
                    .tracks
                    .iter()
                    .map(|track| BoxedAnyObject::new(track.clone()))
                    .collect();
                store.splice(0, store.n_items(), &items);
            }
            stack.set_visible_child_name(if library.tracks.is_empty() {
                "empty"
            } else {
                "list"
            });
        }
    };
    rebuild();

    {
        let rebuild = rebuild.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::LibraryReloaded | AppEvent::LovedChanged { .. } => rebuild(),
            AppEvent::SearchChanged(_) => filter.changed(gtk::FilterChange::Different),
            _ => {}
        });
    }

    stack.upcast()
}

/// Clicking a column header re-sorts under a preserved pixel offset, stranding
/// the view deep in the new order; snap back to the top so a fresh sort reads
/// from its beginning, matching the Albums sort dropdown.
fn install_sort_scroll_reset(column_view: &gtk::ColumnView, scroll: &gtk::ScrolledWindow) {
    let Some(sorter) = column_view.sorter() else { return };
    let vadj = scroll.vadjustment();
    sorter.connect_changed(move |_, _| {
        let vadj = vadj.clone();
        gtk::glib::idle_add_local_once(move || vadj.set_value(vadj.lower()));
    });
}

/// Collects the tracks currently highlighted in the multi-selection, in model
/// order, for the bulk context-menu actions.
fn selected_tracks(selection: &gtk::MultiSelection) -> Vec<Track> {
    let mut tracks = Vec::new();
    for position in 0..selection.n_items() {
        if selection.is_selected(position) {
            if let Some(boxed) = selection.item(position).and_downcast::<BoxedAnyObject>() {
                tracks.push(boxed.borrow::<Track>().clone());
            }
        }
    }
    tracks
}

/// Registers the `songs.*` action group backing the multi-select context menu;
/// each action resolves the live selection at activation time. The group lives
/// on the window because the popovers that reference it are parented to the
/// window root, not the column view.
fn install_bulk_actions(ui: &Rc<Ui>, selection: &gtk::MultiSelection) {
    let actions = gio::SimpleActionGroup::new();

    let add = |name: &str, handler: Box<dyn Fn(Vec<Track>)>| {
        let action = gio::SimpleAction::new(name, None);
        let selection = selection.clone();
        action.connect_activate(move |_, _| handler(selected_tracks(&selection)));
        actions.add_action(&action);
    };

    {
        let ui = Rc::clone(ui);
        add(
            "bulk-play",
            Box::new(move |tracks| {
                if !tracks.is_empty() {
                    ui.core.play_tracks(tracks, 0);
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-play-next",
            Box::new(move |tracks| {
                for track in tracks.iter().rev() {
                    ui.core.player.insert_next(track.clone());
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-queue",
            Box::new(move |tracks| {
                for track in &tracks {
                    ui.core.player.add_to_queue(track.clone());
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-love",
            Box::new(move |tracks| {
                for track in &tracks {
                    if !track.loved {
                        ui.core.toggle_love(&track.rel_path);
                    }
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-unlove",
            Box::new(move |tracks| {
                for track in &tracks {
                    if track.loved {
                        ui.core.toggle_love(&track.rel_path);
                    }
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-dedup",
            Box::new(move |tracks| crate::ui::cleanup::present_selection_dedup(&ui, tracks)),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-delete",
            Box::new(move |tracks| crate::ui::delete::present_delete_tracks(&ui, tracks)),
        );
    }

    ui.window.insert_action_group("songs", Some(&actions));
}

fn bulk_menu(count: usize, has_duplicates: bool) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append(Some(&format!("Play {count} Songs")), Some("songs.bulk-play"));
    menu.append_section(None, &play_section);

    let queue_section = gio::Menu::new();
    queue_section.append(Some("Play Next"), Some("songs.bulk-play-next"));
    queue_section.append(Some("Add to Queue"), Some("songs.bulk-queue"));
    menu.append_section(None, &queue_section);

    let love_section = gio::Menu::new();
    love_section.append(Some("Love on Last.fm"), Some("songs.bulk-love"));
    love_section.append(Some("Unlove"), Some("songs.bulk-unlove"));
    menu.append_section(None, &love_section);

    if has_duplicates {
        let dedup_section = gio::Menu::new();
        dedup_section.append(
            Some("Remove Duplicates in Selection"),
            Some("songs.bulk-dedup"),
        );
        menu.append_section(None, &dedup_section);
    }

    let delete_section = gio::Menu::new();
    delete_section.append(
        Some(&format!("Move {count} Songs to Trash…")),
        Some("songs.bulk-delete"),
    );
    menu.append_section(None, &delete_section);
    menu
}

/// Order-sensitive digest of every field the songs table renders or filters
/// on, so redundant LibraryReloaded emissions (e.g. from enrichment passes
/// that only touch album metadata) skip the expensive model rebuild.
fn tracks_fingerprint(tracks: &[Track]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for track in tracks {
        let row = format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{:?}|{:?}|{:?}",
            track.rel_path,
            track.title,
            track.artist,
            track.album,
            track.loved,
            track.duration,
            track.track_number,
            track.play_count,
            track.date_added,
            track.codec,
            track.bit_depth,
            track.sample_rate
        );
        hash = hash.rotate_left(5) ^ crate::palette::fnv1a_64(&row);
    }
    hash
}

fn format_date_added(unix: i64) -> String {
    if unix <= 0 {
        return String::new();
    }
    chrono::DateTime::<chrono::Utc>::from_timestamp(unix, 0)
        .map(|stamp| {
            stamp
                .with_timezone(&chrono::Local)
                .format("%b %-d, %Y")
                .to_string()
        })
        .unwrap_or_default()
}

fn string_column(
    title: &str,
    expand: bool,
    text_for: impl Fn(&Track) -> String + 'static,
    compare: impl Fn(&Track, &Track) -> Ordering + 'static,
    menu: Option<Rc<MenuHandler>>,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
        let label = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        item.set_child(Some(&label));
        if let Some(menu) = menu.clone() {
            let gesture = gtk::GestureClick::builder()
                .button(gdk::BUTTON_SECONDARY)
                .build();
            let item_weak = item.downgrade();
            let label_ref = label.clone();
            gesture.connect_pressed(move |_, _, x, y| {
                let Some(item) = item_weak.upgrade() else { return };
                let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                    return;
                };
                let track = boxed.borrow::<Track>().clone();
                menu(&track, label_ref.upcast_ref::<gtk::Widget>(), x, y);
            });
            label.add_controller(gesture);
        }
    });
    let text_for = Rc::new(text_for);
    {
        let text_for = Rc::clone(&text_for);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let Some(label) = item.child().and_downcast::<gtk::Label>() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else { return };
            let track = boxed.borrow::<Track>();
            label.set_label(&text_for(&track));
        });
    }

    let sorter = gtk::CustomSorter::new(move |a, b| {
        let (Some(a), Some(b)) = (
            a.downcast_ref::<BoxedAnyObject>(),
            b.downcast_ref::<BoxedAnyObject>(),
        ) else {
            return gtk::Ordering::Equal;
        };
        let track_a = a.borrow::<Track>();
        let track_b = b.borrow::<Track>();
        compare(&track_a, &track_b)
            .then_with(|| track_a.rel_path.cmp(&track_b.rel_path))
            .into()
    });

    gtk::ColumnViewColumn::builder()
        .title(title)
        .factory(&factory)
        .sorter(&sorter)
        .expand(expand)
        .resizable(true)
        .build()
}
