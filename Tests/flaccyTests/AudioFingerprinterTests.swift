import XCTest
@testable import flaccy

nonisolated final class AudioFingerprinterTests: XCTestCase {

    private var created: [URL] = []

    override func tearDown() {
        created.forEach { try? FileManager.default.removeItem(at: $0) }
        created.removeAll()
        super.tearDown()
    }

    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprinter-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        created.append(url)
        return url
    }

    private func flacHeader(md5: [UInt8]) -> [UInt8] {
        var info = [UInt8](repeating: 0, count: 34)
        info.replaceSubrange(18..<34, with: md5)
        return Array("fLaC".utf8) + [0x80, 0, 0, 34] + info + [UInt8](repeating: 0, count: 64)
    }

    private func waveFile(payload: Int) -> [UInt8] {
        let size = UInt32(payload)
        let littleEndian = { (value: UInt32) in (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
        return Array("RIFF".utf8) + littleEndian(size + 12) + Array("WAVEdata".utf8) + littleEndian(size)
            + [UInt8](repeating: 3, count: payload)
    }

    func testAFlacWithAnMD5IsFingerprintedWithoutReadingItsAudio() throws {
        let url = try file(flacHeader(md5: [UInt8](repeating: 7, count: 16)))
        XCTAssertEqual(AudioFingerprinter.quickFingerprint(of: url), "flac:07070707070707070707070707070707")
        XCTAssertEqual(AudioFingerprinter.quickFingerprint(of: url), AudioFingerprinter.fingerprint(of: url))
    }

    func testAFlacWhoseEncoderLeftTheMD5EmptyIsLeftForTheRevisionPass() throws {
        let url = try file(flacHeader(md5: [UInt8](repeating: 0, count: 16)))
        XCTAssertNil(AudioFingerprinter.quickFingerprint(of: url))
        XCTAssertNotNil(AudioFingerprinter.fingerprint(of: url))
    }

    func testEveryOtherFormatIsLeftForTheRevisionPass() throws {
        let wave = try file(waveFile(payload: 2_000))
        XCTAssertNil(AudioFingerprinter.quickFingerprint(of: wave))
        XCTAssertTrue(AudioFingerprinter.fingerprint(of: wave)?.hasPrefix("sha256:") == true)
        XCTAssertNil(AudioFingerprinter.quickFingerprint(of: try file(Array("not audio at all".utf8))))
    }

    func testAMissingFileHasNoFingerprint() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        XCTAssertNil(AudioFingerprinter.quickFingerprint(of: missing))
    }
}
