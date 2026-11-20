import Foundation

/// A weighted order that holds for a whole night's listening: the same
/// candidates and weights give the same order on every build that day, on
/// every client, and a fresh order the next. Home's suggestions are ordered
/// through it so what Home offers stays put while the page rebuilds around it.
public enum DayStableOrder {

    /// The hour a listening day turns over, local time: an evening that runs
    /// past midnight keeps the evening's suggestion.
    public static let dayStartsAtHour = 5

    /// The listening day `date` falls in, counted from 1970-01-01 on the
    /// person's own clock.
    public static func day(of date: Date, secondsFromGMT: Int) -> Int64 {
        let local = date.timeIntervalSince1970 + Double(secondsFromGMT - dayStartsAtHour * 3_600)
        return Int64((local / 86_400).rounded(.down))
    }

    /// A draw strictly between 0 and 1, fixed by the day and a candidate's name.
    public static func draw(day: Int64, name: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(day)\u{0}\(name)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return (Double(finalized(hash) >> 11) + 0.5) / 9_007_199_254_740_992
    }

    /// Efraimidis–Spirakis with the day's draws instead of random ones: each
    /// candidate's key is `draw^(1/weight)`, highest first, so heavier
    /// candidates tend to lead while every one keeps a chance. Equal keys keep
    /// the order they were given in.
    public static func ordered<Element>(
        _ items: [Element],
        day: Int64,
        name: (Element) -> String,
        weight: (Element) -> Double
    ) -> [Element] {
        items.enumerated()
            .map { position, element in
                Keyed(position: position, element: element, key: pow(draw(day: day, name: name(element)), 1 / max(weight(element), 0.0001)))
            }
            .sorted { $0.key != $1.key ? $0.key > $1.key : $0.position < $1.position }
            .map(\.element)
    }

    private struct Keyed<Element> {
        let position: Int
        let element: Element
        let key: Double
    }

    /// MurmurHash3's 64-bit finalizer, so names that differ only in their last
    /// letters still land far apart.
    private static func finalized(_ value: UInt64) -> UInt64 {
        var hash = value
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b3fe_1a85_ec53
        hash ^= hash >> 33
        return hash
    }
}
