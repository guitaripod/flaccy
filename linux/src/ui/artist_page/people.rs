//! The people around the artist: similar artists the library holds, as round
//! portraits that open their pages, and the About card with the biography,
//! the artist's reach on Last.fm and their genres.

use crate::ui::{context, home_parts};
use adw::prelude::*;
use gtk::{gdk, pango};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

const PORTRAIT: i32 = 136;
const ABOUT_PHOTO: i32 = 220;
/// The biography folds to this many lines, behind Read More when it runs
/// longer.
const FOLDED_BIO_LINES: i32 = 5;

pub struct SimilarRow {
    pub widget: gtk::Box,
    avatars: RefCell<HashMap<String, adw::Avatar>>,
}

impl SimilarRow {
    pub fn new(
        artist: &str,
        names: &[(String, usize)],
        page: &gtk::ScrolledWindow,
        open: Rc<dyn Fn(&str)>,
    ) -> Option<Self> {
        if names.is_empty() {
            return None;
        }
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 12);
        widget.append(&super::discography::section_heading("Fans Also Like"));
        let caption = gtk::Label::builder()
            .label(format!("Artists in your library that listeners of {artist} play"))
            .xalign(0.0)
            .wrap(true)
            .build();
        caption.add_css_class("dim");
        caption.add_css_class("caption");
        widget.append(&caption);
        let mut avatars = HashMap::new();
        let tiles: Vec<gtk::Widget> = names
            .iter()
            .map(|(name, albums)| {
                let avatar = adw::Avatar::new(PORTRAIT, Some(name), true);
                avatar.add_css_class("artist-portrait");
                avatars.insert(name.clone(), avatar.clone());
                portrait_tile(name, *albums, &avatar, Rc::clone(&open))
            })
            .collect();
        widget.append(&home_parts::shelf(tiles, page));
        Some(Self {
            widget,
            avatars: RefCell::new(avatars),
        })
    }

    pub fn set_photo(&self, name: &str, texture: &gdk::Texture) {
        if let Some(avatar) = self.avatars.borrow().get(name) {
            avatar.set_custom_image(Some(texture));
        }
    }
}

fn portrait_tile(
    name: &str,
    albums: usize,
    avatar: &adw::Avatar,
    open: Rc<dyn Fn(&str)>,
) -> gtk::Widget {
    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .width_request(PORTRAIT + 16)
        .build();
    column.append(avatar);
    let title = gtk::Label::builder()
        .label(name)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(14)
        .margin_top(8)
        .build();
    title.add_css_class("home-tile-title");
    column.append(&title);
    let subtitle = gtk::Label::new(Some(&match albums {
        0 => "Artist".to_string(),
        1 => "1 album".to_string(),
        count => format!("{count} albums"),
    }));
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    column.append(&subtitle);
    let button = gtk::Button::builder().child(&column).build();
    button.add_css_class("flat");
    button.add_css_class("artist-portrait-tile");
    button.set_tooltip_text(Some(name));
    button.update_property(&[gtk::accessible::Property::Label(name)]);
    {
        let name = name.to_string();
        button.connect_clicked(move |_| open(&name));
    }
    context::attach_artist_context_menu(&button, name.to_string());
    button.upcast()
}

/// The artist's reach: "4.1M listeners · 182.3M plays on Last.fm".
pub fn reach_text(listeners: u64, plays: u64) -> String {
    format!("{} listeners  ·  {} plays on Last.fm", compact(listeners), compact(plays))
}

/// "4.1M", "312K", "980".
pub fn compact(value: u64) -> String {
    let scaled = |divisor: f64, unit: &str| {
        let value = value as f64 / divisor;
        if value >= 100.0 {
            format!("{}{unit}", value.floor() as u64)
        } else {
            let text = format!("{:.1}", (value * 10.0).floor() / 10.0);
            format!("{}{unit}", text.trim_end_matches(".0"))
        }
    };
    match value {
        0..=999 => value.to_string(),
        1_000..=999_999 => scaled(1_000.0, "K"),
        1_000_000..=999_999_999 => scaled(1_000_000.0, "M"),
        _ => scaled(1_000_000_000.0, "B"),
    }
}

pub struct About {
    pub widget: gtk::Box,
    photo: gtk::Picture,
    reach: gtk::Label,
    tags: adw::WrapBox,
    bio_box: gtk::Box,
}

impl About {
    pub fn new(bio: Option<&str>) -> Rc<Self> {
        let widget = gtk::Box::new(gtk::Orientation::Horizontal, 28);
        widget.add_css_class("artist-card");
        widget.add_css_class("artist-about");
        let photo = gtk::Picture::builder()
            .width_request(ABOUT_PHOTO)
            .height_request(ABOUT_PHOTO)
            .content_fit(gtk::ContentFit::Cover)
            .valign(gtk::Align::Start)
            .visible(false)
            .build();
        photo.set_overflow(gtk::Overflow::Hidden);
        photo.add_css_class("artist-about-photo");
        widget.append(&photo);

        let column = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .hexpand(true)
            .valign(gtk::Align::Center)
            .build();
        column.append(&super::discography::section_heading("About"));
        let reach = gtk::Label::builder().xalign(0.0).visible(false).build();
        reach.add_css_class("artist-about-reach");
        column.append(&reach);
        let bio_box = gtk::Box::new(gtk::Orientation::Vertical, 4);
        column.append(&bio_box);
        let tags = adw::WrapBox::builder().child_spacing(6).line_spacing(6).build();
        tags.set_visible(false);
        tags.set_margin_top(4);
        column.append(&tags);
        widget.append(&column);
        {
            let photo = photo.downgrade();
            crate::ui::resize::watch_width(&widget, move |width, _| {
                if let Some(photo) = photo.upgrade() {
                    photo.set_visible(width >= 640 && photo.paintable().is_some());
                }
            });
        }
        let about = Rc::new(Self {
            widget,
            photo,
            reach,
            tags,
            bio_box,
        });
        about.set_bio(bio);
        about
    }

    pub fn set_bio(&self, bio: Option<&str>) {
        while let Some(child) = self.bio_box.first_child() {
            self.bio_box.remove(&child);
        }
        let Some(bio) = bio.map(str::trim).filter(|bio| !bio.is_empty()) else {
            self.refresh_visibility();
            return;
        };
        let label = gtk::Label::builder()
            .label(bio)
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(pango::WrapMode::WordChar)
            .selectable(false)
            .build();
        label.add_css_class("artist-about-bio");
        self.bio_box.append(&label);
        label.set_lines(FOLDED_BIO_LINES);
        label.set_ellipsize(pango::EllipsizeMode::End);
        let toggle = gtk::Button::with_label("Read More");
        toggle.add_css_class("flat");
        toggle.add_css_class("artist-link");
        toggle.set_halign(gtk::Align::Start);
        toggle.set_visible(false);
        {
            let label = label.downgrade();
            toggle.connect_clicked(move |toggle| {
                let Some(label) = label.upgrade() else { return };
                let folded = label.lines() > 0;
                label.set_lines(if folded { -1 } else { FOLDED_BIO_LINES });
                label.set_ellipsize(if folded {
                    pango::EllipsizeMode::None
                } else {
                    pango::EllipsizeMode::End
                });
                toggle.set_label(if folded { "Read Less" } else { "Read More" });
            });
        }
        {
            let (label_weak, toggle) = (label.downgrade(), toggle.downgrade());
            crate::ui::resize::watch_width(&label, move |_, _| {
                let (Some(label), Some(toggle)) = (label_weak.upgrade(), toggle.upgrade()) else {
                    return;
                };
                let folded = label.lines() > 0;
                toggle.set_visible(!folded || label.layout().is_ellipsized());
            });
        }
        self.bio_box.append(&toggle);
        self.refresh_visibility();
    }

    pub fn set_reach(&self, reach: Option<(u64, u64)>) {
        if let Some((listeners, plays)) = reach.filter(|(listeners, _)| *listeners > 0) {
            self.reach.set_label(&reach_text(listeners, plays));
            self.reach.set_visible(true);
        }
        self.refresh_visibility();
    }

    pub fn set_tags(&self, tags: &[String]) {
        while let Some(child) = self.tags.first_child() {
            self.tags.remove(&child);
        }
        for tag in tags.iter().take(6) {
            let chip = gtk::Label::new(Some(tag));
            chip.add_css_class("genre-chip");
            self.tags.append(&chip);
        }
        self.tags.set_visible(!tags.is_empty());
        self.refresh_visibility();
    }

    pub fn set_photo(&self, texture: &gdk::Texture) {
        self.photo.set_paintable(Some(texture));
        self.photo.set_visible(self.widget.width() == 0 || self.widget.width() >= 640);
    }

    fn refresh_visibility(&self) {
        let has_words = self.bio_box.first_child().is_some() || self.reach.is_visible();
        self.widget.set_visible(has_words);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_read_compactly_without_rounding_up() {
        assert_eq!(compact(980), "980");
        assert_eq!(compact(1_000), "1K");
        assert_eq!(compact(1_250), "1.2K");
        assert_eq!(compact(312_499), "312K");
        assert_eq!(compact(4_199_999), "4.1M");
        assert_eq!(compact(182_345_678), "182M");
        assert_eq!(compact(2_000_000_000), "2B");
    }

    #[test]
    fn reach_reads_as_one_line() {
        assert_eq!(
            reach_text(4_100_000, 182_300_000),
            "4.1M listeners  ·  182M plays on Last.fm"
        );
    }
}
