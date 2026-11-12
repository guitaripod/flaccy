import Foundation
import MidgarCore

/// What a support email carries besides the person's own words: a line naming the build and the
/// system under the space they write in, and the log with the latest crash reports attached,
/// which the draft shows and lets them remove before sending.
nonisolated enum SupportReport {

    static let subject = "Flaccy"

    private static let attachedCrashReports = 3

    static var body: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "\n\n\n—\nFlaccy \(version) (\(build)) · \(system) · \(deviceModel)"
    }

    /// The log files, newest first, then the latest crash reports, after writing out every line
    /// logged so far.
    static func attachments() -> [URL] {
        MidgarLog.flush()
        return MidgarLog.logFileURLs + CrashReportRecorder.reportURLs.prefix(attachedCrashReports)
    }

    /// The hardware model identifier, such as `iPhone17,3` or `Mac16,1`.
    private static var deviceModel: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}
