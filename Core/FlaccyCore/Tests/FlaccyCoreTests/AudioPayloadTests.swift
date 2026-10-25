import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/audio_payload.rs`: same bytes,
/// same locations.
final class AudioPayloadTests: XCTestCase {

    private func locate(_ bytes: [UInt8]) -> AudioPayload.Location {
        AudioPayload.locate(fileSize: Int64(bytes.count)) { offset, length in
            let start = min(Int(offset), bytes.count)
            let end = min(start + length, bytes.count)
            return Array(bytes[start..<end])
        }
    }

    private func join(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }

    private func ascii(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func zeros(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: count)
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        Array(le32(value).reversed())
    }

    private func be64(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private var streamInfo: [UInt8] {
        (0..<18).map { UInt8($0) } + (0x10...0x1F).map { UInt8($0) }
    }

    private var flacMD5Block: [UInt8] {
        join(ascii("fLaC"), [0x80, 0, 0, 34], streamInfo, zeros(10))
    }

    func testFlacMD5() {
        XCTAssertEqual(locate(flacMD5Block), .flacMD5("101112131415161718191a1b1c1d1e1f"))
    }

    func testFlacZeroMD5() {
        let bytes = join(
            ascii("fLaC"), [0x00, 0, 0, 34], zeros(34),
            [0x84, 0, 0, 3], ascii("abc"), zeros(5)
        )

        XCTAssertEqual(locate(bytes), .ranges([49..<54]))
    }

    func testFlacAfterID3() {
        let bytes = join(ascii("ID3"), [3, 0, 0], [0, 0, 0, 6], zeros(6), flacMD5Block)

        XCTAssertEqual(locate(bytes), .flacMD5("101112131415161718191a1b1c1d1e1f"))
    }

    func testWavDataChunk() {
        let bytes = join(
            ascii("RIFF"), le32(0), ascii("WAVE"),
            ascii("fmt "), le32(16), zeros(16),
            ascii("LIST"), le32(5), zeros(5), [0],
            ascii("data"), le32(8), zeros(8)
        )

        XCTAssertEqual(locate(bytes), .ranges([58..<66]))
    }

    func testAiffSSND() {
        let bytes = join(
            ascii("FORM"), be32(0), ascii("AIFF"),
            ascii("COMM"), be32(18), zeros(18),
            ascii("SSND"), be32(12), zeros(12)
        )

        XCTAssertEqual(locate(bytes), .ranges([46..<58]))
    }

    func testMp4Mdat() {
        let bytes = join(
            be32(16), ascii("ftyp"), zeros(8),
            be32(12), ascii("moov"), zeros(4),
            be32(20), ascii("mdat"), zeros(12)
        )

        XCTAssertEqual(locate(bytes), .ranges([36..<48]))
    }

    func testMp4Largesize() {
        let bytes = join(
            be32(16), ascii("ftyp"), zeros(8),
            be32(1), ascii("mdat"), be64(28), zeros(12)
        )

        XCTAssertEqual(locate(bytes), .ranges([32..<44]))
    }

    func testMp3ID3AndV1() {
        let bytes = join(
            ascii("ID3"), [3, 0, 0], [0, 0, 0, 4], zeros(4),
            [0xFF, 0xFB], zeros(6),
            ascii("TAG"), zeros(125)
        )

        XCTAssertEqual(bytes.count, 150)
        XCTAssertEqual(locate(bytes), .ranges([14..<22]))
    }

    func testMp3APEAndV1() {
        let bytes = join(
            [0xFF, 0xFB], zeros(6),
            zeros(10),
            ascii("APETAGEX"), le32(2000), le32(42), le32(1), le32(0), zeros(8),
            ascii("TAG"), zeros(125)
        )

        XCTAssertEqual(locate(bytes), .ranges([0..<8]))
    }

    func testUnknown() {
        XCTAssertEqual(locate(ascii("hello world")), .ranges([0..<11]))
    }

    func testFlacTruncated() {
        let bytes = join(ascii("fLaC"), [0x80, 0, 0, 34], zeros(10))

        XCTAssertEqual(locate(bytes), .ranges([0..<18]))
    }

    func testWavWithoutData() {
        let bytes = join(ascii("RIFF"), le32(0), ascii("WAVE"), ascii("fmt "), le32(4), zeros(4))

        XCTAssertEqual(locate(bytes), .ranges([0..<24]))
    }

    func testEmpty() {
        XCTAssertEqual(locate([]), .ranges([]))
    }

    func testID3HeaderCutShortIsTheWholeFile() {
        let bytes = join(ascii("ID3"), [3, 0])

        XCTAssertEqual(locate(bytes), .ranges([0..<5]))
    }

    func testMp4TruncatedBoxKeepsTheMdatFoundBeforeIt() {
        let bytes = join(
            be32(16), ascii("ftyp"), zeros(8),
            be32(12), ascii("mdat"), zeros(4),
            [0, 0, 0]
        )

        XCTAssertEqual(locate(bytes), .ranges([24..<28]))
    }

    func testMp4TruncatedBoxWithoutMdatIsTheWholeFile() {
        let bytes = join(be32(16), ascii("ftyp"), zeros(8), [0, 0, 0])

        XCTAssertEqual(locate(bytes), .ranges([0..<19]))
    }
}
