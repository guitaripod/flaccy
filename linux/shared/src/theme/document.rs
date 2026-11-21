//! Reads the TOML a `theme.toml` is written in. Mirrored character for
//! character by FlaccyCore's `ThemeDocument`, so a theme means the same thing
//! on every client and a mistake in one is reported in the same words.
//!
//! It reads what a theme can need: strings of all four kinds, numbers,
//! booleans, arrays, inline tables, `[tables]`, `[[arrays of tables]]`, dotted
//! keys and comments. A value it has no use for (a date) is kept as written
//! rather than refused.

/// One value of a document.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Text(String),
    Integer(i64),
    Float(f64),
    Flag(bool),
    List(Vec<Value>),
    Table(Table),
    Other(String),
}

/// A table with its keys in the order they were written.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table {
    entries: Vec<(String, Value)>,
}

impl Table {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|(name, _)| name.as_str())
    }

    fn position(&self, key: &str) -> Option<usize> {
        self.entries.iter().position(|(name, _)| name == key)
    }

    fn insert(&mut self, key: &str, value: Value) {
        self.entries.push((key.to_string(), value));
    }
}

/// Where a `[header]` said the following keys belong, and how it got there.
#[derive(Clone, Copy, PartialEq)]
enum Step {
    Key,
    LastOfList,
}

struct Reader {
    chars: Vec<char>,
    at: usize,
    line: usize,
}

type Fallible<T> = Result<T, String>;

impl Reader {
    fn fail<T>(&self, what: &str) -> Fallible<T> {
        Err(format!("line {}: {what}", self.line))
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    fn peek_at(&self, ahead: usize) -> Option<char> {
        self.chars.get(self.at + ahead).copied()
    }

    fn starts_with(&self, text: &str) -> bool {
        text.chars().enumerate().all(|(index, c)| self.peek_at(index) == Some(c))
    }

    fn advance(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.at += 1;
        if c == '\n' {
            self.line += 1;
        }
        Some(c)
    }

    /// Steps over `wanted` if it is next, and says whether it was. Looking
    /// before stepping keeps a mistake on the line it was made on.
    fn take(&mut self, wanted: char) -> bool {
        if self.peek() == Some(wanted) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn skip_spaces(&mut self) {
        while matches!(self.peek(), Some(' ') | Some('\t')) {
            self.at += 1;
        }
    }

    fn skip_comment(&mut self) {
        if self.peek() == Some('#') {
            while !matches!(self.peek(), None | Some('\n')) {
                self.at += 1;
            }
        }
    }

    /// Skips spaces, comments and line ends, as between the items of an array.
    fn skip_blank(&mut self) {
        loop {
            self.skip_spaces();
            self.skip_comment();
            match self.peek() {
                Some('\n') | Some('\r') => {
                    self.advance();
                }
                _ => return,
            }
        }
    }

    /// Ends a line: nothing but spaces and a comment may follow a value.
    fn end_line(&mut self) -> Fallible<()> {
        self.skip_spaces();
        self.skip_comment();
        match self.peek() {
            None => Ok(()),
            Some('\r') if self.peek_at(1) == Some('\n') => {
                self.advance();
                self.advance();
                Ok(())
            }
            Some('\n') => {
                self.advance();
                Ok(())
            }
            Some(_) => self.fail("there is something after the value that does not belong"),
        }
    }

    fn escape(&mut self) -> Fallible<char> {
        let Some(c) = self.advance() else {
            return self.fail("a string ends in the middle of an escape");
        };
        match c {
            'b' => Ok('\u{8}'),
            't' => Ok('\t'),
            'n' => Ok('\n'),
            'f' => Ok('\u{c}'),
            'r' => Ok('\r'),
            '"' => Ok('"'),
            '\\' => Ok('\\'),
            'u' | 'U' => {
                let digits = if c == 'u' { 4 } else { 8 };
                let mut code: u32 = 0;
                for _ in 0..digits {
                    let Some(digit) = self.advance().and_then(|c| c.to_digit(16)) else {
                        return self.fail("a \\u escape needs hexadecimal digits");
                    };
                    code = code * 16 + digit;
                }
                match char::from_u32(code) {
                    Some(c) => Ok(c),
                    None => self.fail("a \\u escape names no character"),
                }
            }
            _ => self.fail("a backslash is followed by something that is not an escape"),
        }
    }

    fn basic_string(&mut self) -> Fallible<String> {
        self.advance();
        let mut text = String::new();
        loop {
            match self.advance() {
                None | Some('\n') => return self.fail("a string is never closed"),
                Some('"') => return Ok(text),
                Some('\\') => text.push(self.escape()?),
                Some(c) => text.push(c),
            }
        }
    }

    fn literal_string(&mut self) -> Fallible<String> {
        self.advance();
        let mut text = String::new();
        loop {
            match self.advance() {
                None | Some('\n') => return self.fail("a string is never closed"),
                Some('\'') => return Ok(text),
                Some(c) => text.push(c),
            }
        }
    }

    /// A string in triple quotes. A line end right after the opening quotes is
    /// dropped, and in a basic string a backslash at a line's end joins it to
    /// the next line's first word.
    fn long_string(&mut self, quote: char) -> Fallible<String> {
        for _ in 0..3 {
            self.advance();
        }
        if self.peek() == Some('\r') && self.peek_at(1) == Some('\n') {
            self.advance();
        }
        if self.peek() == Some('\n') {
            self.advance();
        }
        let closing: String = std::iter::repeat(quote).take(3).collect();
        let mut text = String::new();
        loop {
            if self.starts_with(&closing) {
                for _ in 0..3 {
                    self.advance();
                }
                return Ok(text);
            }
            match self.advance() {
                None => return self.fail("a string is never closed"),
                Some('\\') if quote == '"' => {
                    if matches!(self.peek(), Some('\n') | Some('\r') | Some(' ') | Some('\t')) {
                        let mark = self.at;
                        self.skip_spaces();
                        if matches!(self.peek(), Some('\n') | Some('\r')) {
                            while matches!(self.peek(), Some('\n') | Some('\r') | Some(' ') | Some('\t')) {
                                self.advance();
                            }
                        } else {
                            self.at = mark;
                            return self.fail("a backslash is followed by something that is not an escape");
                        }
                    } else {
                        text.push(self.escape()?);
                    }
                }
                Some(c) => text.push(c),
            }
        }
    }

    fn key_part(&mut self) -> Fallible<String> {
        match self.peek() {
            Some('"') => self.basic_string(),
            Some('\'') => self.literal_string(),
            _ => {
                let mut name = String::new();
                while let Some(c) = self.peek() {
                    if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                        name.push(c);
                        self.at += 1;
                    } else {
                        break;
                    }
                }
                if name.is_empty() {
                    return self.fail("a key is missing");
                }
                Ok(name)
            }
        }
    }

    /// One or more key parts joined by dots.
    fn key_path(&mut self) -> Fallible<Vec<String>> {
        let mut path = vec![self.key_part()?];
        loop {
            self.skip_spaces();
            if self.peek() != Some('.') {
                return Ok(path);
            }
            self.advance();
            self.skip_spaces();
            path.push(self.key_part()?);
        }
    }

    fn list(&mut self) -> Fallible<Value> {
        self.advance();
        let mut items = Vec::new();
        loop {
            self.skip_blank();
            if self.peek() == Some(']') {
                self.advance();
                return Ok(Value::List(items));
            }
            items.push(self.value()?);
            self.skip_blank();
            match self.peek() {
                Some(',') => {
                    self.advance();
                }
                Some(']') => {}
                _ => return self.fail("an array's items must be separated by commas"),
            }
        }
    }

    fn inline_table(&mut self) -> Fallible<Value> {
        self.advance();
        let mut table = Table::default();
        self.skip_spaces();
        if self.peek() == Some('}') {
            self.advance();
            return Ok(Value::Table(table));
        }
        loop {
            self.skip_spaces();
            let path = self.key_path()?;
            self.skip_spaces();
            if !self.take('=') {
                return self.fail("a key must be followed by =");
            }
            self.skip_spaces();
            let value = self.value()?;
            self.assign(&mut table, &path, value)?;
            self.skip_spaces();
            if self.take('}') {
                return Ok(Value::Table(table));
            }
            if !self.take(',') {
                return self.fail("an inline table's entries must be separated by commas");
            }
        }
    }

    /// A number, a boolean, or anything else written without quotes.
    fn bare(&mut self) -> Fallible<Value> {
        let mut word = String::new();
        while let Some(c) = self.peek() {
            if matches!(c, ',' | ']' | '}' | '#' | '\n' | '\r' | ' ' | '\t') {
                break;
            }
            word.push(c);
            self.at += 1;
        }
        if word.is_empty() {
            return self.fail("a value is missing");
        }
        Ok(match word.as_str() {
            "true" => Value::Flag(true),
            "false" => Value::Flag(false),
            _ => number(&word).unwrap_or(Value::Other(word)),
        })
    }

    fn value(&mut self) -> Fallible<Value> {
        match self.peek() {
            None | Some('\n') | Some('\r') => self.fail("a value is missing"),
            Some('"') if self.starts_with("\"\"\"") => self.long_string('"').map(Value::Text),
            Some('\'') if self.starts_with("'''") => self.long_string('\'').map(Value::Text),
            Some('"') => self.basic_string().map(Value::Text),
            Some('\'') => self.literal_string().map(Value::Text),
            Some('[') => self.list(),
            Some('{') => self.inline_table(),
            Some(_) => self.bare(),
        }
    }

    /// Sets `path` inside `table`, making the tables a dotted key passes
    /// through. A key may be set once.
    fn assign(&self, table: &mut Table, path: &[String], value: Value) -> Fallible<()> {
        let (last, parents) = path.split_last().expect("a key path has at least one part");
        let mut current = table;
        for part in parents {
            let at = match current.position(part) {
                Some(at) => at,
                None => {
                    current.insert(part, Value::Table(Table::default()));
                    current.entries.len() - 1
                }
            };
            match &mut current.entries[at].1 {
                Value::Table(inner) => current = inner,
                _ => return self.fail(&format!("{part} is already a value, so it cannot hold keys")),
            }
        }
        if current.position(last).is_some() {
            return self.fail(&format!("{last} is set twice"));
        }
        current.insert(last, value);
        Ok(())
    }
}

/// An integer or a float as TOML writes them, or nothing if `word` is neither.
fn number(word: &str) -> Option<Value> {
    let plain: String = word.chars().filter(|c| *c != '_').collect();
    let unsigned = plain.strip_prefix(['+', '-']).unwrap_or(&plain);
    let negative = plain.starts_with('-');
    for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
        if let Some(digits) = unsigned.strip_prefix(prefix) {
            return i64::from_str_radix(digits, radix)
                .ok()
                .map(|value| Value::Integer(if negative { -value } else { value }));
        }
    }
    match unsigned {
        "inf" => return Some(Value::Float(if negative { f64::NEG_INFINITY } else { f64::INFINITY })),
        "nan" => return Some(Value::Float(f64::NAN)),
        _ => {}
    }
    if unsigned.is_empty() || !unsigned.starts_with(|c: char| c.is_ascii_digit()) {
        return None;
    }
    if unsigned.chars().all(|c| c.is_ascii_digit()) {
        return plain.parse::<i64>().ok().map(Value::Integer);
    }
    let numeric = unsigned
        .chars()
        .all(|c| c.is_ascii_digit() || matches!(c, '.' | 'e' | 'E' | '+' | '-'));
    if !numeric || unsigned.ends_with('.') {
        return None;
    }
    plain.parse::<f64>().ok().map(Value::Float)
}

/// Walks from the root to the table a header names, making tables on the way
/// and stepping into the last entry of any array of tables it crosses.
fn table_at<'a>(root: &'a mut Table, path: &[(String, Step)], line: usize) -> Fallible<&'a mut Table> {
    let mut current = root;
    for (part, step) in path {
        let at = match current.position(part) {
            Some(at) => at,
            None => {
                let fresh = match step {
                    Step::Key => Value::Table(Table::default()),
                    Step::LastOfList => Value::List(vec![Value::Table(Table::default())]),
                };
                current.insert(part, fresh);
                current.entries.len() - 1
            }
        };
        current = match &mut current.entries[at].1 {
            Value::Table(inner) => inner,
            Value::List(items) => match items.last_mut() {
                Some(Value::Table(inner)) => inner,
                _ => return Err(format!("line {line}: {part} is not a list of tables")),
            },
            _ => return Err(format!("line {line}: {part} is already a value, so it cannot be a table")),
        };
    }
    Ok(current)
}

/// Reads a whole document. The error names the line and what is wrong on it.
pub fn read(document: &str) -> Result<Table, String> {
    let mut reader = Reader {
        chars: document.chars().collect(),
        at: 0,
        line: 1,
    };
    let mut root = Table::default();
    let mut here: Vec<(String, Step)> = Vec::new();
    loop {
        reader.skip_blank();
        let Some(c) = reader.peek() else {
            return Ok(root);
        };
        if c == '[' {
            let listed = reader.peek_at(1) == Some('[');
            reader.advance();
            if listed {
                reader.advance();
            }
            reader.skip_spaces();
            let path = reader.key_path()?;
            reader.skip_spaces();
            let closed = reader.take(']') && (!listed || reader.take(']'));
            if !closed {
                return reader.fail("a table's name is never closed");
            }
            let line = reader.line;
            let (last, parents) = path.split_last().expect("a key path has at least one part");
            let mut route: Vec<(String, Step)> = parents
                .iter()
                .map(|part| (part.clone(), Step::Key))
                .collect();
            let parent = table_at(&mut root, &route, line)?;
            if listed {
                match parent.position(last) {
                    None => parent.insert(last, Value::List(vec![Value::Table(Table::default())])),
                    Some(at) => match &mut parent.entries[at].1 {
                        Value::List(items) => items.push(Value::Table(Table::default())),
                        _ => return Err(format!("line {line}: {last} is already a value, so it cannot be a list of tables")),
                    },
                }
                route.push((last.clone(), Step::LastOfList));
            } else {
                match parent.position(last) {
                    None => parent.insert(last, Value::Table(Table::default())),
                    Some(at) => match &parent.entries[at].1 {
                        Value::Table(_) => {}
                        Value::List(_) => {}
                        _ => return Err(format!("line {line}: {last} is already a value, so it cannot be a table")),
                    },
                }
                route.push((last.clone(), Step::Key));
            }
            here = route;
            reader.end_line()?;
            continue;
        }
        let path = reader.key_path()?;
        reader.skip_spaces();
        if !reader.take('=') {
            return reader.fail("a key must be followed by =");
        }
        reader.skip_spaces();
        let value = reader.value()?;
        let line = reader.line;
        let table = table_at(&mut root, &here, line)?;
        reader.assign(table, &path, value)?;
        reader.end_line()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(table: &Table, key: &str) -> String {
        match table.get(key) {
            Some(Value::Text(text)) => text.clone(),
            other => panic!("{key} is {other:?}"),
        }
    }

    fn table<'a>(table: &'a Table, key: &str) -> &'a Table {
        match table.get(key) {
            Some(Value::Table(inner)) => inner,
            other => panic!("{key} is {other:?}"),
        }
    }

    fn tables<'a>(table: &'a Table, key: &str) -> Vec<&'a Table> {
        match table.get(key) {
            Some(Value::List(items)) => items
                .iter()
                .map(|item| match item {
                    Value::Table(inner) => inner,
                    other => panic!("{key} holds {other:?}"),
                })
                .collect(),
            other => panic!("{key} is {other:?}"),
        }
    }

    #[test]
    fn reads_keys_tables_and_lists_of_tables_in_order() {
        let root = read(
            "# a theme\nname = \"Phosphor\"  # trailing\nformat = 1\nratio = 1.25\nloud = true\n\n\
             [fonts]\ninterface = 'JetBrains Mono, monospace'\n\n\
             [[scheme]]\nname = \"Green\"\n[scheme.dark]\nwindow = \"#040705\"\n\n\
             [[scheme]]\nname = \"Amber\"\n[scheme.dark]\nwindow = \"#070502\"\n",
        )
        .unwrap();
        assert_eq!(root.keys().collect::<Vec<_>>(), ["name", "format", "ratio", "loud", "fonts", "scheme"]);
        assert_eq!(text(&root, "name"), "Phosphor");
        assert_eq!(root.get("format"), Some(&Value::Integer(1)));
        assert_eq!(root.get("ratio"), Some(&Value::Float(1.25)));
        assert_eq!(root.get("loud"), Some(&Value::Flag(true)));
        assert_eq!(text(table(&root, "fonts"), "interface"), "JetBrains Mono, monospace");
        let schemes = tables(&root, "scheme");
        assert_eq!(schemes.len(), 2);
        assert_eq!(text(schemes[0], "name"), "Green");
        assert_eq!(text(table(schemes[0], "dark"), "window"), "#040705");
        assert_eq!(text(table(schemes[1], "dark"), "window"), "#070502");
    }

    #[test]
    fn reads_every_kind_of_string() {
        let root = read(
            "a = \"tab\\there \\\"quoted\\\" \\u00e9 \\\\\"\nb = 'C:\\raw\\path'\n\
             c = \"\"\"\nfirst\nsecond \\\n   joined\"\"\"\nd = '''\nkept \\ as is\n'''\n",
        )
        .unwrap();
        assert_eq!(text(&root, "a"), "tab\there \"quoted\" é \\");
        assert_eq!(text(&root, "b"), "C:\\raw\\path");
        assert_eq!(text(&root, "c"), "first\nsecond joined");
        assert_eq!(text(&root, "d"), "kept \\ as is\n");
    }

    #[test]
    fn reads_numbers_lists_inline_tables_and_dotted_keys() {
        let root = read(
            "big = 1_000\nneg = -7\nhex = 0xff\nexp = 5e-1\nwhen = 2026-11-21\n\
             sizes = [96, 140,\n  320, # the largest\n]\npoint = { x = 1, y = 2.5 }\n\
             fonts.interface = \"Inter\"\nfonts.headings = \"Charter\"\n\"quoted key\" = false\n",
        )
        .unwrap();
        assert_eq!(root.get("big"), Some(&Value::Integer(1000)));
        assert_eq!(root.get("neg"), Some(&Value::Integer(-7)));
        assert_eq!(root.get("hex"), Some(&Value::Integer(255)));
        assert_eq!(root.get("exp"), Some(&Value::Float(0.5)));
        assert_eq!(root.get("when"), Some(&Value::Other("2026-11-21".to_string())));
        assert_eq!(
            root.get("sizes"),
            Some(&Value::List(vec![Value::Integer(96), Value::Integer(140), Value::Integer(320)]))
        );
        assert_eq!(table(&root, "point").get("y"), Some(&Value::Float(2.5)));
        assert_eq!(text(table(&root, "fonts"), "headings"), "Charter");
        assert_eq!(root.get("quoted key"), Some(&Value::Flag(false)));
    }

    #[test]
    fn a_table_can_come_back_and_a_windows_file_reads_the_same() {
        let root = read("[layout]\r\nalbums = \"list\"\r\n[shape]\r\ncovers = \"square\"\r\n[layout.extra]\r\nglow = false\r\n").unwrap();
        assert_eq!(text(table(&root, "layout"), "albums"), "list");
        assert_eq!(table(table(&root, "layout"), "extra").get("glow"), Some(&Value::Flag(false)));
    }

    #[test]
    fn names_the_line_and_the_mistake() {
        for (document, error) in [
            ("name = ", "line 1: a value is missing"),
            ("name = \"open", "line 1: a string is never closed"),
            ("a = 1\nname \"x\"", "line 2: a key must be followed by ="),
            ("a = 1\na = 2", "line 2: a is set twice"),
            ("a = 1 2", "line 1: there is something after the value that does not belong"),
            ("[fonts\ninterface = 1", "line 1: a table's name is never closed"),
            ("a = [1 2]", "line 1: an array's items must be separated by commas"),
            ("a = \"bad \\q\"", "line 1: a backslash is followed by something that is not an escape"),
            ("a = 1\n[a]\nb = 2", "line 2: a is already a value, so it cannot be a table"),
            ("= 1", "line 1: a key is missing"),
        ] {
            assert_eq!(read(document), Err(error.to_string()), "{document:?}");
        }
    }
}
