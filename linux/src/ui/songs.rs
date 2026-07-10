use crate::events::AppEvent;
use crate::library::{format_time, Track};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::pango;
use gtk::{gio, gdk};
use std::cmp::Ordering;
use std::rc::Rc;

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
        .reorderable(false)
        .show_row_separators(false)
        .build();
    column_view.add_css_class("data-table");

    let sort_model = gtk::SortListModel::new(Some(filter_model), column_view.sorter());
    let selection = gtk::SingleSelection::new(Some(sort_model));
    column_view.set_model(Some(&selection));

    let title_column = string_column(
        ui,
        "Title",
        true,
        |track| track.title.clone(),
        |a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()),
        true,
    );
    column_view.append_column(&title_column);
    column_view.append_column(&string_column(
        ui,
        "Artist",
        true,
        |track| track.artist.clone(),
        |a, b| a.artist.to_lowercase().cmp(&b.artist.to_lowercase()),
        false,
    ));
    column_view.append_column(&string_column(
        ui,
        "Album",
        true,
        |track| track.album.clone(),
        |a, b| a.album.to_lowercase().cmp(&b.album.to_lowercase()),
        false,
    ));
    column_view.append_column(&string_column(
        ui,
        "Duration",
        false,
        |track| format_time(track.duration),
        |a, b| a.duration.partial_cmp(&b.duration).unwrap_or(Ordering::Equal),
        false,
    ));
    column_view.append_column(&string_column(
        ui,
        "Quality",
        false,
        |track| track.quality_badge().unwrap_or_default(),
        |a, b| {
            let score = |t: &Track| {
                (t.bit_depth.unwrap_or(0) as i64) * 1_000_000 + t.sample_rate.unwrap_or(0) as i64
            };
            score(a).cmp(&score(b))
        },
        false,
    ));

    column_view.sort_by_column(Some(&title_column), gtk::SortType::Ascending);

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

    let empty = adw::StatusPage::builder()
        .icon_name("emblem-music-symbolic")
        .title("No Songs")
        .description("Your library is empty. Add music to your music folder and rescan.")
        .build();

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&list_box, Some("list"));

    let rebuild = {
        let store = store.clone();
        let stack = stack.clone();
        let ui = Rc::clone(ui);
        move || {
            store.remove_all();
            let library = ui.core.library.borrow().clone();
            for track in &library.tracks {
                store.append(&BoxedAnyObject::new(track.clone()));
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

fn string_column(
    ui: &Rc<Ui>,
    title: &str,
    expand: bool,
    text_for: impl Fn(&Track) -> String + 'static,
    compare: impl Fn(&Track, &Track) -> Ordering + 'static,
    with_context_menu: bool,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    let core = Rc::clone(&ui.core);
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
        let label = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        item.set_child(Some(&label));
        if with_context_menu {
            let gesture = gtk::GestureClick::builder()
                .button(gdk::BUTTON_SECONDARY)
                .build();
            let item_weak = item.downgrade();
            let core = Rc::clone(&core);
            let label_ref = label.clone();
            gesture.connect_pressed(move |_, _, x, y| {
                let Some(item) = item_weak.upgrade() else { return };
                let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                    return;
                };
                let track = boxed.borrow::<Track>().clone();
                let menu = context::track_menu(&core, &track.rel_path, track.loved);
                context::popup_menu_at(&label_ref, &menu, x, y);
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
        compare(&a.borrow::<Track>(), &b.borrow::<Track>()).into()
    });

    gtk::ColumnViewColumn::builder()
        .title(title)
        .factory(&factory)
        .sorter(&sorter)
        .expand(expand)
        .resizable(true)
        .build()
}
