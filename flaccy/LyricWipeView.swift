import FlaccyCore
import UIKit

/// Draws the line being sung with the sung part in one colour and the rest in
/// another, the edge following the words. It sits over the cell's label while a
/// line with timed words is current, and is hidden otherwise.
final class LyricWipeView: UIView {

    var layout: LyricWipeLayout?
    var edge: LyricWipeEdge = .nothing
    var text = ""
    var words: [LyricsWord] = []
    var font = UIFont.systemFont(ofSize: 24, weight: .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(text: String, words: [LyricsWord], font: UIFont) {
        self.text = text
        self.words = words
        self.font = font
        layout = nil
        edge = .nothing
    }

    /// Moves the edge to a clock position, or hides the view for `nil`.
    func show(_ progress: LyricsLineProgress?) {
        guard let progress, !words.isEmpty else {
            isHidden = true
            return
        }
        guard let layout = currentLayout() else { return }
        let next = layout.edge(for: progress)
        if isHidden || next != edge {
            edge = next
            isHidden = false
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let layout, abs(layout.width - bounds.width) > 0.5 {
            self.layout = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout = currentLayout() else { return }
        layout.draw(edge: edge, in: context)
    }

    func currentLayout() -> LyricWipeLayout? {
        if let layout { return layout }
        guard bounds.width > 1 else { return nil }
        let built = LyricWipeLayout(
            text: text, words: words, font: font, width: bounds.width,
            bright: .white, dim: .white.withAlphaComponent(0.4)
        )
        layout = built
        return built
    }
}
