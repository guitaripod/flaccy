//! Soak and chaos harness for Flaccy Server: the real server binary and the Linux client engine, driven through a faulty proxy.

mod args;
mod canon;
mod client;
mod controller;
mod faults;
mod fixtures;
mod invariants;
mod metrics;
mod monitor;
mod oracle;
mod proxy;
mod report;
mod rngs;
mod run;
mod server;
mod shared;
mod signals;
mod sync_util;
mod tally;
mod tracker;
mod view;
mod workload;

use args::{Cli, Command};
use clap::Parser;
use std::process::ExitCode;

fn main() -> ExitCode {
    signals::unblock_all();
    match Cli::parse().command {
        Command::Run(arguments) => match run::execute(&arguments) {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::from(1),
            Err(message) => {
                report::progress(&format!("harness error: {message}"));
                ExitCode::from(2)
            }
        },
    }
}
