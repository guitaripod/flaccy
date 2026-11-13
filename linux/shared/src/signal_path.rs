//! What happens between the file and the listener's ears, the Rust mirror of
//! `Core/FlaccyCore/Sources/FlaccyCore/Sound/SignalPath.swift`: the same
//! verdicts in the same order of precedence, and the same Listening Guide cards
//! for each kind of output, by their position in the Apple guide.

/// Where the sound goes after Flaccy hands it over, as far as the app can tell
/// from the output.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SignalOutputKind {
    Speaker,
    Headphones,
    Bluetooth,
    AirPlay,
    Usb,
    Display,
    Car,
    Other,
}

impl SignalOutputKind {
    pub const ALL: [SignalOutputKind; 8] = [
        SignalOutputKind::Speaker,
        SignalOutputKind::Headphones,
        SignalOutputKind::Bluetooth,
        SignalOutputKind::AirPlay,
        SignalOutputKind::Usb,
        SignalOutputKind::Display,
        SignalOutputKind::Car,
        SignalOutputKind::Other,
    ];
}

/// The one-line account of what happens between the file and the listener's
/// ears, chosen from what Flaccy knows for certain: the file's format, whether
/// the equalizer or a song's own volume changes the samples, and the kind of
/// output. It never claims more than the app can see, so a clean path reads
/// "untouched by Flaccy", not "bit-perfect at the DAC".
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SignalPathVerdict {
    Idle,
    Untouched,
    Shaped,
    ReencodedForBluetooth,
    LossySource,
}

/// How many cards the Apple Listening Guide holds; `guide_cards` points into it.
pub const GUIDE_CARD_COUNT: usize = 6;

impl SignalPathVerdict {
    /// The verdict for a playing song, or `Idle` with nothing playing.
    /// Bluetooth leads because it changes the sound most whatever Flaccy does;
    /// then Flaccy's own processing; then a lossy file.
    pub fn of(
        source_is_lossless: Option<bool>,
        processed: bool,
        output: Option<SignalOutputKind>,
    ) -> SignalPathVerdict {
        let Some(source_is_lossless) = source_is_lossless else {
            return SignalPathVerdict::Idle;
        };
        if output == Some(SignalOutputKind::Bluetooth) {
            return SignalPathVerdict::ReencodedForBluetooth;
        }
        if processed {
            return SignalPathVerdict::Shaped;
        }
        if source_is_lossless {
            SignalPathVerdict::Untouched
        } else {
            SignalPathVerdict::LossySource
        }
    }

    /// The Listening Guide cards worth reading for an output, by their position
    /// in the Apple guide: Bluetooth gets the three about AAC and AirPods, a
    /// wire or a DAC the one about when FLAC is worth it, and every other output
    /// the one about hearing the difference.
    pub fn guide_cards(output: Option<SignalOutputKind>) -> &'static [usize] {
        match output {
            Some(SignalOutputKind::Bluetooth) => &[0, 1, 2],
            Some(SignalOutputKind::Headphones) | Some(SignalOutputKind::Usb) => &[3],
            Some(SignalOutputKind::Speaker)
            | Some(SignalOutputKind::AirPlay)
            | Some(SignalOutputKind::Display)
            | Some(SignalOutputKind::Car)
            | Some(SignalOutputKind::Other)
            | None => &[5],
        }
    }

    /// The sentence the Sound page shows under the signal path, word for word
    /// the Apple clients'.
    pub fn sentence(self) -> &'static str {
        match self {
            SignalPathVerdict::Idle => "Play a song to see how it reaches you.",
            SignalPathVerdict::Untouched => "Flaccy passes every sample through untouched.",
            SignalPathVerdict::Shaped => {
                "Your equalizer or song volume shapes the sound before it plays."
            }
            SignalPathVerdict::ReencodedForBluetooth => {
                "Bluetooth re-encodes the sound to AAC on its way to your headphones."
            }
            SignalPathVerdict::LossySource => "This file is lossy. Flaccy plays it as it is.",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_playing_is_idle() {
        assert_eq!(
            SignalPathVerdict::of(None, true, Some(SignalOutputKind::Bluetooth)),
            SignalPathVerdict::Idle
        );
    }

    #[test]
    fn bluetooth_leads_whatever_flaccy_does() {
        assert_eq!(
            SignalPathVerdict::of(Some(true), false, Some(SignalOutputKind::Bluetooth)),
            SignalPathVerdict::ReencodedForBluetooth
        );
        assert_eq!(
            SignalPathVerdict::of(Some(false), true, Some(SignalOutputKind::Bluetooth)),
            SignalPathVerdict::ReencodedForBluetooth
        );
    }

    #[test]
    fn processing_comes_before_the_file_format() {
        assert_eq!(
            SignalPathVerdict::of(Some(false), true, Some(SignalOutputKind::Headphones)),
            SignalPathVerdict::Shaped
        );
        assert_eq!(
            SignalPathVerdict::of(Some(true), true, Some(SignalOutputKind::Usb)),
            SignalPathVerdict::Shaped
        );
    }

    #[test]
    fn an_unprocessed_file_is_untouched_or_lossy() {
        assert_eq!(
            SignalPathVerdict::of(Some(true), false, Some(SignalOutputKind::Usb)),
            SignalPathVerdict::Untouched
        );
        assert_eq!(
            SignalPathVerdict::of(Some(true), false, None),
            SignalPathVerdict::Untouched
        );
        assert_eq!(
            SignalPathVerdict::of(Some(false), false, Some(SignalOutputKind::Speaker)),
            SignalPathVerdict::LossySource
        );
    }

    #[test]
    fn every_output_points_at_guide_cards_that_exist() {
        for output in SignalOutputKind::ALL {
            let cards = SignalPathVerdict::guide_cards(Some(output));
            assert!(!cards.is_empty());
            assert!(cards.iter().all(|card| *card < GUIDE_CARD_COUNT));
        }
        assert_eq!(
            SignalPathVerdict::guide_cards(Some(SignalOutputKind::Bluetooth)),
            &[0, 1, 2]
        );
    }
}
