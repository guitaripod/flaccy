//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/LibrarySearch.swift`.
//!
//! How a typed query finds an album, an artist, a song or a playlist, the same
//! on every client. Text is folded before it is compared: case and accents go,
//! and punctuation is read both as a word break and as nothing at all, so
//! "ac dc", "acdc" and "AC/DC" all meet. A query is cut into words and every
//! word must be found somewhere in the row, in any order and in any field, so
//! "beatles abbey" finds Abbey Road. `rank` says how well a name answers the
//! query, which is the order results are shown in.

use std::cell::RefCell;

/// Keeps the fields of one haystack apart. A query word can never contain it,
/// so a match can never straddle two fields.
pub const FIELD_BREAK: char = '\n';

/// How well a name answers a query, best first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Rank {
    /// The name is the query.
    Exact,
    /// The name begins with the query as typed.
    Prefix,
    /// Every word of the query begins a word of the name.
    WordPrefix,
    /// Every word of the query is somewhere in the name.
    Contains,
    /// The name alone does not answer it; the row's other fields do.
    Elsewhere,
}

/// ASCII letters for the Latin letters with a diacritic or a ligature that
/// music tags carry, lowercase only. Other scripts are compared as written.
fn fold_diacritic(c: char) -> Option<&'static str> {
    let folded = match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
        'ý' | 'ÿ' => "y",
        'ñ' | 'ń' | 'ň' => "n",
        'ç' | 'ć' | 'č' => "c",
        'ß' => "ss",
        'š' | 'ś' | 'ş' => "s",
        'ž' | 'ź' | 'ż' => "z",
        'ł' => "l",
        'đ' | 'ď' | 'ð' => "d",
        'ţ' | 'ť' => "t",
        'ř' => "r",
        'ğ' => "g",
        'æ' => "ae",
        'œ' => "oe",
        'þ' => "th",
        _ => return None,
    };
    Some(folded)
}

fn is_combining_mark(c: char) -> bool {
    ('\u{0300}'..='\u{036F}').contains(&c)
}

/// One field folded twice: `spaced` reads punctuation as a word break,
/// `joined` reads it as nothing. Both are lowercase, unaccented, and hold
/// single spaces between words with none at either end.
#[derive(Default)]
struct Folded {
    spaced: String,
    joined: String,
}

impl Folded {
    fn clear(&mut self) {
        self.spaced.clear();
        self.joined.clear();
    }

    fn push_letters(&mut self, letters: &str) {
        self.spaced.push_str(letters);
        self.joined.push_str(letters);
    }

    fn push_letter(&mut self, letter: char) {
        self.spaced.push(letter);
        self.joined.push(letter);
    }

    fn break_word(text: &mut String) {
        if !text.is_empty() && !text.ends_with(' ') {
            text.push(' ');
        }
    }

    fn push(&mut self, c: char) {
        if c.is_ascii() {
            if c.is_ascii_alphanumeric() {
                self.push_letter(c.to_ascii_lowercase());
            } else if c.is_ascii_whitespace() {
                Self::break_word(&mut self.spaced);
                Self::break_word(&mut self.joined);
            } else {
                Self::break_word(&mut self.spaced);
            }
            return;
        }
        if c.is_whitespace() {
            Self::break_word(&mut self.spaced);
            Self::break_word(&mut self.joined);
            return;
        }
        if is_combining_mark(c) {
            return;
        }
        let mut kept = false;
        for lower in c.to_lowercase() {
            if is_combining_mark(lower) {
                kept = true;
            } else if let Some(letters) = fold_diacritic(lower) {
                self.push_letters(letters);
                kept = true;
            } else if lower.is_alphanumeric() {
                self.push_letter(lower);
                kept = true;
            }
        }
        if !kept {
            Self::break_word(&mut self.spaced);
        }
    }

    fn fill(&mut self, text: &str) {
        self.clear();
        for c in text.chars() {
            self.push(c);
        }
        if self.spaced.ends_with(' ') {
            self.spaced.pop();
        }
        if self.joined.ends_with(' ') {
            self.joined.pop();
        }
    }
}

thread_local! {
    static FOLD_SCRATCH: RefCell<Folded> = RefCell::new(Folded::default());
    static HAYSTACK_SCRATCH: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Appends one field to a haystack: its folded text, twice when punctuation
/// makes the two readings differ, or the lowercased text itself for a name
/// made of nothing but symbols ("÷", "!!!"), which would otherwise fold away.
fn push_field(out: &mut String, field: &str) {
    FOLD_SCRATCH.with(|scratch| {
        let mut folded = scratch.borrow_mut();
        folded.fill(field);
        if !out.is_empty() {
            out.push(FIELD_BREAK);
        }
        if folded.spaced.is_empty() {
            out.extend(field.trim().chars().flat_map(char::to_lowercase));
            return;
        }
        out.push_str(&folded.spaced);
        if folded.joined != folded.spaced {
            out.push(FIELD_BREAK);
            out.push_str(&folded.joined);
        }
    });
}

/// What a query is matched against for one row: every field folded and kept
/// apart. Build it once per row and keep it when the rows outlive a keystroke.
pub fn haystack(fields: &[&str]) -> String {
    let mut out = String::with_capacity(fields.iter().map(|field| field.len() + 1).sum());
    for field in fields {
        push_field(&mut out, field);
    }
    out
}

/// A typed query, cut into folded words.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Query {
    words: Vec<String>,
}

impl Query {
    pub fn new(text: &str) -> Self {
        let mut folded = Folded::default();
        let words: Vec<String> = text
            .split_whitespace()
            .map(|chunk| {
                folded.fill(chunk);
                if folded.joined.is_empty() {
                    chunk.to_lowercase()
                } else {
                    folded.joined.clone()
                }
            })
            .collect();
        Self { words }
    }

    /// A query of nothing but spaces asks for nothing and matches every row.
    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    /// Whether every word of the query is in a haystack built by [`haystack`].
    pub fn matches_haystack(&self, haystack: &str) -> bool {
        self.words.iter().all(|word| haystack.contains(word.as_str()))
    }

    /// Whether every word of the query is in one of `fields`. Folds the fields
    /// into a buffer it keeps, so filtering a long list allocates nothing.
    pub fn matches(&self, fields: &[&str]) -> bool {
        if self.is_empty() {
            return true;
        }
        HAYSTACK_SCRATCH.with(|scratch| {
            let mut scratch = scratch.borrow_mut();
            scratch.clear();
            for field in fields {
                push_field(&mut scratch, field);
            }
            self.matches_haystack(&scratch)
        })
    }

    /// How well a row named `name` answers the query, or `None` when the name
    /// and the row's `other` fields together do not hold every word of it.
    /// Words the other fields answer (the artist in "metallica one") are set
    /// aside and the name is judged by the rest, so the song called One comes
    /// before a song that merely mentions both words in its title.
    pub fn rank(&self, name: &str, other: &[&str]) -> Option<Rank> {
        if self.is_empty() {
            return None;
        }
        let name_text = haystack(&[name]);
        let other_text = haystack(other);
        let left_to_name: Vec<&str> = self
            .words
            .iter()
            .map(String::as_str)
            .filter(|word| other.is_empty() || !other_text.contains(word))
            .collect();
        if left_to_name.is_empty() {
            return Some(if self.matches_haystack(&name_text) {
                Self::rank_in_name(&self.all_words(), &name_text)
            } else {
                Rank::Elsewhere
            });
        }
        left_to_name
            .iter()
            .all(|word| name_text.contains(word))
            .then(|| Self::rank_in_name(&left_to_name, &name_text))
    }

    fn all_words(&self) -> Vec<&str> {
        self.words.iter().map(String::as_str).collect()
    }

    fn rank_in_name(words: &[&str], name_text: &str) -> Rank {
        let readings = || name_text.split(FIELD_BREAK);
        let phrase = words.join(" ");
        let joined = words.concat();
        if readings().any(|reading| reading == phrase || reading == joined) {
            return Rank::Exact;
        }
        if readings().any(|reading| reading.starts_with(&phrase)) {
            return Rank::Prefix;
        }
        let begins_a_word = |word: &&str| {
            readings().any(|reading| reading.split(' ').any(|part| part.starts_with(word)))
        };
        if words.iter().all(begins_a_word) {
            return Rank::WordPrefix;
        }
        Rank::Contains
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HAYSTACKS: [(&[&str], &str); 12] = [
        (&["Abbey Road", "The Beatles"], "abbey road\nthe beatles"),
        (&["AC/DC"], "ac dc\nacdc"),
        (&["Sigur Rós", "Ágætis byrjun"], "sigur ros\nagaetis byrjun"),
        (&["Don't Stop Me Now"], "don t stop me now\ndont stop me now"),
        (&["R.E.M."], "r e m\nrem"),
        (&["÷"], "÷"),
        (&["  !!!  "], "!!!"),
        (&["Motörhead", "Björk", "Mötley Crüe"], "motorhead\nbjork\nmotley crue"),
        (&["Straße", "ŁÓDŹ", "İstanbul"], "strasse\nlodz\nistanbul"),
        (&["Beyonce\u{0301}"], "beyonce"),
        (&["東京事変  スポーツ"], "東京事変 スポーツ"),
        (&["Jay-Z", ""], "jay z\njayz\n"),
    ];

    const MATCHES: [(&str, &[&str], bool); 22] = [
        ("", &["anything"], true),
        ("   ", &["anything"], true),
        ("ROAD", &["Abbey Road", "The Beatles"], true),
        ("beatles abbey", &["Abbey Road", "The Beatles"], true),
        ("abbey beatles road", &["Abbey Road", "The Beatles"], true),
        ("beatles revolver", &["Abbey Road", "The Beatles"], false),
        ("sigur ros", &["Sigur Rós"], true),
        ("SIGUR RÓS", &["Sigur Ros"], true),
        ("acdc", &["AC/DC"], true),
        ("ac dc", &["AC/DC"], true),
        ("ac/dc", &["AC/DC"], true),
        ("ac-dc", &["ACDC"], true),
        ("dont stop", &["Don't Stop Me Now"], true),
        ("don't", &["Dont Stop Me Now"], true),
        ("rem", &["R.E.M."], true),
        ("r.e.m.", &["REM"], true),
        ("÷", &["÷"], true),
        ("÷", &["Divide"], false),
        ("!!!", &["!!!"], true),
        ("roadthe", &["Abbey Road", "The Beatles"], false),
        ("jayz", &["Jay-Z"], true),
        ("東京", &["東京事変"], true),
    ];

    const RANKS: [(&str, &str, &[&str], Option<Rank>); 20] = [
        ("abbey road", "Abbey Road", &[], Some(Rank::Exact)),
        ("acdc", "AC/DC", &[], Some(Rank::Exact)),
        ("ac dc", "AC/DC", &[], Some(Rank::Exact)),
        ("abbey", "Abbey Road", &[], Some(Rank::Prefix)),
        ("abbey ro", "Abbey Road", &[], Some(Rank::Prefix)),
        ("road", "Abbey Road", &[], Some(Rank::WordPrefix)),
        ("ro ab", "Abbey Road", &[], Some(Rank::WordPrefix)),
        ("bey", "Abbey Road", &[], Some(Rank::Contains)),
        ("road bey", "Abbey Road", &[], Some(Rank::Contains)),
        ("beatles", "Abbey Road", &["The Beatles"], Some(Rank::Elsewhere)),
        ("beatles abbey", "Abbey Road", &["The Beatles"], Some(Rank::Prefix)),
        ("abbey road", "Come Together", &["The Beatles", "Abbey Road"], Some(Rank::Elsewhere)),
        ("abbey road", "Abbey Road", &["The Beatles", "Abbey Road"], Some(Rank::Exact)),
        ("metallica one", "One", &["Metallica", "...And Justice for All"], Some(Rank::Exact)),
        ("metallica one", "One [Live cover on Metallica]", &["KoRn", "Live & Rare"], Some(Rank::WordPrefix)),
        ("metallica one", "Spit Out the Bone", &["Metallica", "Hardwired"], Some(Rank::Contains)),
        ("metallica two", "One", &["Metallica", "...And Justice for All"], None),
        ("stones", "Abbey Road", &["The Beatles"], None),
        ("", "Abbey Road", &[], None),
        ("bjork", "Björk", &[], Some(Rank::Exact)),
    ];

    #[test]
    fn haystacks_match_the_shared_vectors() {
        for (fields, expected) in HAYSTACKS {
            assert_eq!(haystack(fields), expected, "{fields:?}");
        }
    }

    #[test]
    fn matches_agree_with_the_shared_vectors() {
        for (query, fields, expected) in MATCHES {
            let query_words = Query::new(query);
            assert_eq!(query_words.matches(fields), expected, "{query:?} in {fields:?}");
            if !query_words.is_empty() {
                assert_eq!(
                    query_words.matches_haystack(&haystack(fields)),
                    expected,
                    "{query:?} in the haystack of {fields:?}"
                );
            }
        }
    }

    #[test]
    fn ranks_agree_with_the_shared_vectors() {
        for (query, name, other, expected) in RANKS {
            assert_eq!(Query::new(query).rank(name, other), expected, "{query:?} for {name:?}");
        }
    }

    #[test]
    fn ranks_order_best_first() {
        let mut ranks = [Rank::Elsewhere, Rank::Contains, Rank::Exact, Rank::WordPrefix, Rank::Prefix];
        ranks.sort();
        assert_eq!(
            ranks,
            [Rank::Exact, Rank::Prefix, Rank::WordPrefix, Rank::Contains, Rank::Elsewhere]
        );
    }
}
