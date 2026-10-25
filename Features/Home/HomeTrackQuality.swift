import FlaccyCore

extension Track {

    /// Above CD quality in either depth or rate, the only tracks Home labels.
    var isHighResolutionMaster: Bool {
        (bitDepth ?? 0) > 16 || (sampleRate ?? 0) > 48_000
    }
}

extension Album {

    /// The album's best-resolution track, when any of them is a hi-res master.
    var highResolutionRepresentative: Track? {
        tracks.filter(\.isHighResolutionMaster).max {
            ($0.bitDepth ?? 0, $0.sampleRate ?? 0) < ($1.bitDepth ?? 0, $1.sampleRate ?? 0)
        }
    }
}
