//! The text keys the library layer shares: diacritic-folded normalization and
//! the edition-free base title, so SQL, grouping and the wantlist agree.

/// Strips diacritics and every non-alphanumeric character, lowercased —
/// the iOS WantlistOwnership.normalize.
pub fn normalize(value: &str) -> String {
    value
        .chars()
        .flat_map(fold_diacritic)
        .filter(|c| c.is_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// ASCII-folds the Latin-1/Latin Extended diacritics that occur in practice in
/// music metadata; other scripts pass through untouched.
fn fold_diacritic(c: char) -> Vec<char> {
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
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_diacritics_and_punctuation() {
        assert_eq!(normalize("Sigur Rós"), "sigurros");
        assert_eq!(normalize("Beyoncé!"), "beyonce");
        assert_eq!(normalize("AC/DC"), "acdc");
        assert_eq!(normalize("Björk"), "bjork");
    }
}
