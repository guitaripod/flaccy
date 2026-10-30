#if DEBUG
import Foundation

/// The one HTTP call the debug drives make on their own: a GET of a JSON object, with the device token when there is one,
/// answering the status and the decoded object so the drive can judge both.
enum DebugDriveHTTPClient {

    static func object(at url: URL, token: String?) async throws -> (status: Int, object: [String: Any]?) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif
