import UIKit

/// A picture in a message: attachment, media embed, sticker or embed image.
/// Pixel sizes come from the API, so its box is known before it loads.
nonisolated struct MediaItem: Hashable, @unchecked Sendable {
    var url: URL
    var openURL: URL
    var width: CGFloat
    var height: CGFloat
    var isVideo: Bool
    var isSpoiler: Bool
    var alt: String?
    /// The poster/open target stays distinct from a gifv's native video URL.
    var loopVideoURL: URL? = nil
    var hasPoster = true
}

nonisolated struct FileItem: Hashable, Sendable {
    var name: String
    var size: Int
    var url: URL
    var isSpoiler = false
    var attachmentID: Snowflake? = nil
    var messageID: Snowflake? = nil
}

nonisolated struct ReactionItem: Hashable, @unchecked Sendable {
    var emoji: Emoji
    var count: Int
    var me: Bool
    var countText: String
}

nonisolated struct RenderedEmbed: @unchecked Sendable {
    var color: UIColor?
    var author: NSAttributedString?
    var title: NSAttributedString?
    var titleURL: URL?
    var body: NSAttributedString?
    var fields: [(name: NSAttributedString, value: NSAttributedString, inline: Bool)]
    var image: MediaItem?
    var thumbnail: MediaItem?
    var footer: NSAttributedString?
    var url: URL?
}

nonisolated struct ReplyPreview: @unchecked Sendable {
    var messageID: Snowflake?
    var avatarURL: URL?
    var name: String
    var nameColor: UIColor
    var snippet: String
}

/// Width-independent presentation of one message, built once per content
/// change from the message and the store.
nonisolated struct RenderedMessage: @unchecked Sendable {
    var id: Snowflake
    var authorID: Snowflake
    var isContinuation: Bool
    var authorName: String
    var authorColor: UIColor
    var isBot: Bool
    var avatarURL: URL?
    var timestamp: String
    var shortTime: String
    var reply: ReplyPreview?
    var body: NSAttributedString?
    /// The body split into text runs and code cards, in order.
    var segments: [MarkdownRenderer.Segment] = []
    var systemIcon: String?
    var media: [MediaItem]
    var files: [FileItem]
    var embeds: [RenderedEmbed]
    var reactions: [ReactionItem]
    /// The small "add reaction" pill after existing reactions.
    var showsAddReaction = false
    var isMentioned: Bool
    var sendState: SendState?
    var accessibilityText: String
    /// Changes whenever anything that affects height changes.
    var contentKey: Int
    /// The source message's hash; a cached render is reused only while it matches.
    var source: Int = 0
    var hidesBlocked = false
}

/// Exact frames for a rendered message at one width.
nonisolated struct MessageLayout: @unchecked Sendable {
    struct EmbedLayout {
        var frame: CGRect
        var author: CGRect?
        var title: CGRect?
        var body: CGRect?
        var fields: [(name: CGRect, value: CGRect)]
        var image: CGRect?
        var thumbnail: CGRect?
        var footer: CGRect?
    }

    var height: CGFloat
    var avatar: CGRect?
    var header: CGRect?
    var reply: CGRect?
    var body: CGRect?
    /// One frame per body segment; code frames carry their scrollable content width.
    var segments: [(frame: CGRect, contentWidth: CGFloat)] = []
    var media: [CGRect]
    var files: [CGRect]
    var embeds: [EmbedLayout]
    var reactions: [CGRect]
    var addReaction: CGRect?
    var status: CGRect?
}

/// Measures attributed text with the same TextKit 1 setup `RichTextView`
/// draws with, so measured and drawn heights agree to the point.
nonisolated enum TextMeasurer {
    static func size(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        guard text.length > 0, width > 0 else { return .zero }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

nonisolated enum MessageMetrics {
    static let sideInset: CGFloat = 16
    static let avatarSize: CGFloat = 40
    static let contentLeft: CGFloat = sideInset + avatarSize + 12
    static let groupTopPadding: CGFloat = 14
    static let continuationTopPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 3
    static let blockSpacing: CGFloat = 6
    static let replyHeight: CGFloat = 22
    static let fileHeight: CGFloat = 56
    static let reactionHeight: CGFloat = 30
    static let reactionSpacing: CGFloat = 6
    static let addReactionWidth: CGFloat = 40
    static let embedMaxWidth: CGFloat = 432
    static let embedPadding: CGFloat = 12
    static let thumbnailSize: CGFloat = 80
    static let codePadding: CGFloat = 10

    static var headerHeight: CGFloat { ceil(Theme.authorName.lineHeight) }

    static func mediaMaxHeight(for width: CGFloat) -> CGFloat { width < 500 ? 300 : 350 }
}

nonisolated enum MessageLayoutEngine {
    static func layout(_ message: RenderedMessage, width: CGFloat) -> MessageLayout {
        let m = MessageMetrics.self
        let contentWidth = max(80, width - m.contentLeft - m.sideInset)
        var layout = MessageLayout(height: 0, media: [], files: [], embeds: [], reactions: [])
        // System lines (joins, pins, boosts): an icon in the avatar column, one compact row.
        if message.systemIcon != nil, let body = message.body {
            let top: CGFloat = 6
            let size = TextMeasurer.size(body, width: contentWidth)
            let lineHeight = max(20, size.height)
            layout.avatar = CGRect(x: m.sideInset + (m.avatarSize - 20) / 2, y: top + (min(lineHeight, 22) - 20) / 2, width: 20, height: 20)
            layout.body = CGRect(x: m.contentLeft, y: top, width: contentWidth, height: size.height)
            layout.height = ceil(top + lineHeight + 6)
            return layout
        }
        var y: CGFloat = message.isContinuation ? m.continuationTopPadding : m.groupTopPadding

        if let _ = message.reply, !message.isContinuation {
            layout.reply = CGRect(x: m.contentLeft - 28, y: y, width: contentWidth + 28, height: m.replyHeight)
            y += m.replyHeight + 2
        }
        if !message.isContinuation {
            layout.avatar = CGRect(x: m.sideInset, y: y + 1, width: m.avatarSize, height: m.avatarSize)
            layout.header = CGRect(x: m.contentLeft, y: y, width: contentWidth, height: m.headerHeight)
            y += m.headerHeight + 1
        }
        if !message.segments.isEmpty {
            let top = y
            for (index, segment) in message.segments.enumerated() {
                switch segment {
                case .text(let text):
                    if index > 0 { y += 4 }
                    let size = TextMeasurer.size(text, width: contentWidth)
                    layout.segments.append((CGRect(x: m.contentLeft, y: y, width: contentWidth, height: size.height), contentWidth))
                    y += size.height
                case .code(let code):
                    // Lines never wrap: the card scrolls sideways, so its height is exact.
                    y += index > 0 ? 6 : 2
                    let lines = max(1, code.string.components(separatedBy: "\n").count)
                    let font = Theme.mono(14)
                    let natural = ceil(code.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], context: nil).width)
                    let height = ceil(CGFloat(lines) * font.lineHeight) + m.codePadding * 2
                    let frame = CGRect(x: m.contentLeft, y: y, width: min(contentWidth, max(80, natural + m.codePadding * 2 + 2)), height: height)
                    layout.segments.append((frame, natural + m.codePadding * 2))
                    y += height + 2
                }
            }
            layout.body = CGRect(x: m.contentLeft, y: top, width: contentWidth, height: y - top)
        }
        if message.isContinuation == false, message.segments.isEmpty, message.systemIcon == nil {
            // Header-only messages (attachment only) still breathe a little.
            y += 2
        }

        // Media: one picture fits its box; several go in a two-column grid.
        if !message.media.isEmpty {
            y += message.segments.isEmpty ? 2 : m.blockSpacing
            let maxWidth = min(contentWidth, 400)
            if message.media.count == 1 {
                let item = message.media[0]
                let size = fit(item, maxWidth: maxWidth, maxHeight: m.mediaMaxHeight(for: width))
                layout.media.append(CGRect(x: m.contentLeft, y: y, width: size.width, height: size.height))
                y += size.height
            } else {
                let gap: CGFloat = 4
                let cell = floor(min(200, (maxWidth - gap) / 2))
                for (index, _) in message.media.enumerated() {
                    let column = CGFloat(index % 2), row = CGFloat(index / 2)
                    layout.media.append(CGRect(x: m.contentLeft + column * (cell + gap), y: y + row * (cell + gap), width: cell, height: cell))
                }
                let rows = CGFloat((message.media.count + 1) / 2)
                y += rows * cell + (rows - 1) * gap
            }
        }

        for _ in message.files {
            y += m.blockSpacing
            layout.files.append(CGRect(x: m.contentLeft, y: y, width: min(contentWidth, 400), height: m.fileHeight))
            y += m.fileHeight
        }

        for embed in message.embeds {
            y += m.blockSpacing
            let embedLayout = layoutEmbed(embed, x: m.contentLeft, y: y, maxWidth: min(contentWidth, m.embedMaxWidth), viewWidth: width)
            layout.embeds.append(embedLayout)
            y = embedLayout.frame.maxY
        }

        if !message.reactions.isEmpty {
            y += m.blockSpacing
            var x = m.contentLeft
            let font = Theme.smallBold
            for reaction in message.reactions {
                let countWidth = ceil((reaction.countText as NSString).size(withAttributes: [.font: font]).width)
                let pillWidth = 8 + 20 + 6 + countWidth + 10
                if x + pillWidth > m.contentLeft + contentWidth, x > m.contentLeft {
                    x = m.contentLeft
                    y += m.reactionHeight + m.reactionSpacing
                }
                layout.reactions.append(CGRect(x: x, y: y, width: pillWidth, height: m.reactionHeight))
                x += pillWidth + m.reactionSpacing
            }
            if message.showsAddReaction {
                if x + m.addReactionWidth > m.contentLeft + contentWidth, x > m.contentLeft {
                    x = m.contentLeft
                    y += m.reactionHeight + m.reactionSpacing
                }
                layout.addReaction = CGRect(x: x, y: y, width: m.addReactionWidth, height: m.reactionHeight)
            }
            y += m.reactionHeight
        }

        if message.sendState != nil {
            y += 2
            layout.status = CGRect(x: m.contentLeft, y: y, width: contentWidth, height: ceil(Theme.small.lineHeight))
            y += ceil(Theme.small.lineHeight)
        }

        layout.height = ceil(y + m.bottomPadding)
        if let avatar = layout.avatar { layout.height = max(layout.height, ceil(avatar.maxY + m.bottomPadding)) }
        return layout
    }

    static func fit(_ item: MediaItem, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let w = max(1, item.width), h = max(1, item.height)
        let scale = min(1, maxWidth / w, maxHeight / h)
        return CGSize(width: max(40, floor(w * scale)), height: max(40, floor(h * scale)))
    }

    private static func layoutEmbed(_ embed: RenderedEmbed, x: CGFloat, y: CGFloat, maxWidth: CGFloat, viewWidth: CGFloat) -> MessageLayout.EmbedLayout {
        let m = MessageMetrics.self
        // Media-only embeds (pictures, gifs) are just the picture.
        if embed.author == nil, embed.title == nil, embed.body == nil, embed.fields.isEmpty, embed.footer == nil,
           let media = embed.image ?? embed.thumbnail {
            let size = fit(media, maxWidth: min(maxWidth, 400), maxHeight: m.mediaMaxHeight(for: viewWidth))
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            return MessageLayout.EmbedLayout(frame: frame, fields: [], image: frame)
        }
        let pad = m.embedPadding
        let innerX = x + 4 + pad
        var innerWidth = maxWidth - 4 - pad * 2
        let hasThumb = embed.thumbnail != nil && embed.image == nil
        // At narrow widths or large text sizes, stack the thumbnail below
        // the text. Reserving a fixed side column can leave no readable width.
        let sideThumb = hasThumb && innerWidth >= max(240, Theme.body.pointSize * 14)
        if sideThumb { innerWidth -= m.thumbnailSize + pad }
        var cy = y + pad
        var result = MessageLayout.EmbedLayout(frame: .zero, fields: [])
        func place(_ text: NSAttributedString?, spacing: CGFloat = 6, minimumHeight: CGFloat = 0) -> CGRect? {
            guard let text else { return nil }
            if cy > y + pad { cy += spacing }
            let size = TextMeasurer.size(text, width: innerWidth)
            let rect = CGRect(x: innerX, y: cy, width: innerWidth, height: max(minimumHeight, size.height))
            cy += max(minimumHeight, size.height)
            return rect
        }
        result.author = place(embed.author)
        result.title = place(embed.title, minimumHeight: embed.titleURL == nil ? 0 : 44)
        result.body = place(embed.body)
        if !embed.fields.isEmpty {
            let columns = innerWidth > 300 ? 2 : 1
            var column = 0
            var rowTop = cy + 8
            var rowBottom = rowTop
            let columnWidth = (innerWidth - CGFloat(columns - 1) * 12) / CGFloat(columns)
            for field in embed.fields {
                let inline = field.inline && columns > 1
                if !inline || column >= columns {
                    if column > 0 { rowTop = rowBottom + 8; column = 0 }
                }
                let width = inline ? columnWidth : innerWidth
                let fx = innerX + CGFloat(column) * (columnWidth + 12)
                let nameHeight = TextMeasurer.size(field.name, width: width).height
                let valueHeight = TextMeasurer.size(field.value, width: width).height
                let nameRect = CGRect(x: fx, y: rowTop, width: width, height: nameHeight)
                let valueRect = CGRect(x: fx, y: rowTop + nameHeight + 2, width: width, height: valueHeight)
                result.fields.append((nameRect, valueRect))
                rowBottom = max(rowBottom, valueRect.maxY)
                if inline { column += 1 } else { rowTop = rowBottom + 8; column = 0 }
            }
            cy = rowBottom
        }
        if let image = embed.image {
            cy += 10
            let size = fit(image, maxWidth: maxWidth - 4 - pad * 2, maxHeight: 300)
            result.image = CGRect(x: innerX, y: cy, width: size.width, height: size.height)
            cy += size.height
        }
        result.footer = place(embed.footer, spacing: 8)
        var height = cy - y + pad
        if hasThumb && !sideThumb, let item = embed.thumbnail {
            cy += 8
            let size = fit(item, maxWidth: innerWidth, maxHeight: 160)
            result.thumbnail = CGRect(x: innerX, y: cy, width: size.width, height: size.height)
            cy += size.height
            height = cy - y + pad
        } else if hasThumb {
            result.thumbnail = CGRect(x: x + maxWidth - pad - m.thumbnailSize, y: y + pad, width: m.thumbnailSize, height: m.thumbnailSize)
            height = max(height, m.thumbnailSize + pad * 2)
        }
        // Text-light embeds shrink to their content, like Discord's.
        result.frame = CGRect(x: x, y: y, width: maxWidth, height: ceil(height))
        return result
    }
}
