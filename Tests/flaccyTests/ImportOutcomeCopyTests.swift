import Foundation
import Testing
@testable import flaccy

/// The English sentences, mirrored word for word by `import_plan::report` in `linux/shared` apart from the formats
/// Linux plays and how it says to unpack a zip.
@MainActor
struct ImportOutcomeCopyTests {

    private func outcome(
        imported: Int = 0, skipped: Int = 0, failed: Int = 0, replaced: Int = 0,
        unplayable: [String: Int] = [:], archives: Int = 0, stopped: Int = 0, lyrics: Int = 0
    ) -> LibraryImportOutcome {
        LibraryImportOutcome(
            imported: imported, skipped: skipped, failed: failed, replaced: replaced,
            unplayable: unplayable, archives: archives, stopped: stopped, lyrics: lyrics
        )
    }

    @Test func aPickOfOnlyLyricsSaysTheyWereAdded() {
        let report = ImportOutcomeCopy.report(outcome(lyrics: 3))
        #expect(report.message == "Added 3 lyrics files")
        #expect(!report.isDeadEnd && !report.isNoOp)
        #expect(ImportOutcomeCopy.report(outcome(unplayable: ["ogg": 2], lyrics: 1)).message
            == "Added 1 lyrics file · 2 OGG files weren't added: Flaccy can't play them.")
    }

    @Test func aFailureBesideReplacementsCountsTheFailuresAlone() {
        let report = ImportOutcomeCopy.report(outcome(skipped: 1, failed: 1, replaced: 2))
        #expect(report.message == "1 failed to copy · 2 songs replaced with newer versions")
        #expect(report.isFailure)
    }

    @Test func aPickWithNoMusicSaysWhatFlaccyAdds() {
        let report = ImportOutcomeCopy.report(.empty)
        #expect(report.message == "No music found there. Flaccy adds FLAC, ALAC, MP3, AAC, WAV and AIFF files.")
        #expect(report.isDeadEnd && report.isNoOp && !report.isFailure)
    }

    @Test func aPickInFormatsFlaccyCannotPlayNamesThem() {
        #expect(ImportOutcomeCopy.report(outcome(unplayable: ["ogg": 1])).message
            == "Flaccy can't play OGG files, so this one wasn't added.")
        let several = ImportOutcomeCopy.report(outcome(unplayable: ["wv": 2, "ape": 3, "dsf": 9]))
        #expect(several.message == "Flaccy can't play APE, DSF, or WV files, so these 14 weren't added.")
        #expect(several.isDeadEnd)
    }

    @Test func musicInsideAZipSaysToUnzipItInFiles() {
        #expect(ImportOutcomeCopy.report(outcome(archives: 1)).message
            == "The music there is in a zip archive. Tap it in the Files app to unzip it, then add the folder it makes.")
        #expect(ImportOutcomeCopy.report(outcome(archives: 3)).message
            == "The music there is in 3 zip archives. Tap each in the Files app to unzip it, then add the folders they make.")
        #expect(ImportOutcomeCopy.report(outcome(unplayable: ["wma": 2], archives: 1)).message
            == "Flaccy can't play WMA files, so these 2 weren't added. · 1 zip archive wasn't opened: unzip it first.")
    }

    @Test func whatWasPassedOverFollowsWhatCameIn() {
        let report = ImportOutcomeCopy.report(outcome(imported: 12, unplayable: ["ape": 1, "wv": 3], archives: 2))
        #expect(report.message
            == "Imported 12 items · 4 APE and WV files weren't added: Flaccy can't play them. · 2 zip archives weren't opened: unzip them first.")
        #expect(!report.isDeadEnd && !report.isNoOp)
        #expect(ImportOutcomeCopy.report(outcome(skipped: 1, unplayable: ["wma": 1])).message
            == "Already in your library. · 1 WMA file wasn't added: Flaccy can't play it.")
    }

    @Test func songsAlreadyThereOrFailedAreNotADeadEnd() {
        #expect(!ImportOutcomeCopy.report(outcome(skipped: 4)).isDeadEnd)
        #expect(!ImportOutcomeCopy.report(outcome(failed: 2)).isDeadEnd)
        #expect(!ImportOutcomeCopy.report(
            LibraryImportOutcome(imported: 0, skipped: 0, failed: 0, shortfall: StorageShortfall(needed: 10, available: 1))
        ).isDeadEnd)
    }

    @Test func replacedSongsAndAStoppedImportAreJoinedLikeLinux() {
        #expect(ImportOutcomeCopy.report(outcome(imported: 3, replaced: 2)).message
            == "Imported 3 items · 2 songs replaced with newer versions")
        let stopped = ImportOutcomeCopy.report(outcome(imported: 12, stopped: 28))
        #expect(stopped.message == "Imported 12 items · Stopped with 28 songs left. Add the same songs again to finish.")
        #expect(!stopped.isNoOp && !stopped.isDeadEnd)
        let stoppedEarly = ImportOutcomeCopy.report(outcome(stopped: 1))
        #expect(stoppedEarly.message == "Stopped with 1 song left. Add the same songs again to finish.")
        #expect(stoppedEarly.isNoOp && !stoppedEarly.isFailure && !stoppedEarly.isDeadEnd)
    }
}
