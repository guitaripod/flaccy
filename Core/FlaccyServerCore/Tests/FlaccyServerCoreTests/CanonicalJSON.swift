import Foundation

enum CanonicalJSON {
    static func string(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try render(withoutNulls(object))
    }

    static func string(encoding value: some Encodable) throws -> String {
        try string(from: JSONEncoder().encode(value))
    }

    private static func withoutNulls(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { !($0.value is NSNull) }.mapValues(withoutNulls)
        case let array as [Any]:
            return array.map(withoutNulls)
        default:
            return value
        }
    }

    private static func render(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
