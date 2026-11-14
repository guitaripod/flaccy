import FlaccyCore
import Foundation
import Testing
@testable import flaccy

@MainActor
struct EqualizerDescribeTests {

    @Test func aBandIsNamedByItsKindItsFrequencyAndItsGain() {
        #expect(EqualizerDescribeCopy.bandTitle(EqualizerBand(type: .lowShelf, frequency: 90, gain: 3)) == "Low shelf · 90 Hz · +3.0 dB")
        #expect(EqualizerDescribeCopy.bandTitle(EqualizerBand(type: .bell, frequency: 3300, gain: -2.5, q: 1.2)) == "Bell · 3.3 kHz · \u{2212}2.5 dB")
    }

    @Test func aPassFilterIsNamedWithoutAGain() {
        #expect(EqualizerDescribeCopy.bandTitle(EqualizerBand(type: .highPass, frequency: 28)) == "High-pass · 28 Hz")
        #expect(EqualizerDescribeCopy.bandTitle(EqualizerBand(type: .lowPass, frequency: 9000)) == "Low-pass · 9 kHz")
    }

    @Test func aSentenceThatDescribedNoSoundShowsTheReplysOwnNoteOrTheAppsSentence() {
        #expect(EqualizerDescribeCopy.failure(.nothingToShape(note: "An equalizer cannot do that.")) == "An equalizer cannot do that.")
        #expect(EqualizerDescribeCopy.failure(.nothingToShape(note: "")) == "That didn't describe a sound an equalizer can shape. Say how you want the music to sound.")
    }

    @Test func onlyASentenceThatDescribedNoSoundInvitesAnother() {
        #expect(EqualizerDescriptionFailure.nothingToShape(note: "").invitesAnotherSentence)
        for failure in [EqualizerDescriptionFailure.needsEntitlement, .unreachable, .unavailable, .quotaReached(resetsAt: Date())] {
            #expect(!failure.invitesAnotherSentence)
        }
    }

    @Test func theLineUnderTheSwitchSaysWhatIsHeardAndThatNothingIsKept() {
        #expect(EqualizerDescribeCopy.hearing(isPlaying: false, isHearing: true) == "Play a song to hear this curve before you keep it.")
        #expect(EqualizerDescribeCopy.hearing(isPlaying: true, isHearing: true) == "You are hearing this curve. Nothing is saved until you add it.")
        #expect(EqualizerDescribeCopy.hearing(isPlaying: true, isHearing: false) == "You are hearing your music as it was. Nothing is saved until you add it.")
    }

    @Test func aKeptCurveTakesANameNoOtherCarries() {
        #expect(EqualizerEngine.freeName("Warm Evening", taken: []) == "Warm Evening")
        #expect(EqualizerEngine.freeName("Warm Evening", taken: ["Warm Evening"]) == "Warm Evening 2")
        #expect(EqualizerEngine.freeName("Warm Evening", taken: ["Warm Evening", "Warm Evening 2", "Other"]) == "Warm Evening 3")
    }
}
