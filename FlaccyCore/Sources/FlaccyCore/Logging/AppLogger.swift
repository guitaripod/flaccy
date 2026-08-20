#if canImport(OSLog)
import OSLog
#endif

/// Structured logging facade shared by the iOS and watchOS apps.
///
/// Every call fans out to OSLog (live streaming via Console/`log`) and to
/// `LogFileWriter` (persisted in `Library/Logs` for offline retrieval).
/// On platforms without OSLog only the file half runs, which keeps the
/// package compiling and testable on Linux.
public enum AppLogger {

    public enum Category: String {
        case auth
        case database
        case content
        case sync
        case learning
        case gamification
        case purchases
        case ui
        case viewModel
        case mlx
        case performance
        case playback
        case watch
        case connectivity
        case general
    }

    #if canImport(OSLog)
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy"

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
    #endif

    public static func debug(_ message: String, category: Category = .general) {
        #if canImport(OSLog)
        logger(for: category).debug("\(message)")
        #endif
        LogFileWriter.shared.write(level: "DEBUG", category: category.rawValue, message: message)
    }

    public static func info(_ message: String, category: Category = .general) {
        #if canImport(OSLog)
        logger(for: category).info("\(message)")
        #endif
        LogFileWriter.shared.write(level: "INFO", category: category.rawValue, message: message)
    }

    public static func warning(_ message: String, category: Category = .general) {
        #if canImport(OSLog)
        logger(for: category).warning("\(message)")
        #endif
        LogFileWriter.shared.write(level: "WARN", category: category.rawValue, message: message)
    }

    public static func error(_ message: String, category: Category = .general) {
        #if canImport(OSLog)
        logger(for: category).error("\(message)")
        #endif
        LogFileWriter.shared.write(level: "ERROR", category: category.rawValue, message: message)
    }
}
