//! A tiny xorshift generator: the simulation's only source of chance.

/// Seeded xorshift64*; the same seed always gives the same run.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    /// Starts a stream from a seed; the seed is mixed so neighbouring seeds differ.
    pub fn new(seed: u64) -> Self {
        let mut mixed = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        Rng((mixed ^ (mixed >> 31)).max(1))
    }

    /// The next 64 random bits.
    pub fn next_u64(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// A number in `0..bound` (zero when the bound is zero).
    pub fn below(&mut self, bound: usize) -> usize {
        if bound == 0 {
            0
        } else {
            (self.next_u64() % bound as u64) as usize
        }
    }

    /// A number in `low..=high`.
    pub fn between(&mut self, low: i64, high: i64) -> i64 {
        low + self.below((high - low + 1) as usize) as i64
    }

    /// True with the given chance in percent.
    pub fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    /// One element of a non-empty slice.
    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }

    /// A fresh 32 hex character id.
    pub fn id(&mut self) -> String {
        format!("{:016x}{:016x}", self.next_u64(), self.next_u64())
    }
}
