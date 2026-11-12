import Foundation

/// Which addresses belong to the network a person is on at home: the private IPv4 ranges, IPv4 and IPv6 link-local, and
/// IPv6 unique local addresses, minus the Tailscale range inside them. A Flaccy Server shares on these addresses over TLS
/// with a pinned key, so a typed address on them defaults to `https`.
///
/// Mirrored in Rust as `linux/shared/src/remote/local_network.rs`.
public enum LocalNetwork {

    private static let tailnetPrefix: [UInt16] = [0xfd7a, 0x115c, 0xa1e0]
    private static let bonjourSuffix = ".local"

    /// True for 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7 and fe80::/10, except Tailscale's fd7a:115c:a1e0::/48.
    /// An IPv4-mapped IPv6 address counts as the address it wraps, and an IPv6 zone (`%en0`) is ignored.
    public static func isLocalNetwork(_ address: String) -> Bool {
        let unzoned = address.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if let octets = ipv4Octets(unzoned) {
            return isLocalIPv4(octets)
        }
        if unzoned.hasPrefix("::ffff:"), let octets = ipv4Octets(String(unzoned.dropFirst(7))) {
            return isLocalIPv4(octets)
        }
        guard unzoned.contains(":"), let groups = leadingGroups(unzoned) else { return false }
        let first = groups.first ?? 0
        let isUniqueLocal = first & 0xFE00 == 0xFC00
        let isLinkLocal = first & 0xFFC0 == 0xFE80
        return (isUniqueLocal && Array(groups.prefix(3)) != tailnetPrefix) || isLinkLocal
    }

    /// Whether a host as typed names a machine on the local network: a local IP literal (IPv6 with or without brackets) or a
    /// `.local` Bonjour name.
    public static func isLocalHost(_ host: String) -> Bool {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        let unbracketed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ipv4Octets(unbracketed) != nil || unbracketed.contains(":") {
            return isLocalNetwork(unbracketed)
        }
        let lowered = trimmed.lowercased()
        return lowered.count > bonjourSuffix.count && lowered.hasSuffix(bonjourSuffix)
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }

    /// The groups before any `::`, as numbers; nil when one is not hexadecimal.
    private static func leadingGroups(_ address: String) -> [UInt16]? {
        let head = address.components(separatedBy: "::").first ?? address
        guard !head.isEmpty else { return [0] }
        var groups: [UInt16] = []
        for part in head.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = UInt16(part, radix: 16) else { return nil }
            groups.append(value)
        }
        return groups
    }
}
