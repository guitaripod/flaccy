import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

    nonisolated static let readThrottle = RequestThrottle(minInterval: 0.25)

    nonisolated func throttledGET(params: [String: String]) async throws -> Data {
        await Self.readThrottle.acquire()
        return try await performUnsignedGET(params: params)
    }

    /// Performs a throttled read and classifies the outcome the way
    /// `EnrichmentPolicy` needs it. `parse` runs on the decoded body inside this
    /// call so the untyped JSON never leaves the function.
    ///
    /// Only a body that decoded as JSON can produce `.success`, because
    /// `.success(nil)` is what eventually writes an album off as `.exhausted`.
    /// A captive portal answering HTTP 200 with a login page is `.transport`,
    /// which costs the album nothing.
    nonisolated func classifiedRead<Value: Sendable>(
        params: [String: String],
        parse: @Sendable ([String: Any]) -> Value?
    ) async -> EnrichmentSourceOutcome<Value> {
        var allParams = params
        allParams["format"] = "json"

        var components = URLComponents(string: Self.baseURL)!
        components.percentEncodedQuery = allParams
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        guard let url = components.url else { return .failed(.transport) }

        await Self.readThrottle.acquire()

        do {
            let (data, response) = try await client.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed(.transport) }
            if http.statusCode == 429 { return .failed(.rateLimited) }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(.transport)
            }
            if let code = Self.intValue(json["error"]) {
                switch Self.verdict(forAPIError: code) {
                case .answeredEmpty: return .empty
                case .failed(let failure): return .failed(failure)
                }
            }
            guard (200...299).contains(http.statusCode) else { return .failed(.transport) }
            guard let value = parse(json) else { return .empty }
            return .value(value)
        } catch {
            return .failed(await EnrichmentFailureClassifier.classify(error))
        }
    }

    nonisolated enum APIVerdict {
        case answeredEmpty
        case failed(EnrichmentFailure)
    }

    /// Maps a Last.fm error code onto the enrichment vocabulary. Only code 6
    /// ("item not found") is the service genuinely answering that it has
    /// nothing; every other code is a condition that may clear on its own, so
    /// it must not count towards the attempts an entity is allowed.
    nonisolated static func verdict(forAPIError code: Int) -> APIVerdict {
        switch code {
        case 6: return .answeredEmpty
        case 29: return .failed(.rateLimited)
        case 4, 9, 10, 13, 26: return .failed(.unauthorized)
        default: return .failed(.transport)
        }
    }

    /// Retries an operation whose response body carries Last.fm error 29 (rate
    /// limit) with exponential backoff, up to `maxRetries` extra attempts.
    nonisolated static func performWithBackoff(
        maxRetries: Int = 3,
        _ operation: () async throws -> Data
    ) async throws -> Data {
        var attempt = 0
        while true {
            let data = try await operation()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               intValue(json["error"]) == 29, attempt < maxRetries {
                let delay = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
                continue
            }
            return data
        }
    }

    nonisolated static func asArray(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    nonisolated struct ScrobbleEntryStatus {
        let accepted: Bool
        let ignoredCode: Int
    }

    nonisolated enum ScrobbleResponse {
        case entries([ScrobbleEntryStatus])
        case acceptedCount(Int)
        case retryableError(code: Int, message: String)
    }

    /// Parses a track.scrobble response body. Returns per-entry accepted/ignored
    /// statuses when the response matches the submitted count, a retryable API
    /// error (codes 11/16/29) when the whole request should be retried later,
    /// or falls back to the top-level accepted count for malformed responses.
    nonisolated static func parseScrobbleResponse(data: Data, expectedCount: Int) -> ScrobbleResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .acceptedCount(0)
        }

        if let errorCode = intValue(json["error"]) {
            let message = json["message"] as? String ?? "unknown"
            if [11, 16, 29].contains(errorCode) {
                return .retryableError(code: errorCode, message: message)
            }
            return .acceptedCount(0)
        }

        guard let scrobbles = json["scrobbles"] as? [String: Any] else {
            return .acceptedCount(0)
        }

        let attr = scrobbles["@attr"] as? [String: Any]
        let acceptedCount = intValue(attr?["accepted"]) ?? 0

        let rawEntries: [[String: Any]]
        if let array = scrobbles["scrobble"] as? [[String: Any]] {
            rawEntries = array
        } else if let single = scrobbles["scrobble"] as? [String: Any] {
            rawEntries = [single]
        } else {
            rawEntries = []
        }

        guard rawEntries.count == expectedCount else {
            return .acceptedCount(acceptedCount)
        }

        let statuses = rawEntries.map { entry -> ScrobbleEntryStatus in
            let ignored = entry["ignoredMessage"] as? [String: Any]
            let code = intValue((ignored?["@attr"] as? [String: Any])?["code"])
                ?? intValue(ignored?["code"])
                ?? 0
            return ScrobbleEntryStatus(accepted: code == 0, ignoredCode: code)
        }
        return .entries(statuses)
    }

    nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    nonisolated func performSignedRequest(
        params: [String: String],
        httpMethod: String
    ) async throws -> Data {
        var signedParams = params
        signedParams["api_sig"] = try await requestSignature(for: params)
        signedParams["format"] = "json"

        if httpMethod == "GET" {
            return try await performGET(params: signedParams)
        } else {
            return try await performPOST(params: signedParams)
        }
    }

    nonisolated func performUnsignedGET(params: [String: String]) async throws -> Data {
        var allParams = params
        allParams["format"] = "json"
        return try await performGET(params: allParams)
    }

    nonisolated func performGET(params: [String: String]) async throws -> Data {
        var components = URLComponents(string: Self.baseURL)!
        components.percentEncodedQuery = params
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")

        guard let url = components.url else {
            throw LastFMError.invalidURL
        }

        let (data, response) = try await client.data(from: url)
        try validateResponse(response, data: data)
        return data
    }

    nonisolated func performPOST(params: [String: String]) async throws -> Data {
        guard let url = URL(string: Self.baseURL) else {
            throw LastFMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await client.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    nonisolated func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    nonisolated func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LastFMError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMessage: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                errorMessage = message
            } else {
                errorMessage = "HTTP \(http.statusCode)"
            }
            throw LastFMError.apiError(errorMessage)
        }
    }

    /// Asks flaccy-api for the `api_sig` of `params`. Last.fm's shared secret
    /// lives only on that Worker, so no build of the app can leak it, and a
    /// refusal (quota, outage, offline) throws like any failed Last.fm call:
    /// scrobbles stay pending and are retried.
    nonisolated func requestSignature(for params: [String: String]) async throws -> String {
        do throws(MidgarHTTPError) {
            return try await FlaccyMidgar.shared.api.lastFMSignature(for: params)
        } catch {
            throw LastFMError.apiError(Self.signingFailure(error))
        }
    }

    /// The reason a signing call failed: the HTTP status when the worker refused, else what kept it from answering.
    nonisolated static func signingFailure(_ error: MidgarHTTPError) -> String {
        switch error {
        case .server(let status, _, _): "signing failed (HTTP \(status))"
        case .rateLimited: "signing failed (HTTP 429)"
        default: "signing failed (\(error.localizedDescription))"
        }
    }

    nonisolated static func extractLargestImage(from imageArray: Any?) -> String? {
        guard let images = imageArray as? [[String: Any]] else { return nil }

        let sizeOrder = ["mega", "extralarge", "large", "medium", "small"]
        for size in sizeOrder {
            if let match = images.first(where: { ($0["size"] as? String) == size }),
               let url = match["#text"] as? String,
               !url.isEmpty {
                return url
            }
        }
        return nil
    }
}
