use rand::rngs::StdRng;
use rand::SeedableRng;

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

/// An independent random stream for one actor, derived from the run seed and the actor's name so every actor replays the same choices.
pub fn stream(seed: u64, label: &str) -> StdRng {
    let mut hash = FNV_OFFSET;
    for byte in label.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    StdRng::seed_from_u64(seed ^ hash)
}
