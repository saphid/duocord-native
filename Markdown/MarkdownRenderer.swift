import UIKit

extension NSAttributedString.Key {
    nonisolated static let dcLink = NSAttributedString.Key("dcLink")
    nonisolated static let dcUser = NSAttributedString.Key("dcUser")
    nonisolated static let dcChannel = NSAttributedString.Key("dcChannel")
    nonisolated static let dcSpoiler = NSAttributedString.Key("dcSpoiler")
    nonisolated static let dcCodeBlock = NSAttributedString.Key("dcCodeBlock")
    nonisolated static let dcQuote = NSAttributedString.Key("dcQuote")
    nonisolated static let dcInlineCode = NSAttributedString.Key("dcInlineCode")
}

/// An inline custom emoji. Bounds are fixed up front so loading the image
/// never changes the text's height.
nonisolated final class EmojiAttachment: NSTextAttachment {
    let url: URL
    let name: String
    let animated: Bool

    init(url: URL, name: String, size: CGFloat, font: UIFont, animated: Bool = false) {
        self.url = url
        self.name = name
        self.animated = animated
        super.init(data: nil, ofType: nil)
        // Sit on the baseline like text, centred on the cap height.
        bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Names and colours the renderer looks up; captured on the main actor.
nonisolated struct RenderContext: Sendable {
    var userName: @Sendable (Snowflake) -> String?
    var channelName: @Sendable (Snowflake) -> String?
    var role: @Sendable (Snowflake) -> (name: String, color: Int)?
    var baseFont: UIFont
    var textColor: UIColor
}

nonisolated enum MarkdownRenderer {
    /// Messages of only emoji (≤ 27) render large, like Discord's jumbo emoji.
    static func isJumbo(_ blocks: [MDBlock]) -> Bool {
        guard blocks.count == 1, case .paragraph(let inlines) = blocks[0] else { return false }
        var count = 0
        for inline in inlines {
            switch inline {
            case .customEmoji: count += 1
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard trimmed.unicodeScalars.allSatisfy({ $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C || $0.value == 0x200D || $0.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains($0.value) }) else { return false }
                count += trimmed.count
            default: return false
            }
        }
        return count > 0 && count <= 27
    }

    /// A message body in reading order: text runs, and top-level code blocks
    /// that the list shows as non-wrapping, horizontally scrolling cards.
    enum Segment: @unchecked Sendable {
        case text(NSAttributedString)
        case code(NSAttributedString)
    }

    static func renderSegments(_ source: String, context: RenderContext) -> [Segment] {
        let blocks = DiscordMarkdown.parse(source)
        let jumbo = isJumbo(blocks)
        var segments: [Segment] = []
        var current = NSMutableAttributedString()
        func flush() {
            if current.length > 0 { segments.append(.text(current)) }
            current = NSMutableAttributedString()
        }
        for block in blocks {
            if case .codeBlock(_, let code) = block {
                flush()
                // One line separator everywhere, so measured lines match drawn lines.
                let normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
                    .replacingOccurrences(of: "\u{2029}", with: "\n")
                let trimmed = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized
                segments.append(.code(NSAttributedString(string: trimmed.isEmpty ? " " : trimmed,
                                                         attributes: [.font: Theme.mono(14), .foregroundColor: Theme.textPrimary])))
                continue
            }
            if current.length > 0 { current.append(NSAttributedString(string: "\n", attributes: [.font: context.baseFont])) }
            append(block, to: current, context: context, quoteDepth: 0, jumbo: jumbo)
        }
        flush()
        return segments
    }

    static func render(_ source: String, context: RenderContext) -> NSAttributedString {
        let blocks = DiscordMarkdown.parse(source)
        let jumbo = isJumbo(blocks)
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: context.baseFont])) }
            append(block, to: output, context: context, quoteDepth: 0, jumbo: jumbo)
        }
        return output
    }

    private static func paragraphStyle(indent: CGFloat = 0, spacingBefore: CGFloat = 0, lineHeight: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byWordWrapping
        if let lineHeight {
            style.minimumLineHeight = lineHeight
        }
        return style
    }

    private static func append(_ block: MDBlock, to output: NSMutableAttributedString, context: RenderContext,
                               quoteDepth: Int, jumbo: Bool) {
        let quoteIndent: CGFloat = quoteDepth > 0 ? 14 : 0
        switch block {
        case .paragraph(let inlines):
            var attrs: [NSAttributedString.Key: Any] = [
                .font: context.baseFont, .foregroundColor: context.textColor,
                .paragraphStyle: paragraphStyle(indent: quoteIndent),
            ]
            if quoteDepth > 0 { attrs[.dcQuote] = quoteDepth }
            appendInlines(inlines, to: output, attrs: attrs, context: context, emojiSize: jumbo ? 48 : context.baseFont.pointSize * 1.375)
        case .heading(let level, let inlines):
            let sizes: [CGFloat] = [24, 20, 17]
            let font = Theme.font(sizes[level - 1], .bold, style: level == 1 ? .title2 : .headline)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: Theme.textPrimary,
                .paragraphStyle: paragraphStyle(indent: quoteIndent, spacingBefore: 4),
            ]
            if quoteDepth > 0 { attrs[.dcQuote] = quoteDepth }
            appendInlines(inlines, to: output, attrs: attrs, context: context, emojiSize: font.pointSize * 1.2)
        case .subtext(let inlines):
            var attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(12.5, style: .caption1), .foregroundColor: Theme.textMuted,
                .paragraphStyle: paragraphStyle(indent: quoteIndent),
            ]
            if quoteDepth > 0 { attrs[.dcQuote] = quoteDepth }
            appendInlines(inlines, to: output, attrs: attrs, context: context, emojiSize: 16)
        case .quote(let blocks):
            for (index, inner) in blocks.enumerated() {
                if index > 0 {
                    output.append(NSAttributedString(string: "\n", attributes: [.font: context.baseFont, .dcQuote: quoteDepth + 1,
                                                                               .paragraphStyle: paragraphStyle(indent: 14)]))
                }
                append(inner, to: output, context: context, quoteDepth: quoteDepth + 1, jumbo: false)
            }
        case .codeBlock(_, let code):
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = quoteIndent + 10
            style.headIndent = quoteIndent + 10
            style.tailIndent = -10
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 8
            style.lineBreakMode = .byCharWrapping
            var attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.mono(14), .foregroundColor: Theme.textPrimary,
                .paragraphStyle: style, .dcCodeBlock: true,
            ]
            if quoteDepth > 0 { attrs[.dcQuote] = quoteDepth }
            let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
            // One paragraph (line separators), so spacing applies around the block, not between its lines.
            let body = trimmed.isEmpty ? " " : trimmed.replacingOccurrences(of: "\n", with: "\u{2028}")
            output.append(NSAttributedString(string: body, attributes: attrs))
        case .listItem(let marker, let depth, let inlines):
            let indent = quoteIndent + CGFloat(depth) * 18
            let markerWidth: CGFloat = marker == "•" ? 16 : 24
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent + markerWidth
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            var attrs: [NSAttributedString.Key: Any] = [.font: context.baseFont, .foregroundColor: context.textColor, .paragraphStyle: style]
            if quoteDepth > 0 { attrs[.dcQuote] = quoteDepth }
            output.append(NSAttributedString(string: "\(marker)\t", attributes: attrs))
            appendInlines(inlines, to: output, attrs: attrs, context: context, emojiSize: context.baseFont.pointSize * 1.375)
        }
    }

    private static func appendInlines(_ inlines: [MDInline], to output: NSMutableAttributedString,
                                      attrs: [NSAttributedString.Key: Any], context: RenderContext, emojiSize: CGFloat) {
        for inline in inlines {
            appendInline(inline, to: output, attrs: attrs, context: context, emojiSize: emojiSize)
        }
    }


    private static func appendInline(_ inline: MDInline, to output: NSMutableAttributedString,
                                     attrs: [NSAttributedString.Key: Any], context: RenderContext, emojiSize: CGFloat) {
        let font = attrs[.font] as? UIFont ?? context.baseFont
        func styled(_ traits: UIFontDescriptor.SymbolicTraits) -> [NSAttributedString.Key: Any] {
            var copy = attrs
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) ?? font.fontDescriptor
            copy[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            return copy
        }
        switch inline {
        case .text(let text):
            output.append(NSAttributedString(string: text, attributes: attrs))
        case .lineBreak:
            output.append(NSAttributedString(string: "\n", attributes: attrs))
        case .bold(let children):
            appendInlines(children, to: output, attrs: styled(.traitBold), context: context, emojiSize: emojiSize)
        case .italic(let children):
            appendInlines(children, to: output, attrs: styled(.traitItalic), context: context, emojiSize: emojiSize)
        case .underline(let children):
            var copy = attrs
            copy[.underlineStyle] = NSUnderlineStyle.single.rawValue
            appendInlines(children, to: output, attrs: copy, context: context, emojiSize: emojiSize)
        case .strike(let children):
            var copy = attrs
            copy[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            appendInlines(children, to: output, attrs: copy, context: context, emojiSize: emojiSize)
        case .spoiler(let children):
            var copy = attrs
            // Random, not a shared counter: rendering runs concurrently.
            copy[.dcSpoiler] = Int.random(in: 1...Int.max)
            appendInlines(children, to: output, attrs: copy, context: context, emojiSize: emojiSize)
        case .code(let code):
            var copy = attrs
            copy[.font] = Theme.mono(font.pointSize * 0.875)
            copy[.backgroundColor] = Theme.codeBackground
            copy[.dcInlineCode] = true
            output.append(NSAttributedString(string: "\u{2009}\(code)\u{2009}", attributes: copy))
        case .link(let label, let url):
            var copy = attrs
            copy[.foregroundColor] = Theme.link
            copy[.dcLink] = url
            appendInlines(label, to: output, attrs: copy, context: context, emojiSize: emojiSize)
        case .autolink(let url):
            var copy = attrs
            copy[.foregroundColor] = Theme.link
            copy[.dcLink] = url
            output.append(NSAttributedString(string: url, attributes: copy))
        case .userMention(let id):
            var copy = attrs
            copy[.foregroundColor] = Theme.mentionText
            copy[.backgroundColor] = Theme.mentionBackground
            copy[.dcUser] = id.description
            copy[.font] = UIFont.systemFont(ofSize: font.pointSize, weight: .medium)
            output.append(NSAttributedString(string: "@\(context.userName(id) ?? "unknown-user")", attributes: copy))
        case .roleMention(let id):
            var copy = attrs
            let role = context.role(id)
            let color = role.map { $0.color != 0 ? UIColor.role($0.color) : Theme.mentionText } ?? Theme.mentionText
            copy[.foregroundColor] = color
            copy[.backgroundColor] = color.withAlphaComponent(0.16)
            copy[.font] = UIFont.systemFont(ofSize: font.pointSize, weight: .medium)
            output.append(NSAttributedString(string: "@\(role?.name ?? "deleted-role")", attributes: copy))
        case .channelMention(let id):
            var copy = attrs
            copy[.foregroundColor] = Theme.mentionText
            copy[.backgroundColor] = Theme.mentionBackground
            copy[.dcChannel] = id.description
            copy[.font] = UIFont.systemFont(ofSize: font.pointSize, weight: .medium)
            output.append(NSAttributedString(string: "#\(context.channelName(id) ?? "unknown")", attributes: copy))
        case .everyone(let word):
            var copy = attrs
            copy[.foregroundColor] = Theme.mentionText
            copy[.backgroundColor] = Theme.mentionBackground
            copy[.font] = UIFont.systemFont(ofSize: font.pointSize, weight: .medium)
            output.append(NSAttributedString(string: word, attributes: copy))
        case .customEmoji(let name, let id, let animated):
            let size = emojiSize
            // Mock data's emoji draw generated images (see `Emoji.url`).
            let url = id.raw < 1_000_000 ? URL(string: animated ? "mock://animation/pulse.gif" : "mock://emoji/\(id)")!
                : URL(string: "https://cdn.discordapp.com/emojis/\(id).\(animated ? "gif" : "webp")?size=\(cdnSize(Int(size * 2)))&quality=lossless")!
            let attachment = EmojiAttachment(url: url, name: name, size: size, font: font, animated: animated)
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
            output.append(string)
        case .timestamp(let unix, let style):
            var copy = attrs
            copy[.backgroundColor] = Theme.codeBackground
            output.append(NSAttributedString(string: formatTimestamp(unix, style: style), attributes: copy))
        }
    }

    static func formatTimestamp(_ unix: Int, style: Character) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        switch style {
        case "t": return date.formatted(date: .omitted, time: .shortened)
        case "T": return date.formatted(date: .omitted, time: .standard)
        case "d": return date.formatted(date: .numeric, time: .omitted)
        case "D": return date.formatted(date: .long, time: .omitted)
        case "F": return date.formatted(date: .complete, time: .shortened)
        case "R": return date.formatted(.relative(presentation: .named))
        default: return date.formatted(date: .long, time: .shortened)
        }
    }

    /// Plain text for previews, notifications and accessibility. Spoilers stay hidden.
    static func plainText(_ source: String, context: RenderContext) -> String {
        redactingSpoilers(render(source, context: context)).string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Replaces spoiler ranges with a placeholder, for surfaces that can't
    /// cover and reveal them (snippets, notifications, plain text).
    static func redactingSpoilers(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let output = NSMutableAttributedString(attributedString: text)
        var ranges: [NSRange] = []
        text.enumerateAttribute(.dcSpoiler, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        for range in ranges.reversed() {
            var attrs = output.attributes(at: range.location, effectiveRange: nil)
            attrs[.dcSpoiler] = nil
            attrs[.foregroundColor] = Theme.textMuted
            attrs[.backgroundColor] = Theme.spoiler
            output.replaceCharacters(in: range, with: NSAttributedString(string: " spoiler ", attributes: attrs))
        }
        return output
    }
}
