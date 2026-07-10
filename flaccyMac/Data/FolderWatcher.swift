import CoreServices
import Foundation

/// FSEvents watcher over the library root. Events are debounced for a second
/// because imports land files back-to-back, and a generation counter makes a
/// restart drop any change callback that was already in flight for the old
/// root.
final class FolderWatcher {

    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var generation = 0

    var onChange: (() -> Void)?

    func start(watching url: URL) {
        stop()
        generation += 1
        let currentGeneration = generation

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleChange() }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        ) else {
            AppLogger.error("FSEventStreamCreate failed for \(url.path)", category: .content)
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
        AppLogger.info("Watching library folder \(url.path) (generation \(currentGeneration))", category: .content)
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        tearDownStream()
    }

    deinit {
        tearDownStream()
    }

    nonisolated private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleChange() {
        let scheduledGeneration = generation
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.generation == scheduledGeneration else { return }
            AppLogger.info("Library folder changed, triggering rescan", category: .content)
            self.onChange?()
        }
    }
}
