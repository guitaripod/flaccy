import Foundation

public enum WeightedShuffle {

    /// Weighted random ordering (Efraimidis–Spirakis): each element gets the key
    /// `u^(1/weight)` for a uniform `u`, sorted descending, so higher weights tend
    /// to sort earlier while every element keeps a chance — variety without bias loss.
    public static func shuffled<Element>(_ items: [Element], weight: (Element) -> Double) -> [Element] {
        items
            .map { element -> (element: Element, key: Double) in
                let w = max(weight(element), 0.0001)
                let u = Double.random(in: 1e-12..<1)
                return (element, pow(u, 1.0 / w))
            }
            .sorted { $0.key > $1.key }
            .map(\.element)
    }
}
