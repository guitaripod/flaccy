import Foundation

/// The failure a Subsonic server names in its `error` object, by the protocol's error code.
///
/// Codes 20 and 30 both mean the protocol versions disagree, so they share one case.
/// Any code the protocol does not name is kept as `other`.
public enum SubsonicFailure: Equatable, Sendable {
    case missingParameter
    case incompatibleVersion
    case wrongCredentials
    case tokenAuthUnsupported
    case authMechanismUnsupported
    case conflictingAuth
    case invalidAPIKey
    case notAuthorized
    case trialExpired
    case notFound
    case other(Int)

    public init(code: Int) {
        switch code {
        case 10: self = .missingParameter
        case 20, 30: self = .incompatibleVersion
        case 40: self = .wrongCredentials
        case 41: self = .tokenAuthUnsupported
        case 42: self = .authMechanismUnsupported
        case 43: self = .conflictingAuth
        case 44: self = .invalidAPIKey
        case 50: self = .notAuthorized
        case 60: self = .trialExpired
        case 70: self = .notFound
        default: self = .other(code)
        }
    }
}
