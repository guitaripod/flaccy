import Foundation

/// Synthesizes a few short royalty-free tone tracks into Documents so the watch
/// app is demonstrable on the Simulator. Compiled only for the Simulator
/// (`#if targetEnvironment(simulator)`); real devices rely on side-loaded music.
enum SampleContent {

    private struct Demo {
        let folder: String
        let file: String
        let frequency: Double
        let seconds: Double
    }

    private static let tracks: [Demo] = [
        Demo(folder: "Demo Artist/Neon Nights", file: "01 - Sunrise", frequency: 261.63, seconds: 6),
        Demo(folder: "Demo Artist/Neon Nights", file: "02 - Midnight Drive", frequency: 329.63, seconds: 6),
        Demo(folder: "Demo Artist/Neon Nights", file: "03 - Afterglow", frequency: 392.00, seconds: 6),
        Demo(folder: "Aurora/Glacier", file: "01 - Drift", frequency: 220.00, seconds: 5),
        Demo(folder: "Aurora/Glacier", file: "02 - Tides", frequency: 277.18, seconds: 5),
    ]

    static func seedIfNeeded(in documentsDirectory: URL) async {
        let fileManager = FileManager.default
        let marker = documentsDirectory.appendingPathComponent("Demo Artist")
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        for track in tracks { write(track, in: documentsDirectory, fileManager: fileManager) }
    }

    private static func write(_ track: Demo, in documentsDirectory: URL, fileManager: FileManager) {
        let folderURL = documentsDirectory.appendingPathComponent(track.folder, isDirectory: true)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("\(track.file).wav")
        let data = makeWAV(frequency: track.frequency, seconds: track.seconds)
        try? data.write(to: fileURL)
    }

    private static func makeWAV(frequency: Double, seconds: Double, sampleRate: Double = 22_050) -> Data {
        let frameCount = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)
        let amplitude = 0.25 * Double(Int16.max)
        let fade = Int(sampleRate * 0.05)

        for index in 0..<frameCount {
            let theta = 2.0 * Double.pi * frequency * Double(index) / sampleRate
            var value = sin(theta) * amplitude
            if index < fade { value *= Double(index) / Double(fade) }
            if index > frameCount - fade { value *= Double(frameCount - index) / Double(fade) }
            samples[index] = Int16(value)
        }

        let byteRate = Int(sampleRate) * 2
        let dataBytes = samples.withUnsafeBytes { Data($0) }
        var wav = Data()

        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) { var v = value.littleEndian; wav.append(Data(bytes: &v, count: 4)) }
        func appendUInt16(_ value: UInt16) { var v = value.littleEndian; wav.append(Data(bytes: &v, count: 2)) }

        append("RIFF")
        appendUInt32(UInt32(36 + dataBytes.count))
        append("WAVE")
        append("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2)
        appendUInt16(16)
        append("data")
        appendUInt32(UInt32(dataBytes.count))
        wav.append(dataBytes)
        return wav
    }
}
