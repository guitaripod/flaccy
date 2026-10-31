import Foundation

/// What the scan journal left by an earlier run says about the files it was
/// reading when that run ended.
///
/// A scan writes `R` before it reads a file among others, `S` before it reads
/// one on its own, and `D` once a read is done, and removes the journal when
/// the scan completes. A journal still there at the next scan means the app
/// stopped mid-scan: every file begun and never done is a suspect, and a file
/// begun on its own and never done is the one that stopped it. Suspects are
/// read again one at a time, so a crash names its file instead of taking seven
/// innocent neighbours with it; a file that crashed alone is never read again
/// until the person asks for a rescan.
public struct ScanJournalReplay: Sendable, Equatable {

    public static let readingMark: Character = "R"
    public static let aloneMark: Character = "S"
    public static let doneMark: Character = "D"

    public private(set) var suspects: Set<String> = []
    public private(set) var crashedAlone: Set<String> = []

    public init(journal: String) {
        var open: [String: Character] = [:]
        for line in journal.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 2, let mark = line.first, line.dropFirst().first == "\t" else { continue }
            let path = String(line.dropFirst(2))
            switch mark {
            case Self.readingMark, Self.aloneMark: open[path] = mark
            case Self.doneMark: open[path] = nil
            default: continue
            }
        }
        for (path, mark) in open {
            if mark == Self.aloneMark {
                crashedAlone.insert(path)
            } else {
                suspects.insert(path)
            }
        }
    }

    public static func line(_ mark: Character, path: String) -> String {
        "\(mark)\t\(path)\n"
    }
}
