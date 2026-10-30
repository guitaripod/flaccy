//! The `flaccy-server` command line.

use clap::Parser;
use flaccy_server::command::{run, Cli};

/// The system allocators on Linux keep the memory a request burst touched, so an always-on server climbed past 300 MB in half an hour on musl with a live heap under 10 MB; mimalloc hands it back.
#[cfg(target_os = "linux")]
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[tokio::main]
async fn main() {
    let code = run(Cli::parse()).await;
    std::process::exit(code);
}
