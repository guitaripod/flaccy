import XCTest
@testable import flaccy

/// The lit chip is always the way back: tapping it again shows everything, it
/// says so with a cross, and the row scrolls to whichever chip lights.
nonisolated final class FilterChipsViewTests: XCTestCase {

    @MainActor private final class Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 200))
        let chips = FilterChipsView(frame: CGRect(x: 0, y: 0, width: 393, height: 46))
        var picked: [LibraryFilter] = []

        init(selected: LibraryFilter) {
            window.addSubview(chips)
            window.isHidden = false
            chips.onSelect = { [unowned self] in picked.append($0) }
            chips.configure(filters: LibraryFilter.allCases, selected: selected)
            chips.layoutIfNeeded()
        }

        func tap(_ filter: LibraryFilter) {
            button(for: filter).sendActions(for: .touchUpInside)
        }

        func button(for filter: LibraryFilter) -> UIButton {
            let label = String(localized: "\(filter.displayName) filter")
            func find(in view: UIView) -> UIButton? {
                if let button = view as? UIButton, button.accessibilityLabel == label { return button }
                for subview in view.subviews {
                    if let found = find(in: subview) { return found }
                }
                return nil
            }
            return find(in: chips)!
        }

        var scrollView: UIScrollView {
            chips.subviews.compactMap { $0 as? UIScrollView }.first!
        }

        func isFullyVisible(_ filter: LibraryFilter) -> Bool {
            let chip = button(for: filter)
            let frame = chip.convert(chip.bounds, to: chips)
            return frame.minX >= 0 && frame.maxX <= chips.bounds.width
        }
    }

    @MainActor func testTappingTheLitChipGoesBackToAll() {
        let rig = Rig(selected: .recentlyPlayed)
        rig.tap(.recentlyPlayed)
        XCTAssertEqual(rig.picked, [.all])
        XCTAssertTrue(rig.button(for: .all).isSelected)
        XCTAssertFalse(rig.button(for: .recentlyPlayed).isSelected)
    }

    @MainActor func testTappingAnotherChipLightsIt() {
        let rig = Rig(selected: .all)
        rig.tap(.lossless)
        XCTAssertEqual(rig.picked, [.lossless])
        XCTAssertTrue(rig.button(for: .lossless).isSelected)
    }

    @MainActor func testTappingTheLitAllChipChangesNothing() {
        let rig = Rig(selected: .all)
        rig.tap(.all)
        XCTAssertEqual(rig.picked, [])
        XCTAssertTrue(rig.button(for: .all).isSelected)
    }

    @MainActor func testOnlyALitChipOtherThanAllCarriesTheCross() {
        let rig = Rig(selected: .recentlyPlayed)
        XCTAssertEqual(rig.button(for: .recentlyPlayed).configuration?.imagePlacement, .trailing)
        XCTAssertNotNil(rig.button(for: .recentlyPlayed).accessibilityHint)
        XCTAssertEqual(rig.button(for: .lossless).configuration?.imagePlacement, .leading)
        XCTAssertNil(rig.button(for: .lossless).accessibilityHint)

        rig.chips.setSelected(.all, animated: false)
        XCTAssertEqual(rig.button(for: .all).configuration?.imagePlacement, .leading)
        XCTAssertNil(rig.button(for: .all).accessibilityHint)
        XCTAssertNil(rig.button(for: .recentlyPlayed).accessibilityHint)
    }

    @MainActor func testAChipLitOffScreenIsScrolledIntoViewAndAllScrollsBack() {
        let rig = Rig(selected: .all)
        XCTAssertFalse(rig.isFullyVisible(.rediscover))

        rig.chips.setSelected(.rediscover, animated: false)
        XCTAssertTrue(rig.isFullyVisible(.rediscover))
        XCTAssertFalse(rig.isFullyVisible(.all))

        rig.tap(.rediscover)
        XCTAssertEqual(rig.picked, [.all])
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(rig.isFullyVisible(.all))
    }

    @MainActor func testAPersistedPivotIsInViewOnceTheRowIsLaidOut() {
        let rig = Rig(selected: .rediscover)
        XCTAssertTrue(rig.isFullyVisible(.rediscover))
    }

    @MainActor func testTheSameSelectionRepeatedLeavesTheRowWhereItWasScrolled() {
        let rig = Rig(selected: .all)
        rig.scrollView.setContentOffset(CGPoint(x: 120, y: 0), animated: false)
        rig.chips.setSelected(.all, animated: false)
        XCTAssertEqual(rig.scrollView.contentOffset.x, 120)
    }
}
