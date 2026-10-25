import Foundation

/// The sections Home can show, in their default order. The raw values are the
/// persisted identifiers, shared with Linux (`home::Section`), so they never
/// change. Mirrored in Rust as `linux/shared/src/home.rs`.
public enum HomeSection: String, CaseIterable, Sendable, Codable {
    case resume = "continue"
    case jumpBackIn
    case onThisDay
    case thisWeek
    case madeForYou
    case recentlyAdded

    /// Sections small enough to sit side by side when they are neighbours.
    public var isCompact: Bool {
        self == .onThisDay || self == .thisWeek
    }
}

/// The person's arrangement of Home: every section in their order, and the
/// ones they switched off. Hidden sections keep their place so switching one
/// back on returns it where it was.
public struct HomeLayout: Equatable, Sendable {
    public private(set) var order: [HomeSection]
    public private(set) var hidden: Set<HomeSection>

    public static let standard = HomeLayout(order: HomeSection.allCases, hidden: [])

    public init(order: [HomeSection], hidden: Set<HomeSection>) {
        self.order = Self.completed(order)
        self.hidden = hidden
    }

    public var visible: [HomeSection] {
        order.filter { !hidden.contains($0) }
    }

    public var isStandard: Bool {
        self == .standard
    }

    public func isVisible(_ section: HomeSection) -> Bool {
        !hidden.contains(section)
    }

    /// Moves the section at `source` to `destination` in `order`, clamping both
    /// so a drag past either end lands on it.
    public func moving(from source: Int, to destination: Int) -> HomeLayout {
        guard order.indices.contains(source) else { return self }
        var reordered = order
        let section = reordered.remove(at: source)
        reordered.insert(section, at: min(max(destination, 0), reordered.count))
        return HomeLayout(order: reordered, hidden: hidden)
    }

    public func setting(_ section: HomeSection, visible: Bool) -> HomeLayout {
        var updated = hidden
        if visible {
            updated.remove(section)
        } else {
            updated.insert(section)
        }
        return HomeLayout(order: order, hidden: updated)
    }

    /// `continue,jumpBackIn,…|thisWeek`: the order, then the hidden sections in
    /// that order. The same text on every client.
    public var encoded: String {
        let orderText = order.map(\.rawValue).joined(separator: ",")
        let hiddenText = order.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",")
        return "\(orderText)|\(hiddenText)"
    }

    /// Reads `encoded` back. Unknown identifiers are dropped, duplicates keep
    /// their first place, and a section the text does not mention (one added
    /// by a later version) joins at the end, visible.
    public static func decode(_ text: String?) -> HomeLayout {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .standard }
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let order = sections(in: parts.first.map(String.init) ?? "")
        let hidden = parts.count > 1 ? Set(sections(in: String(parts[1]))) : []
        return HomeLayout(order: order, hidden: hidden)
    }

    private static func sections(in list: String) -> [HomeSection] {
        list.split(separator: ",").compactMap { HomeSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func completed(_ order: [HomeSection]) -> [HomeSection] {
        var seen = Set<HomeSection>()
        var result: [HomeSection] = []
        for section in order + HomeSection.allCases where seen.insert(section).inserted {
            result.append(section)
        }
        return result
    }
}
