/// Sentence ends that need a space after them, and the full-width ones that
/// do not.
const SENTENCE_ENDS: [char; 3] = ['.', '!', '?'];
const WIDE_SENTENCE_ENDS: [char; 3] = ['\u{3002}', '\u{FF01}', '\u{FF1F}'];
/// The least room worth filling with part of a paragraph after a whole one.
const SMALLEST_TAIL: usize = 120;
const ELLIPSIS: char = '\u{2026}';

/// Length the way the flaccy-api Worker and Swift's `utf16.count` measure it.
pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// Whole paragraphs, trimmed and joined by a blank line, up to `limit` UTF-16
/// units. A paragraph that does not fit whole is cut after its last sentence
/// that does, or after a word with an ellipsis, and nothing follows it.
pub fn clip(paragraphs: &[&str], limit: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for paragraph in paragraphs {
        let paragraph = paragraph.trim();
        if paragraph.is_empty() {
            continue;
        }
        let separator = if out.is_empty() { 0 } else { 2 };
        let length = utf16_len(paragraph);
        if used + separator + length <= limit {
            if separator > 0 {
                out.push_str("\n\n");
            }
            out.push_str(paragraph);
            used += separator + length;
            continue;
        }
        let room = limit.saturating_sub(used + separator);
        if out.is_empty() || room >= SMALLEST_TAIL {
            if let Some(head) = cut(paragraph, room) {
                if separator > 0 {
                    out.push_str("\n\n");
                }
                out.push_str(&head);
            }
        }
        break;
    }
    out
}

/// The longest head of `text` within `room` units that ends a sentence, when
/// that keeps at least half of what fits; otherwise the head that ends a word,
/// or failing that the head that fits, followed by an ellipsis.
fn cut(text: &str, room: usize) -> Option<String> {
    let scalars: Vec<char> = text.chars().collect();
    let fits = fitting(&scalars, room);
    let sentence = (1..=fits)
        .rev()
        .find(|&end| ends_sentence(&scalars, end));
    if let Some(end) = sentence {
        if end * 2 >= fits {
            return Some(scalars[..end].iter().collect());
        }
    }
    let shorter = fitting(&scalars, room.saturating_sub(1));
    if shorter == 0 {
        return None;
    }
    let word = (1..=shorter)
        .rev()
        .find(|&end| scalars.get(end).is_none_or(|next| next.is_whitespace()));
    let end = word.unwrap_or(shorter);
    let head: String = scalars[..end].iter().collect();
    Some(format!("{}{ELLIPSIS}", head.trim_end()))
}

/// How many leading scalars fit in `room` UTF-16 units.
fn fitting(scalars: &[char], room: usize) -> usize {
    let mut used = 0;
    for (index, scalar) in scalars.iter().enumerate() {
        used += scalar.len_utf16();
        if used > room {
            return index;
        }
    }
    scalars.len()
}

fn ends_sentence(scalars: &[char], end: usize) -> bool {
    let last = scalars[end - 1];
    if WIDE_SENTENCE_ENDS.contains(&last) {
        return true;
    }
    SENTENCE_ENDS.contains(&last) && scalars.get(end).is_none_or(|next| next.is_whitespace())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_paragraphs_join_with_a_blank_line() {
        assert_eq!(clip(&["One.", "  Two.  ", ""], 100), "One.\n\nTwo.");
    }

    #[test]
    fn a_paragraph_that_does_not_fit_after_another_is_left_out_when_little_room_is_left() {
        let long = "word ".repeat(40);
        assert_eq!(clip(&["Short first.", &long], 60), "Short first.");
    }

    #[test]
    fn an_overlong_paragraph_ends_at_its_last_sentence_that_fits() {
        let text = "The first sentence is here. The second one runs on and on past the limit.";
        assert_eq!(clip(&[text], 40), "The first sentence is here.");
    }

    #[test]
    fn a_decimal_point_is_not_a_sentence_end() {
        let text = "It reached 3.5 million listeners in a week and kept going for months";
        assert_eq!(clip(&[text], 20), "It reached 3.5\u{2026}");
    }

    #[test]
    fn without_an_early_sentence_end_the_cut_falls_on_a_word() {
        let text = "Hi. this sentence keeps going without any stop for a long while";
        assert_eq!(clip(&[text], 30), "Hi. this sentence keeps going\u{2026}");
    }

    #[test]
    fn text_without_spaces_is_cut_where_it_fits() {
        assert_eq!(clip(&["这是一首关于青春的歌曲没有句号"], 6), "这是一首关\u{2026}");
        assert_eq!(clip(&["这是一首歌。关于青春的故事"], 8), "这是一首歌。");
    }

    #[test]
    fn length_counts_utf16_units_like_the_worker() {
        assert_eq!(utf16_len("a\u{1F3B5}é"), 4);
        assert_eq!(clip(&["\u{1F3B5}\u{1F3B5}\u{1F3B5}"], 5), "\u{1F3B5}\u{1F3B5}\u{2026}");
    }

    #[test]
    fn no_room_means_nothing() {
        assert_eq!(clip(&["Anything at all"], 0), "");
    }
}
