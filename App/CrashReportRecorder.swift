import FlaccyCore
import Foundation
import MetricKit
import MidgarCore

/// Keeps the crash and hang reports MetricKit hands the app: one summary line in the log for each,
/// with the exception UIKit raised when there was one, and the full report saved beside the log.
/// Nothing leaves the device unless the person sends it with Contact Support.
nonisolated final class CrashReportRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = CrashReportRecorder()

    private static let keptReports = 10
    private static let folderName = "Diagnostics"

    /// Subscribes once at launch; MetricKit delivers the reports of earlier runs on a later launch.
    func start() {
        MXMetricManager.shared.add(self)
    }

    /// The saved reports, newest first.
    static var reportURLs: [URL] {
        guard let folder else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { record(payload) }
    }

    private func record(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics ?? []
        let hangs = payload.hangDiagnostics ?? []
        for crash in crashes {
            MidgarLog.fault("Crash report: \(Self.summary(of: crash))", category: .general)
        }
        for hang in hangs {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            MidgarLog.error("Hang report: \(String(format: "%.1f", seconds)) s in build \(hang.metaData.applicationBuildVersion)", category: .general)
        }
        guard !crashes.isEmpty || !hangs.isEmpty else { return }
        Self.save(payload.jsonRepresentation(), endingAt: payload.timeStampEnd)
    }

    /// The build, system, signal and, for an Objective-C exception such as a list holding one
    /// identifier twice, its name and message.
    static func summary(of crash: MXCrashDiagnostic) -> String {
        let meta = crash.metaData
        var parts = ["build \(meta.applicationBuildVersion)", meta.osVersion, meta.deviceType]
        if let type = crash.exceptionType { parts.append("exception type \(type)") }
        if let code = crash.exceptionCode { parts.append("code \(code)") }
        if let signal = crash.signal { parts.append("signal \(signal)") }
        if let reason = crash.terminationReason { parts.append(reason) }
        if let exception = crash.exceptionReason {
            parts.append("\(exception.exceptionName): \(exception.composedMessage)")
        }
        return parts.joined(separator: ", ")
    }

    private static var folder: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func save(_ report: Data, endingAt end: Date) {
        guard let folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = end.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            let name = "flaccy-diagnostic-\(stamp.replacingOccurrences(of: ":", with: "")).json"
            try report.write(to: folder.appendingPathComponent(name), options: .atomic)
            for stale in reportURLs.dropFirst(keptReports) {
                try? FileManager.default.removeItem(at: stale)
            }
        } catch {
            MidgarLog.error("Crash report not saved: \(error.localizedDescription)", category: .general)
        }
    }
}
