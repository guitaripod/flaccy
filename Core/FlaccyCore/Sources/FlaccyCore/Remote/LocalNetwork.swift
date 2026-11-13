import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Which addresses belong to the network a person is on at home: the private IPv4 ranges, IPv4 and IPv6 link-local, and
/// IPv6 unique local addresses, minus the Tailscale range inside them. A Flaccy Server shares on these addresses over TLS
/// with a pinned key, so a typed address on them defaults to `https`. Literals are read the way Rust's address parser
/// reads them (four decimal parts, no leading zeros, no signs; IPv6 by `inet_pton`), so both clients agree on every typed
/// address. Darwin's `inet_pton` takes `010` as an IPv4 part, so IPv4 is checked here instead.
///
/// Mirrored in Rust as `linux/shared/src/remote/local_network.rs`.
public enum LocalNetwork {

    private static let tailnetPrefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    private static let bonjourSuffix = ".local"

    /// True for 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7 and fe80::/10, except Tailscale's fd7a:115c:a1e0::/48.
    /// An IPv4-mapped IPv6 address counts as the address it wraps, and an IPv6 zone (`%en0`) is ignored.
    public static func isLocalNetwork(_ address: String) -> Bool {
        let literal = unzoned(address)
        if let octets = ipv4Octets(literal) {
            return isLocalIPv4(octets)
        }
        guard let bytes = ipv6Bytes(literal) else { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isLocalIPv4(Array(bytes.suffix(4)))
        }
        let isUniqueLocal = bytes[0] & 0xFE == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        return (isUniqueLocal && Array(bytes.prefix(6)) != tailnetPrefix) || isLinkLocal
    }

    /// Whether a host as typed names a machine on the local network: a local IP literal (IPv6 with or without brackets
    /// and zone) or a `.local` Bonjour name.
    public static func isLocalHost(_ host: String) -> Bool {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        let unbracketed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPLiteral(unzoned(unbracketed)) {
            return isLocalNetwork(unbracketed)
        }
        let lowered = trimmed.lowercased()
        return lowered.count > bonjourSuffix.count && lowered.hasSuffix(bonjourSuffix)
    }

    /// Whether `text` is a bare IPv6 address, which a URL needs in brackets.
    public static func isIPv6Literal(_ text: String) -> Bool {
        ipv6Bytes(text) != nil
    }

    private static func isIPLiteral(_ text: String) -> Bool {
        ipv4Octets(text) != nil || ipv6Bytes(text) != nil
    }

    private static func unzoned(_ address: String) -> String {
        String(address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let octet = UInt8(part)
            else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func ipv6Bytes(_ text: String) -> [UInt8]? {
        if text.contains("."), ipv4Octets(String(text.split(separator: ":").last ?? "")) == nil { return nil }
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }
}
