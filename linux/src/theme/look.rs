pub use flaccy_shared::theme::look::*;

use super::pack::{AlbumsView, CoverShape, Style, CORNERS_ROUND, CORNERS_SHARP, CORNERS_STANDARD, COVER_SIZE_MAX, COVER_SIZE_MIN};
use crate::config::Config;

/// Which theme, scheme and variant `config.toml` has on.
pub fn choice_from_config(config: &Config) -> Choice {
    Choice {
        pack: config.theme_pack.clone(),
        scheme: config.theme.clone(),
        variant: config.theme_variant.clone(),
    }
}

/// The person's own choices, laid over whatever the theme says. They are read
/// from `config.toml`, where an empty or zero value means "as the theme has it".
pub fn overrides_from_config(config: &Config) -> Style {
    Style {
        interface_font: Some(config.look_font.trim().to_string()).filter(|font| !font.is_empty()),
        heading_font: None,
        corners: match config.look_corners.as_str() {
            "sharp" => Some(CORNERS_SHARP),
            "standard" => Some(CORNERS_STANDARD),
            "round" => Some(CORNERS_ROUND),
            _ => None,
        },
        covers: CoverShape::from_id(&config.look_covers),
        shadows: None,
        albums: AlbumsView::from_id(&config.albums_view),
        cover_size: Some(config.look_cover_size)
            .filter(|size| *size > 0)
            .map(|size| size.clamp(COVER_SIZE_MIN, COVER_SIZE_MAX)),
        glow: match config.look_glow.as_str() {
            "on" => Some(true),
            "off" => Some(false),
            _ => None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_persons_choices_read_from_config() {
        let mut config = Config::default();
        assert!(overrides_from_config(&config).is_empty());
        config.albums_view = "carousel".to_string();
        config.look_cover_size = 999;
        config.look_covers = "circle".to_string();
        config.look_corners = "sharp".to_string();
        config.look_font = " Inter ".to_string();
        config.look_glow = "off".to_string();
        let mine = overrides_from_config(&config);
        assert_eq!(mine.albums, Some(AlbumsView::Carousel));
        assert_eq!(mine.cover_size, Some(COVER_SIZE_MAX));
        assert_eq!(mine.covers, Some(CoverShape::Circle));
        assert_eq!(mine.corners, Some(CORNERS_SHARP));
        assert_eq!(mine.interface_font.as_deref(), Some("Inter"));
        assert_eq!(mine.glow, Some(false));
    }
}
