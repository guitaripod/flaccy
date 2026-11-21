use crate::events::AppEvent;
use crate::theme::pack::{CORNERS_SHARP, CORNERS_STANDARD, COVER_SIZE_MAX, COVER_SIZE_MIN};
use crate::theme::{AlbumsView, Appearance, CoverShape, Look, Pack, ThemeController};
use crate::ui::{look as own, theme_preview, Ui};
use adw::prelude::*;
use gtk::{gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::time::Duration;

const GUIDE_URL: &str =
    "https://github.com/guitaripod/flaccy/blob/master/linux/data/themes/README.md";
const THEMES_CHOICE: &str = "Theme's Choice";
const CORNER_IDS: [&str; 3] = ["sharp", "standard", "round"];
const CORNER_TITLES: [&str; 3] = ["Sharp", "Standard", "Round"];
const MODE_IDS: [&str; 3] = ["system", "light", "dark"];
const PREVIEW_WIDTH: i32 = 164;
const PREVIEW_HEIGHT: i32 = 100;

/// A drag of the cover size slider is applied once it rests this long, since
/// every new size rebuilds the Albums page.
const SIZE_SETTLE: Duration = Duration::from_millis(220);

/// The Appearance page: the gallery of themes with the worn theme's colors,
/// variant and mode under it, the person's own choices over any theme, and
/// the folder their own themes live in. Every control writes through
/// `ui::look` and is set back from the look that results, so the page follows
/// a theme edited on disk or a view switched on the Albums page as well.
struct Page {
    ui: Rc<Ui>,
    syncing: Cell<bool>,
    gallery: gtk::FlowBox,
    gallery_shows: Cell<u64>,
    colors: adw::ComboRow,
    colors_swatch: gtk::Box,
    variant: adw::ComboRow,
    mode: adw::ComboRow,
    theme_problems: adw::ExpanderRow,
    theme_problem_rows: RefCell<Vec<adw::ActionRow>>,
    albums: adw::ComboRow,
    cover_size: gtk::Scale,
    cover_size_row: adw::ActionRow,
    cover_size_pending: RefCell<Option<glib::SourceId>>,
    covers: adw::ComboRow,
    corners: adw::ComboRow,
    font_row: adw::ActionRow,
    font_button: gtk::FontDialogButton,
    font_clear: gtk::Button,
    glow: adw::ComboRow,
    reset: adw::ButtonRow,
    copy: adw::ButtonRow,
    folders: adw::PreferencesGroup,
    folder_problem_rows: RefCell<Vec<adw::ActionRow>>,
}

fn combo(title: &str, items: &[&str]) -> adw::ComboRow {
    adw::ComboRow::builder()
        .title(title)
        .model(&gtk::StringList::new(items))
        .build()
}

fn with_themes_choice(titles: &[&str]) -> Vec<String> {
    std::iter::once(THEMES_CHOICE.to_string())
        .chain(titles.iter().map(|title| title.to_string()))
        .collect()
}

fn own_combo(title: &str, titles: &[&str]) -> adw::ComboRow {
    let items = with_themes_choice(titles);
    let items: Vec<&str> = items.iter().map(String::as_str).collect();
    combo(title, &items)
}

/// The position of `id` among `ids`, one past the "Theme's Choice" entry that
/// leads every such row, or that entry when `id` is none of them.
fn own_position(ids: &[&str], id: &str) -> u32 {
    ids.iter()
        .position(|known| *known == id)
        .map(|at| at as u32 + 1)
        .unwrap_or(0)
}

fn own_id(ids: &[&'static str], selected: u32) -> &'static str {
    selected
        .checked_sub(1)
        .and_then(|at| ids.get(at as usize))
        .copied()
        .unwrap_or("")
}

fn warning_row(text: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(text)
        .use_markup(false)
        .title_lines(0)
        .build();
    let icon = gtk::Image::from_icon_name("flaccy-warning-symbolic");
    icon.add_css_class("warning");
    row.add_prefix(&icon);
    row
}

/// A fingerprint of everything a gallery card shows, so the cards are rebuilt
/// only when a theme was added, removed or edited, or a remembered scheme
/// changed.
fn gallery_fingerprint(packs: &[Rc<Pack>], schemes: &[String], dark: bool) -> u64 {
    let mut hasher = DefaultHasher::new();
    dark.hash(&mut hasher);
    for (pack, scheme) in packs.iter().zip(schemes) {
        format!("{pack:?}").hash(&mut hasher);
        scheme.hash(&mut hasher);
    }
    hasher.finish()
}

/// What a corner scale is called in the Corners row.
fn corners_title(scale: f64) -> &'static str {
    if scale <= CORNERS_SHARP {
        "Sharp"
    } else if scale < CORNERS_STANDARD {
        "Soft"
    } else if scale == CORNERS_STANDARD {
        "Standard"
    } else {
        "Round"
    }
}

/// The interface font as Pango resolves it for `widget`: of the families a
/// theme lists, the first this computer has. The font button can only show a
/// font that exists.
fn worn_font(widget: &impl IsA<gtk::Widget>) -> pango::FontDescription {
    let context = widget.as_ref().pango_context();
    let asked = context.font_description().unwrap_or_default();
    context
        .load_font(&asked)
        .map(|font| font.describe())
        .unwrap_or(asked)
}

fn first_family(look: &Look) -> Option<String> {
    look.heading_font
        .as_deref()
        .or(look.interface_font.as_deref())
        .and_then(|families| families.split(',').next())
        .map(|family| family.trim().to_string())
        .filter(|family| !family.is_empty())
}

fn card_caption(pack: &Pack) -> String {
    if !pack.description.is_empty() {
        pack.description.clone()
    } else if !pack.author.is_empty() {
        format!("By {}", pack.author)
    } else {
        "In your themes folder".to_string()
    }
}

/// One theme in the gallery: a drawing of the app dressed in it, its name set
/// in its own typeface when it has one, and what its author says of it.
fn card(pack: &Rc<Pack>, scheme: &str) -> gtk::FlowBoxChild {
    let look = ThemeController::preview(pack, scheme);
    let preview = theme_preview::thumbnail(look.clone());
    preview.set_content_width(PREVIEW_WIDTH);
    preview.set_content_height(PREVIEW_HEIGHT);
    let frame = gtk::Box::new(gtk::Orientation::Vertical, 0);
    frame.set_overflow(gtk::Overflow::Hidden);
    frame.set_halign(gtk::Align::Center);
    frame.add_css_class("theme-card-frame");
    frame.append(&preview);

    let name = gtk::Label::builder()
        .label(&pack.name)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(12)
        .build();
    name.add_css_class("heading");
    if let Some(family) = first_family(&look) {
        let attributes = pango::AttrList::new();
        attributes.insert(pango::AttrString::new_family(&family));
        name.set_attributes(Some(&attributes));
    }
    let caption = gtk::Label::builder()
        .label(card_caption(pack))
        .xalign(0.0)
        .yalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .lines(3)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(12)
        .build();
    caption.add_css_class("caption");
    caption.add_css_class("dim");

    let body = gtk::Box::new(gtk::Orientation::Vertical, 6);
    body.set_valign(gtk::Align::Start);
    body.set_halign(gtk::Align::Center);
    body.set_width_request(PREVIEW_WIDTH);
    body.append(&frame);
    body.append(&name);
    body.append(&caption);
    let child = gtk::FlowBoxChild::builder().child(&body).build();
    child.set_widget_name(&pack.id);
    child.set_tooltip_text(Some(&card_caption(pack)));
    child.update_property(&[gtk::accessible::Property::Label(&pack.name)]);
    child
}

impl Page {
    fn new(ui: &Rc<Ui>) -> Rc<Page> {
        let gallery = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::Single)
            .activate_on_single_click(true)
            .homogeneous(true)
            .min_children_per_line(1)
            .max_children_per_line(3)
            .column_spacing(0)
            .row_spacing(4)
            .build();
        gallery.add_css_class("theme-gallery");

        let colors = combo("Colors", &[]);
        let colors_swatch = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        colors.add_prefix(&colors_swatch);
        let variant = combo("Variant", &[]);
        let mode = combo("Mode", &["System", "Light", "Dark"]);
        let theme_problems = adw::ExpanderRow::builder().visible(false).build();
        let problems_icon = gtk::Image::from_icon_name("flaccy-warning-symbolic");
        problems_icon.add_css_class("warning");
        theme_problems.add_prefix(&problems_icon);

        let view_titles: Vec<&str> = AlbumsView::ALL.iter().map(|view| view.title()).collect();
        let albums = own_combo("Albums View", &view_titles);
        let cover_size = gtk::Scale::with_range(
            gtk::Orientation::Horizontal,
            COVER_SIZE_MIN as f64,
            COVER_SIZE_MAX as f64,
            4.0,
        );
        cover_size.set_width_request(220);
        cover_size.set_valign(gtk::Align::Center);
        cover_size.set_draw_value(false);
        let cover_size_row = adw::ActionRow::builder().title("Cover Size").build();
        cover_size_row.add_suffix(&cover_size);
        let shape_titles: Vec<&str> = CoverShape::ALL.iter().map(|shape| shape.title()).collect();
        let covers = own_combo("Covers", &shape_titles);
        let corners = own_combo("Corners", &CORNER_TITLES);

        let font_button = gtk::FontDialogButton::new(Some(
            gtk::FontDialog::builder().title("Interface Font").build(),
        ));
        font_button.set_level(gtk::FontLevel::Family);
        font_button.set_valign(gtk::Align::Center);
        let font_clear = gtk::Button::from_icon_name("flaccy-undo-symbolic");
        font_clear.add_css_class("flat");
        font_clear.set_valign(gtk::Align::Center);
        font_clear.set_tooltip_text(Some("Use the theme's font"));
        font_clear.update_property(&[gtk::accessible::Property::Label("Use the theme's font")]);
        let font_row = adw::ActionRow::builder().title("Font").build();
        font_row.add_suffix(&font_clear);
        font_row.add_suffix(&font_button);

        let glow = own_combo("Window Glow", &["On", "Off"]);
        let reset = adw::ButtonRow::builder()
            .title("Reset to the Theme")
            .build();
        reset.add_css_class("destructive-action");
        let copy = adw::ButtonRow::builder().build();
        let folders = adw::PreferencesGroup::builder()
            .title("Your Own Themes")
            .description("A theme is a folder holding a theme.toml and, when it wants one, a style.css. A saved change shows at once.")
            .build();

        Rc::new(Page {
            ui: Rc::clone(ui),
            syncing: Cell::new(false),
            gallery,
            gallery_shows: Cell::new(0),
            colors,
            colors_swatch,
            variant,
            mode,
            theme_problems,
            theme_problem_rows: RefCell::new(Vec::new()),
            albums,
            cover_size,
            cover_size_row,
            cover_size_pending: RefCell::new(None),
            covers,
            corners,
            font_row,
            font_button,
            font_clear,
            glow,
            reset,
            copy,
            folders,
            folder_problem_rows: RefCell::new(Vec::new()),
        })
    }

    fn theme_group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder().title("Theme").build();
        group.add(&self.gallery);
        let rows = adw::PreferencesGroup::new();
        rows.set_margin_top(12);
        rows.add(&self.colors);
        rows.add(&self.variant);
        rows.add(&self.albums);
        rows.add(&self.mode);
        rows.add(&self.theme_problems);
        group.add(&rows);
        group
    }

    fn own_group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder()
            .title("Your Own Choices")
            .description("These hold whichever theme is on.")
            .build();
        group.add(&self.cover_size_row);
        group.add(&self.covers);
        group.add(&self.corners);
        group.add(&self.font_row);
        group.add(&self.glow);
        group.add(&crate::ui::prefs::ui_scale_row(&self.ui));
        group.add(&crate::ui::prefs_sound::home_screen_row(&self.ui));
        group.add(&self.reset);
        group
    }

    fn folders_group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let open = adw::ButtonRow::builder()
            .title("Open Themes Folder")
            .end_icon_name("flaccy-folder-open-symbolic")
            .build();
        {
            let page = Rc::downgrade(self);
            open.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.open_folder(None);
                }
            });
        }
        let guide = adw::ButtonRow::builder()
            .title("How to Make a Theme")
            .end_icon_name("flaccy-link-symbolic")
            .build();
        {
            let window = self.ui.window.clone();
            guide.connect_activated(move |_| {
                gtk::UriLauncher::new(GUIDE_URL).launch(
                    Some(&window),
                    gio::Cancellable::NONE,
                    |result| {
                        if let Err(error) = result {
                            crate::logger::warn(
                                "ui",
                                &format!("theme guide did not open: {error}"),
                            );
                        }
                    },
                );
            });
        }
        self.folders.add(&self.copy);
        self.folders.add(&open);
        self.folders.add(&guide);
        self.folders.clone()
    }

    fn open_folder(&self, inside: Option<&std::path::Path>) {
        let Some(controller) = ThemeController::current() else {
            return;
        };
        let folder = inside
            .map(|path| path.to_path_buf())
            .unwrap_or_else(|| controller.themes_dir().to_path_buf());
        let _ = std::fs::create_dir_all(&folder);
        gtk::FileLauncher::new(Some(&gio::File::for_path(&folder))).launch(
            Some(&self.ui.window),
            gio::Cancellable::NONE,
            move |result| {
                if let Err(error) = result {
                    crate::logger::warn("ui", &format!("themes folder did not open: {error}"));
                }
            },
        );
    }

    fn copy_worn_theme(&self) {
        let Some(controller) = ThemeController::current() else {
            return;
        };
        let worn = controller.look().pack.id.clone();
        match controller.make_editable_copy(&worn) {
            Ok((id, folder)) => {
                let name = controller
                    .packs()
                    .iter()
                    .find(|pack| pack.id == id)
                    .map(|pack| pack.name.clone())
                    .unwrap_or_else(|| id.clone());
                own::wear_pack(&self.ui.core, &id);
                self.open_folder(Some(&folder));
                self.ui.core.toast(&format!(
                    "{name} is in your themes folder. Edit its files and watch it change."
                ));
            }
            Err(reason) => self
                .ui
                .core
                .toast(&format!("The theme was not copied. {reason}")),
        }
    }

    /// Wires every control. Each handler holds the page weakly: the page owns
    /// these widgets, so a strong hold would keep both alive after the dialog
    /// closed and leave a dead page answering look changes.
    fn connect(self: &Rc<Self>) {
        let page = Rc::downgrade(self);
        self.gallery.connect_child_activated(move |_, child| {
            if let Some(page) = page.upgrade().filter(|page| !page.syncing.get()) {
                own::wear_pack(&page.ui.core, &child.widget_name());
            }
        });
        let page = Rc::downgrade(self);
        self.colors.connect_selected_notify(move |row| {
            if let Some(page) = page.upgrade() {
                page.choose_scheme(row.selected());
            }
        });
        let page = Rc::downgrade(self);
        self.variant.connect_selected_notify(move |row| {
            if let Some(page) = page.upgrade() {
                page.choose_variant(row.selected());
            }
        });
        let page = Rc::downgrade(self);
        self.mode.connect_selected_notify(move |row| {
            let Some(page) = page.upgrade().filter(|page| !page.syncing.get()) else {
                return;
            };
            let appearance = MODE_IDS[(row.selected() as usize).min(MODE_IDS.len() - 1)];
            page.ui.core.config.borrow_mut().appearance = appearance.to_string();
            page.ui.core.save_config();
            if let Some(controller) = ThemeController::current() {
                controller.set_user_appearance(appearance);
            }
            crate::logger::info("ui", &format!("appearance set to {appearance}"));
        });
        self.connect_own(&self.albums, |config, selected| {
            let ids: Vec<&'static str> = AlbumsView::ALL.iter().map(|view| view.id()).collect();
            config.albums_view = own_id(&ids, selected).to_string();
        });
        self.connect_own(&self.covers, |config, selected| {
            let ids: Vec<&'static str> = CoverShape::ALL.iter().map(|shape| shape.id()).collect();
            config.look_covers = own_id(&ids, selected).to_string();
        });
        self.connect_own(&self.corners, |config, selected| {
            config.look_corners = own_id(&CORNER_IDS, selected).to_string();
        });
        self.connect_own(&self.glow, |config, selected| {
            config.look_glow = own_id(&["on", "off"], selected).to_string();
        });
        let page = Rc::downgrade(self);
        self.cover_size.connect_value_changed(move |scale| {
            if let Some(page) = page.upgrade() {
                page.cover_size_moved(scale.value());
            }
        });
        let page = Rc::downgrade(self);
        self.font_button.connect_font_desc_notify(move |button| {
            let Some(page) = page.upgrade().filter(|page| !page.syncing.get()) else {
                return;
            };
            let Some(family) = button.font_desc().and_then(|font| font.family()) else {
                return;
            };
            own::edit(&page.ui.core, |config| {
                config.look_font = family.to_string()
            });
        });
        let page = Rc::downgrade(self);
        self.font_clear.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                own::edit(&page.ui.core, |config| config.look_font.clear());
            }
        });
        let page = Rc::downgrade(self);
        self.reset.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                own::reset_own(&page.ui.core);
            }
        });
        let page = Rc::downgrade(self);
        self.copy.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.copy_worn_theme();
            }
        });
        let page = Rc::downgrade(self);
        self.ui
            .core
            .hub
            .subscribe_widget(&self.gallery, move |_, event| {
                if matches!(event, AppEvent::LookChanged) {
                    if let Some(page) = page.upgrade() {
                        page.sync();
                    }
                }
            });
    }

    fn connect_own(
        self: &Rc<Self>,
        row: &adw::ComboRow,
        write: impl Fn(&mut crate::config::Config, u32) + 'static,
    ) {
        let page = Rc::downgrade(self);
        row.connect_selected_notify(move |row| {
            let Some(page) = page.upgrade().filter(|page| !page.syncing.get()) else {
                return;
            };
            let selected = row.selected();
            own::edit(&page.ui.core, |config| write(config, selected));
        });
    }

    fn choose_scheme(&self, selected: u32) {
        if self.syncing.get() {
            return;
        }
        let Some(look) = ThemeController::current().map(|controller| controller.look()) else {
            return;
        };
        if let Some(scheme) = look.pack.schemes.get(selected as usize) {
            own::edit(&self.ui.core, |config| config.theme = scheme.id.clone());
        }
    }

    fn choose_variant(&self, selected: u32) {
        if self.syncing.get() {
            return;
        }
        let Some(look) = ThemeController::current().map(|controller| controller.look()) else {
            return;
        };
        if let Some(variant) = look.pack.variants.get(selected as usize) {
            own::wear_variant(&self.ui.core, &variant.id);
        }
    }

    fn cover_size_moved(self: &Rc<Self>, value: f64) {
        let size = value.round() as i32;
        self.cover_size_row.set_subtitle(&format!("{size} px"));
        if self.syncing.get() {
            return;
        }
        if let Some(pending) = self.cover_size_pending.borrow_mut().take() {
            pending.remove();
        }
        let page = Rc::downgrade(self);
        let pending = glib::timeout_add_local_once(SIZE_SETTLE, move || {
            if let Some(page) = page.upgrade() {
                page.cover_size_pending.borrow_mut().take();
                own::edit(&page.ui.core, |config| config.look_cover_size = size);
            }
        });
        *self.cover_size_pending.borrow_mut() = Some(pending);
    }

    fn sync_gallery(&self, controller: &ThemeController, look: &Look) {
        let packs = controller.packs();
        let schemes: Vec<String> = {
            let config = self.ui.core.config.borrow();
            packs
                .iter()
                .map(|pack| own::remembered(&config, &pack.id).scheme)
                .collect()
        };
        let fingerprint =
            gallery_fingerprint(&packs, &schemes, adw::StyleManager::default().is_dark());
        if self.gallery_shows.replace(fingerprint) != fingerprint {
            self.gallery.remove_all();
            for (pack, scheme) in packs.iter().zip(&schemes) {
                self.gallery.append(&card(pack, scheme));
            }
        }
        let mut index = 0;
        while let Some(child) = self.gallery.child_at_index(index) {
            if child.widget_name() == look.pack.id {
                self.gallery.select_child(&child);
            }
            index += 1;
        }
    }

    fn sync_theme_rows(&self, controller: &ThemeController, look: &Look) {
        let schemes: Vec<&str> = look
            .pack
            .schemes
            .iter()
            .map(|scheme| scheme.name.as_str())
            .collect();
        self.colors.set_model(Some(&gtk::StringList::new(&schemes)));
        self.colors.set_selected(look.scheme as u32);
        self.colors.set_visible(schemes.len() > 1);
        while let Some(old) = self.colors_swatch.first_child() {
            self.colors_swatch.remove(&old);
        }
        self.colors_swatch
            .append(&theme_preview::swatch(ThemeController::preview(
                &look.pack,
                &look.scheme().id,
            )));

        let variants: Vec<&str> = look
            .pack
            .variants
            .iter()
            .map(|variant| variant.name.as_str())
            .collect();
        self.variant
            .set_model(Some(&gtk::StringList::new(&variants)));
        self.variant.set_selected(look.variant.unwrap_or(0) as u32);
        self.variant.set_visible(variants.len() > 1);

        let asked = self.ui.core.config.borrow().appearance.clone();
        let forced = match look.appearance() {
            Appearance::Dark => Some((2, "dark")),
            Appearance::Light => Some((1, "light")),
            Appearance::Any => None,
        };
        let asked_at = MODE_IDS.iter().position(|id| *id == asked).unwrap_or(0) as u32;
        self.mode
            .set_selected(forced.map(|(at, _)| at).unwrap_or(asked_at));
        self.mode.set_sensitive(forced.is_none());
        self.mode.set_subtitle(
            &forced
                .map(|(_, mode)| {
                    let owner = if look.scheme().appearance.is_some() {
                        &look.scheme().name
                    } else {
                        &look.pack.name
                    };
                    format!("{owner} is drawn {mode}")
                })
                .unwrap_or_default(),
        );

        let mut problems = look.pack.warnings.clone();
        problems.extend(controller.stylesheet_errors());
        for row in self.theme_problem_rows.borrow_mut().drain(..) {
            self.theme_problems.remove(&row);
        }
        self.theme_problems.set_visible(!problems.is_empty());
        self.theme_problems.set_title(&match problems.len() {
            1 => format!("1 problem in {}", look.pack.name),
            count => format!("{count} problems in {}", look.pack.name),
        });
        self.theme_problems
            .set_subtitle("The rest of the theme still applies");
        for problem in &problems {
            let row = warning_row(problem);
            self.theme_problems.add_row(&row);
            self.theme_problem_rows.borrow_mut().push(row);
        }
    }

    fn sync_own_rows(&self, look: &Look) {
        let config = self.ui.core.config.borrow();
        let view_ids: Vec<&str> = AlbumsView::ALL.iter().map(|view| view.id()).collect();
        self.albums
            .set_selected(own_position(&view_ids, &config.albums_view));
        self.albums.set_subtitle(if config.albums_view.is_empty() {
            look.albums.title()
        } else {
            ""
        });
        let shape_ids: Vec<&str> = CoverShape::ALL.iter().map(|shape| shape.id()).collect();
        self.covers
            .set_selected(own_position(&shape_ids, &config.look_covers));
        self.covers.set_subtitle(if config.look_covers.is_empty() {
            look.covers.title()
        } else {
            ""
        });
        self.corners
            .set_selected(own_position(&CORNER_IDS, &config.look_corners));
        self.corners
            .set_subtitle(if config.look_corners.is_empty() {
                corners_title(look.corners)
            } else {
                ""
            });
        self.glow
            .set_selected(own_position(&["on", "off"], &config.look_glow));
        self.glow.set_subtitle(if !config.look_glow.is_empty() {
            ""
        } else if look.glow {
            "On"
        } else {
            "Off"
        });
        self.cover_size.set_value(look.cover_size as f64);
        self.cover_size_row
            .set_subtitle(&format!("{} px", look.cover_size));

        self.font_button.set_font_desc(&worn_font(&self.font_row));
        self.font_clear.set_visible(!config.look_font.is_empty());
        self.font_row.set_subtitle(if config.look_font.is_empty() {
            if look.interface_font.is_some() {
                "The theme's own"
            } else {
                "The desktop's"
            }
        } else {
            ""
        });
        self.reset.set_sensitive(own::has_own(&config));
    }

    fn sync_folders(&self, controller: &ThemeController, look: &Look) {
        self.copy
            .set_title(&format!("Copy {} to Change It", look.pack.name));
        for row in self.folder_problem_rows.borrow_mut().drain(..) {
            self.folders.remove(&row);
        }
        for problem in controller.problems() {
            let row = warning_row(&format!("{}: {}", problem.folder, problem.reason));
            self.folders.add(&row);
            self.folder_problem_rows.borrow_mut().push(row);
        }
    }

    /// Sets every control from the look that is on, without any of them
    /// reading the change as the person's.
    fn sync(&self) {
        let Some(controller) = ThemeController::current() else {
            return;
        };
        let look = controller.look();
        self.syncing.set(true);
        self.sync_gallery(&controller, &look);
        self.sync_theme_rows(&controller, &look);
        self.sync_own_rows(&look);
        self.sync_folders(&controller, &look);
        self.syncing.set(false);
    }
}

/// The groups of the Appearance page. The first group, which the page does
/// not own, keeps the page alive for as long as it is on screen.
pub fn groups(ui: &Rc<Ui>) -> Vec<adw::PreferencesGroup> {
    let page = Page::new(ui);
    let groups = vec![page.theme_group(), page.own_group(), page.folders_group()];
    page.connect();
    page.sync();
    groups[0].connect_destroy(move |_| {
        let _ = &page;
    });
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_s_choice_leads_every_own_row() {
        assert_eq!(
            with_themes_choice(&["On", "Off"]),
            ["Theme's Choice", "On", "Off"]
        );
        assert_eq!(own_position(&CORNER_IDS, ""), 0);
        assert_eq!(own_position(&CORNER_IDS, "sharp"), 1);
        assert_eq!(own_position(&CORNER_IDS, "round"), 3);
        assert_eq!(own_position(&CORNER_IDS, "gone"), 0);
        assert_eq!(own_id(&CORNER_IDS, 0), "");
        assert_eq!(own_id(&CORNER_IDS, 2), "standard");
        assert_eq!(own_id(&CORNER_IDS, 9), "");
    }

    #[test]
    fn a_corner_scale_has_a_name() {
        assert_eq!(corners_title(0.0), "Sharp");
        assert_eq!(corners_title(0.4), "Soft");
        assert_eq!(corners_title(1.0), "Standard");
        assert_eq!(corners_title(1.6), "Round");
    }
}
