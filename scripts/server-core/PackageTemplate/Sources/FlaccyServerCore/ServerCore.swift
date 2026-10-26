import FlaccyServerCoreBindings
import Foundation

public enum ServerCoreError: Error, Equatable {
    case core(String)
    case malformedResponse
}

public enum ServerCore {
    public static var version: String {
        FlaccyServerCoreBindings.version()
    }

    public static func songKey(artistKey: String, titleKey: String) -> String {
        FlaccyServerCoreBindings.songKey(artistKey: artistKey, titleKey: titleKey)
    }

    public static func between(_ lower: String, _ upper: String) throws -> String {
        let response = try decodeObject(FlaccyServerCoreBindings.between(a: lower, b: upper))
        guard let key = response["key"] as? String else { throw ServerCoreError.malformedResponse }
        return key
    }

    public static func apply(state: String, mutation: String) throws -> String {
        let raw = FlaccyServerCoreBindings.applyJson(state: state, mutation: mutation)
        _ = try decodeObject(raw)
        return raw
    }

    private static func decodeObject(_ raw: String) throws -> [String: Any] {
        guard
            let data = raw.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ServerCoreError.malformedResponse }
        if let message = object["error"] as? String { throw ServerCoreError.core(message) }
        return object
    }
}
