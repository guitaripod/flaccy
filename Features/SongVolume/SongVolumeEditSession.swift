import FlaccyCore
import FlaccyEngine
import Foundation

/// One song's level while a control moves: the sound follows every step at
/// once and the level is saved when the control rests, so a drag across the
/// slider writes once instead of on every step.
@MainActor
final class SongVolumeEditSession {

    private static let saveDelay: Duration = .milliseconds(350)

    let track: Track
    private(set) var level: Int
    private var pendingSave: Task<Void, Never>?
    private let onSaveFailure: (String) -> Void

    init(track: Track, onSaveFailure: @escaping (String) -> Void) {
        self.track = track
        self.level = SongVolumeStore.shared.level(for: track)
        self.onSaveFailure = onSaveFailure
    }

    /// Moves to `tenths`, heard at once and saved shortly after. Answers false when the level did not change.
    @discardableResult
    func move(to tenths: Int) -> Bool {
        let clamped = SongGain.clamped(tenths)
        guard clamped != level else { return false }
        level = clamped
        SongVolumeStore.shared.preview(clamped, for: track)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
        return true
    }

    /// Saves now, for when the control is let go or the screen closes.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let store = SongVolumeStore.shared
        guard store.level(for: track) != level else { return }
        do {
            level = try store.set(level, for: track)
        } catch {
            level = store.level(for: track)
            onSaveFailure(SongVolumeCopy.saveFailed(title: track.title))
        }
    }
}
