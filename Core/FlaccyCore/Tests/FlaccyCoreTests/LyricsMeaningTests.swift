import XCTest
@testable import FlaccyCore

/// The same cases as `linux/shared/src/meaning`, so both clients find the same
/// article, keep the same sections and ask the same words.
final class LyricsMeaningTests: XCTestCase {

    private func candidate(_ title: String, _ description: String) -> MeaningArticleCandidate {
        MeaningArticleCandidate(title: title, description: description)
    }

    func testWholeParagraphsJoinWithABlankLine() {
        XCTAssertEqual(MeaningText.clip(["One.", "  Two.  ", ""], limit: 100), "One.\n\nTwo.")
    }

    func testAParagraphThatDoesNotFitAfterAnotherIsLeftOutWhenLittleRoomIsLeft() {
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(MeaningText.clip(["Short first.", long], limit: 60), "Short first.")
    }

    func testAnOverlongParagraphEndsAtItsLastSentenceThatFits() {
        let text = "The first sentence is here. The second one runs on and on past the limit."
        XCTAssertEqual(MeaningText.clip([text], limit: 40), "The first sentence is here.")
    }

    func testADecimalPointIsNotASentenceEnd() {
        let text = "It reached 3.5 million listeners in a week and kept going for months"
        XCTAssertEqual(MeaningText.clip([text], limit: 20), "It reached 3.5\u{2026}")
    }

    func testWithoutAnEarlySentenceEndTheCutFallsOnAWord() {
        let text = "Hi. this sentence keeps going without any stop for a long while"
        XCTAssertEqual(MeaningText.clip([text], limit: 30), "Hi. this sentence keeps going\u{2026}")
    }

    func testTextWithoutSpacesIsCutWhereItFits() {
        XCTAssertEqual(MeaningText.clip(["这是一首关于青春的歌曲没有句号"], limit: 6), "这是一首关\u{2026}")
        XCTAssertEqual(MeaningText.clip(["这是一首歌。关于青春的故事"], limit: 8), "这是一首歌。")
    }

    func testLengthCountsUTF16UnitsLikeTheWorker() {
        XCTAssertEqual(MeaningText.utf16Length("a\u{1F3B5}é"), 4)
        XCTAssertEqual(MeaningText.clip(["\u{1F3B5}\u{1F3B5}\u{1F3B5}"], limit: 5), "\u{1F3B5}\u{1F3B5}\u{2026}")
    }

    func testNoRoomMeansNothing() {
        XCTAssertEqual(MeaningText.clip(["Anything at all"], limit: 0), "")
    }

    func testARecordingIsSearchedForAsTheSongItIsAVersionOf() {
        XCTAssertEqual(MeaningWikipedia.songTitle("Smells Like Teen Spirit (Remastered 2021)"), "Smells Like Teen Spirit")
        XCTAssertEqual(MeaningWikipedia.songTitle("When I'm Gone (Album Version (Explicit))"), "When I'm Gone")
        XCTAssertEqual(MeaningWikipedia.songTitle("09 - Flashing Lights feat. Dwele"), "Flashing Lights")
        XCTAssertEqual(MeaningWikipedia.songTitle("9. Breed"), "Breed")
        XCTAssertEqual(MeaningWikipedia.songTitle("A Small Victory (Live In Munich 1992)"), "A Small Victory")
        XCTAssertEqual(MeaningWikipedia.songTitle("Play - INFANCTUS Remix"), "Play")
        XCTAssertEqual(MeaningWikipedia.songTitle("99 Problems"), "99 Problems")
        XCTAssertEqual(MeaningWikipedia.songTitle("1-800-273-8255"), "1-800-273-8255")
        XCTAssertEqual(MeaningWikipedia.songTitle("(Untitled)"), "(Untitled)")
    }

    func testTheSearchNamesTheSongItsLeadArtistAndTheWordSong() {
        XCTAssertEqual(
            MeaningWikipedia.searchTerms(
                title: "Mo Money Mo Problems (Feat. Mase & Puff Daddy)", artist: "The Notorious B.I.G. feat. Mase"),
            "Mo Money Mo Problems The Notorious B.I.G. song"
        )
    }

    func testTheSongsOwnArticleIsPickedOverTheAlbumAndAParody() {
        let candidates = [
            candidate("Nevermind", "1991 studio album by Nirvana"),
            candidate("Smells Like Nirvana", "1992 single by \"Weird Al\" Yankovic"),
            candidate("Smells Like Teen Spirit", "1991 single by Nirvana"),
        ]
        XCTAssertEqual(MeaningWikipedia.pickArticle(candidates, title: "Smells Like Teen Spirit", artist: "Nirvana"), 2)
    }

    func testADisambiguatedTitleMatchesAndCanNameTheArtist() {
        let candidates = [candidate("Kim Mathers", "American woman"), candidate("Kim (song)", "2000 song by Eminem")]
        XCTAssertEqual(MeaningWikipedia.pickArticle(candidates, title: "Kim", artist: "Eminem"), 1)
        let qualified = [candidate("Nightmare (Avenged Sevenfold song)", "")]
        XCTAssertEqual(MeaningWikipedia.pickArticle(qualified, title: "Nightmare", artist: "Avenged Sevenfold"), 0)
    }

    func testASongBySomeoneElseOrAnAlbumIsRefused() {
        let candidates = [
            candidate("Nightmare (Avenged Sevenfold album)", "2010 studio album by Avenged Sevenfold"),
            candidate("Nightmare (Halsey song)", "2019 single by Halsey"),
        ]
        XCTAssertNil(MeaningWikipedia.pickArticle(candidates, title: "Nightmare", artist: "Avenged Sevenfold"))
    }

    func testPunctuationAndCaseDoNotMatterButWholeWordsDo() {
        let candidates = [candidate("Mr. Brownstone", "1987 single by Guns N' Roses")]
        XCTAssertEqual(MeaningWikipedia.pickArticle(candidates, title: "Mr Brownstone", artist: "Guns N’ Roses"), 0)
        let partial = [candidate("Ross", "Song by Diana Ross")]
        XCTAssertEqual(MeaningWikipedia.pickArticle(partial, title: "Ross", artist: "Ross"), 0)
        XCTAssertEqual(MeaningWikipedia.pickArticle(partial, title: "Ross", artist: "Diana"), 0)
        XCTAssertNil(MeaningWikipedia.pickArticle(partial, title: "Ross", artist: "Dian"))
    }

    func testNothingIsPickedWithoutATitleOrAnArtist() {
        let candidates = [candidate("Song", "song by someone")]
        XCTAssertNil(MeaningWikipedia.pickArticle(candidates, title: "", artist: "someone"))
        XCTAssertNil(MeaningWikipedia.pickArticle(candidates, title: "Song", artist: "  "))
    }

    func testLocalizationsMapToTheirWikipedia() {
        XCTAssertEqual(MeaningWikipedia.wiki(for: "en"), MeaningWiki(language: "en", variant: nil))
        XCTAssertEqual(MeaningWikipedia.wiki(for: "pt-BR"), MeaningWiki(language: "pt", variant: nil))
        XCTAssertEqual(MeaningWikipedia.wiki(for: "zh-Hans"), MeaningWiki(language: "zh", variant: "zh-cn"))
        XCTAssertEqual(MeaningWikipedia.wiki(for: "zh-Hant"), MeaningWiki(language: "zh", variant: "zh-tw"))
        XCTAssertEqual(MeaningWikipedia.wiki(for: ""), MeaningWiki(language: "en", variant: nil))
    }

    private let extract = "\"Breed\" is a song by Nirvana.\nIt was written by Kurt Cobain.\n\n\n== Early history ==\nOriginally titled \"Imodium\".\n\n\n== Composition ==\n\n\n=== Music ===\nA driving riff.\n\n\n=== Lyrics ===\nThe lyrics mock suburban conformity.\nCobain called it a joke.\n\n\n== Release and reception ==\nIt charted.\n\n\n== Song meaning ==\nA second take.\n\n\n== Themes ==\nA third.\n\n\n== Lyrical content ==\nA fourth that is never shown.\n\n\n== References ==\n"

    func testAnExtractSplitsIntoItsIntroductionAndSections() {
        let parsed = MeaningWikipedia.parseExtract(extract)
        XCTAssertEqual(parsed.lead, ["\"Breed\" is a song by Nirvana.", "It was written by Kurt Cobain."])
        XCTAssertEqual(parsed.sections.map(\.heading), [
            "Early history", "Composition", "Music", "Lyrics", "Release and reception", "Song meaning", "Themes",
            "Lyrical content", "References",
        ])
        XCTAssertEqual(parsed.sections.map(\.level), [2, 2, 3, 3, 2, 2, 2, 2, 2])
        XCTAssertEqual(parsed.sections[3].body, ["The lyrics mock suburban conformity.", "Cobain called it a joke."])
        XCTAssertTrue(parsed.sections[1].body.isEmpty)
    }

    func testHeadingsAboutMeaningAreKeptAndTheRecordsAfterlifeIsNot() {
        for heading in ["Background", "Writing and recording", "Lyrics and interpretation", "Song", "Composition and lyrics"] {
            XCTAssertTrue(MeaningWikipedia.isMeaningHeading(heading), heading)
        }
        for heading in ["Music video", "Release and reception", "Charts", "Live performances", "Covers of the song", "Music", "In popular culture"] {
            XCTAssertFalse(MeaningWikipedia.isMeaningHeading(heading), heading)
        }
    }

    func testAStoryKeepsTheIntroductionAndTheFirstThreeMeaningSectionsWithText() throws {
        let story = try XCTUnwrap(MeaningWikipedia.story(
            article: "Breed (song)", url: "https://en.wikipedia.org/wiki/Breed_(song)", language: "en",
            extract: extract, withSections: true))
        XCTAssertEqual(story.lead, "\"Breed\" is a song by Nirvana.\n\nIt was written by Kurt Cobain.")
        XCTAssertEqual(story.sections.map(\.heading), ["Lyrics", "Song meaning", "Themes"])
        XCTAssertEqual(story.sections[0].body, "The lyrics mock suburban conformity.\n\nCobain called it a joke.")
    }

    func testAStoryWithoutSectionsIsTheIntroductionAlone() throws {
        let story = try XCTUnwrap(MeaningWikipedia.story(article: "Breed", url: "u", language: "de", extract: extract, withSections: false))
        XCTAssertTrue(story.sections.isEmpty)
        XCTAssertNil(MeaningWikipedia.story(article: "x", url: "u", language: "en", extract: "== Only ==\n", withSections: true))
    }

    func testTheBackgroundNamesEachSectionAndStaysWithinItsLimit() throws {
        let story = try XCTUnwrap(MeaningWikipedia.story(article: "Breed", url: "u", language: "en", extract: extract, withSections: true))
        XCTAssertEqual(
            MeaningWikipedia.background(story),
            "\"Breed\" is a song by Nirvana.\n\nIt was written by Kurt Cobain.\n\nLyrics: The lyrics mock suburban conformity.\n\nCobain called it a joke.\n\nSong meaning: A second take.\n\nThemes: A third."
        )
        let long = SongStory(article: "a", url: "u", language: "en", lead: String(repeating: "word ", count: 1_000), sections: [])
        XCTAssertLessThanOrEqual(MeaningText.utf16Length(MeaningWikipedia.background(long)), MeaningWikipedia.backgroundLimit)
    }

    func testAStoryRoundTripsThroughJSON() throws {
        let story = try XCTUnwrap(MeaningWikipedia.story(article: "Breed", url: "u", language: "en", extract: extract, withSections: true))
        let data = try JSONEncoder().encode(story)
        XCTAssertEqual(try JSONDecoder().decode(SongStory.self, from: data), story)
    }

    private func document() -> LyricsDocument {
        LyricsParser.parseLRC(
            "[00:01.00]Load up on guns\n[00:03.00]Bring your friends\n[00:05.00]\n[00:12.00]It's fun to lose\n[00:14.00]And to pretend\n[00:16.00]Hello, hello"
        )
    }

    func testSungLinesKeepVerseBreaksOnce() {
        XCTAssertEqual(
            MeaningPrompt.sungLines(document()),
            ["Load up on guns", "Bring your friends", "", "It's fun to lose", "And to pretend", "Hello, hello"]
        )
        let plain = LyricsDocument(lines: [], plain: "\n\nFirst\n\n\n\nSecond\nThird\n\n", instrumental: false)
        XCTAssertEqual(MeaningPrompt.sungLines(plain), ["First", "", "Second", "Third"])
        XCTAssertTrue(MeaningPrompt.sungLines(LyricsDocument()).isEmpty)
    }

    func testLongLyricsAreCutAtALineWithAnEllipsis() {
        let lines = (0..<2_000).map { "line \($0)" }
        let text = MeaningPrompt.lyricsText(lines)
        XCTAssertLessThanOrEqual(MeaningText.utf16Length(text), MeaningPrompt.lyricsLimit)
        XCTAssertTrue(text.hasSuffix("\n\u{2026}"))
        XCTAssertTrue(text.hasPrefix("line 0\nline 1\n"))
        XCTAssertEqual(MeaningPrompt.lyricsText(["One", "", "Two"]), "One\n\nTwo")
    }

    func testAFocusQuotesTheSungLinesAroundItAcrossABreak() throws {
        let document = document()
        let index = try XCTUnwrap(document.lines.firstIndex { $0.text == "It's fun to lose" })
        XCTAssertEqual(
            MeaningPrompt.focus(document, index: index),
            MeaningFocus(
                line: "It's fun to lose", before: ["Load up on guns", "Bring your friends"],
                after: ["And to pretend", "Hello, hello"])
        )
        XCTAssertEqual(MeaningPrompt.focus(document, index: 0)?.before, [])
        let interlude = try XCTUnwrap(document.lines.firstIndex { $0.isInterlude })
        XCTAssertNil(MeaningPrompt.focus(document, index: interlude))
        XCTAssertNil(MeaningPrompt.focus(document, index: 999))
    }

    func testTheSystemPromptNamesTheLanguageAndTheAnswerShape() {
        let prompt = MeaningPrompt.systemPrompt(language: "German")
        XCTAssertTrue(prompt.contains("Write in German."))
        XCTAssertTrue(prompt.hasSuffix("{\"meaning\": \"your explanation\"}."))
    }

    func testASongQuestionCarriesTheSongBackgroundAndLyrics() {
        let question = MeaningQuestion(
            title: "Smells Like Teen Spirit", artist: "Nirvana", album: "",
            lyrics: "Load up on guns\nBring your friends", background: "A song by Nirvana.", focus: nil)
        XCTAssertEqual(
            MeaningPrompt.userPrompt(question),
            "Song: \"Smells Like Teen Spirit\"\nArtist: Nirvana\n\nBackground from Wikipedia:\nA song by Nirvana.\n\nLyrics:\nLoad up on guns\nBring your friends\n\nWhat is this song about? Answer in at most 130 words, in one or two short paragraphs."
        )
    }

    func testALineQuestionQuotesTheLineAndItsNeighbours() {
        let focus = MeaningFocus(line: "A mulatto", before: ["Here we are now", "Entertain us"], after: [])
        let question = MeaningQuestion(
            title: "Smells Like Teen Spirit", artist: "Nirvana", album: "Nevermind",
            lyrics: "Entertain us\nA mulatto", background: "  ", focus: focus)
        XCTAssertEqual(
            MeaningPrompt.userPrompt(question),
            "Song: \"Smells Like Teen Spirit\"\nArtist: Nirvana\nAlbum: Nevermind\n\nLyrics:\nEntertain us\nA mulatto\n\nThe listener asked about this line:\n\"A mulatto\"\nIt follows: \"Here we are now / Entertain us\"\n\nWhat does this line mean in the song? Answer in at most 70 words, in one paragraph."
        )
    }

    func testAReplyIsReadThroughFencesReasoningAndProse() {
        XCTAssertEqual(MeaningPrompt.parseReply("{\"meaning\": \"It is about boredom.\"}"), "It is about boredom.")
        XCTAssertEqual(
            MeaningPrompt.parseReply("<think>Let me see {not json}</think>\n```json\n{\"meaning\": \" Two\\n\\nparagraphs \"}\n```"),
            "Two\n\nparagraphs"
        )
        XCTAssertEqual(MeaningPrompt.parseReply("Plain words about the song."), "Plain words about the song.")
    }

    func testAReplyWithoutAUsableMeaningIsNothing() {
        XCTAssertNil(MeaningPrompt.parseReply("{\"summary\": \"x\"}"))
        XCTAssertNil(MeaningPrompt.parseReply("{\"meaning\": \"   \"}"))
        XCTAssertNil(MeaningPrompt.parseReply("{\"meaning\": 3}"))
        XCTAssertNil(MeaningPrompt.parseReply("{broken"))
        XCTAssertNil(MeaningPrompt.parseReply("<think>never closed"))
        XCTAssertNil(MeaningPrompt.parseReply("   "))
    }

    func testALineIsOneQuestionWhateverItsCaseOrSpacing() {
        XCTAssertEqual(MeaningCache.lineScope("  Here we are NOW,\tentertain us "), "line:here we are now, entertain us")
        XCTAssertEqual(MeaningCache.lineScope("Here we are now, entertain us"), MeaningCache.lineScope("here  we are now, ENTERTAIN us"))
    }

    func testAStoryIsAskedForAgainAfterNinetyDaysAndAMissAfterThirty() {
        XCTAssertTrue(MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: true, ageDays: 89.9))
        XCTAssertFalse(MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: true, ageDays: 90))
        XCTAssertTrue(MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: false, ageDays: 29.9))
        XCTAssertFalse(MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: false, ageDays: 30))
    }

    func testAReadingNeverGoesStaleAndAnEmptyOneNeverCounts() {
        XCTAssertTrue(MeaningCache.isFresh(scope: MeaningCache.songScope, hasBody: true, ageDays: 10_000))
        XCTAssertTrue(MeaningCache.isFresh(scope: MeaningCache.lineScope("a"), hasBody: true, ageDays: 10_000))
        XCTAssertFalse(MeaningCache.isFresh(scope: MeaningCache.songScope, hasBody: false, ageDays: 0))
    }
}
