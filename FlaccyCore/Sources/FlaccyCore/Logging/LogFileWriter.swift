import Foundation

/// Append-only, size-rotated file logger living in `Library/Logs`.
///
/// An agent cannot attach Xcode or Console to a phone or a watch, so the app must
/// persist its own diagnostics where `devicectl` / a container dump can retrieve them.
/// Writes are serialized on a utility queue; the current file rotates to a single
/// previous file once it exceeds `maxBytes`.
public final class LogFileWriter: @unchecked Sendable {

    public static let shared = LogFileWriter()

    private let queue = DispatchQueue(label: "com.midgarcorp.flaccy.logwriter", qos: .utility)
    private let maxBytes: UInt64
    private let baseName: String
    private let logsDirectory: URL
    private var handle: FileHandle?

    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(baseName: String = "flaccy", maxBytes: UInt64 = 1_048_576) {
        self.baseName = baseName
        self.maxBytes = maxBytes
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        self.logsDirectory = library.appendingPathComponent("Logs", isDirectory: true)
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            openHandle()
        }
    }

    public var currentLogURL: URL { logsDirectory.appendingPathComponent("\(baseName).log") }
    public var previousLogURL: URL { logsDirectory.appendingPathComponent("\(baseName).prev.log") }

    public func write(level: String, category: String, message: String) {
        let stamped = "\(timestampFormatter.string(from: Date())) [\(level)] [\(category)] \(message)"
        queue.async { [self] in
            rotateIfNeeded()
            if handle == nil { openHandle() }
            guard let data = (stamped + "\n").data(using: .utf8) else { return }
            handle?.seekToEndOfFile()
            handle?.write(data)
        }
    }

    /// Synchronously returns current + previous log contents, newest file last.
    /// Intended for in-app "export logs" diagnostics.
    public func dump() -> String {
        queue.sync {
            let previous = (try? String(contentsOf: previousLogURL, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: currentLogURL, encoding: .utf8)) ?? ""
            return previous + current
        }
    }

    private func openHandle() {
        let path = currentLogURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: currentLogURL)
        handle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxBytes
        else { return }

        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousLogURL)
        try? FileManager.default.moveItem(at: currentLogURL, to: previousLogURL)
        openHandle()
    }
}
