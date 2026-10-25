import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    /// The day-6 runway sits in its own slot between the chips and the status
    /// banner, with its own height constraint, so the two never fight over one.
    func setupRunwayBanner() {
        runwayBanner.onGetLifetime = {
            PurchaseManager.shared.requestPaywall()
        }
        runwayBanner.onDismiss = { [weak self] in
            PurchaseManager.shared.markRunwayPromptShown()
            self?.setRunwayBanner(visible: false)
            MidgarLog.info("Runway banner dismissed", category: .purchases)
        }
        view.addSubview(runwayBanner)
        runwayBannerHeight = runwayBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            runwayBanner.topAnchor.constraint(equalTo: sourceChipsView.bottomAnchor),
            runwayBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            runwayBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            runwayBannerHeight,
        ])
    }

    func setRunwayBanner(visible: Bool) {
        runwayBannerRequested = visible
        applyRunwayBannerVisibility(animated: true)
    }

    /// Sizes the runway slot to the stored request. A request that arrives before the view has loaded is kept in `runwayBannerRequested` and applied by the first render after `setupRunwayBanner` creates the slot.
    func applyRunwayBannerVisibility(animated: Bool) {
        guard isViewLoaded, let height = runwayBannerHeight else { return }
        let show = runwayBannerRequested && !debutOwnsScreen
        let target = show ? runwayBanner.expandedHeight(forWidth: view.bounds.width) : 0
        guard height.constant != target else { return }
        height.constant = target
        runwayBanner.isAccessibilityElement = false
        runwayBanner.accessibilityElementsHidden = !show
        guard animated, !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        }
        if show {
            MidgarLog.info("Runway banner shown", category: .purchases)
        }
    }

    func setupStatusBanner() {
        statusBanner.accessibilityIdentifier = "library.statusBanner"
        statusBanner.onTap = { [weak self] in
            guard let self else { return }
            if self.viewModel.debutIsPending, self.debutView != nil {
                self.presentDebutSheet()
            } else {
                self.navigationController?.pushViewController(EnrichmentReportViewController(), animated: true)
            }
        }
        view.addSubview(statusBanner)
        statusBannerHeight = statusBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            statusBanner.topAnchor.constraint(equalTo: runwayBanner.bottomAnchor),
            statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBannerHeight,
        ])
    }

    func setStatusBanner(visible: Bool, animated: Bool) {
        let target = visible ? LibraryStatusBanner.expandedHeight : 0
        guard statusBannerHeight.constant != target else { return }
        statusBannerHeight.constant = target
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        }
    }
}
