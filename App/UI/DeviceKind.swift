import Foundation

/// Which device a person holds, for the few words that name it ("this
/// iPhone", "this iPad"). Layout never asks; `AdaptiveLayout` works from the
/// room a view was given. Read from the hardware model rather than UIKit so
/// copy built off the main actor can ask too; the Simulator reports the model
/// it stands in for.
enum DeviceKind {

    nonisolated static let isPad: Bool = {
        #if os(iOS)
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return (simulated ?? hardwareModel()).hasPrefix("iPad")
        #else
        return false
        #endif
    }()

    private nonisolated static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
