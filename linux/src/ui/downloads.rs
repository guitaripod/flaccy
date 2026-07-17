use crate::db::DownloadRow;
use crate::downloads::{self, ToolStatus};
use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

struct StepCard {
    icon: &'static str,
    title: &'static str,
    body: &'static str,
}

const STEP_CARDS: [StepCard; 3] = [
    StepCard {
        icon: "insert-link-symbolic",
        title: "Paste any link",
        body: "A single song, a full album, or a whole playlist — from YouTube, YouTube Music, \
               SoundCloud, Bandcamp, and hundreds of other sites. Playlists are expanded into \
               individual tracks and queued one by one.",
    },
    StepCard {
        icon: "audio-x-generic-symbolic",
        title: "Best quality, fully tagged",
        body: "The best audio stream available is saved without re-encoding — for YouTube that's \
               usually Opus. Title, artist, album, track number, and cover art are embedded \
               automatically.",
    },
    StepCard {
        icon: "folder-download-symbolic",
        title: "Straight into your library",
        body: "Tracks land in a YouTube folder inside your music library and appear in Albums, \
               Songs, and Artists the moment they finish — ready for playlists, stations, and \
               scrobbling. Press Ctrl+D anywhere to jump here, or Ctrl+V to drop a copied link \
               straight into the queue.",
    },
];

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(24)
        .margin_bottom(32)
        .margin_start(28)
        .margin_end(28)
        .build();

    let caption = gtk::Label::builder().label("GET MUSIC").xalign(0.0).build();
    caption.add_css_class("stat-caption");
    content.append(&caption);
    let headline = gtk::Label::builder().label("Downloads").xalign(0.0).build();
    headline.add_css_class("title-1");
    content.append(&headline);
    let intro = gtk::Label::builder()
        .label("Paste a link, get the music — downloaded at the best available quality, tagged, and added to your library automatically.")
        .xalign(0.0)
        .wrap(true)
        .build();
    intro.add_css_class("dim");
    content.append(&intro);

    let entry = gtk::Entry::builder()
        .placeholder_text("https://youtube.com/watch?v=…")
        .hexpand(true)
        .secondary_icon_name("edit-paste-symbolic")
        .secondary_icon_tooltip_text("Paste link")
        .build();
    let download_button = gtk::Button::builder().label("Download").build();
    download_button.add_css_class("suggested-action");
    download_button.add_css_class("pill");

    let submit = {
        let ui = Rc::clone(ui);
        let entry = entry.clone();
        Rc::new(move || {
            let text = entry.text().to_string();
            if text.trim().is_empty() {
                return;
            }
            downloads::enqueue(&ui.core, &text);
            entry.set_text("");
        })
    };
    {
        let submit = Rc::clone(&submit);
        entry.connect_activate(move |_| submit());
    }
    {
        let submit = Rc::clone(&submit);
        download_button.connect_clicked(move |_| submit());
    }
    {
        let submit = Rc::clone(&submit);
        entry.connect_icon_release(move |entry, position| {
            if position != gtk::EntryIconPosition::Secondary {
                return;
            }
            let entry = entry.clone();
            let submit = Rc::clone(&submit);
            entry.clipboard().read_text_async(
                None::<&gtk::gio::Cancellable>,
                move |result| {
                    if let Ok(Some(text)) = result {
                        entry.set_text(text.trim());
                        submit();
                    }
                },
            );
        });
    }

    let hero = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .build();
    hero.add_css_class("guide-card");
    let entry_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    entry_row.append(&entry);
    entry_row.append(&download_button);
    hero.append(&entry_row);
    let hero_caption = gtk::Label::builder()
        .label("Songs, albums, and playlists · best available quality · tagged and added automatically")
        .xalign(0.0)
        .wrap(true)
        .build();
    hero_caption.add_css_class("caption");
    hero_caption.add_css_class("dim");
    hero.append(&hero_caption);
    content.append(&hero);

    let setup_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&setup_box);

    let queue_section = gtk::Box::new(gtk::Orientation::Vertical, 10);
    let queue_header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let queue_heading = gtk::Label::builder().label("Queue").xalign(0.0).hexpand(true).build();
    queue_heading.add_css_class("heading");
    queue_header.append(&queue_heading);
    let clear_button = gtk::Button::builder().label("Clear Finished").build();
    clear_button.add_css_class("flat");
    {
        let ui = Rc::clone(ui);
        clear_button.connect_clicked(move |_| downloads::clear_finished(&ui.core));
    }
    queue_header.append(&clear_button);
    queue_section.append(&queue_header);
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    queue_section.append(&list);
    content.append(&queue_section);

    for card in &STEP_CARDS {
        content.append(&step_card(card));
    }

    let bars: Rc<RefCell<HashMap<i64, gtk::ProgressBar>>> = Rc::new(RefCell::new(HashMap::new()));
    let rebuild = {
        let ui = Rc::clone(ui);
        let list = list.clone();
        let queue_section = queue_section.clone();
        let clear_button = clear_button.clone();
        let bars = Rc::clone(&bars);
        Rc::new(move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            bars.borrow_mut().clear();
            let rows = ui.core.db.download_rows();
            queue_section.set_visible(!rows.is_empty());
            clear_button.set_visible(ui.core.db.finished_download_count() > 0);
            for row in &rows {
                list.append(&queue_row(&ui, row, &bars));
            }
        })
    };
    rebuild();
    {
        let rebuild = Rc::clone(&rebuild);
        let bars = Rc::clone(&bars);
        ui.core.hub.subscribe_widget(&list, move |_, event| match event {
            AppEvent::DownloadsChanged => rebuild(),
            AppEvent::DownloadProgress { id, fraction } => {
                if let Some(bar) = bars.borrow().get(id) {
                    bar.set_fraction(*fraction);
                }
            }
            _ => {}
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(760).child(&content).build())
        .build();
    ui.register_scroller(&scroll);

    let recheck: Rc<RefCell<Option<Rc<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    let check_tools = {
        let ui = Rc::clone(ui);
        let setup_box = setup_box.clone();
        let entry = entry.clone();
        let download_button = download_button.clone();
        let recheck = Rc::clone(&recheck);
        Rc::new(move || {
            let (tx, rx) = async_channel::bounded::<ToolStatus>(1);
            std::thread::Builder::new()
                .name("flaccy-dl-tools".into())
                .spawn(move || {
                    let _ = tx.send_blocking(downloads::check_tools());
                })
                .ok();
            let ui = Rc::clone(&ui);
            let setup_box = setup_box.clone();
            let entry = entry.clone();
            let download_button = download_button.clone();
            let recheck = Rc::clone(&recheck);
            glib::spawn_future_local(async move {
                let Ok(status) = rx.recv().await else { return };
                entry.set_sensitive(status.ready());
                download_button.set_sensitive(status.ready());
                render_setup(&ui, &setup_box, &status, &recheck);
            });
        })
    };
    *recheck.borrow_mut() = Some(check_tools.clone() as Rc<dyn Fn()>);
    check_tools();
    {
        let check_tools = Rc::clone(&check_tools);
        scroll.connect_map(move |_| check_tools());
    }

    scroll.upcast()
}

fn render_setup(
    ui: &Rc<Ui>,
    container: &gtk::Box,
    status: &ToolStatus,
    recheck: &Rc<RefCell<Option<Rc<dyn Fn()>>>>,
) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
    if status.ready() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let icon = gtk::Image::from_icon_name("object-select-symbolic");
        icon.add_css_class("accent-toggle");
        row.append(&icon);
        let label = gtk::Label::builder()
            .label(format!(
                "Ready · yt-dlp {} · FFmpeg installed",
                status.yt_dlp_version.as_deref().unwrap_or("?")
            ))
            .xalign(0.0)
            .build();
        label.add_css_class("caption");
        label.add_css_class("dim");
        row.append(&label);
        container.append(&row);
        return;
    }

    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .build();
    card.add_css_class("guide-card");

    let header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let icon = gtk::Image::from_icon_name("applications-system-symbolic");
    icon.add_css_class("accent-toggle");
    header.append(&icon);
    let title = gtk::Label::builder().label("One-minute setup").xalign(0.0).build();
    title.add_css_class("heading");
    header.append(&title);
    card.append(&header);

    let body = gtk::Label::builder()
        .label("Downloads are powered by two free, open-source tools: yt-dlp fetches the audio and FFmpeg extracts it losslessly. Install them once and this page comes alive.")
        .xalign(0.0)
        .wrap(true)
        .build();
    card.append(&body);

    card.append(&tool_row(
        "yt-dlp — the downloader",
        status.yt_dlp_version.as_deref(),
    ));
    card.append(&tool_row("FFmpeg — the audio toolbox", status.ffmpeg.then_some("installed")));

    let run_caption = gtk::Label::builder().label("Run this in a terminal").xalign(0.0).build();
    run_caption.add_css_class("stat-caption");
    card.append(&run_caption);

    let command = install_command();
    let command_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let command_label = gtk::Label::builder()
        .label(&command)
        .xalign(0.0)
        .hexpand(true)
        .wrap(true)
        .selectable(true)
        .build();
    command_label.add_css_class("dl-command");
    command_row.append(&command_label);
    let copy_button = gtk::Button::from_icon_name("edit-copy-symbolic");
    copy_button.add_css_class("flat");
    copy_button.set_tooltip_text(Some("Copy command"));
    copy_button.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        copy_button.connect_clicked(move |button| {
            button.clipboard().set_text(&command);
            ui.core.toast("Command copied");
        });
    }
    command_row.append(&copy_button);
    card.append(&command_row);

    let check_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let check_button = gtk::Button::builder().label("Check Again").build();
    check_button.add_css_class("suggested-action");
    check_button.add_css_class("pill");
    {
        let recheck = Rc::clone(recheck);
        check_button.connect_clicked(move |_| {
            if let Some(check) = recheck.borrow().clone() {
                check();
            }
        });
    }
    check_row.append(&check_button);
    let check_caption = gtk::Label::builder()
        .label("Also re-checked automatically whenever you open this page.")
        .xalign(0.0)
        .wrap(true)
        .build();
    check_caption.add_css_class("caption");
    check_caption.add_css_class("dim");
    check_caption.set_valign(gtk::Align::Center);
    check_row.append(&check_caption);
    card.append(&check_row);

    container.append(&card);
}

fn tool_row(name: &str, version: Option<&str>) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let icon = gtk::Image::from_icon_name(if version.is_some() {
        "object-select-symbolic"
    } else {
        "dialog-warning-symbolic"
    });
    if version.is_some() {
        icon.add_css_class("accent-toggle");
    } else {
        icon.add_css_class("dim");
    }
    row.append(&icon);
    let label = gtk::Label::builder().label(name).xalign(0.0).hexpand(true).build();
    row.append(&label);
    let state = gtk::Label::builder()
        .label(version.unwrap_or("not installed"))
        .xalign(1.0)
        .build();
    state.add_css_class("caption");
    state.add_css_class("dim");
    row.append(&state);
    row.upcast()
}

fn install_command() -> String {
    let os_release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
    let field = |key: &str| {
        os_release
            .lines()
            .find_map(|line| line.strip_prefix(key))
            .map(|value| value.trim_matches('"').to_lowercase())
            .unwrap_or_default()
    };
    let id = field("ID=");
    let id_like = field("ID_LIKE=");
    let matches = |name: &str| id == name || id_like.contains(name);
    if matches("arch") {
        "sudo pacman -S --needed yt-dlp ffmpeg".to_string()
    } else if matches("debian") || matches("ubuntu") {
        "sudo apt install yt-dlp ffmpeg".to_string()
    } else if matches("fedora") || matches("rhel") {
        "sudo dnf install yt-dlp ffmpeg".to_string()
    } else if matches("suse") {
        "sudo zypper install yt-dlp ffmpeg".to_string()
    } else {
        "pipx install yt-dlp   # and install ffmpeg from your package manager".to_string()
    }
}

fn queue_row(
    ui: &Rc<Ui>,
    row: &DownloadRow,
    bars: &Rc<RefCell<HashMap<i64, gtk::ProgressBar>>>,
) -> gtk::ListBoxRow {
    let outer = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(10)
        .margin_bottom(10)
        .margin_start(12)
        .margin_end(12)
        .build();

    let status_widget: gtk::Widget = match row.status.as_str() {
        downloads::STATUS_FETCHING | downloads::STATUS_DOWNLOADING => {
            let spinner = gtk::Spinner::new();
            spinner.start();
            spinner.upcast()
        }
        downloads::STATUS_DONE => {
            let icon = gtk::Image::from_icon_name("object-select-symbolic");
            icon.add_css_class("accent-toggle");
            icon.upcast()
        }
        downloads::STATUS_FAILED => {
            let icon = gtk::Image::from_icon_name("dialog-error-symbolic");
            icon.add_css_class("error");
            icon.upcast()
        }
        downloads::STATUS_CANCELLED => {
            let icon = gtk::Image::from_icon_name("media-playback-stop-symbolic");
            icon.add_css_class("dim");
            icon.upcast()
        }
        _ => {
            let icon = gtk::Image::from_icon_name("content-loading-symbolic");
            icon.add_css_class("dim");
            icon.upcast()
        }
    };
    status_widget.set_valign(gtk::Align::Center);
    outer.append(&status_widget);

    let center = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(3)
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();
    let title = gtk::Label::builder()
        .label(row.title.clone().unwrap_or_else(|| row.url.clone()))
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("dl-row-title");
    center.append(&title);
    let subtitle = gtk::Label::builder()
        .label(subtitle_text(row))
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("caption");
    if row.status == downloads::STATUS_FAILED {
        subtitle.add_css_class("error");
        subtitle.set_tooltip_text(row.error.as_deref());
    } else {
        subtitle.add_css_class("dim");
    }
    center.append(&subtitle);
    if row.status == downloads::STATUS_DOWNLOADING {
        let bar = gtk::ProgressBar::builder().margin_top(4).build();
        bar.add_css_class("osd");
        bar.add_css_class("dl-progress");
        bars.borrow_mut().insert(row.id, bar.clone());
        center.append(&bar);
    }
    outer.append(&center);

    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(4)
        .valign(gtk::Align::Center)
        .build();
    match row.status.as_str() {
        downloads::STATUS_QUEUED | downloads::STATUS_FETCHING | downloads::STATUS_DOWNLOADING => {
            actions.append(&action_button(ui, "media-playback-stop-symbolic", "Cancel", row.id, downloads::cancel));
        }
        downloads::STATUS_FAILED => {
            actions.append(&action_button(ui, "view-refresh-symbolic", "Retry", row.id, downloads::retry));
            actions.append(&action_button(ui, "window-close-symbolic", "Remove from list", row.id, downloads::remove));
        }
        _ => {
            actions.append(&action_button(ui, "window-close-symbolic", "Remove from list", row.id, downloads::remove));
        }
    }
    outer.append(&actions);

    gtk::ListBoxRow::builder().child(&outer).activatable(false).build()
}

fn subtitle_text(row: &DownloadRow) -> String {
    let artist = row.artist.clone().filter(|a| !a.is_empty());
    let with_artist = |state: &str| match &artist {
        Some(artist) => format!("{artist} · {state}"),
        None => state.to_string(),
    };
    match row.status.as_str() {
        downloads::STATUS_FETCHING => "Fetching link details…".to_string(),
        downloads::STATUS_QUEUED => with_artist("Queued"),
        downloads::STATUS_DOWNLOADING => with_artist("Downloading…"),
        downloads::STATUS_DONE => match row.error.as_deref() {
            Some(note) => with_artist(note),
            None => with_artist("Added to library"),
        },
        downloads::STATUS_FAILED => row.error.clone().unwrap_or_else(|| "Download failed".to_string()),
        downloads::STATUS_CANCELLED => "Cancelled".to_string(),
        other => other.to_string(),
    }
}

fn action_button(
    ui: &Rc<Ui>,
    icon: &str,
    tooltip: &str,
    id: i64,
    handler: fn(&Rc<crate::app::AppCore>, i64),
) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("circular");
    button.set_tooltip_text(Some(tooltip));
    let ui = Rc::clone(ui);
    button.connect_clicked(move |_| handler(&ui.core, id));
    button
}

fn step_card(card: &StepCard) -> gtk::Widget {
    let card_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .build();
    card_box.add_css_class("guide-card");
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let icon = gtk::Image::from_icon_name(card.icon);
    icon.add_css_class("accent-toggle");
    header.append(&icon);
    let title = gtk::Label::builder().label(card.title).xalign(0.0).build();
    title.add_css_class("heading");
    header.append(&title);
    card_box.append(&header);
    let body = gtk::Label::builder()
        .label(card.body)
        .xalign(0.0)
        .wrap(true)
        .build();
    card_box.append(&body);
    card_box.upcast()
}
