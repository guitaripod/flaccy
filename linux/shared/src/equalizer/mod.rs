//! The equalizer's shared maths and state, mirrored from
//! `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/`.
//!
//! Every module here follows a Swift file operation for operation and carries
//! the same golden numbers as its Swift test, so the curve a person draws, the
//! preamp the stage applies, the text a profile exports and the samples the
//! kernel produces are the same on the Apple clients and on Linux.

pub mod biquad;
pub mod graphic;
pub mod headroom;
pub mod interaction;
pub mod kernel;
pub mod plot;
pub mod plot_model;
pub mod presets;
pub mod profile;
pub mod profile_text;
pub mod spectrum;
pub mod state;

#[cfg(test)]
pub(crate) mod test_support {
    /// A tiny deterministic generator so the property-style tests are repeatable
    /// without a random-number dependency.
    pub(crate) struct Lcg(u64);

    impl Lcg {
        pub(crate) fn new(seed: u64) -> Self {
            Self(seed)
        }

        /// A value in `[0, 1)`.
        pub(crate) fn unit(&mut self) -> f64 {
            self.0 = self
                .0
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }

        pub(crate) fn range(&mut self, low: f64, high: f64) -> f64 {
            low + (high - low) * self.unit()
        }

        pub(crate) fn below(&mut self, count: usize) -> usize {
            ((self.unit() * count as f64) as usize).min(count - 1)
        }
    }
}
