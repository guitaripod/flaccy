use crate::app::AppCore;
use crate::config::Config;
use crate::theme::look::{choice_from_config, overrides_from_config};
use crate::theme::{builtin, ThemeController};

/// The id of the theme `config` has on, with the empty default spelled out.
pub fn worn_pack_id(config: &Config) -> String {
    if config.theme_pack.is_empty() {
        builtin::DEFAULT_ID.to_string()
    } else {
        config.theme_pack.clone()
    }
}

/// What a theme was last worn with: its color scheme, its variant and the
/// Albums view the person switched it to. Each is empty where the theme's own
/// first choice applies.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Worn {
    pub scheme: String,
    pub variant: String,
    pub view: String,
}

impl Worn {
    fn of(config: &Config) -> Worn {
        Worn {
            scheme: config.theme.clone(),
            variant: config.theme_variant.clone(),
            view: config.albums_view.clone(),
        }
    }

    fn encoded(&self) -> String {
        format!("{}|{}|{}", self.scheme, self.variant, self.view)
    }

    fn decoded(memory: &str) -> Worn {
        let mut parts = memory.split('|').map(str::to_string);
        Worn {
            scheme: parts.next().unwrap_or_default(),
            variant: parts.next().unwrap_or_default(),
            view: parts.next().unwrap_or_default(),
        }
    }
}

/// How `pack` was last worn, or all defaults when it never was.
pub fn remembered(config: &Config, pack: &str) -> Worn {
    if worn_pack_id(config) == pack {
        return Worn::of(config);
    }
    config
        .theme_memory
        .get(pack)
        .map(|memory| Worn::decoded(memory))
        .unwrap_or_default()
}

fn remember_worn(config: &mut Config) {
    let worn = worn_pack_id(config);
    let memory = Worn::of(config).encoded();
    config.theme_memory.insert(worn, memory);
}

fn apply(core: &AppCore) {
    let (choice, overrides) = {
        let config = core.config.borrow();
        (choice_from_config(&config), overrides_from_config(&config))
    };
    if let Some(controller) = ThemeController::current() {
        controller.apply(choice, overrides);
    }
}

/// The one place the look changes: `change` rewrites what the config says
/// about it (scheme, variant, view or any of the person's own choices), which
/// is then remembered for the theme that is on, saved and applied.
pub fn edit(core: &AppCore, change: impl FnOnce(&mut Config)) {
    {
        let mut config = core.config.borrow_mut();
        change(&mut config);
        remember_worn(&mut config);
    }
    core.save_config();
    apply(core);
}

/// Puts on the theme with this id, as it was last worn.
pub fn wear_pack(core: &AppCore, pack: &str) {
    {
        let mut config = core.config.borrow_mut();
        if worn_pack_id(&config) == pack {
            return;
        }
        remember_worn(&mut config);
        let worn = remembered(&config, pack);
        config.theme_pack = pack.to_string();
        config.theme = worn.scheme;
        config.theme_variant = worn.variant;
        config.albums_view = worn.view;
    }
    core.save_config();
    crate::logger::info("ui", &format!("theme set to {pack}"));
    apply(core);
}

/// Puts on another variant of the worn theme. A variant is a layout of its
/// own, so a view the person switched to earlier gives way to it.
pub fn wear_variant(core: &AppCore, variant: &str) {
    edit(core, |config| {
        config.theme_variant = variant.to_string();
        config.albums_view.clear();
    });
}

/// Clears every choice of the person's own, leaving the theme as its author
/// made it. The interface zoom is not one of them and stays.
pub fn reset_own(core: &AppCore) {
    edit(core, |config| {
        config.albums_view.clear();
        config.look_cover_size = 0;
        config.look_covers.clear();
        config.look_corners.clear();
        config.look_font.clear();
        config.look_glow.clear();
    });
}

pub fn has_own(config: &Config) -> bool {
    !overrides_from_config(config).is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worn(scheme: &str, variant: &str, view: &str) -> Worn {
        Worn {
            scheme: scheme.to_string(),
            variant: variant.to_string(),
            view: view.to_string(),
        }
    }

    #[test]
    fn a_theme_is_remembered_as_it_was_left() {
        let mut config = Config::default();
        assert_eq!(worn_pack_id(&config), "flaccy");
        assert_eq!(remembered(&config, "flaccy"), worn("adaptive", "", ""));
        assert_eq!(remembered(&config, "phosphor"), Worn::default());

        config.theme = "aurora".to_string();
        config.albums_view = "wall".to_string();
        remember_worn(&mut config);
        config.theme_pack = "phosphor".to_string();
        config.theme = "amber".to_string();
        config.theme_variant = "grid".to_string();
        config.albums_view.clear();
        remember_worn(&mut config);

        assert_eq!(remembered(&config, "flaccy"), worn("aurora", "", "wall"));
        assert_eq!(remembered(&config, "phosphor"), worn("amber", "grid", ""));
    }

    #[test]
    fn a_memory_written_short_reads_with_the_rest_empty() {
        assert_eq!(Worn::decoded("amber|grid"), worn("amber", "grid", ""));
        assert_eq!(Worn::decoded(""), Worn::default());
        assert_eq!(
            Worn::decoded(&worn("a", "b", "c").encoded()),
            worn("a", "b", "c")
        );
    }

    #[test]
    fn the_memory_survives_the_config_file() {
        let mut config = Config::default();
        config.theme_pack = "phosphor".to_string();
        config.theme = "amber".to_string();
        remember_worn(&mut config);
        let written = toml::to_string_pretty(&config).unwrap();
        let read: Config = toml::from_str(&written).unwrap();
        assert_eq!(read.theme_pack, "phosphor");
        assert_eq!(
            read.theme_memory.get("phosphor").map(String::as_str),
            Some("amber||")
        );
    }

    #[test]
    fn a_config_from_before_themes_keeps_its_palette() {
        let read: Config = toml::from_str("theme = \"aurora\"\nappearance = \"dark\"\n").unwrap();
        assert_eq!(worn_pack_id(&read), "flaccy");
        assert_eq!(read.theme, "aurora");
        assert!(!has_own(&read));
    }
}
