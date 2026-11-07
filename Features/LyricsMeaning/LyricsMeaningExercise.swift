import MidgarCore
#if DEBUG
import FlaccyCore
import Foundation

/// Asks the real Wikipedia and flaccy-api the questions the Meaning sheet
/// asks, in the app's language (launch with `-AppleLanguages "(de)"` to try
/// another), and logs PASS/FAIL per expectation: a well-known song's article
/// is found, an invented one is not, and both a line and the whole song get a
/// reading that is stored and answered from the store the second time.
/// Launch with `--exercise-lyric-meaning`.
@MainActor
enum LyricsMeaningExercise {

    static let launchArgument = "--exercise-lyric-meaning"

    static let fixture = """
        [00:01.00]Load up on guns, bring your friends
        [00:04.00]It's fun to lose and to pretend
        [00:08.00]She's over-bored and self-assured
        [00:12.00]Oh no, I know a dirty word
        [00:20.00]Here we are now, entertain us
        [00:24.00]I feel stupid and contagious
        """

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(2))
        let service = LyricsMeaningService.shared
        MidgarLog.info("LyricsMeaningExercise in \(LyricsMeaningService.localization) (\(LyricsMeaningService.languageName))", category: .content)
        let song = MeaningSong(title: "Smells Like Teen Spirit (Remastered 2021)", artist: "Nirvana", album: "Nevermind")
        let found = await service.story(for: song)
        if case .found(let story) = found {
            report("the song's article is found: \(story.article) [\(story.language)], \(story.sections.count) sections, \(story.lead.count) characters of introduction", true)
        } else {
            report("the song's article is found (\(found))", false)
        }
        let invented = await service.story(for: MeaningSong(title: "Parallax Hours Overture", artist: "Meridian Wolde", album: ""))
        report("an invented song has no article (\(invented))", invented == .missing)

        let document = LyricsParser.parseLRC(fixture)
        let story: SongStory? = if case .found(let story) = found { story } else { nil }
        let focus = MeaningPrompt.focus(document, index: document.lines.firstIndex { $0.text.hasPrefix("Here we are") } ?? 0)
        for (name, asked) in [("line", focus), ("song", nil)] as [(String, MeaningFocus?)] {
            let started = Date()
            let first = await service.reading(for: song, document: document, focus: asked, story: story)
            let seconds = Date().timeIntervalSince(started)
            guard case .answered(let text) = first else {
                report("the \(name) is explained (\(first))", false)
                continue
            }
            report("the \(name) is explained in \(String(format: "%.1f", seconds)) s: \(text.prefix(160))…", true)
            let again = Date()
            let second = await service.reading(for: song, document: document, focus: asked, story: story)
            report("the \(name)'s reading comes from the store the second time", second == first && Date().timeIntervalSince(again) < 0.5)
        }
        MidgarLog.info("LyricsMeaningExercise done", category: .content)
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("LyricsMeaningExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .content)
    }
}
#endif
