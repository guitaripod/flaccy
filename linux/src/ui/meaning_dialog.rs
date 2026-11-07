use crate::library::Track;
use crate::lyrics::LyricsResult;
use crate::meaning::{copy, focus_for, Reading, StoryOutcome};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::lyrics::Document;
use flaccy_shared::meaning::{sung_lines, Focus, SongStory};
use gtk::glib;
use std::rc::Rc;

/// What the worker thread reports back, in the order it learns it.
enum Update {
    Story(StoryOutcome),
    Asking(String),
    Reading(Reading),
}

/// The parts of the dialog an answer fills in.
struct View {
    status: gtk::Box,
    status_label: gtk::Label,
    body: gtk::Label,
    note: gtk::Label,
    failure: gtk::Label,
    retry: gtk::Button,
    wikipedia: gtk::Box,
    wikipedia_body: gtk::Box,
    wikipedia_credit: gtk::Label,
    wikipedia_link: gtk::LinkButton,
    wikipedia_failure: gtk::Label,
}

/// Opens the dialog on the playing song once its lyrics are read, for the
/// `FLACCY_DEMO_MEANING` hook (`song`, or a line's index).
pub fn present_for_current(ui: &Rc<Ui>, line: Option<usize>) {
    let Some(track) = ui.core.player.current_track() else {
        ui.core.toast("Play a song with lyrics to see what they mean.");
        return;
    };
    let (tx, rx) = async_channel::bounded::<Option<LyricsResult>>(1);
    let db_path = ui.core.db_path.clone();
    let music_root = ui.core.music_root();
    let for_thread = track.clone();
    std::thread::spawn(move || {
        let outcome = crate::lyrics::fetch_shared(&db_path, &music_root, &for_thread, crate::lyrics::Pace::Immediate);
        let _ = tx.send_blocking(outcome);
    });
    let ui = Rc::clone(ui);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(Some(LyricsResult::Found(lyrics))) => present(&ui, track, lyrics.document, line),
            _ => ui.core.toast(copy::NO_LYRICS),
        }
    });
}

/// Opens the Meaning dialog: what line `line` of the document means, or with
/// `None` what the whole song is about, beside what Wikipedia says about it.
pub fn present(ui: &Rc<Ui>, track: Track, document: Document, line: Option<usize>) {
    let Some(focus) = focus_for(&document, line) else {
        return;
    };
    if sung_lines(&document).is_empty() {
        ui.core.toast(copy::NO_LYRICS);
        return;
    }
    let (view, content) = build(focus.as_ref());
    let title = adw::WindowTitle::new(copy::TITLE, &format!("{} — {}", track.title, track.artist));
    let header = adw::HeaderBar::builder().title_widget(&title).build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(
            &adw::Clamp::builder()
                .maximum_size(620)
                .child(&content)
                .build(),
        )
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&scroll));
    let dialog = adw::Dialog::builder()
        .title(copy::TITLE)
        .content_width(540)
        .content_height(640)
        .child(&toolbar)
        .build();
    let view = Rc::new(view);
    let ask: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let view = Rc::clone(&view);
        Rc::new(move || ask(&ui, &view, track.clone(), document.clone(), focus.clone()))
    };
    {
        let ask = Rc::clone(&ask);
        view.retry.connect_clicked(move |_| ask());
    }
    ask();
    dialog.present(Some(&ui.window));
}

/// Asks for the story, then the reading, off the main thread, and shows each
/// as it lands.
fn ask(ui: &Rc<Ui>, view: &Rc<View>, track: Track, document: Document, focus: Option<Focus>) {
    view.status.set_visible(true);
    view.status_label.set_label(copy::LOOKING_UP);
    view.body.set_visible(false);
    view.note.set_visible(false);
    view.failure.set_visible(false);
    view.retry.set_visible(false);
    view.wikipedia_failure.set_visible(false);
    let (tx, rx) = async_channel::unbounded::<Update>();
    let db_path = ui.core.db_path.clone();
    let (server, model) = {
        let config = ui.core.config.borrow();
        (config.meaning_server.clone(), config.meaning_model.clone())
    };
    std::thread::Builder::new()
        .name("flaccy-meaning".into())
        .spawn(move || {
            let story = crate::meaning::story(&db_path, &track);
            let found = match &story {
                StoryOutcome::Found(story) => Some(story.clone()),
                _ => None,
            };
            if tx.send_blocking(Update::Story(story)).is_err() {
                return;
            }
            let reading = crate::meaning::reading(
                &db_path,
                &track,
                &document,
                focus.as_ref(),
                found.as_ref(),
                &server,
                &model,
                &|model| {
                    let _ = tx.send_blocking(Update::Asking(model.to_string()));
                },
            );
            let _ = tx.send_blocking(Update::Reading(reading));
        })
        .ok();
    let view = Rc::downgrade(view);
    glib::spawn_future_local(async move {
        while let Ok(update) = rx.recv().await {
            let Some(view) = view.upgrade() else { return };
            match update {
                Update::Story(story) => {
                    show_story(&view, &story);
                    view.status_label.set_label(copy::READING);
                }
                Update::Asking(model) => view.status_label.set_label(&copy::asking(&model)),
                Update::Reading(reading) => show_reading(&view, &reading),
            }
        }
    });
}

fn show_story(view: &View, outcome: &StoryOutcome) {
    match outcome {
        StoryOutcome::Found(story) => fill_story(view, story),
        StoryOutcome::Missing => view.wikipedia.set_visible(false),
        StoryOutcome::Failed(failure) => {
            view.wikipedia.set_visible(false);
            view.wikipedia_failure.set_label(&copy::wikipedia_failure(*failure));
            view.wikipedia_failure.set_visible(true);
        }
    }
}

fn fill_story(view: &View, story: &SongStory) {
    while let Some(child) = view.wikipedia_body.first_child() {
        view.wikipedia_body.remove(&child);
    }
    if !story.lead.is_empty() {
        view.wikipedia_body.append(&paragraphs(&story.lead));
    }
    for section in &story.sections {
        let heading = gtk::Label::builder()
            .label(&section.heading)
            .xalign(0.0)
            .wrap(true)
            .margin_top(6)
            .build();
        heading.add_css_class("heading");
        view.wikipedia_body.append(&heading);
        view.wikipedia_body.append(&paragraphs(&section.body));
    }
    view.wikipedia_credit.set_label(&copy::wikipedia_credit(&story.article));
    view.wikipedia_link.set_uri(&story.url);
    view.wikipedia.set_visible(true);
}

fn show_reading(view: &View, reading: &Reading) {
    view.status.set_visible(false);
    match reading {
        Reading::Answered { text, model } => {
            view.body.set_label(text);
            view.body.set_visible(true);
            let model = if model.is_empty() { "a local model" } else { model.as_str() };
            view.note.set_label(&copy::written_by(model));
            view.note.set_visible(true);
        }
        Reading::Failed { failure, reader } => {
            let model = if reader.model.is_empty() { "the model" } else { reader.model.as_str() };
            view.failure
                .set_label(&copy::model_failure(failure, &reader.server, model));
            view.failure.set_visible(true);
            view.retry.set_visible(true);
        }
    }
}

/// A wrapped body label for text whose paragraphs are separated by blank
/// lines.
fn paragraphs(text: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::WordChar)
        .build();
    label.add_css_class("meaning-text");
    label
}

fn build(focus: Option<&Focus>) -> (View, gtk::Box) {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .margin_top(18)
        .margin_bottom(24)
        .margin_start(22)
        .margin_end(22)
        .build();
    if let Some(focus) = focus {
        let quote = gtk::Label::builder()
            .label(&focus.line)
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .build();
        quote.add_css_class("meaning-quote");
        content.append(&quote);
    }
    let heading = gtk::Label::builder()
        .label(if focus.is_some() { copy::LINE_HEADER } else { copy::SONG_HEADER })
        .xalign(0.0)
        .build();
    heading.add_css_class("title-4");
    content.append(&heading);

    let status_label = gtk::Label::builder().label(copy::LOOKING_UP).xalign(0.0).build();
    status_label.add_css_class("dim");
    let status = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    status.append(&adw::Spinner::new());
    status.append(&status_label);
    content.append(&status);

    let body = paragraphs("");
    body.set_visible(false);
    content.append(&body);
    let note = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
    note.add_css_class("dim");
    note.add_css_class("caption");
    content.append(&note);
    let failure = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
    failure.add_css_class("meaning-failure");
    content.append(&failure);
    let retry = gtk::Button::with_label(copy::TRY_AGAIN);
    retry.add_css_class("pill");
    retry.set_halign(gtk::Align::Start);
    retry.set_visible(false);
    content.append(&retry);

    let wikipedia_heading = gtk::Label::builder()
        .label(copy::WIKIPEDIA_HEADER)
        .xalign(0.0)
        .margin_top(12)
        .build();
    wikipedia_heading.add_css_class("title-4");
    let wikipedia_body = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let wikipedia_credit = gtk::Label::builder().xalign(0.0).wrap(true).build();
    wikipedia_credit.add_css_class("dim");
    wikipedia_credit.add_css_class("caption");
    let wikipedia_link = gtk::LinkButton::with_label("https://en.wikipedia.org", copy::READ_ON_WIKIPEDIA);
    wikipedia_link.set_halign(gtk::Align::Start);
    let wikipedia = gtk::Box::new(gtk::Orientation::Vertical, 8);
    wikipedia.append(&wikipedia_heading);
    wikipedia.append(&wikipedia_body);
    wikipedia.append(&wikipedia_credit);
    wikipedia.append(&wikipedia_link);
    wikipedia.set_visible(false);
    content.append(&wikipedia);
    let wikipedia_failure = gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .margin_top(12)
        .visible(false)
        .build();
    wikipedia_failure.add_css_class("dim");
    wikipedia_failure.add_css_class("caption");
    content.append(&wikipedia_failure);

    let view = View {
        status,
        status_label,
        body,
        note,
        failure,
        retry,
        wikipedia,
        wikipedia_body,
        wikipedia_credit,
        wikipedia_link,
        wikipedia_failure,
    };
    (view, content)
}
