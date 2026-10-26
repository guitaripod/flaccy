//! Running other programs: `tailscale`, `systemctl`, `launchctl`, `ffmpeg`, `df`. A test supplies its own [`Runner`].

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(20);
const POLL: Duration = Duration::from_millis(20);

/// What a finished program left behind.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    /// Whether it exited with status 0.
    pub success: bool,
    /// Standard output as text.
    pub stdout: String,
    /// Standard error as text.
    pub stderr: String,
}

/// Why a program did not run to the end.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunError {
    /// No such program on the `PATH`.
    NotFound,
    /// It could not be started, or it ran past the deadline.
    Failed(String),
}

/// Runs a program with arguments and collects its output.
pub trait Runner {
    /// Runs `program` and waits for it.
    fn run(&self, program: &str, args: &[&str]) -> Result<Output, RunError>;
}

/// Runs real programs, killing one that takes longer than twenty seconds.
pub struct SystemRunner;

fn drain(mut pipe: impl Read + Send + 'static) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe.read_to_end(&mut bytes);
        String::from_utf8_lossy(&bytes).into_owned()
    })
}

impl Runner for SystemRunner {
    fn run(&self, program: &str, args: &[&str]) -> Result<Output, RunError> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::NotFound => RunError::NotFound,
                _ => RunError::Failed(format!("could not start {program}: {error}")),
            })?;
        let stdout = child.stdout.take().map(drain);
        let stderr = child.stderr.take().map(drain);
        let started = Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if started.elapsed() < DEADLINE => std::thread::sleep(POLL),
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(RunError::Failed(format!("{program} did not finish within {} seconds", DEADLINE.as_secs())));
                }
                Err(error) => return Err(RunError::Failed(format!("could not wait for {program}: {error}"))),
            }
        };
        let collect = |handle: Option<std::thread::JoinHandle<String>>| handle.and_then(|handle| handle.join().ok()).unwrap_or_default();
        Ok(Output { success: status.success(), stdout: collect(stdout), stderr: collect(stderr) })
    }
}

#[cfg(test)]
pub mod fake {
    use std::cell::RefCell;
    use std::collections::HashMap;

    use super::*;

    /// A runner that answers from a table and remembers every call.
    #[derive(Default)]
    pub struct FakeRunner {
        answers: HashMap<String, Result<Output, RunError>>,
        pub calls: RefCell<Vec<String>>,
    }

    impl FakeRunner {
        /// Answers a call whose `program args...` line starts with `prefix`.
        pub fn on(mut self, prefix: &str, answer: Result<Output, RunError>) -> Self {
            self.answers.insert(prefix.to_owned(), answer);
            self
        }

        pub fn ok(stdout: &str) -> Result<Output, RunError> {
            Ok(Output { success: true, stdout: stdout.to_owned(), stderr: String::new() })
        }

        pub fn fails(stderr: &str) -> Result<Output, RunError> {
            Ok(Output { success: false, stdout: String::new(), stderr: stderr.to_owned() })
        }
    }

    impl Runner for FakeRunner {
        fn run(&self, program: &str, args: &[&str]) -> Result<Output, RunError> {
            let line = std::iter::once(program).chain(args.iter().copied()).collect::<Vec<_>>().join(" ");
            self.calls.borrow_mut().push(line.clone());
            self.answers
                .iter()
                .filter(|(prefix, _)| line.starts_with(prefix.as_str()))
                .max_by_key(|(prefix, _)| prefix.len())
                .map(|(_, answer)| answer.clone())
                .unwrap_or(Err(RunError::NotFound))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_program_is_not_found_and_a_real_one_is_collected() {
        assert_eq!(SystemRunner.run("flaccy-no-such-program", &[]), Err(RunError::NotFound));
        let output = SystemRunner.run("sh", &["-c", "printf out; printf err >&2; exit 3"]).unwrap();
        assert_eq!((output.success, output.stdout.as_str(), output.stderr.as_str()), (false, "out", "err"));
    }
}
