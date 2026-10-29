use clap::Parser;
use std::path::PathBuf;

/// Command line of the soak harness.
#[derive(Parser, Debug)]
#[command(name = "flaccy-soak", about = "Soak and chaos test of flaccy-server and the Linux client engine")]
pub struct Cli {
    /// What to run.
    #[command(subcommand)]
    pub command: Command,
}

/// The subcommands.
#[derive(clap::Subcommand, Debug)]
pub enum Command {
    /// Runs the chaos soak and exits 0 only when every invariant holds.
    Run(RunArgs),
}

/// Options of `run`.
#[derive(clap::Args, Debug, Clone)]
pub struct RunArgs {
    /// Minutes of workload and chaos before the settle phase.
    #[arg(long, default_value_t = 30)]
    pub minutes: u64,
    /// Number of clients, each with its own database.
    #[arg(long, default_value_t = 4)]
    pub clients: usize,
    /// The seed every random choice derives from.
    #[arg(long, default_value_t = 1)]
    pub seed: u64,
    /// Use the release build of flaccy-server.
    #[arg(long)]
    pub release: bool,
    /// An explicit flaccy-server binary instead of the one in the cargo target directory.
    #[arg(long)]
    pub server_bin: Option<PathBuf>,
    /// Keep the temp directory (databases, server log) after the run.
    #[arg(long)]
    pub keep: bool,
}
