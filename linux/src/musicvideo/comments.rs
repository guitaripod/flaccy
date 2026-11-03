use crate::downloads::resolve_tool;
use std::collections::VecDeque;
use std::ops::Range;
use std::process::{Command, Stdio};
use std::sync::Arc;

/// How many comments one fetch brings back. A hundred top comments take about
/// three seconds through yt-dlp and are more than anyone reads beside a song;
/// the rest are a click away on YouTube.
pub const FETCH_LIMIT: usize = 100;

/// How many videos' comments stay in memory, so going back to a song or
/// flipping the sort shows them at once.
const REMEMBERED: usize = 24;

const FETCH_TIMEOUT_SECS: &str = "20";

/// Which comments YouTube hands over first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Sort {
    Top,
    Newest,
}

impl Sort {
    pub fn id(self) -> &'static str {
        match self {
            Sort::Top => "top",
            Sort::Newest => "new",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Sort::Top => "Top",
            Sort::Newest => "Newest",
        }
    }
}

/// One top-level comment under a music video.
#[derive(Clone, Debug, PartialEq)]
pub struct Comment {
    pub id: String,
    pub author: String,
    pub avatar: Option<String>,
    pub text: String,
    pub likes: u64,
    /// YouTube's own wording of the comment's age, "7 years ago".
    pub age: String,
    pub edited: bool,
    pub pinned: bool,
    pub by_uploader: bool,
    /// The uploader hearted it.
    pub hearted: bool,
    pub verified: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Loaded(Arc<Vec<Comment>>),
    /// The uploader switched comments off, or YouTube does on videos made
    /// for children.
    TurnedOff,
    Failed(String),
}

/// A moment of the video a comment points at ("the flip at 1:29"): where the
/// time sits in the text, in bytes, and the second it names.
#[derive(Clone, Debug, PartialEq)]
pub struct Moment {
    pub range: Range<usize>,
    pub seconds: f64,
}

/// Fetches a video's comments through yt-dlp, which reads them the way the
/// YouTube page does: no API key, no account. Blocking; run it off the main
/// thread.
pub fn fetch(video_id: &str, sort: Sort) -> Outcome {
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        return Outcome::Failed(super::YT_DLP_MISSING.to_string());
    };
    let arguments = format!(
        "youtube:comment_sort={};max_comments={FETCH_LIMIT},{FETCH_LIMIT},0,0;skip=dash,hls,translated_subs",
        sort.id()
    );
    let output = Command::new(yt_dlp)
        .args(["--ignore-config", "--no-warnings", "--write-comments"])
        .args(["--socket-timeout", FETCH_TIMEOUT_SECS])
        .args(["--extractor-args", &arguments])
        .args(["--print", "%(comments)j", "--"])
        .arg(super::search::watch_url(video_id))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(err) => return Outcome::Failed(format!("could not start yt-dlp: {err}")),
    };
    match parse(&output.stdout) {
        Some(outcome) => outcome,
        None if !output.status.success() => Outcome::Failed(crate::downloads::friendly_error(
            &String::from_utf8_lossy(&output.stderr),
        )),
        None => Outcome::Failed("yt-dlp returned something unreadable".to_string()),
    }
}

/// Reads what `--print "%(comments)j"` wrote: a JSON list of comments, or
/// `NA` when the video has none to give because they are turned off. `None`
/// when the output is neither.
pub fn parse(stdout: &[u8]) -> Option<Outcome> {
    let text = String::from_utf8_lossy(stdout);
    let line = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    if line == "NA" {
        return Some(Outcome::TurnedOff);
    }
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let comments = value
        .as_array()?
        .iter()
        .filter(|entry| entry["parent"].as_str().is_none_or(|parent| parent == "root"))
        .filter_map(parse_comment)
        .collect();
    Some(Outcome::Loaded(Arc::new(comments)))
}

fn parse_comment(value: &serde_json::Value) -> Option<Comment> {
    let text = value["text"].as_str()?.trim();
    if text.is_empty() {
        return None;
    }
    let raw_age = value["_time_text"].as_str().unwrap_or_default().trim();
    let (age, edited) = match raw_age.strip_suffix("(edited)") {
        Some(age) => (age.trim().to_string(), true),
        None => (raw_age.to_string(), false),
    };
    let flag = |key: &str| value[key].as_bool().unwrap_or(false);
    Some(Comment {
        id: value["id"].as_str().unwrap_or_default().to_string(),
        author: value["author"].as_str().unwrap_or_default().trim().to_string(),
        avatar: value["author_thumbnail"]
            .as_str()
            .filter(|url| url.starts_with("https://"))
            .map(str::to_string),
        text: text.to_string(),
        likes: value["like_count"].as_u64().unwrap_or(0),
        age,
        edited,
        pinned: flag("is_pinned"),
        by_uploader: flag("author_is_uploader"),
        hearted: flag("is_favorited"),
        verified: flag("author_is_verified"),
    })
}

/// Finds the times a comment names, `1:29` or `1:02:03`, the way YouTube
/// turns them into links: whole numbers only, seconds below sixty, nothing
/// glued on either side that would make it a ratio, a score or a clock.
pub fn moments(text: &str) -> Vec<Moment> {
    let bytes = text.as_bytes();
    let mut found = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() || (index > 0 && glued_before(bytes[index - 1])) {
            index += 1;
            continue;
        }
        let mut end = index;
        while end < bytes.len() && (bytes[end].is_ascii_digit() || bytes[end] == b':') {
            end += 1;
        }
        if !glued_after(bytes, end) {
            if let Some(seconds) = clock_seconds(&text[index..end]) {
                found.push(Moment {
                    range: index..end,
                    seconds,
                });
            }
        }
        index = end.max(index + 1);
    }
    found
}

/// A character before a run of digits that makes it part of something larger
/// than a time: a word, a version, a decimal, a fraction.
fn glued_before(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'.' | b'/')
}

/// The same after the run, where a full stop or a comma only glues when a
/// digit follows it: "at 1:29, the drop" is a time, "12:30.5" is not.
fn glued_after(bytes: &[u8], end: usize) -> bool {
    let Some(&next) = bytes.get(end) else {
        return false;
    };
    let digit_follows = bytes.get(end + 1).is_some_and(u8::is_ascii_digit);
    next.is_ascii_alphanumeric()
        || matches!(next, b':' | b'/')
        || (matches!(next, b'.' | b',') && digit_follows)
}

/// `m:ss` or `h:mm:ss` in seconds, or `None` for anything else.
fn clock_seconds(token: &str) -> Option<f64> {
    let parts: Vec<&str> = token.split(':').collect();
    if !(2..=3).contains(&parts.len()) || parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    let numbers: Vec<u64> = parts
        .iter()
        .map(|part| part.parse().ok())
        .collect::<Option<_>>()?;
    let lead = parts[0];
    let tail_ok = parts[1..].iter().all(|part| part.len() == 2);
    if !tail_ok || lead.len() > 2 || numbers[1..].iter().any(|value| *value >= 60) {
        return None;
    }
    Some(
        numbers
            .iter()
            .fold(0u64, |total, value| total * 60 + value) as f64,
    )
}

/// The comments of the last few videos and sorts, newest first.
#[derive(Default)]
pub struct Store {
    entries: std::cell::RefCell<VecDeque<((String, Sort), Outcome)>>,
}

impl Store {
    pub fn get(&self, video_id: &str, sort: Sort) -> Option<Outcome> {
        self.entries
            .borrow()
            .iter()
            .find(|((id, kind), _)| id == video_id && *kind == sort)
            .map(|(_, outcome)| outcome.clone())
    }

    /// Keeps a fetch's answer, unless it failed: a failure is worth asking
    /// again the next time the comments are opened.
    pub fn insert(&self, video_id: &str, sort: Sort, outcome: Outcome) {
        if matches!(outcome, Outcome::Failed(_)) {
            return;
        }
        let mut entries = self.entries.borrow_mut();
        entries.retain(|((id, kind), _)| !(id == video_id && *kind == sort));
        entries.push_front(((video_id.to_string(), sort), outcome));
        entries.truncate(REMEMBERED);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seconds(text: &str) -> Vec<f64> {
        moments(text).into_iter().map(|moment| moment.seconds).collect()
    }

    #[test]
    fn times_in_a_comment_are_found_where_they_sit() {
        let text = "The flip is SO under appreciated 1:29";
        let found = moments(text);
        assert_eq!(found.len(), 1);
        assert_eq!(&text[found[0].range.clone()], "1:29");
        assert_eq!(found[0].seconds, 89.0);
        assert_eq!(seconds("0:45 and again at 2:10!"), vec![45.0, 130.0]);
        assert_eq!(seconds("(3:05) the bridge"), vec![185.0]);
        assert_eq!(seconds("1:02:03 marathon"), vec![3723.0]);
        assert_eq!(seconds("ends at 4:20."), vec![260.0]);
        assert_eq!(seconds("at 1:29, the drop"), vec![89.0]);
    }

    #[test]
    fn things_that_only_look_like_times_are_left_alone() {
        assert!(seconds("odds 3:1 on a 16:9 screen").is_empty());
        assert!(seconds("score 2:75").is_empty());
        assert!(seconds("v1:30 build").is_empty());
        assert!(seconds("1:30:5").is_empty());
        assert!(seconds("12:30.5 seconds").is_empty());
        assert!(seconds("100:00").is_empty());
        assert!(seconds("no times here").is_empty());
        assert!(seconds("").is_empty());
    }

    #[test]
    fn a_comment_list_is_read_with_its_badges() {
        let stdout = br#"[{"id":"a","parent":"root","text":"  Who else hates growing up?? ","like_count":5600,"author":"@carl","author_thumbnail":"https://yt3.ggpht.com/x=s88","author_is_uploader":false,"author_is_verified":true,"is_favorited":true,"_time_text":"7 years ago (edited)","is_pinned":true},{"id":"b","parent":"a","text":"a reply","author":"@r"},{"id":"c","parent":"root","text":"","author":"@empty"},{"id":"d","parent":"root","text":"me","author":"@AvrilLavigne","author_is_uploader":true,"_time_text":"1 month ago"}]
"#;
        let Some(Outcome::Loaded(comments)) = parse(stdout) else {
            panic!("not loaded");
        };
        assert_eq!(comments.len(), 2);
        let first = &comments[0];
        assert_eq!(first.text, "Who else hates growing up??");
        assert_eq!(first.likes, 5600);
        assert_eq!(first.age, "7 years ago");
        assert!(first.edited && first.pinned && first.hearted && first.verified);
        assert!(!first.by_uploader);
        assert_eq!(first.avatar.as_deref(), Some("https://yt3.ggpht.com/x=s88"));
        let second = &comments[1];
        assert!(second.by_uploader && !second.edited);
        assert_eq!(second.likes, 0);
        assert_eq!(second.avatar, None);
    }

    #[test]
    fn turned_off_comments_and_junk_are_told_apart() {
        assert_eq!(parse(b"NA\n"), Some(Outcome::TurnedOff));
        assert_eq!(parse(b"[]\n"), Some(Outcome::Loaded(Arc::new(Vec::new()))));
        assert_eq!(parse(b""), None);
        assert_eq!(parse(b"ERROR: nope"), None);
    }

    #[test]
    fn the_store_remembers_answers_but_not_failures() {
        let store = Store::default();
        store.insert("v", Sort::Top, Outcome::TurnedOff);
        store.insert("v", Sort::Newest, Outcome::Failed("offline".into()));
        assert_eq!(store.get("v", Sort::Top), Some(Outcome::TurnedOff));
        assert_eq!(store.get("v", Sort::Newest), None);
        for index in 0..REMEMBERED {
            store.insert(&format!("other{index}"), Sort::Top, Outcome::TurnedOff);
        }
        assert_eq!(store.get("v", Sort::Top), None);
    }
}
