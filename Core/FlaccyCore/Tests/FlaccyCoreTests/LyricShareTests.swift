import XCTest
@testable import FlaccyCore

final class LyricShareTests: XCTestCase {

    private func raw(_ start: Double, _ end: Double?, _ text: String) -> LyricsRawLine {
        LyricsRawLine(start: start, end: end, text: text, words: [])
    }

    /// Lines 0–3, an interlude at index 4, then lines 5–8, with "hold on"
    /// sung three times.
    private func song() -> LyricsDocument {
        LyricsDocument.resolve(
            raw: [
                raw(1.0, 4.0, "Streetlights hum"),
                raw(4.0, 7.0, "Hold on, hold on!"),
                raw(7.0, 10.0, "We were young"),
                raw(10.0, 13.0, "Hold on hold on"),
                raw(20.0, 23.0, "Second verse"),
                raw(23.0, 26.0, "hold on, HOLD ON"),
                raw(26.0, 40.0, "A very long held note"),
                raw(40.0, 44.0, "Outro"),
            ],
            plain: nil, instrumental: false)
    }

    func testTheDocumentUnderTestHasOneInterlude() {
        let doc = song()
        XCTAssertEqual(doc.lines.count, 9)
        XCTAssertFalse(doc.lines[0].isInterlude)
        XCTAssertEqual(doc.lines.filter(\.isInterlude).count, 1)
        XCTAssertTrue(doc.lines[4].isInterlude)
    }

    func testTheStyleRoundTripsAndToleratesUnknownValues() {
        let style = LyricShareStyle(
            template: .pulse, format: .wide, theme: .light, typeface: .mono,
            showArtwork: false, showVisualizer: true, showMark: false)
        XCTAssertEqual(
            style.encoded,
            "template=pulse;format=wide;theme=light;typeface=mono;artwork=0;visualizer=1;mark=0")
        XCTAssertEqual(LyricShareStyle(encoded: style.encoded), style)
        let odd = LyricShareStyle(encoded: "template=hologram;format=square;artwork=yes;bogus;mark=0;=1")
        XCTAssertEqual(odd.template, .spotlight)
        XCTAssertEqual(odd.format, .square)
        XCTAssertTrue(odd.showArtwork)
        XCTAssertFalse(odd.showMark)
        XCTAssertEqual(LyricShareStyle(encoded: ""), .standard)
    }

    func testFormatsHaveTheirPixelSizes() {
        XCTAssertEqual(LyricShareFormat.story.pixelWidth, 1080)
        XCTAssertEqual(LyricShareFormat.story.pixelHeight, 1920)
        XCTAssertEqual(LyricShareFormat.portrait.pixelHeight, 1350)
        XCTAssertEqual(LyricShareFormat.square.pixelHeight, 1080)
        XCTAssertEqual(LyricShareFormat.wide.pixelWidth, 1920)
        XCTAssertEqual(LyricShareFormat.wide.pixelHeight, 1080)
    }

    func testTheDefaultSelectionFollowsTheClock() {
        let doc = song()
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: 5.0), LyricShareSelection(first: 1, last: 3))
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: 0.2), LyricShareSelection(first: 0, last: 3))
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: 15.0), LyricShareSelection(first: 5, last: 6))
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: 999.0), LyricShareSelection(first: 8, last: 8))
    }

    func testWithoutAClockTheDefaultSelectionStartsAtTheChorus() {
        let doc = song()
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: nil), LyricShareSelection(first: 1, last: 3))
        let plainDoc = LyricsDocument.resolve(
            raw: [raw(0, 2, "one"), raw(2, 4, "two"), raw(4, 6, "three")], plain: nil, instrumental: false)
        XCTAssertEqual(LyricShareClip.defaultSelection(in: plainDoc, at: nil), LyricShareSelection(first: 0, last: 2))
        XCTAssertNil(LyricShareClip.defaultSelection(in: LyricsDocument(), at: 3))
    }

    func testTheDefaultSelectionStopsAtTheSpan() {
        let doc = song()
        XCTAssertEqual(LyricShareClip.defaultSelection(in: doc, at: 24.0), LyricShareSelection(first: 6, last: 6))
    }

    func testNormalizationIgnoresCaseAndPunctuation() {
        XCTAssertEqual(LyricShareClip.normalized("  Hold on, HOLD   on!! "), "hold on hold on")
        XCTAssertEqual(LyricShareClip.normalized("Ça va? 99 Luftballons"), "ça va 99 luftballons")
        XCTAssertEqual(LyricShareClip.normalized("♪ ... ♪"), "")
        XCTAssertNil(LyricShareClip.mostRepeated(["a", "b", "c"]))
        XCTAssertEqual(LyricShareClip.mostRepeated(["a", "b", "b", "a", "c", "b"]), 1)
        XCTAssertEqual(LyricShareClip.mostRepeated(["x", "a", "b", "a", "b"]), 1)
        XCTAssertNil(LyricShareClip.mostRepeated(["", "", "q"]))
    }

    func testTogglingExtendsShrinksAndKeepsTheLastLine() {
        let doc = song()
        let one = LyricShareSelection(first: 2, last: 2)
        XCTAssertEqual(LyricShareClip.toggle(one, line: 2, in: doc), one)
        XCTAssertEqual(LyricShareClip.toggle(one, line: 0, in: doc), LyricShareSelection(first: 0, last: 2))
        XCTAssertEqual(LyricShareClip.toggle(one, line: 5, in: doc), LyricShareSelection(first: 2, last: 5))
        XCTAssertEqual(LyricShareClip.toggle(one, line: 4, in: doc), one)
        XCTAssertEqual(LyricShareClip.toggle(one, line: 42, in: doc), one)
        let run = LyricShareSelection(first: 1, last: 5)
        XCTAssertEqual(LyricShareClip.toggle(run, line: 1, in: doc), LyricShareSelection(first: 2, last: 5))
        XCTAssertEqual(LyricShareClip.toggle(run, line: 5, in: doc), LyricShareSelection(first: 1, last: 3))
        XCTAssertEqual(LyricShareClip.toggle(LyricShareSelection(first: 3, last: 5), line: 5, in: doc), LyricShareSelection(first: 3, last: 3))
        XCTAssertEqual(LyricShareClip.toggle(LyricShareSelection(first: 3, last: 5), line: 3, in: doc), LyricShareSelection(first: 5, last: 5))
        XCTAssertEqual(LyricShareClip.toggle(run, line: 2, in: doc), LyricShareSelection(first: 1, last: 2))
    }

    func testExtendingPastTheLongestClipLetsGoOfTheFarEnd() {
        let doc = song()
        let start = LyricShareSelection(first: 0, last: 1)
        XCTAssertEqual(LyricShareClip.toggle(start, line: 8, in: doc), LyricShareSelection(first: 5, last: 8))
        XCTAssertEqual(LyricShareClip.toggle(LyricShareSelection(first: 7, last: 8), line: 0, in: doc), LyricShareSelection(first: 0, last: 6))
        XCTAssertTrue(LyricShareClip.fits(LyricShareSelection(first: 5, last: 8), in: doc))
        XCTAssertFalse(LyricShareClip.fits(LyricShareSelection(first: 3, last: 8), in: doc))
        XCTAssertEqual(LyricShareClip.span(of: LyricShareSelection(first: 0, last: 3), in: doc), 12, accuracy: 1e-9)
    }

    func testPlainTogglingCapsTheCount() {
        let full = LyricShareSelection(first: 0, last: 5)
        XCTAssertEqual(LyricShareClip.togglePlain(full, line: 7, count: 10), LyricShareSelection(first: 2, last: 7))
        XCTAssertEqual(LyricShareClip.togglePlain(LyricShareSelection(first: 4, last: 9), line: 1, count: 10), LyricShareSelection(first: 1, last: 6))
        XCTAssertEqual(LyricShareClip.togglePlain(full, line: 0, count: 10), LyricShareSelection(first: 1, last: 5))
        XCTAssertEqual(LyricShareClip.togglePlain(full, line: 5, count: 10), LyricShareSelection(first: 0, last: 4))
        XCTAssertEqual(LyricShareClip.togglePlain(full, line: 3, count: 10), LyricShareSelection(first: 0, last: 3))
        XCTAssertEqual(LyricShareClip.togglePlain(LyricShareSelection(first: 2, last: 2), line: 2, count: 10), LyricShareSelection(first: 2, last: 2))
        XCTAssertEqual(LyricShareClip.togglePlain(full, line: 10, count: 10), full)
    }

    func testPlainLinesAndTheirDefaultSelection() {
        let lines = LyricShareClip.plainLines("  First\r\n\nSecond  \n   \nChorus!\nchorus\nLast\n")
        XCTAssertEqual(lines, ["First", "Second", "Chorus!", "chorus", "Last"])
        XCTAssertEqual(LyricShareClip.defaultPlainSelection(lines: lines), LyricShareSelection(first: 2, last: 4))
        XCTAssertEqual(LyricShareClip.defaultPlainSelection(lines: ["a", "b"]), LyricShareSelection(first: 0, last: 1))
        XCTAssertNil(LyricShareClip.defaultPlainSelection(lines: []))
    }

    func testTheWindowBreathesAroundTheLines() {
        let doc = song()
        let window = LyricShareClip.window(for: LyricShareSelection(first: 1, last: 2), in: doc, offset: 0, trackDuration: 200)
        XCTAssertEqual(window.lyricStart, 3.4, accuracy: 1e-9)
        XCTAssertEqual(window.duration, 8.0, accuracy: 1e-9)
        XCTAssertEqual(window.audioStart, 3.4, accuracy: 1e-9)
        let short = LyricShareClip.window(for: LyricShareSelection(first: 0, last: 0), in: doc, offset: 0, trackDuration: 200)
        XCTAssertEqual(short.lyricStart, 0.4, accuracy: 1e-9)
        XCTAssertEqual(short.duration, 6.0, accuracy: 1e-9)
    }

    func testTheWindowAppliesTheOffsetAndStaysInsideTheSong() {
        let doc = song()
        let later = LyricShareClip.window(for: LyricShareSelection(first: 0, last: 1), in: doc, offset: 1.5, trackDuration: 200)
        XCTAssertEqual(later.lyricStart, 0.4, accuracy: 1e-9)
        XCTAssertEqual(later.audioStart, 1.9, accuracy: 1e-9)
        let earlier = LyricShareClip.window(for: LyricShareSelection(first: 0, last: 1), in: doc, offset: -2, trackDuration: 200)
        XCTAssertEqual(earlier.lyricStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(earlier.audioStart, 0.0, accuracy: 1e-9)
        let atEnd = LyricShareClip.window(for: LyricShareSelection(first: 8, last: 8), in: doc, offset: 0, trackDuration: 44.5)
        XCTAssertEqual(atEnd.lyricStart, 38.5, accuracy: 1e-9)
        XCTAssertEqual(atEnd.duration, 6.0, accuracy: 1e-9)
        let long = LyricShareClip.window(for: LyricShareSelection(first: 0, last: 8), in: doc, offset: 0, trackDuration: 0)
        XCTAssertEqual(long.lyricStart, 0.4, accuracy: 1e-9)
        XCTAssertEqual(long.duration, 30.0, accuracy: 1e-9)
    }

    func testThePlainWindowIsFifteenSecondsInsideTheSong() {
        XCTAssertEqual(LyricShareClip.plainWindow(start: 30, trackDuration: 200), LyricShareWindow(lyricStart: 30, duration: 15, offset: 0))
        XCTAssertEqual(LyricShareClip.plainWindow(start: 195, trackDuration: 200), LyricShareWindow(lyricStart: 185, duration: 15, offset: 0))
        XCTAssertEqual(LyricShareClip.plainWindow(start: -4, trackDuration: 10), LyricShareWindow(lyricStart: 0, duration: 10, offset: 0))
        XCTAssertEqual(LyricShareClip.plainWindow(start: 12, trackDuration: 0), LyricShareWindow(lyricStart: 12, duration: 15, offset: 0))
    }

    func testFramesAndGain() {
        XCTAssertEqual(LyricShareClip.frameCount(LyricShareWindow(lyricStart: 0, duration: 15, offset: 0)), 450)
        XCTAssertEqual(LyricShareClip.frameCount(LyricShareWindow(lyricStart: 0, duration: 15.01, offset: 0)), 451)
        XCTAssertEqual(LyricShareClip.frameCount(LyricShareWindow(lyricStart: 0, duration: 0, offset: 0)), 1)
        XCTAssertEqual(LyricShareClip.time(ofFrame: 45, in: LyricShareWindow(lyricStart: 2, duration: 10, offset: 0)), 3.5, accuracy: 1e-9)
        XCTAssertEqual(LyricShareClip.gain(at: 0, duration: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(LyricShareClip.gain(at: 0.15, duration: 10), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LyricShareClip.gain(at: 5, duration: 10), 1, accuracy: 1e-12)
        XCTAssertEqual(LyricShareClip.gain(at: 9.55, duration: 10), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LyricShareClip.gain(at: 10, duration: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(LyricShareClip.gain(at: -1, duration: 10), 0)
        XCTAssertEqual(LyricShareClip.gain(at: 0.075, duration: 10), 0.15625, accuracy: 1e-12)
    }

    func testFocusFollowsTheSungLinesWithALead() {
        let doc = song()
        let selection = LyricShareSelection(first: 2, last: 5)
        XCTAssertEqual(LyricShareMotion.lines(of: selection, in: doc), [2, 3, 5])
        let opening = LyricShareMotion.focus(selection, in: doc, at: 6.4, clipStart: 6.4)
        XCTAssertEqual(opening, LyricShareFocus(index: 2, rank: 0, entrance: 0))
        let landing = LyricShareMotion.focus(selection, in: doc, at: 6.61, clipStart: 6.4)
        XCTAssertEqual(landing.entrance, 0.875, accuracy: 1e-9)
        let second = LyricShareMotion.focus(selection, in: doc, at: 9.88 + 0.21, clipStart: 6.4)
        XCTAssertEqual(second.index, 3)
        XCTAssertEqual(second.rank, 1)
        XCTAssertEqual(second.entrance, 0.875, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.focus(selection, in: doc, at: 30, clipStart: 6.4), LyricShareFocus(index: 5, rank: 2, entrance: 1))
        XCTAssertEqual(LyricShareMotion.scrollPosition(second), 0.875, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.scrollPosition(opening), 0)
    }

    func testInkPerTemplate() {
        let focus = LyricShareFocus(index: 3, rank: 1, entrance: 0.5)
        XCTAssertEqual(LyricShareMotion.ink(rank: 1, focus: focus, template: .verse), 0.67, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 0, focus: focus, template: .verse), 0.67, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 2, focus: focus, template: .verse), 0.34, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 0, focus: focus, template: .poster), 1)
        XCTAssertEqual(LyricShareMotion.ink(rank: 2, focus: focus, template: .poster), 0.34, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 1, focus: focus, template: .spotlight), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 0, focus: focus, template: .pulse), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricShareMotion.ink(rank: 2, focus: focus, template: .spotlight), 0)
        XCTAssertEqual(LyricShareMotion.ease(0.5), 0.875, accuracy: 1e-12)
        XCTAssertEqual(LyricShareMotion.ease(-3), 0)
        XCTAssertEqual(LyricShareMotion.ease(4), 1)
    }

    func testVisualizerMirrorsTheBands() {
        XCTAssertEqual(LyricShareVisualizer.strip([1, 2, 3]), [3, 2, 1, 1, 2, 3])
        XCTAssertEqual(LyricShareVisualizer.ring([1, 2, 3]), [1, 2, 3, 3, 2, 1])
    }

    func testBandEdgesRiseOneBinAtLeast() {
        let edges = LyricShareSpectrum.bandEdges(sampleRate: 48_000)
        XCTAssertEqual(edges.count, 25)
        XCTAssertEqual(edges.first, 3)
        XCTAssertEqual(edges.last, 683)
        XCTAssertEqual(Array(edges.prefix(6)), [3, 4, 5, 6, 7, 8])
        for index in 1..<edges.count {
            XCTAssertGreaterThan(edges[index], edges[index - 1])
        }
        XCTAssertEqual(LyricShareSpectrum.bandEdges(sampleRate: 44_100).last, 744)
    }

    private func sine(hertz: Double, amplitude: Double, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * hertz * Double($0) / sampleRate)) }
    }

    func testASineLightsItsOwnBand() {
        let signal = sine(hertz: 1000, amplitude: 1, sampleRate: 48_000, seconds: 2)
        let analysis = LyricShareSpectrum.analyze(mono: signal, sampleRate: 48_000, frames: 30, fps: 30)
        XCTAssertEqual(analysis.bands.count, 30)
        XCTAssertEqual(analysis.levels.count, 30)
        let settled = analysis.bands[20]
        let loudest = settled.indices.max { settled[$0] < settled[$1] }
        XCTAssertEqual(loudest, 12)
        XCTAssertGreaterThan(settled[12], 0.95)
        XCTAssertLessThan(settled[2], 0.2)
        XCTAssertEqual(Double(analysis.levels[20]), 0.9331, accuracy: 0.002)
        XCTAssertLessThan(analysis.levels[0], analysis.levels[20])
    }

    func testSilenceIsQuietAndTheEndsAreQuiet() {
        let analysis = LyricShareSpectrum.analyze(mono: [Float](repeating: 0, count: 48_000), sampleRate: 48_000, frames: 10, fps: 30)
        XCTAssertTrue(analysis.bands.allSatisfy { $0.allSatisfy { $0 == 0 } })
        XCTAssertTrue(analysis.levels.allSatisfy { $0 == 0 })
        XCTAssertEqual(analysis.bands(at: 99), [Float](repeating: 0, count: 24))
        XCTAssertEqual(analysis.level(at: -1), 0)
        XCTAssertEqual(LyricShareSpectrum.analyze(mono: [], sampleRate: 48_000, frames: 0, fps: 30).bands.count, 0)
    }

    func testTheSpectrumMatchesTheRustMirror() {
        let signal = sine(hertz: 220, amplitude: 0.5, sampleRate: 44_100, seconds: 1)
            .enumerated().map { $0.element + Float(0.25 * sin(2 * Double.pi * 3_000 * Double($0.offset) / 44_100)) }
        let analysis = LyricShareSpectrum.analyze(mono: signal, sampleRate: 44_100, frames: 12, fps: 30)
        let expectedBands: [Float] = Self.pinnedBands
        let expectedLevels: [Float] = Self.pinnedLevels
        XCTAssertEqual(analysis.bands[10].count, expectedBands.count)
        for (value, expected) in zip(analysis.bands[10], expectedBands) {
            XCTAssertEqual(value, expected, accuracy: 1e-4)
        }
        for (value, expected) in zip(analysis.levels, expectedLevels) {
            XCTAssertEqual(value, expected, accuracy: 1e-4)
        }
    }

    /// Frame 10's bands and every frame's level for 220 Hz at half scale plus
    /// 3 kHz at a quarter, asserted to the same digits in `spectrum.rs`.
    static let pinnedBands: [Float] = [
        0.027948, 0.028650, 0.029360, 0.077009, 0.191920, 0.744638, 0.895245, 0.252928,
        0.023902, 0.016810, 0.011899, 0.005871, 0.000000, 0.000000, 0.002315, 0.007378,
        0.612116, 0.789697, 0.005604, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
    ]
    static let pinnedLevels: [Float] = [
        0.489352, 0.705210, 0.780663, 0.806069, 0.816061, 0.819461,
        0.819648, 0.820813, 0.821125, 0.820822, 0.821224, 0.821213,
    ]

    func testPalettesReadOnTheirBackgrounds() {
        let samples = [
            LyricShareColor(hex: 0x203040), LyricShareColor(hex: 0xE04020),
            LyricShareColor(hex: 0x102030), LyricShareColor(hex: 0x404850),
        ]
        for theme in LyricShareTheme.allCases {
            let palette = LyricSharePalette.make(theme: theme, samples: samples)
            XCTAssertGreaterThan(palette.ink.contrast(with: palette.background), 4.5, "\(theme)")
        }
        let artwork = LyricSharePalette.make(theme: .artwork, samples: samples)
        XCTAssertEqual(artwork.backdrop, 0.6)
        XCTAssertEqual(artwork.ink, LyricSharePalette.white)
        XCTAssertEqual(artwork.accent.hsl.hue, LyricShareColor(hex: 0xE04020).hsl.hue, accuracy: 1e-9)
        XCTAssertEqual(artwork.accent.hsl.lightness, 0.64, accuracy: 1e-9)
        XCTAssertEqual(artwork.background.hsl.lightness, 0.18, accuracy: 1e-9)
        let vivid = LyricSharePalette.make(theme: .vivid, samples: samples)
        XCTAssertEqual(vivid.accent, vivid.ink)
        XCTAssertEqual(vivid.backdrop, 0)
        XCTAssertEqual(vivid.backgroundDeep.hsl.lightness, 0.32, accuracy: 1e-9)
        XCTAssertEqual(LyricSharePalette.deepHue(0.02), 0.98, accuracy: 1e-12)
        XCTAssertEqual(LyricSharePalette.deepHue(0.5), 0.46, accuracy: 1e-12)
        XCTAssertEqual(LyricSharePalette.make(theme: .light, samples: samples).ink, LyricSharePalette.nearBlack)
        let grey = LyricSharePalette.make(theme: .dark, samples: [LyricShareColor(hex: 0x808080)])
        XCTAssertEqual(grey.accent, LyricShareColor(hex: 0xF2F2F2))
        let empty = LyricSharePalette.make(theme: .artwork, samples: [])
        XCTAssertEqual(empty.background.hsl.hue, LyricSharePalette.fallback.hsl.hue, accuracy: 1e-9)
    }

    func testColourArithmetic() {
        XCTAssertEqual(LyricSharePalette.white.contrast(with: LyricShareColor(hex: 0x000000)), 21, accuracy: 1e-9)
        XCTAssertEqual(LyricShareColor(hex: 0xFF0000).hsl.hue, 0, accuracy: 1e-12)
        XCTAssertEqual(LyricShareColor(hex: 0x00FF00).hsl.hue, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(LyricShareColor(hex: 0xFF00FF).hsl.hue, 5.0 / 6, accuracy: 1e-12)
        let round = LyricShareColor(hue: 0.58, saturation: 0.6, lightness: 0.4)
        let back = LyricShareColor(hue: round.hsl.hue, saturation: round.hsl.saturation, lightness: round.hsl.lightness)
        XCTAssertEqual(back.red, round.red, accuracy: 1e-9)
        XCTAssertEqual(back.blue, round.blue, accuracy: 1e-9)
        XCTAssertEqual(LyricSharePalette.readableInk(on: LyricShareColor(hex: 0xFFE066)), LyricSharePalette.nearBlack)
        XCTAssertEqual(LyricSharePalette.readableInk(on: LyricShareColor(hex: 0x2040A0)), LyricSharePalette.white)
    }

    func testStoryLayouts() {
        let spotlight = LyricShareLayout.make(format: .story, template: .spotlight, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(spotlight.width, 1080)
        XCTAssertEqual(spotlight.height, 1920)
        XCTAssertEqual(spotlight.mark, LyricShareRect(x: 84, y: 1600, width: 912, height: 40))
        XCTAssertEqual(spotlight.artwork, LyricShareRect(x: 84, y: 220, width: 128, height: 128))
        XCTAssertEqual(spotlight.header, LyricShareRect(x: 240, y: 220, width: 756, height: 128))
        XCTAssertEqual(spotlight.visualizer, LyricShareRect(x: 84, y: 1460, width: 912, height: 112))
        XCTAssertEqual(spotlight.lyrics, LyricShareRect(x: 84, y: 396, width: 912, height: 1024))
        XCTAssertEqual(spotlight.lyricSize, 88)
        XCTAssertEqual(spotlight.lyricAlignment, .center)
        XCTAssertEqual(spotlight.headerAlignment, .leading)

        let verse = LyricShareLayout.make(format: .story, template: .verse, showArtwork: false, showVisualizer: false)
        XCTAssertNil(verse.artwork)
        XCTAssertNil(verse.visualizer)
        XCTAssertEqual(verse.header, LyricShareRect(x: 84, y: 220, width: 912, height: 96))
        XCTAssertEqual(verse.lyrics, LyricShareRect(x: 84, y: 364, width: 912, height: 1208))
        XCTAssertEqual(verse.lyricAlignment, .leading)

        let poster = LyricShareLayout.make(format: .story, template: .poster, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(poster.visualizer, LyricShareRect(x: 84 + 912 * 0.15, y: 1516, width: 912 * 0.7, height: 56))
        XCTAssertEqual(poster.artwork, LyricShareRect(x: 249.5, y: 220, width: 581, height: 581))
        XCTAssertEqual(poster.header, LyricShareRect(x: 84, y: 837, width: 912, height: 100))
        XCTAssertEqual(poster.lyrics, LyricShareRect(x: 84, y: 973, width: 912, height: 511))
        XCTAssertEqual(poster.lyricSize, 54)
        XCTAssertEqual(LyricShareLayout.make(format: .story, template: .poster, showArtwork: false, showVisualizer: true).lyricSize, 67.5)

        let pulse = LyricShareLayout.make(format: .story, template: .pulse, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(pulse.artwork, LyricShareRect(x: 312, y: 471.76, width: 456, height: 456))
        XCTAssertEqual(pulse.artworkRadius, 228)
        let ring = 228 * 1.42
        XCTAssertEqual(pulse.visualizer?.width ?? 0, ring * 2, accuracy: 1e-9)
        XCTAssertEqual(pulse.lyrics.y, 376 + ring * 2 + 40, accuracy: 1e-9)
        XCTAssertEqual(pulse.lyrics.maxY, 1572, accuracy: 1e-9)
    }

    func testSquareAndWideLayouts() {
        let pulse = LyricShareLayout.make(format: .square, template: .pulse, showArtwork: false, showVisualizer: false)
        XCTAssertEqual(pulse.artworkRadius, 162)
        XCTAssertNotNil(pulse.artwork)
        XCTAssertNil(pulse.visualizer)
        XCTAssertEqual(pulse.lyricSize, 48)

        let square = LyricShareLayout.make(format: .square, template: .spotlight, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(square.artwork?.width, 112)
        XCTAssertEqual(square.lyricSize, 68)

        let wide = LyricShareLayout.make(format: .wide, template: .verse, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(wide.artwork, LyricShareRect(x: 120, y: 118, width: 640, height: 640))
        XCTAssertEqual(wide.header, LyricShareRect(x: 120, y: 794, width: 640, height: 100))
        XCTAssertEqual(wide.visualizer, LyricShareRect(x: 856, y: 804, width: 944, height: 112))
        XCTAssertEqual(wide.lyrics, LyricShareRect(x: 856, y: 96, width: 944, height: 668))
        XCTAssertEqual(wide.lyricAlignment, .leading)

        let widePulse = LyricShareLayout.make(format: .wide, template: .pulse, showArtwork: true, showVisualizer: true)
        XCTAssertEqual(widePulse.artworkRadius, 216)
        XCTAssertEqual(widePulse.artwork?.midX ?? 0, 440, accuracy: 1e-9)
        XCTAssertEqual(widePulse.artwork?.midY ?? 0, 506, accuracy: 1e-9)
        XCTAssertEqual(widePulse.header, LyricShareRect(x: 856, y: 96, width: 944, height: 100))

        let bare = LyricShareLayout.make(format: .wide, template: .poster, showArtwork: false, showVisualizer: true)
        XCTAssertNil(bare.artwork)
        XCTAssertEqual(bare.header, LyricShareRect(x: 120, y: 96, width: 1680, height: 100))
        XCTAssertEqual(bare.visualizer, LyricShareRect(x: 120 + 1680 * 0.15, y: 860, width: 1680 * 0.7, height: 56))
        XCTAssertEqual(bare.lyrics, LyricShareRect(x: 120, y: 244, width: 1680, height: 584))
        XCTAssertEqual(bare.lyricSize, 62.5)
    }

    func testFileNames() {
        XCTAssertEqual(
            LyricShareNaming.fileName(title: "Hold On / Let Go?", artist: "  The   Band: ", fileExtension: "mp4"),
            "The Band \u{2013} Hold On Let Go (Lyrics).mp4")
        XCTAssertEqual(LyricShareNaming.fileName(title: "Tab\tSong", artist: "", fileExtension: "png"), "Tab Song (Lyrics).png")
        XCTAssertEqual(LyricShareNaming.fileName(title: "", artist: "", fileExtension: "png"), "Flaccy (Lyrics).png")
        let long = LyricShareNaming.fileName(title: String(repeating: "a", count: 200), artist: "B", fileExtension: "mp4")
        XCTAssertEqual(long.unicodeScalars.count, 133)
        XCTAssertTrue(long.hasSuffix("a (Lyrics).mp4"))
    }
}
