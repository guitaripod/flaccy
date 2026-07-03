import OSLog

/// Structured logging facade shared by the iOS and watchOS apps.
///
/// Every call fans out to OSLog (live streaming via Console/`log`) and to
/// `LogFileWriter` (persisted in `Library/Logs` for offline retrieval).
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

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy"

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public static func debug(_ message: String, category: Category = .general) {
        logger(for: category).debug("\(message)")
        LogFileWriter.shared.write(level: "DEBUG", category: category.rawValue, message: message)
    }

    public static func info(_ message: String, category: Category = .general) {
        logger(for: category).info("\(message)")
        LogFileWriter.shared.write(level: "INFO", category: category.rawValue, message: message)
    }

    public static func warning(_ message: String, category: Category = .general) {
        logger(for: category).warning("\(message)")
        LogFileWriter.shared.write(level: "WARN", category: category.rawValue, message: message)
    }

    public static func error(_ message: String, category: Category = .general) {
        logger(for: category).error("\(message)")
        LogFileWriter.shared.write(level: "ERROR", category: category.rawValue, message: message)
    }
}
