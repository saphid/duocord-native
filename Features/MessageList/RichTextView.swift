import UIKit

/// Draws an attributed string with TextKit 1 (the same stack `TextMeasurer`
/// sizes with), plus Discord's code-block panels, quote bars and spoilers.
/// Taps resolve links, mentions, channels and spoilers by character.
final class RichTextView: UIView {
    enum Tap {
        case link(URL)
        case user(Snowflake)
        case channel(Snowflake)
    }

    var onTap: ((Tap) -> Void)?
    var onEmojiLoaded: (() -> Void)?

    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var revealedSpoilers = Set<Int>()
    private(set) var attributedText: NSAttributedString?
    private(set) var emojiViews: [(range: NSRange, view: RemoteImageView)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setText(_ text: NSAttributedString?) {
        guard text !== attributedText else { return }
        attributedText = text
        revealedSpoilers = []
        storage.setAttributedString(text ?? NSAttributedString())
        for emoji in emojiViews { emoji.view.setImage(nil, size: .zero); emoji.view.removeFromSuperview() }
        emojiViews = []
        loadEmoji()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override var frame: CGRect {
        didSet { if frame.width != oldValue.width { container.size = CGSize(width: frame.width, height: .greatestFiniteMagnitude); setNeedsDisplay() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if container.size.width != bounds.width {
            container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        layoutEmoji()
    }

    private func loadEmoji() {
        guard let text = attributedText, text.length > 0 else { return }
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? EmojiAttachment else { return }
            // TextKit may coalesce adjacent occurrences of a shared attachment.
            // Each glyph still needs its own surface and fixed geometry.
            for location in range.location..<NSMaxRange(range) {
                let view = RemoteImageView()
                view.contentMode = .scaleAspectFit
                view.isUserInteractionEnabled = false
                view.isAccessibilityElement = false
                view.posterOnly = !attachment.animated || emojiViews.count >= 64
                addSubview(view)
                view.setImage(attachment.url, size: attachment.bounds.size, kind: .emoji)
                emojiViews.append((NSRange(location: location, length: 1), view))
            }
        }
        layoutEmoji()
    }

    private func layoutEmoji() {
        guard let text = attributedText else { return }
        manager.ensureLayout(for: container)
        for (range, view) in emojiViews {
            guard let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? EmojiAttachment else { continue }
            let glyph = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
            view.frame = CGRect(x: rect.minX, y: rect.maxY - attachment.bounds.height,
                                width: attachment.bounds.width, height: attachment.bounds.height)
            let spoiler = text.attribute(.dcSpoiler, at: range.location, effectiveRange: nil) as? Int
            let hidden = spoiler.map { !revealedSpoilers.contains($0) } ?? false
            view.suppressed = hidden
            view.isHidden = hidden
        }
    }

    func toggleEmojiPlayback() {
        for emoji in emojiViews where !emoji.view.isHidden && emoji.view.canToggle { emoji.view.togglePlayback() }
    }

    func revealSpoiler(_ id: Int) {
        revealedSpoilers.insert(id)
        layoutEmoji()
        setNeedsDisplay()
    }

    func revealTextSpoilers() {
        guard let text = attributedText else { return }
        text.enumerateAttribute(.dcSpoiler, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let id = value as? Int { revealedSpoilers.insert(id) }
        }
        layoutEmoji()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let text = attributedText, text.length > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let full = NSRange(location: 0, length: storage.length)
        let glyphs = manager.glyphRange(for: container)

        // Code block panels span the full width behind their lines.
        text.enumerateAttribute(.dcCodeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            let indent = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 10
            box.origin.x = indent - 10
            box.size.width = bounds.width - box.origin.x
            box = box.insetBy(dx: 0, dy: -6)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 6)
            Theme.codeBackground.setFill()
            path.fill()
            Theme.codeBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // Quote bars.
        text.enumerateAttribute(.dcQuote, in: full) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            Theme.quoteBar.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: box.minY, width: 4, height: box.height), cornerRadius: 2).fill()
        }

        // Rounded backgrounds for mentions and inline code instead of flat rects.
        context.saveGState()
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        context.restoreGState()

        // Unrevealed spoilers are covered.
        text.enumerateAttribute(.dcSpoiler, in: full) { value, range, _ in
            guard let id = value as? Int, !revealedSpoilers.contains(id) else { return }
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                Theme.spoiler.setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), cornerRadius: 3).fill()
            }
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let text = attributedText, text.length > 0 else { return }
        let point = gesture.location(in: self)
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < text.length else { return }
        let glyph = manager.glyphIndexForCharacter(at: index)
        let lineRect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard lineRect.insetBy(dx: -8, dy: -6).contains(point) else { return }
        let attrs = text.attributes(at: index, effectiveRange: nil)
        if let spoiler = attrs[.dcSpoiler] as? Int, !revealedSpoilers.contains(spoiler) {
            revealSpoiler(spoiler)
        } else if let emoji = emojiViews.first(where: { NSLocationInRange(index, $0.range) }), emoji.view.canToggle {
            emoji.view.togglePlayback()
        } else if let link = attrs[.dcLink] as? String, let url = URL(string: link) {
            onTap?(.link(url))
        } else if let user = (attrs[.dcUser] as? String).flatMap(Snowflake.init) {
            onTap?(.user(user))
        } else if let channel = (attrs[.dcChannel] as? String).flatMap(Snowflake.init) {
            onTap?(.channel(channel))
        }
    }

    /// Whether a tap at `point` would hit something interactive.
    func isInteractive(at point: CGPoint) -> Bool {
        guard let text = attributedText, text.length > 0 else { return false }
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < text.length else { return false }
        let attrs = text.attributes(at: index, effectiveRange: nil)
        return attrs[.dcLink] != nil || attrs[.dcUser] != nil || attrs[.dcChannel] != nil || attrs[.dcSpoiler] != nil || attrs[.attachment] is EmojiAttachment
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture is UITapGestureRecognizer else { return true }
        return isInteractive(at: gesture.location(in: self))
    }
}
