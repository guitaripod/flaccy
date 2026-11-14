import FlaccyCore
import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif

/// Why a sentence gave no curve, each with its own next step for the person.
nonisolated enum EqualizerDescriptionFailure: Error, Sendable, Equatable {
    case needsEntitlement
    case unreachable
    case quotaReached(resetsAt: Date)
    /// The sentence described nothing an equalizer can shape; the model's own sentence about it, when it gave one.
    case nothingToShape(note: String)
    case unavailable

    /// Whether saying it another way is the way forward, so the example sentences are worth showing again.
    var invitesAnotherSentence: Bool {
        switch self {
        case .nothingToShape: true
        case .needsEntitlement, .unreachable, .quotaReached, .unavailable: false
        }
    }
}

/// Describe the Sound on the Apple clients: a sentence becomes an equalizer curve through one call to flaccy-api,
/// whose reply is clamped there and settled again here (`EqualizerDescription` in FlaccyCore) before any of it
/// reaches the audio. The sentence, the listener's language, the kind of output and of device and the bands in
/// force are all that is sent.
nonisolated final class EqualizerDescriptionService: Sendable {

    static let shared = EqualizerDescriptionService()

    /// The curve for `sentence`, starting from `inForce` when the sentence is about how it sounds now.
    func curve(for sentence: String, output: String, inForce: EqualizerProfile) async -> Result<DescribedEqualizer, EqualizerDescriptionFailure> {
        guard await MainActor.run(body: { PurchaseManager.shared.allowsPlayback }) else { return .failure(.needsEntitlement) }
        let body = EqualizerDescription.request(
            sentence, language: LyricsMeaningService.languageName, output: output, device: await Self.device(), inForce: inForce)
        let reply: FlaccyAPIClient.ProxyReply
        do {
            reply = try await FlaccyMidgar.shared.api.postEqualizer(body)
        } catch {
            MidgarLog.notice("Equalizer sentence request failed: \(error.localizedDescription)", category: .content)
            return .failure(error is URLError ? .unreachable : .unavailable)
        }
        let errorCode = (try? JSONDecoder().decode(ProxyError.self, from: reply.body))?.error
        switch AIProxyReply.classify(status: reply.status, errorCode: errorCode, retryAfter: reply.retryAfter, now: Date()) {
        case .answer:
            break
        case .quotaReached(let resetsAt):
            return .failure(.quotaReached(resetsAt: resetsAt))
        case .busy, .payloadTooLarge, .unavailable:
            MidgarLog.notice("Equalizer sentence answered \(reply.status) \(errorCode ?? "")", category: .content)
            return .failure(errorCode == "request_declined" ? .nothingToShape(note: "") : .unavailable)
        }
        guard let decoded = try? JSONDecoder().decode(CurveReply.self, from: reply.body) else {
            MidgarLog.notice("Equalizer sentence reply could not be read", category: .content)
            return .failure(.unavailable)
        }
        guard let settled = EqualizerDescription.settle(decoded.curve, fallbackName: EqualizerDescribeCopy.fallbackName) else {
            MidgarLog.info("Equalizer sentence gave no bands", category: .content)
            return .failure(.nothingToShape(note: decoded.curve.note))
        }
        MidgarLog.info("Equalizer sentence gave \(settled.profile.bands.count) bands for output \(output)", category: .content)
        return .success(settled)
    }
}

private extension EqualizerDescriptionService {
    /// Whether this is a phone, a tablet or a computer, which decides what "the built-in speaker" can play.
    static func device() async -> String {
        #if os(macOS)
        "computer"
        #else
        await MainActor.run { UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone" }
        #endif
    }
}

private nonisolated struct CurveReply: Decodable {
    let curve: DescribedCurve
}

private nonisolated struct ProxyError: Decodable {
    let error: String?
}
