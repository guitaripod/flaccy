import FlaccyCore
import Foundation

/// The equalizer's saved state as one small JSON file beside the library
/// database. A file that cannot be read or is from a newer schema is ignored
/// rather than trusted, and the equalizer starts off and flat.
nonisolated final class EqualizerStore: @unchecked Sendable {

    private let url: URL
    private let queue = DispatchQueue(label: "com.midgarcorp.flaccy.equalizer-store", qos: .utility)
    private var pending: DispatchWorkItem?
    private static let writeDelay: TimeInterval = 0.5

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true))
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("equalizer.json")
    }

    func load() -> EqualizerState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(EqualizerState.self, from: data),
              state.schemaVersion <= EqualizerState.schemaVersion
        else { return EqualizerState() }
        return state
    }

    /// Writes the state half a second after the last change, so a drag that
    /// edits the curve fifty times a second saves once.
    func save(_ state: EqualizerState) {
        let url = url
        pending?.cancel()
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }
}
