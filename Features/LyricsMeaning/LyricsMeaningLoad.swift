import FlaccyCore
import Foundation

/// One Meaning sheet's questions in flight: the story, then the reading, each
/// reported as it lands. The iPhone sheet and the Mac popover both draw from
/// it, so they ask in the same order and show the same states.
@MainActor
final class LyricsMeaningLoad {

    enum StoryState: Equatable {
        case loading
        case found(SongStory)
        case missing
        case failed(WikipediaClient.Failure)
    }

    enum ReadingState: Equatable {
        case lookingUp
        case reading
        case answered(String)
        case failed(MeaningFailure)
    }

    let song: MeaningSong
    let focus: MeaningFocus?
    private let document: LyricsDocument
    private(set) var story: StoryState = .loading
    private(set) var reading: ReadingState = .lookingUp
    var onChange: (() -> Void)?
    private var task: Task<Void, Never>?

    /// The sheet for line `line` of the document, or for the whole song with
    /// `nil`; `nil` when that line has nothing sung in it or there are no
    /// lyrics to read.
    init?(song: MeaningSong, document: LyricsDocument, line: Int?) {
        guard !MeaningPrompt.sungLines(document).isEmpty else { return nil }
        if let line {
            guard let focus = MeaningPrompt.focus(document, index: line) else { return nil }
            self.focus = focus
        } else {
            focus = nil
        }
        self.song = song
        self.document = document
    }

    isolated deinit {
        task?.cancel()
    }

    /// Asks again from the start: a story found before comes from the cache.
    func start() {
        task?.cancel()
        story = .loading
        reading = .lookingUp
        onChange?()
        let song = song
        let focus = focus
        let document = document
        task = Task { [weak self] in
            let story = await LyricsMeaningService.shared.story(for: song)
            guard !Task.isCancelled, let self else { return }
            self.story = Self.state(of: story)
            self.reading = .reading
            self.onChange?()
            let found: SongStory? = if case .found(let story) = story { story } else { nil }
            let reading = await LyricsMeaningService.shared.reading(
                for: song, document: document, focus: focus, story: found)
            guard !Task.isCancelled else { return }
            switch reading {
            case .answered(let text): self.reading = .answered(text)
            case .failed(let failure): self.reading = .failed(failure)
            }
            self.onChange?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func state(of outcome: MeaningStoryOutcome) -> StoryState {
        switch outcome {
        case .found(let story): return .found(story)
        case .missing: return .missing
        case .failed(let failure): return .failed(failure)
        }
    }
}
