import UIKit

/// One place that decides what the runway shows each time the app comes to
/// the front or the entitlement becomes known: the day re-derived first, then
/// the Library's day-6 banner, then the reminders rebuilt for that day. The
/// reminder consent is never asked here — an activation edge is not a completed
/// play, and App Review rejects a modal on foreground — only from
/// `TrialReminderScheduler.optInOpportunity`.
@MainActor
enum TrialRunwayPresenter {

    static func refresh(in window: UIWindow?) {
        let manager = PurchaseManager.shared
        manager.refreshTrialPhase()
        library(in: window)?.setRunwayBanner(visible: manager.runwayBannerIsDue)
        Task { await TrialReminderScheduler.shared.refresh() }
    }

    /// The Library at the root of the window's navigation stack, wherever the
    /// root container has tucked it.
    static func library(in window: UIWindow?) -> LibraryViewController? {
        guard let root = window?.rootViewController else { return nil }
        return firstLibrary(in: root)
    }

    static func topmostViewController(in window: UIWindow?) -> UIViewController? {
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }

    private static func firstLibrary(in controller: UIViewController) -> LibraryViewController? {
        if let library = controller as? LibraryViewController { return library }
        if let nav = controller as? UINavigationController,
           let library = nav.viewControllers.first as? LibraryViewController {
            return library
        }
        for child in controller.children {
            if let library = firstLibrary(in: child) { return library }
        }
        return nil
    }
}
