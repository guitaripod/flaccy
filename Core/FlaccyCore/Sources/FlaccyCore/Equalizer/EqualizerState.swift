import Foundation

/// Everything the equalizer remembers between launches: the master switch, the
/// profile used by default, the person's own profiles, and which output keeps
/// which profile. Pure value logic so the Apple clients and Linux decide the
/// same way; mirrored in Rust as `linux/shared/src/equalizer/state.rs`.
public struct EqualizerState: Codable, Equatable, Sendable {

    public static let schemaVersion = 1
    public static let offBinding = "off"

    public var schemaVersion: Int
    public var isEnabled: Bool
    public var activeProfileID: String
    public var isPeakGuardOn: Bool
    public var userProfiles: [EqualizerProfile]
    public var outputBindings: [String: String]
    public var outputNames: [String: String]

    public init(
        isEnabled: Bool = false,
        activeProfileID: String = EqualizerProfile.flatID,
        isPeakGuardOn: Bool = true,
        userProfiles: [EqualizerProfile] = [],
        outputBindings: [String: String] = [:],
        outputNames: [String: String] = [:]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.isEnabled = isEnabled
        self.activeProfileID = activeProfileID
        self.isPeakGuardOn = isPeakGuardOn
        self.userProfiles = userProfiles
        self.outputBindings = outputBindings
        self.outputNames = outputNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID) ?? EqualizerProfile.flatID
        isPeakGuardOn = try container.decodeIfPresent(Bool.self, forKey: .isPeakGuardOn) ?? true
        userProfiles = try container.decodeIfPresent([EqualizerProfile].self, forKey: .userProfiles) ?? []
        outputBindings = try container.decodeIfPresent([String: String].self, forKey: .outputBindings) ?? [:]
        outputNames = try container.decodeIfPresent([String: String].self, forKey: .outputNames) ?? [:]
    }

    public func profile(withID id: String) -> EqualizerProfile? {
        EqualizerPresets.profile(forID: id) ?? userProfiles.first { $0.id == id }
    }

    /// The profile in force for `outputID`: the output's own when it keeps one,
    /// otherwise the default. Never nil, because an unknown id falls back to Flat.
    public func profileInForce(forOutput outputID: String?) -> EqualizerProfile {
        profile(withID: boundProfileID(forOutput: outputID) ?? activeProfileID) ?? EqualizerPresets.flat
    }

    /// The stage to run for `outputID`, or nil when audio should pass untouched:
    /// the master switch is off, the output is bound to Off, or the profile is flat.
    public func effectiveProfile(forOutput outputID: String?) -> EqualizerProfile? {
        guard isEnabled else { return nil }
        if boundProfileID(forOutput: outputID) == Self.offBinding { return nil }
        let profile = profileInForce(forOutput: outputID)
        return profile.isFlat ? nil : profile
    }

    /// True when the output has a binding of its own, including a binding to Off.
    public func keepsOwnProfile(forOutput outputID: String?) -> Bool {
        outputID.flatMap { outputBindings[$0] } != nil
    }

    private func boundProfileID(forOutput outputID: String?) -> String? {
        outputID.flatMap { outputBindings[$0] }
    }

    /// Chooses `profileID` for `outputID`: the output's own binding when it
    /// has one, the default otherwise.
    public mutating func select(profileID: String, forOutput outputID: String?) {
        if keepsOwnProfile(forOutput: outputID), let outputID {
            outputBindings[outputID] = profileID
        } else {
            activeProfileID = profileID
        }
    }

    /// Makes the output remember the profile now in force, or forget it.
    public mutating func setRemembering(_ remember: Bool, forOutput outputID: String) {
        if remember {
            outputBindings[outputID] = profileInForce(forOutput: outputID).id
        } else {
            outputBindings[outputID] = nil
        }
    }

    public mutating func bindOff(forOutput outputID: String) {
        outputBindings[outputID] = Self.offBinding
    }

    /// Applies an edit to the profile in force. A built-in profile is never
    /// changed in place: the edit lands in a copy called `copyName`, which
    /// becomes the profile in force. Returns the profile that now holds the edit.
    @discardableResult
    public mutating func edit(
        forOutput outputID: String?,
        copyName: String,
        _ transform: (inout EqualizerProfile) -> Void
    ) -> EqualizerProfile {
        var profile = profileInForce(forOutput: outputID)
        if profile.isBuiltIn {
            profile = EqualizerProfile(
                name: copyName,
                kind: profile.kind,
                targets: profile.targets,
                bands: profile.kind == .graphic ? [] : profile.bands,
                isAutoPreamp: profile.isAutoPreamp,
                manualPreamp: profile.manualPreamp
            )
            transform(&profile)
            userProfiles.append(profile)
        } else {
            transform(&profile)
            if let index = userProfiles.firstIndex(where: { $0.id == profile.id }) {
                userProfiles[index] = profile
            } else {
                userProfiles.append(profile)
            }
        }
        select(profileID: profile.id, forOutput: outputID)
        return profile
    }

    /// Removes a user profile and every binding or default that pointed at it.
    public mutating func delete(profileID: String) {
        userProfiles.removeAll { $0.id == profileID }
        if activeProfileID == profileID { activeProfileID = EqualizerProfile.flatID }
        for (output, bound) in outputBindings where bound == profileID {
            outputBindings[output] = EqualizerProfile.flatID
        }
    }
}
