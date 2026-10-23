import ImageIO
import MidgarCore
import UIKit

/// A single muted, rounded placeholder block with an animated diagonal sheen. On
/// Reduce Motion the sheen holds still, reading as a soft static card.
final class ShimmerBlock: UIView {
    let sheen = CAGradientLayer()

    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        sheen.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.locations = [0, 0.5, 1]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(sheen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sheen.frame = bounds
    }

    func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.35
        sweep.repeatCount = .infinity
        sheen.add(sweep, forKey: "shimmer")
    }

    func stopAnimating() { sheen.removeAnimation(forKey: "shimmer") }
}

/// A full-screen skeleton mirroring the Recap layout — profile, top-artist row,
/// album grid, track rows, clock, and heatmap — shown while a period's data is
/// still loading so the screen is never bare or a lone spinner. All blocks share
/// one shimmer that starts/stops with `startAnimating()`/`stopAnimating()`.
final class RecapSkeletonView: UIView {
    var blocks: [ShimmerBlock] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func startAnimating() { blocks.forEach { $0.startAnimating() } }
    func stopAnimating() { blocks.forEach { $0.stopAnimating() } }

    func block(_ cornerRadius: CGFloat = 12) -> ShimmerBlock {
        let block = ShimmerBlock(cornerRadius: cornerRadius)
        block.translatesAutoresizingMaskIntoConstraints = false
        blocks.append(block)
        return block
    }

    func buildLayout() {
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        content.addArrangedSubview(profileSkeleton())
        content.addArrangedSubview(pill(width: 220, height: 20))
        content.addArrangedSubview(artistRowSkeleton())
        content.addArrangedSubview(header())
        content.addArrangedSubview(albumGridSkeleton())
        content.addArrangedSubview(header())
        content.addArrangedSubview(trackListSkeleton())
        content.addArrangedSubview(fixedBlock(height: 200, cornerRadius: 22))
    }

    func header() -> UIView {
        pill(width: 150, height: 22)
    }

    func pill(width: CGFloat, height: CGFloat) -> UIView {
        let container = UIView()
        let bar = block(height / 2)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: width),
            bar.heightAnchor.constraint(equalToConstant: height),
        ])
        return container
    }

    func fixedBlock(height: CGFloat, cornerRadius: CGFloat) -> ShimmerBlock {
        let block = block(cornerRadius)
        block.heightAnchor.constraint(equalToConstant: height).isActive = true
        return block
    }

    func profileSkeleton() -> UIView {
        let avatar = block(34)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 68),
            avatar.heightAnchor.constraint(equalToConstant: 68),
        ])
        let lines = UIStackView(arrangedSubviews: [pill(width: 160, height: 26), pill(width: 110, height: 14)])
        lines.axis = .vertical
        lines.spacing = 8
        lines.alignment = .leading

        let topRow = UIStackView(arrangedSubviews: [avatar, lines])
        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, fixedBlock(height: 84, cornerRadius: 22)])
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }

    func artistRowSkeleton() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .top
        for _ in 0..<5 {
            let disc = block(40)
            NSLayoutConstraint.activate([
                disc.widthAnchor.constraint(equalToConstant: 80),
                disc.heightAnchor.constraint(equalToConstant: 80),
            ])
            row.addArrangedSubview(disc)
        }
        return row
    }

    func albumGridSkeleton() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        for _ in 0..<3 {
            let cover = block(10)
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor).isActive = true
            row.addArrangedSubview(cover)
        }
        return row
    }

    func trackListSkeleton() -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 14
        for _ in 0..<4 {
            let art = block(6)
            NSLayoutConstraint.activate([
                art.widthAnchor.constraint(equalToConstant: 40),
                art.heightAnchor.constraint(equalToConstant: 40),
            ])
            let lines = UIStackView(arrangedSubviews: [pill(width: 180, height: 15), pill(width: 120, height: 11)])
            lines.axis = .vertical
            lines.spacing = 6
            lines.alignment = .leading
            let rowStack = UIStackView(arrangedSubviews: [art, lines])
            rowStack.axis = .horizontal
            rowStack.spacing = 12
            rowStack.alignment = .center
            column.addArrangedSubview(rowStack)
        }
        return column
    }
}
