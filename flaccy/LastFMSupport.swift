import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

enum KeychainStore {

    nonisolated static var service: String {
        Bundle.main.bundleIdentifier ?? "flaccy"
    }

    nonisolated static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(update) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

enum LastFMError: Error, LocalizedError {
    case invalidCallbackURL
    case authenticationFailed
    case authenticationUnavailable
    case invalidURL
    case invalidResponse
    case apiKeyNotConfigured
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallbackURL: String(localized: "Last.fm returned to Flaccy without a sign-in token, so you're not signed in. Try again.")
        case .authenticationFailed: String(localized: "Last.fm didn't confirm the sign-in, so you're not signed in. Try again.")
        case .authenticationUnavailable: String(localized: "Couldn't open the Last.fm sign-in page. Close any other sign-in sheet and try again.")
        case .invalidURL: String(localized: "Flaccy built an invalid Last.fm request address, so nothing was sent.")
        case .invalidResponse: String(localized: "Last.fm or Flaccy's signing service sent a reply Flaccy couldn't read. Try again later.")
        case .apiKeyNotConfigured: String(localized: "Last.fm API key not configured")
        case .apiError(let message): String(localized: "Last.fm API error: \(message)")
        }
    }
}
