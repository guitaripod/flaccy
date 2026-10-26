import Foundation

/// A JSON document of any shape, for the parts of the Flaccy Server protocol whose
/// shape depends on the entity or the mutation they belong to.
public enum ServerJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ServerJSON])
    case object([String: ServerJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ServerJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ServerJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> ServerJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var int: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var array: [ServerJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// The document as compact UTF-8 text, or nil when a number is not finite.
    public var text: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a document from text.
    public init?(text: String) {
        guard let value = try? JSONDecoder().decode(ServerJSON.self, from: Data(text.utf8)) else { return nil }
        self = value
    }
}

extension ServerJSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ServerJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ServerJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
