//! The `flaccy-server` command line.

use clap::Parser;
use flaccy_server::command::{run, Cli};

#[tokio::main]
async fn main() {
    let code = run(Cli::parse()).await;
    std::process::exit(code);
}
