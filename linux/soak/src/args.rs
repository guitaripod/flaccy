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
    /// Multiplies how often clients restore a stale backup and how often they save one; 0 turns restores off.
    #[arg(long, default_value_t = 1.0)]
    pub lifecycle_boost: f64,
    /// The fraction of the run after which the server is no longer killed or stopped, so its last process lives long enough to show a memory plateau.
    #[arg(long, default_value_t = 0.8)]
    pub kills_until: f64,
    /// Seconds to leave the server idle after the final checks while its memory is measured.
    #[arg(long, default_value_t = 0)]
    pub quiet_secs: u64,
    /// Keep the temp directory (databases, server log) after the run.
    #[arg(long)]
    pub keep: bool,
}
