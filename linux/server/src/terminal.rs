//! The terminal the setup and doctor commands talk through, so a test can play the person.

use std::io::{BufRead, IsTerminal, Write};

/// A person at a terminal: lines out, answers in.
pub trait Terminal {
    /// Writes `text` without a line break and shows it at once.
    fn write(&mut self, text: &str);

    /// Whether anyone can answer a question.
    fn is_interactive(&self) -> bool;

    /// Reads one line of the person's answer; `None` at the end of the input.
    fn read_line(&mut self) -> Option<String>;

    /// Writes `text` and a line break.
    fn say(&mut self, text: &str) {
        self.write(text);
        self.write("\n");
    }

    /// Asks `question`, showing `default` in brackets; Return, or a terminal nobody answers, takes the default.
    fn ask(&mut self, question: &str, default: &str) -> String {
        if !self.is_interactive() {
            self.say(&format!("{question} {default}"));
            return default.to_owned();
        }
        self.write(&format!("{question} [{default}] "));
        match self.read_line().map(|line| line.trim().to_owned()) {
            Some(answer) if !answer.is_empty() => answer,
            _ => default.to_owned(),
        }
    }

    /// Asks a yes or no question whose Return answer is `default`.
    fn confirm(&mut self, question: &str, default: bool) -> bool {
        if !self.is_interactive() {
            return default;
        }
        let hint = if default { "[Y/n]" } else { "[y/N]" };
        self.write(&format!("{question} {hint} "));
        match self.read_line().map(|line| line.trim().to_ascii_lowercase()) {
            Some(answer) if answer.starts_with('y') => true,
            Some(answer) if answer.starts_with('n') => false,
            _ => default,
        }
    }
}

/// Standard output and input.
pub struct StdTerminal {
    interactive: bool,
}

impl StdTerminal {
    /// Interactive when standard input is a terminal and `assume_yes` is off.
    pub fn detect(assume_yes: bool) -> Self {
        Self { interactive: !assume_yes && std::io::stdin().is_terminal() }
    }

    /// A terminal that never asks.
    pub fn quiet() -> Self {
        Self { interactive: false }
    }
}

impl Terminal for StdTerminal {
    fn write(&mut self, text: &str) {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(text.as_bytes());
        let _ = out.flush();
    }

    fn is_interactive(&self) -> bool {
        self.interactive
    }

    fn read_line(&mut self) -> Option<String> {
        let mut line = String::new();
        match std::io::stdin().lock().read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(line),
        }
    }
}

/// A scripted terminal for tests: answers come from a list and everything written is kept.
#[cfg(test)]
pub struct ScriptedTerminal {
    answers: std::collections::VecDeque<String>,
    interactive: bool,
    pub output: String,
}

#[cfg(test)]
impl ScriptedTerminal {
    pub fn interactive(answers: &[&str]) -> Self {
        Self { answers: answers.iter().map(|answer| (*answer).to_owned()).collect(), interactive: true, output: String::new() }
    }

    pub fn silent() -> Self {
        Self { answers: Default::default(), interactive: false, output: String::new() }
    }
}

#[cfg(test)]
impl Terminal for ScriptedTerminal {
    fn write(&mut self, text: &str) {
        self.output.push_str(text);
    }

    fn is_interactive(&self) -> bool {
        self.interactive
    }

    fn read_line(&mut self) -> Option<String> {
        self.answers.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn return_takes_the_default_and_an_answer_replaces_it() {
        let mut terminal = ScriptedTerminal::interactive(&["", "  /srv/music  "]);
        assert_eq!(terminal.ask("Where?", "~/Music"), "~/Music");
        assert_eq!(terminal.ask("Where?", "~/Music"), "/srv/music");
        assert_eq!(terminal.output, "Where? [~/Music] Where? [~/Music] ");
    }

    #[test]
    fn a_terminal_nobody_answers_echoes_the_default() {
        let mut terminal = ScriptedTerminal::silent();
        assert_eq!(terminal.ask("Your name on this server?", "marcus"), "marcus");
        assert_eq!(terminal.output, "Your name on this server? marcus\n");
        assert!(terminal.confirm("Keep going?", true));
        assert!(!terminal.confirm("Keep going?", false));
    }

    #[test]
    fn confirm_reads_yes_and_no() {
        let mut terminal = ScriptedTerminal::interactive(&["n", "Yes", "", "what"]);
        assert!(!terminal.confirm("Q?", true));
        assert!(terminal.confirm("Q?", false));
        assert!(terminal.confirm("Q?", true));
        assert!(!terminal.confirm("Q?", false));
    }
}
