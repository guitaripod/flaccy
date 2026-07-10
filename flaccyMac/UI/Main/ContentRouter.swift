import AppKit

/// Hosts the selected section's view controller in the split view's content
/// column. Stage A ships the album grid; every other section renders a
/// placeholder that later stages replace with their real controllers.
final class ContentRouter: NSViewController {

    private(set) var currentSection: SidebarSection?
    private var currentChild: NSViewController?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    func show(_ section: SidebarSection) {
        guard section != currentSection else { return }
        currentSection = section

        let next = makeController(for: section)
        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentChild = next
        AppLogger.info("Content router showing \(section.title)", category: .ui)
    }

    private func makeController(for section: SidebarSection) -> NSViewController {
        switch section {
        case .albums:
            AlbumGridViewController()
        default:
            SectionPlaceholderViewController(section: section)
        }
    }
}

/// Empty-shell content for sections whose real UI arrives in later stages.
final class SectionPlaceholderViewController: NSViewController {

    private let section: SidebarSection

    init(section: SidebarSection) {
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()

        let icon = NSImageView(image: NSImage(
            systemSymbolName: section.symbolName, accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "Arriving in a later stage.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
