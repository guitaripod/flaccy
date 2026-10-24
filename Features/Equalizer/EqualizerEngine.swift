import AVFoundation
import MidgarCore
import FlaccyCore
import Foundation

/// The equalizer as the rest of the app sees it: the saved state, the output it
/// is following, and the taps that put the curve into every `AVPlayerItem`.
///
/// Audio takes the cheapest honest path. With the equalizer off, flat, or bound
/// to Off for the current output, no item carries a tap at all, so samples go
/// from the decoder to the output untouched. While it runs, each item gets an
/// `MTAudioProcessingTap` through an `AVAudioMix`, which leaves `AVQueuePlayer`,
/// gapless preloading, Now Playing and AirPlay exactly as they were. Edits are
/// published as a new immutable config; each tap's kernel ramps to it, so
/// nothing clicks. A screen that wants the live spectrum asks for the analyzer,
/// which keeps a tap attached (passing audio through) while the screen is open.
@MainActor
final class EqualizerEngine {

    static let shared = EqualizerEngine()

    static let stateDidChange = Notification.Name("com.midgarcorp.flaccy.EqualizerStateDidChange")
    static let outputDidChange = Notification.Name("com.midgarcorp.flaccy.EqualizerOutputDidChange")
    static let outputProfileKey = "profileName"

    enum ImportOutcome: Equatable {
        case imported(EqualizerProfile, droppedFilters: Int)
        case unreadable
    }

    private(set) var state: EqualizerState
    private(set) var output: EqualizerOutput?
    private(set) var isComparing = false
    private(set) var auditioned: EqualizerProfile?

    private let store = EqualizerStore()
    private let box = EqualizerConfigBox()
    private let items = NSHashTable<AVPlayerItem>.weakObjects()
    private let attachments = NSMapTable<AVPlayerItem, Attachment>.weakToStrongObjects()
    private var analysisOwners = Set<ObjectIdentifier>()
    private var version: UInt64 = 0
    private var outputWatcher: EqualizerOutputWatcher?
    private var spectrumAnalyzer: SpectrumAnalyzer?
    private var spectrumScratch = [Float](repeating: 0, count: SpectrumAnalyzer.windowSize)

    private final class Attachment {
        var hasMix = false
        var isLoading = false
    }

    private init() {
        state = store.load()
        publish(reason: "launch")
    }

    /// Starts following the output route. Called once at launch.
    func start() {
        guard outputWatcher == nil else { return }
        let watcher = EqualizerOutputWatcher { [weak self] newOutput in
            self?.outputChanged(to: newOutput)
        }
        outputWatcher = watcher
        watcher.start()
        output = watcher.current
        rememberName(of: output)
        publish(reason: "output \(output?.id ?? "none")")
    }

    var outputID: String? {
        output?.id
    }

    /// The profile the screens edit and draw, whether or not it is running.
    var profileInForce: EqualizerProfile {
        state.profileInForce(forOutput: outputID)
    }

    /// The profile actually shaping the sound, or nil when audio is passing untouched.
    var runningProfile: EqualizerProfile? {
        state.effectiveProfile(forOutput: outputID)
    }

    var isRunning: Bool {
        runningProfile != nil
    }

    var keepsOwnProfileForOutput: Bool {
        state.keepsOwnProfile(forOutput: outputID)
    }

    var isOutputBoundToOff: Bool {
        outputID.flatMap { state.outputBindings[$0] } == EqualizerState.offBinding
    }

    var allProfiles: [EqualizerProfile] {
        EqualizerPresets.all + state.userProfiles
    }

    func setEnabled(_ enabled: Bool) {
        guard state.isEnabled != enabled else { return }
        state.isEnabled = enabled
        commit(reason: "enabled \(enabled)")
    }

    func setPeakGuard(_ on: Bool) {
        state.isPeakGuardOn = on
        commit(reason: "peak guard \(on)")
    }

    /// Chooses a profile and turns the equalizer on, since choosing a preset is asking to hear it.
    func select(profileID: String) {
        state.select(profileID: profileID, forOutput: outputID)
        state.isEnabled = true
        commit(reason: "select \(profileID)")
    }

    /// Applies an edit to the profile in force. A built-in profile is copied first, so presets stay put.
    @discardableResult
    func edit(_ transform: (inout EqualizerProfile) -> Void) -> EqualizerProfile {
        let edited = state.edit(forOutput: outputID, copyName: EqualizerCopy.customProfileName, transform)
        state.isEnabled = true
        commit(reason: "edit \(edited.id)")
        return edited
    }

    func setRemembering(_ remember: Bool) {
        guard let outputID else { return }
        state.setRemembering(remember, forOutput: outputID)
        commit(reason: "remember \(remember)")
    }

    func bindOutputToOff(_ id: String? = nil) {
        guard let target = id ?? outputID else { return }
        state.bindOff(forOutput: target)
        commit(reason: "bind off")
    }

    func setBinding(_ profileID: String, forOutput id: String) {
        state.outputBindings[id] = profileID
        commit(reason: "binding \(id)")
    }

    /// Makes `profileID` the default for every output that keeps no profile of its own.
    func setDefaultProfile(_ profileID: String) {
        state.activeProfileID = profileID
        commit(reason: "default \(profileID)")
    }

    /// Stops an output from keeping a profile of its own.
    func forgetOutput(_ id: String) {
        state.outputBindings[id] = nil
        commit(reason: "forget \(id)")
    }

    /// The outputs that keep a profile, current one first, with the names they were last seen under.
    var rememberedOutputs: [(id: String, name: String, binding: String)] {
        state.outputBindings
            .map { (id: $0.key, name: state.outputNames[$0.key] ?? $0.key, binding: $0.value) }
            .sorted { ($0.id == outputID ? 0 : 1, $0.name) < ($1.id == outputID ? 0 : 1, $1.name) }
    }

    /// Copies the profile in force into the other kind, leaving the original
    /// untouched, and makes the copy the one in force. Switching back and forth
    /// lands on the copy already made rather than adding another to the list.
    func convertInForce(to kind: EqualizerKind) -> EqualizerProfile {
        let source = profileInForce
        guard source.kind != kind else { return source }
        var copy = source
        copy.id = UUID().uuidString
        copy.kind = kind
        switch kind {
        case .parametric:
            copy.bands = source.resolvedBands()
            copy.targets = Array(repeating: 0, count: GraphicSolver.centres.count)
        case .graphic:
            copy.targets = GraphicSolver.targets(approximating: source.resolvedBands())
            copy.bands = []
        }
        copy.name = EqualizerCopy.convertedName(base: EqualizerCopy.baseName(of: EqualizerCopy.name(of: source)), to: kind)
        if let existing = state.userProfiles.first(where: { profile in
            var probe = copy
            probe.id = profile.id
            return profile == probe
        }) {
            state.select(profileID: existing.id, forOutput: outputID)
            commit(reason: "convert \(kind.rawValue)")
            return existing
        }
        state.userProfiles.append(copy)
        state.select(profileID: copy.id, forOutput: outputID)
        commit(reason: "convert \(kind.rawValue)")
        return copy
    }

    /// Puts the saved state back exactly as it was, for undo and redo.
    func restore(_ previous: EqualizerState) {
        state = previous
        commit(reason: "restore")
    }

    func rename(profileID: String, to name: String) {
        guard let index = state.userProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        state.userProfiles[index].name = name
        commit(reason: "rename")
    }

    func delete(profileID: String) {
        state.delete(profileID: profileID)
        commit(reason: "delete")
    }

    /// Saves the profile in force under a name of the person's choosing and makes it the one in force.
    @discardableResult
    func saveInForce(as name: String) -> EqualizerProfile {
        let source = profileInForce
        var copy = source
        copy.id = UUID().uuidString
        copy.name = name
        state.userProfiles.append(copy)
        state.select(profileID: copy.id, forOutput: outputID)
        commit(reason: "save as")
        return copy
    }

    func importProfile(text: String, name: String, use: Bool) -> ImportOutcome {
        guard let parsed = EqualizerProfileText.parse(text, fallbackName: name) else { return .unreadable }
        state.userProfiles.append(parsed.profile)
        if use {
            state.select(profileID: parsed.profile.id, forOutput: outputID)
            state.isEnabled = true
        }
        commit(reason: "import")
        return .imported(parsed.profile, droppedFilters: parsed.droppedFilters)
    }

    func exportText(for profile: EqualizerProfile) -> String {
        EqualizerProfileText.write(profile)
    }

    /// Lets the person hear `profile` without choosing it. Nothing is saved and
    /// the saved state is not touched; each tap's kernel ramps to the previewed
    /// curve with its own preamp, so presets are compared at the level they
    /// would really play at, and `endAudition` puts back whatever was there,
    /// bit-perfect passthrough included.
    func beginAudition(_ profile: EqualizerProfile) {
        auditioned = profile
        publish(reason: "audition on")
    }

    func endAudition() {
        guard auditioned != nil else { return }
        auditioned = nil
        publish(reason: "audition off")
    }

    func beginCompare() {
        guard !isComparing, isRunning else { return }
        isComparing = true
        publish(reason: "compare on")
    }

    func endCompare() {
        guard isComparing else { return }
        isComparing = false
        publish(reason: "compare off")
    }

    /// Keeps a tap on the playing item while a screen draws the live spectrum.
    /// Demand is counted per screen, not per call, because a sheet whose
    /// dismissal is cancelled appears again without having disappeared.
    func beginAnalysis(for owner: AnyObject) {
        analysisOwners.insert(ObjectIdentifier(owner))
        refreshAttachments()
    }

    func endAnalysis(for owner: AnyObject) {
        analysisOwners.remove(ObjectIdentifier(owner))
        refreshAttachments()
    }

    /// The level of whatever tap is making sound right now, or nil when none is.
    func meter() -> EqualizerMeter? {
        #if DEBUG
        if isDemoSignal { return EqualizerDemoSignal.meter(time: Date.timeIntervalSinceReferenceDate) }
        #endif
        return EqualizerTapRegistry.shared.playingContext()?.meter()
    }

    /// The last window of audio as 110 log-spaced decibel bins, or nil when no tap is attached.
    func spectrum() -> [Float]? {
        #if DEBUG
        if isDemoSignal {
            let profile = auditioned ?? profileInForce
            let bands = isComparing ? [] : profile.resolvedBands()
            return EqualizerDemoSignal.spectrum(time: Date.timeIntervalSinceReferenceDate, bands: bands, preampDecibels: isComparing ? 0 : profile.preamp())
        }
        #endif
        guard let context = EqualizerTapRegistry.shared.playingContext() else { return nil }
        if spectrumAnalyzer == nil || spectrumAnalyzer?.sampleRate != context.sampleRate {
            spectrumAnalyzer = SpectrumAnalyzer(sampleRate: context.sampleRate)
        }
        let copied = spectrumScratch.withUnsafeMutableBufferPointer {
            context.copyAnalysis(into: $0.baseAddress!, count: SpectrumAnalyzer.windowSize)
        }
        guard copied, let analyzer = spectrumAnalyzer else { return nil }
        return spectrumScratch.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!) }
    }

    /// Milliseconds since any tap last rendered audio, or nil if none has yet.
    var millisecondsSinceLastRender: Double? {
        let tick = box.renderTick.pointee
        guard tick != 0 else { return nil }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time() &- tick) * Double(info.numer) / Double(info.denom) / 1_000_000
    }

    /// How many taps are prepared, for diagnostics and the exercise.
    var preparedTapCount: Int {
        EqualizerTapRegistry.shared.preparedCount
    }

    /// Called by the player for every item it builds, before or just after the item starts.
    func attach(to item: AVPlayerItem) {
        items.add(item)
        refresh(item)
    }

    private var needsTap: Bool {
        box.read().isEngaged || !analysisOwners.isEmpty
    }

    private func commit(reason: String) {
        store.save(state)
        publish(reason: reason)
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }

    private func publish(reason: String) {
        let running: EqualizerProfile?
        if let auditioned {
            running = auditioned.isFlat ? nil : auditioned
        } else {
            running = state.effectiveProfile(forOutput: outputID)
        }
        var bands: [EqualizerBand] = []
        var preamp = 0.0
        if let running {
            let resolved = running.resolvedBands()
            preamp = running.preamp(for: resolved)
            bands = isComparing ? [] : resolved
        }
        version &+= 1
        box.write(EqualizerConfig(
            version: version,
            isEngaged: running != nil,
            bands: bands,
            preampDecibels: preamp,
            peakGuard: state.isPeakGuardOn
        ))
        guard !reason.hasPrefix("edit"), !reason.hasPrefix("audition") else {
            refreshAttachments()
            return
        }
        MidgarLog.info(
            "Equalizer config v\(version) (\(reason)): engaged=\(running != nil) profile=\(running?.name ?? "none") bands=\(bands.count) preamp=\(String(format: "%.1f", preamp)) dB output=\(outputID ?? "none")",
            category: .playback
        )
        refreshAttachments()
    }

    private func outputChanged(to newOutput: EqualizerOutput?) {
        output = newOutput
        rememberName(of: newOutput)
        publish(reason: "output \(newOutput?.id ?? "none")")
        let name = state.keepsOwnProfile(forOutput: newOutput?.id) ? state.profileInForce(forOutput: newOutput?.id).name : nil
        var info: [AnyHashable: Any] = [:]
        if let name { info[Self.outputProfileKey] = name }
        NotificationCenter.default.post(name: Self.outputDidChange, object: self, userInfo: info)
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }

    private func rememberName(of output: EqualizerOutput?) {
        guard let output, state.outputNames[output.id] != output.name else { return }
        state.outputNames[output.id] = output.name
        store.save(state)
    }

    private func refreshAttachments() {
        for item in items.allObjects {
            refresh(item)
        }
    }

    private func attachment(for item: AVPlayerItem) -> Attachment {
        if let existing = attachments.object(forKey: item) { return existing }
        let created = Attachment()
        attachments.setObject(created, forKey: item)
        return created
    }

    private func refresh(_ item: AVPlayerItem) {
        let attachment = attachment(for: item)
        if needsTap {
            guard !attachment.hasMix, !attachment.isLoading else { return }
            attachment.isLoading = true
            Task { [weak self, weak item] in
                guard let item else { return }
                let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
                attachment.isLoading = false
                guard let self, self.needsTap, let track = tracks?.first else { return }
                self.installTap(on: item, track: track, attachment: attachment)
            }
        } else if attachment.hasMix {
            scheduleDetach(item, attachment: attachment)
        }
    }

    /// An item this close to its beginning is still starting, so its tap
    /// brings the curve in at once; further along, turning the equalizer on
    /// has to fade in to avoid a click.
    private static let freshItemSeconds = 0.25

    private func installTap(on item: AVPlayerItem, track: AVAssetTrack, attachment: Attachment) {
        let startsEngaged = item.currentTime().seconds < Self.freshItemSeconds
        guard !attachment.hasMix, let tap = EqualizerTapFactory.makeTap(box: box, startsEngaged: startsEngaged) else {
            if !attachment.hasMix { MidgarLog.notice("Equalizer tap could not be created", category: .playback) }
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        attachment.hasMix = true
        MidgarLog.info("Equalizer tap attached to \((item.asset as? AVURLAsset)?.url.lastPathComponent ?? "item")", category: .playback)
    }

    private func scheduleDetach(_ item: AVPlayerItem, attachment: Attachment) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak item] in
            guard let self, let item, !self.needsTap, attachment.hasMix else { return }
            item.audioMix = nil
            attachment.hasMix = false
            MidgarLog.info("Equalizer tap detached", category: .playback)
        }
    }

    #if DEBUG
    var isDemoSignal = false

    /// Fills the saved state with a fictional listening history for screenshots and the debug drive.
    func seedDemo(activeProfileID: String = "demo.warm", pretendOutput: EqualizerOutput? = nil) {
        let warm = EqualizerProfile.parametric(
            id: "demo.warm",
            name: "Warm Detail",
            bands: [
                EqualizerBand(type: .highPass, frequency: 28, q: 0.71),
                EqualizerBand(type: .lowShelf, frequency: 95, gain: 3.5, q: 0.71),
                EqualizerBand(type: .bell, frequency: 260, gain: -2.2, q: 1.1),
                EqualizerBand(type: .bell, frequency: 3_300, gain: 2.6, q: 1.4),
                EqualizerBand(type: .bell, frequency: 6_800, gain: -3.2, q: 4.2),
                EqualizerBand(type: .highShelf, frequency: 11_500, gain: 2.4, q: 0.71),
            ]
        )
        let bass = EqualizerProfile.graphic(id: "demo.bass", name: "My Bass Boost", targets: [7, 6, 4, 2, 0, 0, 0, 0, 0, 0])
        var demo = EqualizerState(isEnabled: true, activeProfileID: activeProfileID, userProfiles: [warm, bass])
        demo.outputNames = [
            "bluetooth.demo": "AirPods Pro",
            "builtin.speaker": "iPhone Speaker",
            "usb.demo": "Studio DAC",
            "car.demo": "Car",
        ]
        demo.outputBindings = [
            "bluetooth.demo": "demo.warm",
            "builtin.speaker": EqualizerPresets.id(forKey: "loudness"),
            "usb.demo": EqualizerState.offBinding,
            "car.demo": EqualizerPresets.id(forKey: "bassBoost"),
        ]
        state = demo
        if let pretendOutput { output = pretendOutput }
        commit(reason: "demo seed")
    }
    #endif
}
