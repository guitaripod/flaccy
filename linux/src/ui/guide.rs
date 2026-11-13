use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;

struct Card {
    /// Where the card sits in the Apple guide, the numbering
    /// `SignalPathVerdict::guide_cards` speaks in.
    position: usize,
    title: &'static str,
    icon: &'static str,
    body: &'static str,
    bullets_caption: Option<&'static str>,
    bullets: &'static [&'static str],
    takeaway_caption: Option<&'static str>,
    takeaway: Option<&'static str>,
    source_label: Option<&'static str>,
    source_url: Option<&'static str>,
}

/// The six iOS ListeningGuideContent fact cards, with the wired-DAC card
/// first — on a desktop the DAC is usually wired, so it argues FOR the
/// platform (the iOS port note suggests exactly this reorder).
const CARDS: [Card; 6] = [
    Card {
        position: 3,
        title: "When FLAC is worth it",
        icon: "audio-card-symbolic",
        body: "For true lossless, go wired: a desktop or home rig with a wired DAC is exactly where FLAC shines. On iPhone, the Apple headphone adapter delivers up to 24-bit/48 kHz, and an external USB-C DAC unlocks hi-res lossless up to 24-bit/192 kHz.",
        bullets_caption: None,
        bullets: &[],
        takeaway_caption: None,
        takeaway: None,
        source_label: None,
        source_url: None,
    },
    Card {
        position: 0,
        title: "Bluetooth & AAC",
        icon: "bluetooth-active-symbolic",
        body: "AirPods receive audio over Bluetooth using Apple's AAC codec at up to roughly 256 kbps. The rate is adaptive — it can drop when the wireless link degrades.",
        bullets_caption: None,
        bullets: &[],
        takeaway_caption: None,
        takeaway: None,
        source_label: None,
        source_url: None,
    },
    Card {
        position: 1,
        title: "Why lossless can't reach AirPods",
        icon: "audio-headphones-symbolic",
        body: "Apple confirms Bluetooth connections aren't lossless. Playing a FLAC or ALAC file to AirPods delivers, at best, ~256 kbps AAC at your ear. AirPods Pro 3's spec sheet lists \u{201c}No Lossless Audio\u{201d}.",
        bullets_caption: Some("Exceptions"),
        bullets: &[
            "AirPods Max (USB-C) support 24-bit/48 kHz lossless over a USB-C cable, added by a firmware update in March 2025.",
            "H2-chip AirPods get lossless wirelessly only with Apple Vision Pro, over a proprietary 5 GHz link — not standard Bluetooth.",
        ],
        takeaway_caption: None,
        takeaway: None,
        source_label: Some("support.apple.com/en-us/118295"),
        source_url: Some("https://support.apple.com/en-us/118295"),
    },
    Card {
        position: 2,
        title: "What happens to your files",
        icon: "media-playlist-repeat-symbolic",
        body: "iOS mixes all audio — your music plus system sounds — into one stream and re-encodes it to AAC for Bluetooth, so even a 256 kbps AAC file is decoded and encoded again on its way to your AirPods. This is how the audio pipeline works: engineering consensus, as Apple doesn't document passthrough. One extra generation of high-bitrate AAC is essentially inaudible — the loss is real on paper, tiny in practice.",
        bullets_caption: None,
        bullets: &[],
        takeaway_caption: Some("Practical takeaway"),
        takeaway: Some("Storing AAC 256 instead of FLAC loses nothing audible over AirPods and saves roughly 60% storage."),
        source_label: None,
        source_url: None,
    },
    Card {
        position: 4,
        title: "Why some albums still click",
        icon: "media-playlist-consecutive-symbolic",
        body: "Gapless is always on in Flaccy — the next track is decoded and waiting before the current one ends, so a continuous album runs as one piece. What you hear at the seam depends on the file. Lossless formats store exactly the samples the master had, so there is nothing between tracks to remove. MP3 and AAC encode in fixed blocks and pad every file with a fraction of a second of silence at each end, and that padding lives inside the file.",
        bullets_caption: Some("What this means for your library"),
        bullets: &[
            "FLAC, ALAC, WAV and AIFF albums are gapless with no caveat.",
            "MP3 and AAC rips of live albums, DJ mixes and segued records can click between tracks — the padding is baked in, not something a player setting can undo.",
            "Re-ripping the album to FLAC removes the seam for good.",
        ],
        takeaway_caption: Some("Practical takeaway"),
        takeaway: Some("If one album gaps and the rest don't, check its format before blaming the player."),
        source_label: None,
        source_url: None,
    },
    Card {
        position: 5,
        title: "Can you hear the difference?",
        icon: "audio-volume-high-symbolic",
        body: "In published blind tests — the largest public one put 580 participants on CD versus 256 kbps AAC — most listeners cannot reliably tell 256 kbps AAC from lossless. Only a small minority succeed, on specific tracks, under ideal conditions, on revealing gear. Apple itself calls the difference \u{201c}virtually indistinguishable\u{201d}.",
        bullets_caption: None,
        bullets: &[],
        takeaway_caption: None,
        takeaway: None,
        source_label: None,
        source_url: None,
    },
];

/// The built Guide page, kept so another screen can open it at one card.
struct BuiltGuide {
    scroll: glib::WeakRef<gtk::ScrolledWindow>,
    cards: Vec<(usize, glib::WeakRef<gtk::Widget>)>,
}

thread_local! {
    static BUILT: RefCell<Option<BuiltGuide>> = const { RefCell::new(None) };
}

/// The title and icon of the card at `position` in the Apple guide's
/// numbering, `None` for a card this guide does not carry.
pub fn card_heading(position: usize) -> Option<(&'static str, &'static str)> {
    CARDS
        .iter()
        .find(|card| card.position == position)
        .map(|card| (card.title, card.icon))
}

/// Shows the Guide page, scrolled to the card at `position` when one is given
/// and to the top otherwise.
pub fn show(ui: &Rc<Ui>, position: Option<usize>) {
    WidgetExt::activate_action(&ui.window, "win.show-page", Some(&"guide".to_variant())).ok();
    scroll_when_laid_out(position, 0);
}

/// How many frames to wait for the Guide page to be laid out after it is shown.
const SCROLL_ATTEMPTS: u32 = 30;

/// Scrolls once the page has a size; a page that was just switched to is laid
/// out a frame or two later.
fn scroll_when_laid_out(position: Option<usize>, attempt: u32) {
    let ready = BUILT.with(|built| {
        let built = built.borrow();
        let Some(built) = built.as_ref() else {
            return true;
        };
        let Some(scroll) = built.scroll.upgrade() else {
            return true;
        };
        if !scroll.is_mapped() || scroll.height() == 0 {
            return false;
        }
        let card = position.and_then(|position| {
            built
                .cards
                .iter()
                .find(|(card_position, _)| *card_position == position)
                .and_then(|(_, card)| card.upgrade())
        });
        let adjustment = scroll.vadjustment();
        let top = card
            .and_then(|card| card.compute_point(&scroll, &gtk::graphene::Point::new(0.0, 0.0)))
            .map(|point| adjustment.value() + f64::from(point.y()) - 12.0)
            .unwrap_or(0.0);
        let highest = (adjustment.upper() - adjustment.page_size()).max(0.0);
        adjustment.set_value(top.clamp(0.0, highest));
        true
    });
    if !ready && attempt < SCROLL_ATTEMPTS {
        glib::timeout_add_local_once(std::time::Duration::from_millis(16), move || {
            scroll_when_laid_out(position, attempt + 1);
        });
    }
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(24)
        .margin_bottom(32)
        .margin_start(28)
        .margin_end(28)
        .build();

    let caption = gtk::Label::builder()
        .label("AUDIO QUALITY")
        .xalign(0.0)
        .build();
    caption.add_css_class("stat-caption");
    content.append(&caption);
    let headline = gtk::Label::builder()
        .label("Listening Guide")
        .xalign(0.0)
        .build();
    headline.add_css_class("title-1");
    content.append(&headline);
    let intro = gtk::Label::builder()
        .label(
            "Five facts about Bluetooth, AAC, and what your files actually deliver to your ears.",
        )
        .xalign(0.0)
        .wrap(true)
        .build();
    intro.add_css_class("dim");
    content.append(&intro);

    let mut cards = Vec::with_capacity(CARDS.len());
    for card in &CARDS {
        let widget = card_widget(ui, card);
        cards.push((card.position, widget.downgrade()));
        content.append(&widget);
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(
            &adw::Clamp::builder()
                .maximum_size(760)
                .child(&content)
                .build(),
        )
        .build();
    ui.register_scroller(&scroll);
    BUILT.with(|built| {
        *built.borrow_mut() = Some(BuiltGuide {
            scroll: scroll.downgrade(),
            cards,
        });
    });
    scroll.upcast()
}

fn card_widget(ui: &Rc<Ui>, card: &Card) -> gtk::Widget {
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

    if let Some(caption) = card.bullets_caption {
        let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
        caption_label.add_css_class("stat-caption");
        card_box.append(&caption_label);
    }
    for bullet in card.bullets {
        let bullet_label = gtk::Label::builder()
            .label(format!("• {bullet}"))
            .xalign(0.0)
            .wrap(true)
            .build();
        bullet_label.add_css_class("dim");
        card_box.append(&bullet_label);
    }

    if let Some(caption) = card.takeaway_caption {
        let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
        caption_label.add_css_class("stat-caption");
        card_box.append(&caption_label);
    }
    if let Some(takeaway) = card.takeaway {
        let takeaway_label = gtk::Label::builder()
            .label(takeaway)
            .xalign(0.0)
            .wrap(true)
            .build();
        takeaway_label.add_css_class("guide-takeaway");
        card_box.append(&takeaway_label);
    }

    if let (Some(label), Some(url)) = (card.source_label, card.source_url) {
        let link = gtk::Button::builder()
            .label(label)
            .halign(gtk::Align::Start)
            .build();
        link.add_css_class("flat");
        link.add_css_class("caption");
        let ui = Rc::clone(ui);
        let url = url.to_string();
        link.connect_clicked(move |_| {
            gtk::UriLauncher::new(&url).launch(
                Some(&ui.window),
                None::<&gtk::gio::Cancellable>,
                |result| {
                    if let Err(err) = result {
                        crate::logger::warn("ui", &format!("browser launch failed: {err}"));
                    }
                },
            );
        });
        card_box.append(&link);
    }

    card_box.upcast()
}
