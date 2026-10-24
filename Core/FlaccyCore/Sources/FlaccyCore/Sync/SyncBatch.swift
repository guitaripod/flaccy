import Foundation

/// What the phone is sending right now, so the wrist can say "3 of 12" instead
/// of an indeterminate spinner. `remaining` counts tracks the phone still has to
/// get onto the watch, `total` the tracks of the run they belong to.
public struct SyncBatch: Codable, Sendable, Equatable {
    public let total: Int
    public let remaining: Int
    public let preparing: Bool

    public init(total: Int, remaining: Int, preparing: Bool = false) {
        self.total = max(0, total)
        self.remaining = min(max(0, remaining), max(0, total))
        self.preparing = preparing
    }

    public static let idle = SyncBatch(total: 0, remaining: 0)

    public var isActive: Bool { remaining > 0 }
    public var completed: Int { total - remaining }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

public enum SyncBatchTransfer {

    public static func encode(_ batch: SyncBatch) -> Data? {
        try? JSONEncoder().encode(batch)
    }

    public static func decode(_ value: Any?) -> SyncBatch? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(SyncBatch.self, from: data)
    }
}
