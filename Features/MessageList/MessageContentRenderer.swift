import UIKit

/// Readable, read-only incoming content uses the existing exact-height card
/// pipeline. Flattening containers preserves source order without nested views.
nonisolated enum MessageContentRenderer {
    struct Output {
        var cards: [RenderedEmbed]
        var spoken: String
    }

    static func render(_ message: Message, context: RenderContext) -> Output {
        var builder = Builder(context: context)
        if message.stickerItems.contains(where: { $0.formatType == 3 }) {
            for sticker in message.stickerItems {
                if sticker.formatType == 3 { builder.note("Sticker: \(sticker.name) · Preview unavailable") }
                else {
                    builder.media(ComponentMedia(url: sticker.rasterURL?.absoluteString, width: 160, height: 160),
                                  attachments: [], description: sticker.name, spoiler: false)
                }
            }
        }
        if message.messageReference?.type == 1 || !message.messageSnapshots.isEmpty {
            if message.messageSnapshots.isEmpty { builder.note("Forwarded message unavailable") }
            for snapshot in message.messageSnapshots { builder.snapshot(snapshot, reference: message.messageReference, depth: 0) }
        }
        if let poll = message.poll { builder.poll(poll) }
        if message.type == 46 {
            let fields = message.embeds.flatMap { $0.fields ?? [] }
            let question = fields.first { $0.name == "poll_question_text" }?.value ?? message.poll?.question?.text
            let winner = fields.first { $0.name == "victor_answer_text" }?.value
            builder.note("Poll ended" + (question.map { ": \($0)" } ?? "") + (winner.map { "\nTop answer: \($0)" } ?? ""))
        }
        builder.components(message.components, attachments: message.attachments, depth: 0, spoiler: false)
        if builder.cards.isEmpty, message.flags & (1 << 15) != 0 || !message.components.isEmpty {
            builder.note("App content unavailable · Open in Discord to view this message.")
        }
        if builder.truncated { builder.cards.append(builder.card(title: "Additional content omitted", body: "Open in Discord to read the rest of this message.")) }
        let spoken = builder.cards.map { card in
            let text: [NSAttributedString?] = [card.author, card.title, card.body] + card.fields.flatMap { [$0.name, $0.value] } + [card.footer]
            let words = text.compactMap { $0 }.map { MarkdownRenderer.redactingSpoilers($0).string.replacingOccurrences(of: "\u{FFFC}", with: "emoji") }
            let image = card.image.map { $0.isSpoiler ? "Spoiler media" : ($0.alt ?? ($0.isVideo ? "Video" : "Image")) }
            return (words + [image].compactMap { $0 }).joined(separator: ". ")
        }.joined(separator: ". ")
        return Output(cards: builder.cards, spoken: spoken)
    }

    static func referencedAttachments(_ components: [MessageComponent], attachments: [Attachment], depth: Int = 0) -> Set<Snowflake> {
        guard depth < ContentDecoding.depthLimit else { return [] }
        var result: Set<Snowflake> = []
        for component in components.prefix(ContentDecoding.nodeLimit) {
            let media = [component.media, component.file].compactMap { $0 } + component.items.map(\.media)
            for item in media {
                for attachment in attachments where item.attachmentID == attachment.id || item.url == attachment.url || item.url == "attachment://\(attachment.filename)" {
                    result.insert(attachment.id)
                }
            }
            result.formUnion(referencedAttachments(component.components, attachments: attachments, depth: depth + 1))
            result.formUnion(referencedAttachments(component.accessory, attachments: attachments, depth: depth + 1))
        }
        return result
    }

    private struct Builder {
        let context: RenderContext
        var cards: [RenderedEmbed] = []
        var textRemaining = 24_000
        var truncated = false

        mutating func take(_ text: String) -> String {
            let limit = min(ContentDecoding.textLimit, textRemaining)
            let prefix = String(text.prefix(limit))
            textRemaining -= prefix.count
            if prefix.count < text.count { truncated = true }
            return prefix
        }

        func card(title: String? = nil, body: String? = nil, footer: String? = nil, url: URL? = nil) -> RenderedEmbed {
            RenderedEmbed(color: nil,
                          title: title.map { NSAttributedString(string: $0, attributes: [.font: Theme.font(15, .semibold), .foregroundColor: url == nil ? Theme.textPrimary : Theme.link]) },
                          titleURL: url,
                          body: body.map { MarkdownRenderer.render($0, context: context) }, fields: [],
                          footer: footer.map { NSAttributedString(string: $0, attributes: [.font: Theme.small, .foregroundColor: Theme.textSecondary]) }, url: url)
        }

        mutating func add(_ value: RenderedEmbed) {
            guard cards.count < 80 else { truncated = true; return }
            cards.append(value)
        }

        mutating func note(_ value: String) { let value = take(value); add(card(body: value)) }

        mutating func snapshot(_ value: MessageSnapshot, reference: MessageReference?, depth: Int) {
            guard cards.count < 80, depth < 3 else { truncated = true; return }
            let source: String
            var url: URL?
            if let channel = reference?.channelID {
                source = "From #" + (context.channelName(channel) ?? channel.description)
                if let id = reference?.messageID {
                    url = URL(string: "https://discord.com/channels/\(reference?.guildID?.description ?? "@me")/\(channel)/\(id)")
                }
            } else { source = "Original author unavailable" }
            let date = value.timestamp.flatMap(Self.date).map { MessageBuilder.stamp($0) }
            let attribution = source + (date.map { " · \($0)" } ?? "")
            let body = take(value.content)
            add(card(title: "Forwarded", body: body.isEmpty ? nil : body, footer: attribution, url: url))
            let componentAttachments = MessageContentRenderer.referencedAttachments(value.components, attachments: value.attachments)
            for attachment in value.attachments where !componentAttachments.contains(attachment.id) {
                media(ComponentMedia(url: attachment.url, proxyURL: attachment.proxyURL, width: attachment.width, height: attachment.height,
                                     contentType: attachment.contentType, attachmentID: attachment.id), attachments: value.attachments,
                      description: attachment.description ?? attachment.filename, spoiler: attachment.isSpoiler, asFile: !attachment.isImage && !attachment.isVideo)
            }
            for embed in value.embeds.prefix(10) {
                // All text within a forwarded embed shares the message budget.
                var embed = embed
                embed.title = embed.title.map { take($0) }
                embed.description = embed.description.map { take($0) }
                embed.author = embed.author.map { var v = $0; v.name = take(v.name); return v }
                embed.footer = embed.footer.map { var v = $0; v.text = take(v.text); return v }
                embed.fields = embed.fields.map { fields in fields.prefix(25).map { var f = $0; f.name = take(f.name); f.value = take(f.value); return f } }
                if let rendered = MessageBuilder.renderEmbed(embed, context: context, limitDescription: false) { add(rendered) }
            }
            for sticker in value.stickerItems {
                if sticker.formatType == 3 { note("Sticker: \(sticker.name) · Preview unavailable") }
                else {
                    media(ComponentMedia(url: sticker.rasterURL?.absoluteString, width: 160, height: 160),
                          attachments: [], description: sticker.name, spoiler: false)
                }
            }
            if let poll = value.poll { self.poll(poll) }
            components(value.components, attachments: value.attachments, depth: 0, spoiler: false)
            for nested in value.snapshots { snapshot(nested, reference: nil, depth: depth + 1) }
            if value.truncated { truncated = true }
            if value.content.isEmpty, value.attachments.isEmpty, value.embeds.isEmpty, value.stickerItems.isEmpty,
               value.components.isEmpty, value.poll == nil, value.snapshots.isEmpty, !value.truncated {
                note("Forwarded content unavailable")
            }
        }

        mutating func poll(_ value: MessagePoll) {
            let question = take(value.question?.text ?? "Poll question unavailable")
            let emoji = emojiMarkup(value.question?.emoji)
            let answers = Array((value.answers ?? []).prefix(10))
            let counts = value.results?.answerCounts
            let total = (counts ?? []).reduce(0.0) { $0 + Double(max(0, $1.count)) }
            var result = card(title: "Poll", body: emoji + question,
                              footer: "Read-only · Voting is not supported here.")
            for answer in answers {
                let label = take(answer.media.text ?? "Answer \(answer.answerID)")
                let name = MarkdownRenderer.render(emojiMarkup(answer.media.emoji) + label, context: context)
                let count = counts?.first { $0.id == answer.answerID }
                var summary = "Results unavailable"
                if counts != nil {
                    let votes = max(0, count?.count ?? 0)
                    let percent = total > 0 ? Int((Double(votes) / total * 100).rounded()) : 0
                    summary = "\(votes) vote\(votes == 1 ? "" : "s") · \(percent)% of selections"
                    if count?.meVoted == true { summary += " · You voted" }
                }
                result.fields.append((name, NSAttributedString(string: summary, attributes: [.font: Theme.small, .foregroundColor: Theme.textSecondary]), false))
            }
            if answers.isEmpty { result.body = MarkdownRenderer.render(emoji + question + "\nAnswers unavailable", context: context) }
            var state = value.results?.isFinalized == true ? "Final results" : "Results so far"
            if let expiry = value.expiry.flatMap(Self.date) { state += (value.results?.isFinalized == true ? " · Ended " : " · Ends ") + MessageBuilder.stamp(expiry) }
            state += value.allowMultiselect == true ? " · Multiple answers allowed" : " · One answer"
            result.author = NSAttributedString(string: state, attributes: [.font: Theme.small, .foregroundColor: Theme.textSecondary])
            add(result)
        }

        mutating func components(_ values: [MessageComponent], attachments: [Attachment], depth: Int, spoiler: Bool) {
            guard !values.isEmpty else { return }
            guard depth < ContentDecoding.depthLimit else { truncated = true; return }
            for value in values.prefix(ContentDecoding.nodeLimit) {
                guard cards.count < 80 else { truncated = true; return }
                if value.truncated { truncated = true; continue }
                let hidden = spoiler || value.spoiler == true
                let start = cards.count
                if let content = value.content, !content.isEmpty {
                    let text = take(content)
                    var item = card(body: text)
                    if hidden { item.body = Self.spoiler(item.body) }
                    add(item)
                }
                switch value.type {
                case 1, 9, 10, 17: break // rows, sections, text display, containers
                case 2:
                    let label = take(value.label ?? value.emoji?.name ?? "Button")
                    let link = value.style == 5 ? Self.safeURL(value.url) : nil
                    if let link, value.disabled != true, !hidden {
                        add(card(title: "↗ " + label, footer: "Link · Opens in browser", url: link))
                    } else {
                        note("\(label) · \(value.disabled == true ? "Disabled" : "Interaction not supported") · Open in Discord")
                    }
                case 3, 5, 6, 7, 8:
                    let label = take(value.placeholder ?? value.label ?? "Select menu")
                    let options = value.options.prefix(25).map { emojiMarkup($0.emoji) + $0.label + ($0.description.map { " — " + $0 } ?? "") }.joined(separator: "\n")
                    note(label + " · Selection not supported · Open in Discord" + (options.isEmpty ? "" : "\n" + options))
                case 4:
                    note("\(value.label ?? "Text input") · Input not supported · Open in Discord")
                case 11:
                    media(value.media, attachments: attachments, description: value.description, spoiler: hidden)
                case 12:
                    for item in value.items { media(item.media, attachments: attachments, description: item.description, spoiler: hidden || item.spoiler == true) }
                    if value.items.isEmpty { note("Media gallery unavailable") }
                case 13:
                    media(value.file, attachments: attachments, description: value.description, spoiler: hidden, asFile: true)
                case 14: break // spacing/separator is represented by the card gap
                default:
                    note("Unsupported component (type \(value.type)) · Open in Discord")
                    if value.media != nil { media(value.media, attachments: attachments, description: value.description, spoiler: hidden) }
                    if value.file != nil { media(value.file, attachments: attachments, description: value.description, spoiler: hidden, asFile: true) }
                    for item in value.items { media(item.media, attachments: attachments, description: item.description, spoiler: hidden || item.spoiler == true) }
                }
                components(value.components, attachments: attachments, depth: depth + 1, spoiler: hidden)
                components(value.accessory, attachments: attachments, depth: depth + 1, spoiler: hidden)
                if hidden {
                    for index in start..<cards.count {
                        cards[index].author = Self.spoiler(cards[index].author)
                        cards[index].title = Self.spoiler(cards[index].title)
                        cards[index].body = Self.spoiler(cards[index].body)
                        cards[index].footer = Self.spoiler(cards[index].footer)
                        cards[index].titleURL = nil
                        cards[index].url = nil
                        for field in cards[index].fields.indices {
                            let value = cards[index].fields[field]
                            cards[index].fields[field] = (Self.spoiler(value.name)!, Self.spoiler(value.value)!, value.inline)
                        }
                    }
                }
            }
        }

        mutating func media(_ value: ComponentMedia?, attachments: [Attachment], description: String?, spoiler: Bool, asFile: Bool = false) {
            guard let value else { note(asFile ? "File unavailable" : "Media unavailable"); return }
            let attachment = attachments.first { item in
                item.id == value.attachmentID || value.url == "attachment://\(item.filename)" || value.url == item.url
            }
            let isSpoiler = spoiler || attachment?.isSpoiler == true
            guard let url = Self.safeURL(attachment?.url ?? value.url) else { note(asFile ? "File unavailable" : "Media unavailable"); return }
            let label = take(description ?? attachment?.filename ?? url.lastPathComponent)
            if asFile {
                if isSpoiler { note("Spoiler file · Open in Discord to view") }
                else {
                    let size = attachment.map { " · " + ByteCountFormatter.string(fromByteCount: Int64(max(0, $0.size)), countStyle: .file) } ?? ""
                    add(card(title: "File: " + (label.isEmpty ? "Attachment" : label), footer: "Open file" + size, url: url))
                }
                return
            }
            let preview = Self.safeURL(attachment?.proxyURL ?? value.proxyURL) ?? url
            let width = max(1, min(16_384, attachment?.width ?? value.width ?? 320))
            let height = max(1, min(16_384, attachment?.height ?? value.height ?? 180))
            let video = (attachment?.contentType ?? value.contentType)?.hasPrefix("video/") == true
            let item = MediaItem(url: preview, openURL: url, width: CGFloat(width), height: CGFloat(height), isVideo: video,
                                 isSpoiler: isSpoiler, alt: label)
            var result = card()
            result.image = item
            add(result)
        }

        private func emojiMarkup(_ emoji: Emoji?) -> String {
            guard let emoji else { return "" }
            if let id = emoji.id { return "<:\(emoji.name ?? "emoji"):\(id)> " }
            return (emoji.name ?? "") + " "
        }

        private static func date(_ value: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }

        static func safeURL(_ value: String?) -> URL? {
            guard let value, let url = URL(string: value), ["https", "http", "mock"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }

        private static func spoiler(_ text: NSAttributedString?) -> NSAttributedString? {
            guard let text else { return nil }
            let copy = NSMutableAttributedString(attributedString: text)
            copy.addAttribute(.dcSpoiler, value: 0, range: NSRange(location: 0, length: copy.length))
            return copy
        }
    }
}
