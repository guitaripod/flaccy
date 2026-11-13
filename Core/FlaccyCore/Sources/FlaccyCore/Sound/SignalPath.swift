import Foundation

/// Where the sound goes after Flaccy hands it over, as far as the app can tell from the route.
public enum SignalOutputKind: String, Sendable, CaseIterable {
    case speaker
    case headphones
    case bluetooth
    case airPlay
    case usb
    case display
    case car
    case other
}

/// The one-line account of what happens between the file and the person's ears, chosen from what
/// Flaccy knows for certain: the file's format, whether the equalizer or a song's own volume
/// changes the samples, and the kind of output. It never claims more than the app can see, so a
/// clean path reads "untouched by Flaccy", not "bit-perfect at the DAC".
public enum SignalPathVerdict: String, Sendable, CaseIterable {
    case idle
    case untouched
    case shaped
    case reencodedForBluetooth
    case lossySource

    /// The verdict for a playing song, or `.idle` with nothing playing. Bluetooth leads because it
    /// changes the sound most whatever Flaccy does; then Flaccy's own processing; then a lossy file.
    public static func of(sourceIsLossless: Bool?, processed: Bool, output: SignalOutputKind?) -> SignalPathVerdict {
        guard let sourceIsLossless else { return .idle }
        if output == .bluetooth { return .reencodedForBluetooth }
        if processed { return .shaped }
        return sourceIsLossless ? .untouched : .lossySource
    }

    /// The Listening Guide cards worth reading for an output, by their position in the guide:
    /// Bluetooth gets the three about AAC and AirPods, a wire or a DAC the one about when FLAC is
    /// worth it, and every other output the one about hearing the difference.
    public static func guideCards(for output: SignalOutputKind?) -> [Int] {
        switch output {
        case .bluetooth: [0, 1, 2]
        case .headphones, .usb: [3]
        case .speaker, .airPlay, .display, .car, .other, nil: [5]
        }
    }
}
