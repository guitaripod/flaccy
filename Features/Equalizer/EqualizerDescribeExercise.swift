import MidgarCore
#if DEBUG
import FlaccyCore
import Foundation

/// Asks the real flaccy-api for curves from sentences and checks each is one the equalizer can play safely, then
/// changes one with a second sentence, hears it, keeps it twice and removes what it kept, logging
/// `DESCRIBE SOUND DRILL PASSED` or `DESCRIBE SOUND DRILL FAILED: <step>`. Launch with
/// `--exercise-describe-sound`; `FLACCY_EQ_SENTENCES` replaces the sentences (separated by `|`),
/// `FLACCY_EQ_OUTPUT` the kind of output, and `-AppleLanguages "(fi)"` asks in another language.
@MainActor
enum EqualizerDescribeExercise {

    static let launchArgument = "--exercise-describe-sound"

    private static let usualSentences = ["warmer, with softer cymbals", "more bass", "clearer voices"]
    private static let change = "a little less bass, keep the rest"
    private static let bassProbe = 60.0

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let sentences = environment["FLACCY_EQ_SENTENCES"].map { $0.split(separator: "|").map(String.init) } ?? usualSentences
        let engine = EqualizerEngine.shared
        let output = environment["FLACCY_EQ_OUTPUT"] ?? engine.outputKind
        let service = EqualizerDescriptionService.shared
        MidgarLog.info("EqualizerDescribeExercise asks \(sentences.count) sentences in \(LyricsMeaningService.languageName) for output \(output)", category: .content)

        var first: DescribedEqualizer?
        for sentence in sentences {
            let started = Date()
            let result = await service.curve(for: sentence, output: output, inForce: EqualizerPresets.flat)
            guard case .success(let described) = result else { return fail("no curve for \"\(sentence)\" (\(result))") }
            log(described, sentence: sentence, seconds: Date().timeIntervalSince(started))
            if let flaw = flaw(in: described) { return fail("\"\(sentence)\": \(flaw)") }
            if first == nil { first = described }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let first else { return fail("no sentence was asked") }

        let bassy = await service.curve(for: "much more bass", output: "headphones", inForce: EqualizerPresets.flat)
        guard case .success(let loud) = bassy else { return fail("no curve to change (\(bassy))") }
        let changed = await service.curve(for: change, output: "headphones", inForce: loud.profile)
        guard case .success(let quieter) = changed else { return fail("the curve was not changed (\(changed))") }
        log(quieter, sentence: change, seconds: 0)
        if let flaw = flaw(in: quieter) { return fail("after the change, \(flaw)") }
        let before = level(of: loud.profile, at: bassProbe)
        let after = level(of: quieter.profile, at: bassProbe)
        guard after < before - 0.4 else { return fail("the change left the bass at \(format(after)) dB where it was \(format(before))") }
        MidgarLog.info("EqualizerDescribeExercise change took \(Int(bassProbe)) Hz from \(format(before)) to \(format(after)) dB", category: .content)

        engine.beginAudition(first.profile)
        guard engine.auditioned == first.profile else { return fail("the curve was not being heard") }
        engine.endAudition()
        guard engine.auditioned == nil else { return fail("hearing did not end") }

        let stateBefore = engine.state
        defer { engine.restore(stateBefore) }
        let kept = engine.keep(first.profile, use: false)
        let again = engine.keep(first.profile, use: true)
        guard engine.state.userProfiles.contains(where: { $0.id == kept.id }), kept.name != again.name else {
            return fail("keeping twice gave \"\(kept.name)\" and \"\(again.name)\"")
        }
        guard engine.profileInForce.id == again.id, engine.state.isEnabled else {
            return fail("the kept curve is not the one in force")
        }
        MidgarLog.info("EqualizerDescribeExercise kept as \"\(kept.name)\" and \"\(again.name)\"", category: .content)
        MidgarLog.info("DESCRIBE SOUND DRILL PASSED", category: .content)
    }

    /// What is wrong with a made curve as something to play, or nil: every band inside the equalizer's ranges,
    /// no pass filter sharp enough to ring, the summed boost inside the plot and a preamp that covers it.
    private static func flaw(in described: DescribedEqualizer) -> String? {
        let bands = described.profile.bands
        guard (1...EqualizerBand.maximumPerProfile).contains(bands.count) else { return "\(bands.count) bands" }
        guard described.reasons.count == bands.count else { return "\(described.reasons.count) reasons for \(bands.count) bands" }
        for band in bands {
            guard band == band.clamped() else { return "a band outside the ranges: \(band)" }
            if !band.type.hasGain, band.q > EqualizerDescription.highestPassQ { return "a pass filter at Q \(band.q)" }
        }
        let peak = Headroom.peakBoost(of: described.profile.resolvedBands())
        guard peak <= EqualizerDescription.highestBoost + 0.1 else { return "a summed boost of \(format(peak)) dB" }
        guard described.profile.isAutoPreamp, described.profile.preamp() <= -peak + 0.11 else { return "a preamp of \(format(described.profile.preamp())) dB under a boost of \(format(peak))" }
        guard !described.profile.name.isEmpty else { return "no name" }
        return nil
    }

    private static func level(of profile: EqualizerProfile, at frequency: Double) -> Double {
        BiquadMath.responseDecibels(profile.resolvedBands(), frequency: frequency, sampleRate: BiquadMath.referenceSampleRate)
    }

    private static func log(_ described: DescribedEqualizer, sentence: String, seconds: TimeInterval) {
        let resolved = described.profile.resolvedBands()
        MidgarLog.info(
            "EqualizerDescribeExercise \"\(sentence)\" -> \"\(described.profile.name)\": \(resolved.count) bands, peak "
                + "\(format(Headroom.peakBoost(of: resolved))) dB, preamp \(format(described.profile.preamp(for: resolved))) dB, "
                + "\(String(format: "%.1f", seconds)) s, note \"\(described.note)\"",
            category: .content)
        for (index, band) in described.profile.bands.enumerated() {
            MidgarLog.info("EqualizerDescribeExercise   \(EqualizerDescribeCopy.bandTitle(band)) q \(EqualizerCopy.q(band.q)): \(described.reasons[index])", category: .content)
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func fail(_ step: String) {
        MidgarLog.error("DESCRIBE SOUND DRILL FAILED: \(step)", category: .content)
    }
}
#endif
