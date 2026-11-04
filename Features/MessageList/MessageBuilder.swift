import UIKit

/// Turns `Message`s into `RenderedMessage`s using the store for names,
/// colours and mentions. Main actor (reads the store).
struct MessageBuilder {
    let store: DiscordStore
    let guildID: Snowflake?

    /// Store lookups for one message, taken on the main actor so the rest of
    /// rendering can run anywhere.
    nonisolated struct Inputs: @unchecked Sendable {
        var name: String
        var color: UIColor
        var mentioned: Bool
        var replyName: String?
        var replyColor: UIColor?
        var forwardChannelName: String? = nil
        var hidesBlocked = false
        var hidesReply = false
        var thread: ThreadLink? = nil
    }

    func inputs(for message: Message) -> Inputs {
        let guild = guildID ?? message.guildID
        let ref = message.referencedMessage?.message
        return Inputs(
            name: store.displayName(for: message.author, in: guild),
            color: store.roleColor(for: message.author.id, in: guild).map(UIColor.role) ?? Theme.textPrimary,
            mentioned: store.mentionsMe(message),
            replyName: ref.map { store.displayName(for: $0.author, in: guild) },
            replyColor: ref.map { store.roleColor(for: $0.author.id, in: guild).map(UIColor.role) ?? Theme.textSecondary },
            forwardChannelName: message.messageReference?.channelID.flatMap { store.channels[$0]?.name },
            hidesBlocked: store.hidesBlockedMessage(message), hidesReply: ref.map { store.hidesBlockedMessage($0) } ?? false,
            thread: threadLink(for: message))
    }

    /// The thread a message links to, named as the store has it now. A
    /// "started a thread" line (type 18) names its thread in the message
    /// reference; a thread made from a message shares that message's id
    /// (HAS_THREAD, flag 32), and Discord may also send the thread itself.
    func threadLink(for message: Message) -> ThreadLink? {
        let id: Snowflake
        var fallback: String?
        if message.type == 18 {
            guard let thread = message.messageReference?.channelID else { return nil }
            id = thread
            fallback = message.content
        } else if message.thread != nil || message.flags & 32 != 0 {
            id = message.thread?.id ?? message.id
            fallback = message.thread?.name
        } else {
            return nil
        }
        // A forum post's starter lives inside its own thread: no self-link.
        guard id != message.channelID else { return nil }
        let name = [store.channel(id)?.name, fallback].compactMap { $0 }.first { !$0.isEmpty } ?? "Thread"
        return ThreadLink(id: id, name: name)
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    func context(font: UIFont = Theme.body, color: UIColor = Theme.textPrimary) -> RenderContext {
        // Snapshot lookups so rendering can't race the store.
        let users = store.users
        let guild = guildID
        var nicks: [Snowflake: String] = [:]
        if let guild {
            for (id, member) in store.members[guild] ?? [:] { if let nick = member.nick { nicks[id] = nick } }
            if let me = store.me, let nick = store.myMembers[guild]?.nick { nicks[me.id] = nick }
        }
        let members = nicks
        let channels = store.channels.mapValues { $0.name ?? "" }
        let roles = guild.flatMap { store.guilds[$0]?.roles } ?? []
        let roleMap = Dictionary(roles.map { ($0.id, (name: $0.name, color: $0.color)) }, uniquingKeysWith: { a, _ in a })
        return RenderContext(
            userName: { id in members[id] ?? users[id]?.displayName },
            channelName: { id in channels[id] },
            role: { id in roleMap[id] },
            baseFont: font,
            textColor: color)
    }

    func render(_ messages: [Message], timeline: MessageTimeline) -> [RenderedMessage] {
        let context = context()
        var result: [RenderedMessage] = []
        result.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            result.append(render(message, previous: previous, context: context, sendState: timeline.sendState(for: message)))
        }
        return result
    }

    nonisolated static func isContinuation(_ message: Message, after previous: Message?) -> Bool {
        guard let previous, !message.isSystem, !previous.isSystem, message.referencedMessage == nil,
              message.messageReference == nil || message.type != 19,
              previous.author.id == message.author.id else { return false }
        let gap = message.date.timeIntervalSince(previous.date)
        return gap >= 0 && gap < 7 * 60 && Calendar.current.isDate(message.date, inSameDayAs: previous.date)
    }

    func render(_ message: Message, previous: Message?, context: RenderContext, sendState: SendState?) -> RenderedMessage {
        Self.build(message, previous: previous, inputs: inputs(for: message), context: context, sendState: sendState)
    }

    /// Pure rendering: safe off the main thread.
    nonisolated static func build(_ message: Message, previous: Message?, inputs: Inputs, context: RenderContext,
                                  sendState: SendState?) -> RenderedMessage {
        if inputs.hidesBlocked {
            let text = "Blocked message. Reveal message"
            let body = NSAttributedString(string: text, attributes: [.font: Theme.body, .foregroundColor: Theme.textMuted])
            return RenderedMessage(id: message.id, authorID: message.author.id, isContinuation: false,
                authorName: "Blocked user", authorColor: Theme.textMuted, isBot: false, avatarURL: nil,
                timestamp: "", shortTime: "", reply: nil, body: body, segments: [.text(body)], systemIcon: "hand.raised",
                media: [], files: [], embeds: [], reactions: [], isMentioned: false, sendState: nil,
                accessibilityText: text, contentKey: sourceHash(message, inputs: inputs), source: sourceHash(message, inputs: inputs), hidesBlocked: true)
        }
        // A message that mentions you always shows who wrote it, so opening
        // it from a notification lands on the author as well as the text.
        let continuation = isContinuation(message, after: previous) && !inputs.mentioned
        let name = inputs.name
        let color = inputs.color
        var body: NSAttributedString?
        var segments: [MarkdownRenderer.Segment] = []
        var systemIcon: String?
        if message.isSystem {
            let (icon, text) = systemLine(message, name: name)
            systemIcon = icon
            let line = NSMutableAttributedString(string: "", attributes: [:])
            if message.type == 18, let thread = inputs.thread {
                line.append(NSAttributedString(string: "\(name) started a thread: ", attributes: [.font: Theme.font(15), .foregroundColor: Theme.textSecondary]))
                line.append(threadLinkText(thread, font: Theme.font(15, .semibold)))
            } else {
                line.append(NSAttributedString(string: text, attributes: [.font: Theme.font(15), .foregroundColor: Theme.textSecondary]))
            }
            body = line
            segments = [.text(line)]
        } else if !message.content.isEmpty {
            var parts = MarkdownRenderer.renderSegments(message.content, context: context)
            let edited = NSAttributedString(string: " (edited)", attributes: [.font: Theme.font(11, style: .caption2), .foregroundColor: Theme.textMuted])
            if message.isEdited {
                if case .text(let last)? = parts.last {
                    let copy = NSMutableAttributedString(attributedString: last)
                    copy.append(edited)
                    parts[parts.count - 1] = .text(copy)
                } else {
                    parts.append(.text(NSAttributedString(string: "(edited)", attributes: [.font: Theme.font(11, style: .caption2), .foregroundColor: Theme.textMuted])))
                }
            }
            if sendState != nil {
                parts = parts.map { part in
                    guard case .text(let text) = part else { return part }
                    let copy = NSMutableAttributedString(attributedString: text)
                    copy.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: copy.length))
                    return .text(copy)
                }
            }
            segments = parts
            let whole = NSMutableAttributedString()
            for part in parts {
                switch part {
                case .text(let text), .code(let text):
                    if whole.length > 0 { whole.append(NSAttributedString(string: "\n")) }
                    whole.append(text)
                }
            }
            body = whole
        }
        // A thread made from this message: a link under it, as Discord shows.
        if !message.isSystem, let thread = inputs.thread {
            let line = NSMutableAttributedString(string: "Thread · ", attributes: [.font: Theme.font(14), .foregroundColor: Theme.textMuted])
            line.append(threadLinkText(thread, font: Theme.font(14, .semibold), suffix: " ›"))
            segments.append(.text(line))
            let whole = NSMutableAttributedString(attributedString: body ?? NSAttributedString())
            if whole.length > 0 { whole.append(NSAttributedString(string: "\n")) }
            whole.append(line)
            body = whole
        }

        var media: [MediaItem] = []
        var files: [FileItem] = []
        let componentAttachments = MessageContentRenderer.referencedAttachments(message.components, attachments: message.attachments)
        for attachment in message.attachments where !componentAttachments.contains(attachment.id) {
            if (attachment.isImage || attachment.isVideo), let w = attachment.width, let h = attachment.height, w > 0, h > 0,
               let open = URL(string: attachment.url) {
                let preview: URL
                if attachment.isVideo {
                    // The media proxy serves a poster frame for videos.
                    preview = URL(string: (attachment.proxyURL ?? attachment.url) + (attachment.proxyURL?.contains("?") == true ? "&" : "?") + "format=webp") ?? open
                } else {
                    preview = URL(string: attachment.proxyURL ?? attachment.url) ?? open
                }
                media.append(MediaItem(url: preview, openURL: open, width: CGFloat(w), height: CGFloat(h),
                                       isVideo: attachment.isVideo, isSpoiler: attachment.isSpoiler, alt: attachment.description))
            } else if let url = URL(string: attachment.url) {
                files.append(FileItem(name: attachment.filename, size: attachment.size, url: url, isSpoiler: attachment.isSpoiler,
                                      attachmentID: attachment.id, messageID: message.id))
            }
        }
        // Raster-only messages retain their established media presentation. When
        // unsupported stickers occur, the card renderer keeps the whole sequence ordered.
        let hasUnsupportedSticker = message.stickerItems.contains { $0.formatType == 3 }
        for sticker in message.stickerItems where !hasUnsupportedSticker {
            if let url = sticker.rasterURL {
                media.append(MediaItem(url: url, openURL: url, width: 160, height: 160, isVideo: false, isSpoiler: false, alt: sticker.name))
            }
        }

        let primary = MessageContentRenderer.render(message, context: context)
        let embeds = message.embeds.compactMap { renderEmbed($0, context: context) } + primary.cards
        let reactions = message.reactions.map { ReactionItem(emoji: $0.emoji, count: $0.count, me: $0.me, countText: String($0.count)) }
        let reply = message.referencedMessage.map { ref -> ReplyPreview in
            let refMessage = ref.message
            if inputs.hidesReply {
                return ReplyPreview(messageID: refMessage.id, avatarURL: nil, name: "Blocked user", nameColor: Theme.textMuted,
                                    snippet: "Blocked message")
            }
            let refName = inputs.replyName ?? refMessage.author.displayName
            let refColor = inputs.replyColor ?? Theme.textSecondary
            var snippet = MarkdownRenderer.plainText(refMessage.content, context: context).replacingOccurrences(of: "\n", with: " ")
            if snippet.isEmpty { snippet = refMessage.attachments.isEmpty ? "Click to see message" : "Attachment" }
            return ReplyPreview(messageID: refMessage.id, avatarURL: refMessage.author.avatarURL(size: 32), name: refName,
                                nameColor: refColor, snippet: snippet)
        } ?? (message.type == 19 ? ReplyPreview(messageID: nil, avatarURL: nil, name: "", nameColor: Theme.textMuted,
                                               snippet: "Original message was deleted") : nil)

        let mentioned = inputs.mentioned
        let time = timeFormatter.string(from: message.date)
        let stamp = stamp(message.date)
        var hasher = Hasher()
        hasher.combine(message)
        hasher.combine(message.content)
        hasher.combine(message.editedTimestamp)
        hasher.combine(message.reactions)
        hasher.combine(message.embeds.count)
        hasher.combine(message.attachments.count)
        hasher.combine(continuation)
        hasher.combine(sendState == nil ? 0 : (sendState == .sending ? 1 : 2))
        hasher.combine(name)
        hasher.combine(inputs.forwardChannelName)
        hasher.combine(inputs.hidesBlocked)
        hasher.combine(inputs.hidesReply)
        hasher.combine(inputs.thread)

        var spoken = continuation ? "" : "\(name), \(stamp). "
        if let reply { spoken += "Replying to \(reply.name): \(reply.snippet). " }
        spoken += body.map { MarkdownRenderer.redactingSpoilers($0).string.replacingOccurrences(of: "\u{FFFC}", with: "emoji") } ?? ""
        if !primary.spoken.isEmpty { spoken += " " + primary.spoken }
        if !media.isEmpty { spoken += " \(media.count) image\(media.count == 1 ? "" : "s")." }
        if !files.isEmpty { spoken += " \(files.count) file\(files.count == 1 ? "" : "s")." }
        if !reactions.isEmpty { spoken += " Reactions: " + reactions.map { "\($0.emoji.name ?? "") \($0.count)" }.joined(separator: ", ") }

        return RenderedMessage(
            id: message.id, authorID: message.author.id, isContinuation: continuation, authorName: name,
            authorColor: color, isBot: message.author.bot == true, avatarURL: message.author.avatarURL(size: 80),
            timestamp: stamp, shortTime: time, reply: reply, body: body, segments: segments, systemIcon: systemIcon, media: media, files: files,
            embeds: embeds, reactions: reactions, showsAddReaction: !reactions.isEmpty && sendState == nil,
            isMentioned: mentioned, sendState: sendState,
            accessibilityText: spoken, contentKey: hasher.finalize(), source: sourceHash(message, inputs: inputs), thread: inputs.thread)
    }

    /// The tappable thread name: opens the thread like a channel mention.
    nonisolated private static func threadLinkText(_ thread: ThreadLink, font: UIFont, suffix: String = "") -> NSAttributedString {
        NSAttributedString(string: thread.name + suffix, attributes: [
            .font: font, .foregroundColor: Theme.link, .dcChannel: thread.id.description,
        ])
    }

    /// Everything the render depends on: the message and the store lookups.
    nonisolated static func sourceHash(_ message: Message, inputs: Inputs) -> Int {
        var hasher = Hasher()
        hasher.combine(message)
        hasher.combine(message.referencedMessage?.message.content)
        hasher.combine(inputs.name)
        hasher.combine(inputs.mentioned)
        hasher.combine(inputs.replyName)
        hasher.combine(inputs.forwardChannelName)
        hasher.combine(inputs.hidesBlocked)
        hasher.combine(inputs.hidesReply)
        hasher.combine(inputs.thread)
        return hasher.finalize()
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    nonisolated private static func systemLine(_ message: Message, name: String) -> (String, String) {
        switch message.type {
        case 1: return ("person.badge.plus", "\(name) added someone to the group.")
        case 2: return ("person.badge.minus", "\(name) removed someone from the group.")
        case 3: return ("phone", "\(name) started a call.")
        case 4: return ("pencil", "\(name) changed the channel name: \(message.content)")
        case 6: return ("pin", "\(name) pinned a message to this channel.")
        case 7: return ("arrow.right", "\(name) joined the server.")
        case 8, 9, 10, 11: return ("sparkles", "\(name) boosted the server!")
        case 18: return ("bubble.left.and.bubble.right", "\(name) started a thread: \(message.content)")
        case 21: return ("bubble.left.and.text.bubble.right", "Thread starter message")
        default: return ("info.circle", message.content.isEmpty ? "\(name) did something." : message.content)
        }
    }

    nonisolated static func renderEmbed(_ embed: Embed, context: RenderContext, limitDescription: Bool = true) -> RenderedEmbed? {
        func media(_ value: EmbedMedia?, video: Bool = false, open: String? = nil) -> MediaItem? {
            guard let value, let urlString = value.proxyURL ?? value.url, let url = URL(string: urlString),
                  let w = value.width, let h = value.height, w > 0, h > 0 else { return nil }
            let target = URL(string: open ?? value.url ?? urlString) ?? url
            return MediaItem(url: url, openURL: target, width: CGFloat(w), height: CGFloat(h), isVideo: video, isSpoiler: false, alt: nil)
        }
        if embed.type == "image" || embed.type == "gifv" {
            let poster = media(embed.thumbnail, open: embed.url) ?? media(embed.image, open: embed.url)
            guard var item = poster ?? (embed.type == "gifv" ? media(embed.video, video: true, open: embed.url) : nil) else { return nil }
            item.hasPoster = poster != nil
            if embed.type == "gifv" {
                item.loopVideoURL = (embed.video?.url ?? embed.video?.proxyURL).flatMap(URL.init)
                item.isVideo = item.loopVideoURL != nil
            }
            return RenderedEmbed(color: nil, fields: [], image: item, url: embed.url.flatMap(URL.init))
        }
        var result = RenderedEmbed(color: embed.color.map(UIColor.role), fields: [], url: embed.url.flatMap(URL.init))
        let smallContext = RenderContext(userName: context.userName, channelName: context.channelName, role: context.role,
                                         baseFont: Theme.font(14), textColor: Theme.textSecondary)
        if let provider = embed.provider?.name, embed.author == nil {
            result.author = NSAttributedString(string: provider, attributes: [.font: Theme.font(12, style: .caption1), .foregroundColor: Theme.textMuted])
        }
        if let author = embed.author {
            result.author = NSAttributedString(string: author.name, attributes: [.font: Theme.font(14, .semibold), .foregroundColor: Theme.textPrimary])
        }
        if let title = embed.title, !title.isEmpty {
            result.title = NSAttributedString(string: title, attributes: [
                .font: Theme.font(15, .semibold),
                .foregroundColor: embed.url == nil ? Theme.textPrimary : Theme.link,
            ])
            result.titleURL = embed.url.flatMap(URL.init)
        }
        if let description = embed.description, !description.isEmpty {
            result.body = MarkdownRenderer.render(limitDescription ? String(description.prefix(1500)) : description, context: smallContext)
        }
        for field in (embed.fields ?? []).prefix(25) {
            let name = NSAttributedString(string: field.name, attributes: [.font: Theme.font(13, .semibold), .foregroundColor: Theme.textPrimary])
            let value = MarkdownRenderer.render(field.value, context: smallContext)
            result.fields.append((name, value, field.inline ?? false))
        }
        let isVideo = embed.video != nil
        result.image = media(embed.image) ?? (isVideo ? media(embed.thumbnail, video: true, open: embed.url) : nil)
        if result.image == nil { result.thumbnail = media(embed.thumbnail) }
        if let footer = embed.footer?.text, !footer.isEmpty {
            result.footer = NSAttributedString(string: footer, attributes: [.font: Theme.font(12, style: .caption1), .foregroundColor: Theme.textMuted])
        }
        if result.author == nil, result.title == nil, result.body == nil, result.fields.isEmpty, result.image == nil, result.thumbnail == nil {
            return nil
        }
        return result
    }
}
