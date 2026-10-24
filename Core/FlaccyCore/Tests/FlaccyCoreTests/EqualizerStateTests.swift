import XCTest
@testable import FlaccyCore

/// Mirrored by `linux/shared/src/equalizer/state.rs`.
final class EqualizerStateTests: XCTestCase {

    func testAFreshStateRunsNoStage() {
        let state = EqualizerState()

        XCTAssertNil(state.effectiveProfile(forOutput: "speakers"))
        XCTAssertEqual(state.profileInForce(forOutput: "speakers").id, EqualizerProfile.flatID)
    }

    func testTheMasterSwitchOverridesEverything() {
        var state = EqualizerState(isEnabled: false, activeProfileID: EqualizerPresets.id(forKey: "rock"))
        state.outputBindings["pods"] = EqualizerPresets.id(forKey: "jazz")

        XCTAssertNil(state.effectiveProfile(forOutput: "pods"))
        XCTAssertNil(state.effectiveProfile(forOutput: nil))
    }

    func testAnOutputUsesItsOwnProfileAndOthersUseTheDefault() {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "rock"))
        state.outputBindings["pods"] = EqualizerPresets.id(forKey: "jazz")

        XCTAssertEqual(state.effectiveProfile(forOutput: "pods")?.name, "Jazz")
        XCTAssertEqual(state.effectiveProfile(forOutput: "speakers")?.name, "Rock")
        XCTAssertEqual(state.effectiveProfile(forOutput: nil)?.name, "Rock")
    }

    func testAnOutputBoundToOffPassesAudioUntouched() {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "rock"))
        state.bindOff(forOutput: "dac")

        XCTAssertNil(state.effectiveProfile(forOutput: "dac"))
        XCTAssertNotNil(state.effectiveProfile(forOutput: "speakers"))
        XCTAssertTrue(state.keepsOwnProfile(forOutput: "dac"))
    }

    func testAFlatProfileRunsNoStage() {
        let state = EqualizerState(isEnabled: true, activeProfileID: EqualizerProfile.flatID)

        XCTAssertNil(state.effectiveProfile(forOutput: "speakers"))
    }

    func testSelectingChangesTheDefaultUnlessTheOutputRemembersItsOwn() {
        var state = EqualizerState(isEnabled: true)

        state.select(profileID: EqualizerPresets.id(forKey: "pop"), forOutput: "speakers")
        XCTAssertEqual(state.activeProfileID, EqualizerPresets.id(forKey: "pop"))
        XCTAssertTrue(state.outputBindings.isEmpty)

        state.setRemembering(true, forOutput: "pods")
        state.select(profileID: EqualizerPresets.id(forKey: "jazz"), forOutput: "pods")
        XCTAssertEqual(state.outputBindings["pods"], EqualizerPresets.id(forKey: "jazz"))
        XCTAssertEqual(state.activeProfileID, EqualizerPresets.id(forKey: "pop"))
    }

    func testRememberingBindsTheProfileNowInForceAndForgettingRemovesIt() {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "rock"))

        state.setRemembering(true, forOutput: "pods")
        XCTAssertEqual(state.outputBindings["pods"], EqualizerPresets.id(forKey: "rock"))

        state.setRemembering(false, forOutput: "pods")
        XCTAssertNil(state.outputBindings["pods"])
    }

    func testEditingABuiltInProfileMakesACopyAndLeavesTheOriginalAlone() {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "bassBoost"))

        let edited = state.edit(forOutput: nil, copyName: "Custom") { $0.targets[0] = 9 }

        XCTAssertFalse(edited.isBuiltIn)
        XCTAssertEqual(edited.name, "Custom")
        XCTAssertEqual(edited.targets[0], 9)
        XCTAssertEqual(state.activeProfileID, edited.id)
        XCTAssertEqual(state.userProfiles.count, 1)
        XCTAssertEqual(EqualizerPresets.profile(forKey: "bassBoost")?.targets[0], 6)
    }

    func testEditingAUserProfileChangesItInPlace() {
        var state = EqualizerState(isEnabled: true)
        let first = state.edit(forOutput: nil, copyName: "Custom") { $0.targets[2] = 3 }

        let second = state.edit(forOutput: nil, copyName: "Custom") { $0.targets[2] = 5 }

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(state.userProfiles.count, 1)
        XCTAssertEqual(state.userProfiles[0].targets[2], 5)
    }

    func testEditingAnOutputsRememberedProfileKeepsTheBinding() {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "rock"))
        state.setRemembering(true, forOutput: "pods")

        let edited = state.edit(forOutput: "pods", copyName: "Custom") { $0.targets[1] = 7 }

        XCTAssertEqual(state.outputBindings["pods"], edited.id)
        XCTAssertEqual(state.activeProfileID, EqualizerPresets.id(forKey: "rock"))
    }

    func testDeletingAProfileSendsItsUsersBackToFlat() {
        var state = EqualizerState(isEnabled: true)
        let mine = state.edit(forOutput: nil, copyName: "Mine") { $0.targets[0] = 4 }
        state.outputBindings["pods"] = mine.id

        state.delete(profileID: mine.id)

        XCTAssertTrue(state.userProfiles.isEmpty)
        XCTAssertEqual(state.activeProfileID, EqualizerProfile.flatID)
        XCTAssertEqual(state.outputBindings["pods"], EqualizerProfile.flatID)
    }

    func testTheStateSurvivesAJSONRoundTrip() throws {
        var state = EqualizerState(isEnabled: true, activeProfileID: EqualizerPresets.id(forKey: "jazz"))
        state.edit(forOutput: nil, copyName: "Custom") { $0.targets[4] = -3 }
        state.bindOff(forOutput: "dac")

        let decoded = try JSONDecoder().decode(EqualizerState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.schemaVersion, EqualizerState.schemaVersion)
    }
}
