import OSLog

enum AppLogger {

    enum Category: String {
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
        case general
    }

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy", category: category.rawValue)
    }

    static func debug(_ message: String, category: Category = .general) {
        logger(for: category).debug("\(message)")
    }

    static func info(_ message: String, category: Category = .general) {
        logger(for: category).info("\(message)")
    }

    static func warning(_ message: String, category: Category = .general) {
        logger(for: category).warning("\(message)")
    }

    static func error(_ message: String, category: Category = .general) {
        logger(for: category).error("\(message)")
    }
}
