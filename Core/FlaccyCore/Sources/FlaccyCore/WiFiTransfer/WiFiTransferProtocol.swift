import Foundation

/// The little HTTP that Wi-Fi Transfer speaks: enough of HTTP/1.1 for a web browser on the same network to load the
/// upload page and send songs, one request per file. Every route sits under the session's token, so a device that only
/// finds the open port, without the address the phone shows, gets nothing but 404s.
///
/// Routes, all under `/<token>/`:
/// - `GET /<token>/` the upload page.
/// - `PUT /<token>/upload?batch=<id>&path=<relative path>` one file, its bytes as the body, `Content-Length` required.
/// - `POST /<token>/done?batch=<id>` the page has sent everything it was given in that batch.
public enum WiFiTransferProtocol {
    /// The longest request head read before giving up; a browser's is a few hundred bytes.
    public static let maximumHeadLength = 16 * 1024
    /// The largest single file accepted. A 24-bit/192 kHz album side as one FLAC stays well under it.
    public static let maximumFileLength: Int64 = 4 * 1024 * 1024 * 1024
    /// Folders deeper than this below what was dropped are refused rather than recreated.
    public static let maximumPathDepth = 8

    /// Characters of a token: lowercase letters and digits without the ones people misread (0, o, 1, l, i).
    static let tokenAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// A fresh token for one session. Six characters keep the address short enough to type.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in tokenAlphabet.randomElement(using: &generator) ?? "a" })
    }

    /// Whether a peer at `host` may use Wi-Fi Transfer: loopback, link-local, and the private ranges a home or office
    /// network hands out (10/8, 172.16/12, 192.168/16, IPv6 unique-local fc00::/7) plus the 100.64/10 shared range a
    /// Tailscale network uses. A peer on the open internet is refused even with the token. An IPv6 zone (`%en0`) is
    /// ignored and an IPv4-mapped IPv6 address is judged as IPv4.
    public static func isNearby(host: String) -> Bool {
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if let octets = ipv4Octets(address) {
            return isNearbyIPv4(octets)
        }
        if address.hasPrefix("::ffff:"), let octets = ipv4Octets(String(address.dropFirst(7))) {
            return isNearbyIPv4(octets)
        }
        guard address.contains(":") else { return false }
        if address == "::1" { return true }
        let firstGroup = address.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let value = UInt16(firstGroup.isEmpty ? "0" : firstGroup, radix: 16) else { return false }
        let isUniqueLocal = value & 0xFE00 == 0xFC00
        let isLinkLocal = value & 0xFFC0 == 0xFE80
        return isUniqueLocal || isLinkLocal
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func isNearbyIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        case (100, 64...127): true
        default: false
        }
    }

    /// The address the phone shows, e.g. `http://192.168.1.23:8080/k3f9xq/`.
    public static func address(host: String, port: UInt16, token: String) -> String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return port == 80 ? "http://\(shownHost)/\(token)/" : "http://\(shownHost):\(port)/\(token)/"
    }
}

/// The request line and headers of one HTTP request.
public struct WiFiTransferRequestHead: Sendable, Equatable {
    public let method: String
    /// The path without its query, still percent-encoded.
    public let path: String
    /// The query's names and values, percent-decoded. A name given twice keeps its first value.
    public let query: [String: String]
    /// Header names in lowercase.
    public let headers: [String: String]

    public var contentLength: Int64? {
        headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// What reading a request head from the bytes received so far came to.
    public enum Parse: Sendable, Equatable {
        /// The blank line that ends the head has not arrived yet.
        case incomplete
        /// Not a request this server can read, or a head longer than ``WiFiTransferProtocol/maximumHeadLength``.
        case malformed
        /// The head, and where the body starts in the bytes given.
        case complete(WiFiTransferRequestHead, bodyOffset: Int)
    }

    public static func parse(_ bytes: Data) -> Parse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = bytes.range(of: terminator) else {
            return bytes.count > WiFiTransferProtocol.maximumHeadLength ? .malformed : .incomplete
        }
        guard end.lowerBound - bytes.startIndex <= WiFiTransferProtocol.maximumHeadLength,
              let text = String(data: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .malformed }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .malformed }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let head = WiFiTransferRequestHead(
            method: String(requestLine[0]).uppercased(), path: path, query: queryItems(of: target), headers: headers
        )
        return .complete(head, bodyOffset: end.upperBound - bytes.startIndex)
    }

    /// `+` is a space in a form-encoded query; the page encodes with `encodeURIComponent`, which never writes one.
    private static func queryItems(of target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var items: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first,
                  let name = String(rawName).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  items[name] == nil
            else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            items[name] = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return items
    }
}

/// One file the browser is about to send.
public struct WiFiTransferUpload: Sendable, Equatable {
    /// The drop it belongs to; everything in one batch is imported together once the page says it is done.
    public let batch: String
    /// Where it goes below the batch, made safe by ``WiFiTransferPath/sanitized(_:)``.
    public let relativePath: String
    public let length: Int64

    /// The file's own name, for the phone to show.
    public var fileName: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }
}

/// Why an upload was turned away before a byte of it was stored.
public enum WiFiTransferRefusal: Sendable, Equatable {
    /// Not a song or lyrics file Flaccy can import.
    case unsupportedFile
    /// The path is empty, climbs out of its folder or is too deep.
    case badPath
    /// No usable `Content-Length`, so the end of the file could not be known.
    case missingLength
    /// Larger than ``WiFiTransferProtocol/maximumFileLength``.
    case tooLarge
    /// The batch id is missing or not one the page makes.
    case badBatch

    public var status: Int {
        switch self {
        case .unsupportedFile: 415
        case .badPath, .badBatch: 400
        case .missingLength: 411
        case .tooLarge: 413
        }
    }
}

/// What the server does with a request.
public enum WiFiTransferRoute: Sendable, Equatable {
    case page
    case upload(WiFiTransferUpload)
    case finish(batch: String)
    case refuse(WiFiTransferRefusal)
    case notFound

    /// Routes `head` for the session `token`. `acceptedExtensions` are the lowercased extensions Flaccy imports.
    public static func route(_ head: WiFiTransferRequestHead, token: String, acceptedExtensions: Set<String>) -> WiFiTransferRoute {
        let components = head.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.first == token else { return .notFound }
        switch (head.method, Array(components.dropFirst())) {
        case ("GET", []), ("HEAD", []):
            return .page
        case ("PUT", ["upload"]):
            return upload(head, acceptedExtensions: acceptedExtensions)
        case ("POST", ["done"]):
            guard let batch = head.query["batch"], isBatchID(batch) else { return .refuse(.badBatch) }
            return .finish(batch: batch)
        default:
            return .notFound
        }
    }

    private static func upload(_ head: WiFiTransferRequestHead, acceptedExtensions: Set<String>) -> WiFiTransferRoute {
        guard let batch = head.query["batch"], isBatchID(batch) else { return .refuse(.badBatch) }
        guard let raw = head.query["path"], let path = WiFiTransferPath.sanitized(raw) else { return .refuse(.badPath) }
        guard acceptedExtensions.contains((path as NSString).pathExtension.lowercased()) else { return .refuse(.unsupportedFile) }
        guard let length = head.contentLength, length >= 0 else { return .refuse(.missingLength) }
        guard length <= WiFiTransferProtocol.maximumFileLength else { return .refuse(.tooLarge) }
        return .upload(WiFiTransferUpload(batch: batch, relativePath: path, length: length))
    }

    /// The page names a batch with up to 32 letters, digits and dashes.
    static func isBatchID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}

/// Turns the path a browser reports for a dropped file into one that is safe to create below a staging folder.
public enum WiFiTransferPath {
    /// The path with empty and `.` components dropped and both slash kinds as separators, or nil when it is empty,
    /// names a hidden file or folder, climbs with `..`, holds a control character or is deeper than
    /// ``WiFiTransferProtocol/maximumPathDepth`` folders. Each component keeps at most 255 UTF-8 bytes.
    public static func sanitized(_ raw: String) -> String? {
        let components = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty, components.count <= WiFiTransferProtocol.maximumPathDepth + 1 else { return nil }
        for component in components {
            guard component != "..",
                  !component.hasPrefix("."),
                  component.utf8.count <= 255,
                  !component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { return nil }
        }
        return components.joined(separator: "/")
    }
}

/// The bytes of one HTTP response. Every response closes its connection; the page opens a new one per file.
public enum WiFiTransferResponse {
    public static func make(status: Int, contentType: String, body: Data, includeBody: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }

    /// A small JSON answer for the page: `{"ok":true}` or `{"error":"<code>"}`.
    public static func json(status: Int, error: String? = nil) -> Data {
        let body = error.map { #"{"error":"\#($0)"}"# } ?? #"{"ok":true}"#
        return make(status: status, contentType: "application/json; charset=utf-8", body: Data(body.utf8))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Error"
        }
    }
}
