import FlaccyCore
import Foundation

extension HomePromo.Phase {

    nonisolated init(_ state: EntitlementState) {
        switch state {
        case .trialNotStarted: self = .notStarted
        case .trial(let daysRemaining): self = .trial(daysRemaining: daysRemaining)
        case .expired: self = .expired
        case .purchased: self = .purchased
        }
    }

    /// Whether a card in this phase can quote what the person has set up.
    nonisolated var hasProof: Bool {
        switch self {
        case .trial, .expired: true
        case .notStarted, .purchased: false
        }
    }
}

/// What a card that sells Flaccy Pro says, one set of words for both clients:
/// the paywall's own sentences, resolved against the entitlement and the
/// offers on screen.
struct HomePlanCardContent: Equatable {
    let kicker: String
    let title: String
    let proofLines: [String]
    let primaryTitle: String
    let caption: String?
    let offersRestore: Bool
}

/// What a card that invites music in says.
struct HomeGetStartedContent: Equatable {
    let title: String
    let body: String
    let footnote: String?
}

/// The words of the one promo card Home shows, decided by `HomePromo` and
/// worded by `PaywallCopy`, so a price or a trial date is never spelled twice.
enum HomePromoContent: Equatable {
    case getStarted(HomeGetStartedContent)
    case note(String)
    case plan(HomePlanCardContent)

    /// The most proof lines a card quotes, as many as the paywall's own card.
    static let proofLineLimit = 3

    @MainActor
    static func make(
        for promo: HomePromo,
        proof: [PaywallProof.Line],
        gettingStartedBody: String = HomeCopy.getStartedBody,
        manager: PurchaseManager = .shared
    ) -> HomePromoContent {
        switch promo {
        case .getStarted:
            return .getStarted(HomeGetStartedContent(
                title: HomeCopy.getStartedTitle,
                body: gettingStartedBody,
                footnote: manager.state == .trialNotStarted ? PaywallCopy.trialStartsLine : nil
            ))
        case .trialStartsOnFirstPlay:
            return .note(PaywallCopy.trialStartsLine)
        case .trialValue, .lastDay:
            return .plan(planCard(kicker: PaywallCopy.statusLine(for: manager.state), proof: proof, manager: manager, isExpired: false))
        case .keepListening:
            return .plan(planCard(kicker: PaywallCopy.statusLine(for: .expired), proof: proof, manager: manager, isExpired: true))
        }
    }

    @MainActor
    private static func planCard(
        kicker: String, proof: [PaywallProof.Line], manager: PurchaseManager, isExpired: Bool
    ) -> HomePlanCardContent {
        let lines = proof.prefix(proofLineLimit).map(PaywallCopy.proofLine)
        let offer = manager.lifetimeOfferToPresent
        var caption: String?
        if isExpired {
            var welcomeBackEnds: Date?
            if case .available(let endsAt) = manager.lapsedOfferState { welcomeBackEnds = endsAt }
            caption = PaywallCopy.lifetimeCaption(lifetime: offer, yearly: manager.yearlyOffer, welcomeBackEnds: welcomeBackEnds)
        }
        let state: EntitlementState = isExpired ? .expired : manager.state
        return HomePlanCardContent(
            kicker: kicker,
            title: isExpired || lines.isEmpty ? HomeCopy.keepListeningTitle : PaywallCopy.proofTitle(for: state),
            proofLines: lines,
            primaryTitle: PaywallCopy.purchaseTitle(plan: .lifetime, offer: offer),
            caption: caption,
            offersRestore: isExpired
        )
    }
}

/// Fetches the prices a sales card quotes when none have loaded yet, once per
/// launch: the card shows "Get Lifetime" until then and the price when the
/// store answers, which posts the state change Home already rebuilds on.
@MainActor
enum HomePromoOffers {

    private static var requested = false

    static func loadIfNeeded(for promo: HomePromo?) {
        guard let promo, !requested else { return }
        switch promo {
        case .trialValue, .lastDay, .keepListening: break
        case .getStarted, .trialStartsOnFirstPlay: return
        }
        let manager = PurchaseManager.shared
        guard manager.offers.isEmpty else { return }
        requested = true
        Task { await manager.loadLapsedOfferIfNeeded() }
    }
}

/// The sample-album button's words for the state the download is in, the same
/// ones the Library's empty state gives its button.
struct HomeSampleButton: Equatable {
    let title: String
    let subtitle: String
    let isDownloading: Bool

    @MainActor
    static func current(service: SampleMusicService = .shared) -> HomeSampleButton {
        if service.isDownloading {
            return HomeSampleButton(
                title: service.progressText.isEmpty ? String(localized: "Downloading…") : service.progressText,
                subtitle: String(localized: "About 130 MB of 24-bit FLAC"),
                isDownloading: true
            )
        }
        switch service.interruption {
        case .resumable:
            return HomeSampleButton(
                title: String(localized: "Resume Download"),
                subtitle: String(localized: "Interrupted — picks up where it stopped"),
                isDownloading: false
            )
        case .unreachable:
            return HomeSampleButton(
                title: String(localized: "Try Again"),
                subtitle: String(localized: "Couldn't reach the sample music server — check your connection"),
                isDownloading: false
            )
        case nil:
            return HomeSampleButton(
                title: HomeCopy.playSampleAlbum,
                subtitle: String(localized: "Bach, lossless, free · 130 MB"),
                isDownloading: false
            )
        }
    }
}
