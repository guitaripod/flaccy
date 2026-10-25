//! The text keys the library layer shares: diacritic-folded normalization and
//! the edition-free base title, so SQL, grouping and the wantlist agree.

/// Strips diacritics and every non-alphanumeric character, lowercased —
/// the iOS WantlistOwnership.normalize.
pub fn normalize(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        push_normalized(&mut out, c);
    }
    out
}

/// Appends the normalized form of one character: nothing for punctuation and
/// spaces, the folded lowercase letters for a known diacritic, the lowercase
/// expansion for any other alphanumeric.
fn push_normalized(out: &mut String, c: char) {
    if c.is_ascii() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        }
        return;
    }
    if let Some(folded) = fold_diacritic(c) {
        out.extend(folded.chars().map(|letter| letter.to_ascii_lowercase()));
    } else if c.is_alphanumeric() {
        out.extend(c.to_lowercase());
    }
}

/// ASCII-folds the Latin-1/Latin Extended diacritics that occur in practice in
/// music metadata; other scripts pass through untouched (`None`).
fn fold_diacritic(c: char) -> Option<&'static str> {
    let folded = match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' | 'Ā' => "A",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'È' | 'É' | 'Ê' | 'Ë' | 'Ē' => "E",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
        'Ì' | 'Í' | 'Î' | 'Ï' => "I",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
        'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' | 'Ø' => "O",
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
        'Ù' | 'Ú' | 'Û' | 'Ü' => "U",
        'ý' | 'ÿ' => "y",
        'ñ' | 'ń' | 'ň' => "n",
        'Ñ' => "N",
        'ç' | 'ć' | 'č' => "c",
        'Ç' => "C",
        'ß' => "ss",
        'š' | 'ś' => "s",
        'ž' | 'ź' | 'ż' => "z",
        'ł' => "l",
        'đ' => "d",
        'ţ' | 'ť' => "t",
        'ř' => "r",
        'ğ' => "g",
        'æ' => "ae",
        'Æ' => "AE",
        'œ' => "oe",
        _ => return None,
    };
    Some(folded)
}

/// Whether a bracketed or suffix segment carries one of the edition keywords.
pub fn contains_edition_keyword(segment: &str, keywords: &[&str]) -> bool {
    let lowered = segment.to_lowercase();
    let words = lowered
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty());
    for word in words {
        if keywords.contains(&word) {
            return true;
        }
    }
    keywords.contains(&"ft.") && lowered.contains("ft.")
}

/// Removes every bracket group whose content carries an edition keyword.
pub fn strip_decorated_brackets(value: &str, keywords: &[&str]) -> String {
    let mut result = value.to_string();
    for (open, close) in [('(', ')'), ('[', ']'), ('{', '}')] {
        let mut search_from = 0usize;
        while let Some(open_offset) = result[search_from..].find(open) {
            let open_index = search_from + open_offset;
            let Some(close_offset) = result[open_index + open.len_utf8()..].find(close) else {
                break;
            };
            let close_index = open_index + open.len_utf8() + close_offset;
            let segment = &result[open_index + open.len_utf8()..close_index];
            if contains_edition_keyword(segment, keywords) {
                result.replace_range(open_index..close_index + close.len_utf8(), "");
                search_from = 0;
            } else {
                search_from = close_index + close.len_utf8();
            }
        }
    }
    result
}

/// The keyword-parametrized base-title reduction backing both the wantlist
/// (full `EDITION_KEYWORDS`) and library consolidation (`CONSOLIDATION_KEYWORDS`)
/// so the strip logic is never forked.
pub fn base_title_with(raw: &str, keywords: &[&str]) -> String {
    let mut title = strip_decorated_brackets(&raw.to_lowercase(), keywords);
    for separator in [" - ", ": ", " – "] {
        if let Some(index) = title.find(separator) {
            let suffix = &title[index + separator.len()..];
            if contains_edition_keyword(suffix, keywords) {
                title.truncate(index);
            }
        }
    }
    normalize(&title)
}

#[cfg(test)]
pub(crate) mod legacy_keys {
    pub fn fold_diacritic(c: char) -> Vec<char> {
        let folded: &str = match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
            'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' | 'Ā' => "A",
            'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
            'È' | 'É' | 'Ê' | 'Ë' | 'Ē' => "E",
            'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
            'Ì' | 'Í' | 'Î' | 'Ï' => "I",
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
            'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' | 'Ø' => "O",
            'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
            'Ù' | 'Ú' | 'Û' | 'Ü' => "U",
            'ý' | 'ÿ' => "y",
            'ñ' | 'ń' | 'ň' => "n",
            'Ñ' => "N",
            'ç' | 'ć' | 'č' => "c",
            'Ç' => "C",
            'ß' => "ss",
            'š' | 'ś' => "s",
            'ž' | 'ź' | 'ż' => "z",
            'ł' => "l",
            'đ' => "d",
            'ţ' | 'ť' => "t",
            'ř' => "r",
            'ğ' => "g",
            'æ' => "ae",
            'Æ' => "AE",
            'œ' => "oe",
            _ => return vec![c],
        };
        folded.chars().collect()
    }

    pub fn normalize(value: &str) -> String {
        value
            .chars()
            .flat_map(fold_diacritic)
            .filter(|c| c.is_alphanumeric())
            .flat_map(|c| c.to_lowercase())
            .collect()
    }

    pub fn primary_artist(raw: &str) -> String {
        let lower = raw.to_lowercase();
        let mut cut = raw.len();
        for sep in [
            ";",
            " / ",
            " \u{00D7} ",
            " x ",
            " & ",
            " + ",
            " vs. ",
            " vs ",
            " feat. ",
            " feat ",
            " ft. ",
            " ft ",
            " featuring ",
            " (feat.",
            " (ft.",
            " (featuring",
            " with ",
        ] {
            if let Some(idx) = lower.find(sep) {
                cut = cut.min(idx);
            }
        }
        let result = raw[..cut].trim();
        if result.is_empty() {
            raw.trim().to_string()
        } else {
            result.to_string()
        }
    }

    pub fn artist_key(credit: &str) -> String {
        normalize(&primary_artist(credit))
    }

    /// Runs `compute`, mapping a panic to `None` so old and new can be compared
    /// even where the original slices a non-char-boundary offset.
    pub fn outcome(compute: impl FnOnce() -> String + std::panic::UnwindSafe) -> Option<String> {
        std::panic::catch_unwind(compute).ok()
    }

    pub fn corpus() -> Vec<String> {
        let names = [
            "Sigur Rós", "Beyoncé", "deadmau5", "Deadmau5", "Jay-Z", "AC/DC", "Björk", "Mötley Crüe",
            "Æon Flux", "Œuvre", "Straße", "Łódź", "Đorđe", "Škoda", "Ťažký", "Řeřicha", "Ğ", "Ñandú",
            "İstanbul", "ΣΑΣ", "Ǆ", "ǅ", "ß", "ŉ", "ﬁne", "ﬃ", "Ⅷ", "²", "٣", "①", "日本語", "坂本龍一",
            "Ёлка", "Кино", "한국어", "🎵 Emoji 🎶", "👨‍👩‍👧", "e\u{301}", "a\u{308}", "x", "X", "",
            " ", "   ", "(feat. Someone)", "feat. Nobody", "Corvid & Crane", "Simon, Garfunkel",
        ];
        let separators = [
            ";", " / ", " \u{00D7} ", " x ", " X ", " & ", " + ", " vs. ", " VS ", " vs ", " feat. ",
            " Feat. ", " feat ", " ft. ", " FT ", " ft ", " featuring ", " Featuring ", " (feat.",
            " (ft.", " (Featuring", " with ", " With ", ",", "/", "x", "feat.", "&", "-", "'", "  ",
        ];
        let mut corpus: Vec<String> = names.iter().map(|name| name.to_string()).collect();
        for first in names {
            for separator in separators {
                for second in ["Kaskade", "Sia", "Déjà Vu", "", "日本"] {
                    corpus.push(format!("{first}{separator}{second}"));
                    corpus.push(format!("{separator}{first}{separator}{second}"));
                }
            }
        }
        corpus
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_diacritics_and_punctuation() {
        assert_eq!(normalize("Sigur Rós"), "sigurros");
        assert_eq!(normalize("Beyoncé!"), "beyonce");
        assert_eq!(normalize("AC/DC"), "acdc");
        assert_eq!(normalize("Björk"), "bjork");
    }

    #[test]
    fn normalize_matches_the_original_over_every_scalar_value() {
        for code in 0..=0x10FFFFu32 {
            let Some(c) = char::from_u32(code) else {
                continue;
            };
            let single = c.to_string();
            assert_eq!(normalize(&single), legacy_keys::normalize(&single), "U+{code:04X}");
            let wrapped = format!("A{c}b");
            assert_eq!(normalize(&wrapped), legacy_keys::normalize(&wrapped), "U+{code:04X}");
        }
    }

    #[test]
    fn normalize_matches_the_original_over_the_corpus() {
        for text in legacy_keys::corpus() {
            assert_eq!(normalize(&text), legacy_keys::normalize(&text), "{text:?}");
        }
    }

    #[test]
    #[ignore]
    fn normalize_matches_the_original_over_the_real_library() {
        for text in crate::library::perf_fixture::distinct_strings() {
            assert_eq!(normalize(&text), legacy_keys::normalize(&text), "{text:?}");
        }
    }
}
