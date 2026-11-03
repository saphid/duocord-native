import SwiftUI

/// A reveal belongs to this excerpt identity and this relationship/session version.
struct ExcerptRevealScope: Equatable {
    private enum Source: Equatable { case message, forumOwner }
    private let source: Source
    let message: Snowflake
    let channel: Snowflake
    let author: Snowflake
    let relationshipVersion: UInt64
    let peopleEpoch: UUID

    init(message: Message, store: DiscordStore) {
        source = .message
        self.message = message.id
        channel = message.channelID
        author = message.author.id
        relationshipVersion = store.relationshipVersion(message.author.id)
        peopleEpoch = store.peopleEpoch
    }

    init(forumPost: Channel, forum: Snowflake, owner: Snowflake, store: DiscordStore) {
        source = .forumOwner
        message = forumPost.id
        channel = forum
        author = owner
        relationshipVersion = store.relationshipVersion(owner)
        peopleEpoch = store.peopleEpoch
    }
}

struct MessageExcerptPresentation {
    let scope: ExcerptRevealScope
    let concealed: Bool
    let avatarUser: User?
    let segments: [MarkdownRenderer.Segment]
    let fallback: String

    init(message: Message, store: DiscordStore, reveal: ExcerptRevealScope?) {
        scope = ExcerptRevealScope(message: message, store: store)
        concealed = store.isBlocked(message.author.id) && reveal != scope
        avatarUser = concealed ? nil : message.author
        guard !concealed else {
            segments = []
            fallback = "Blocked message"
            return
        }
        let context = MessageBuilder(store: store, guildID: message.guildID).context(font: Theme.font(15))
        segments = message.content.isEmpty ? [] : MarkdownRenderer.renderSegments(message.content, context: context).map { segment in
            switch segment {
            case .text(let value): return .text(MarkdownRenderer.redactingSpoilers(value))
            case .code(let value): return .code(MarkdownRenderer.redactingSpoilers(value))
            }
        }
        fallback = message.attachments.isEmpty ? MarkdownRenderer.plainText(message.embeds.first?.title ?? "Embed", context: context)
            : "\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")"
    }

    var text: String {
        if segments.isEmpty { return fallback }
        return segments.map { segment in
            switch segment {
            case .text(let value), .code(let value): return MarkdownRenderer.redactingSpoilers(value).string
            }
        }.joined(separator: "\n")
    }
}

struct ForumPostPresentation {
    let title: String
    let excerpt: MessageExcerptPresentation?
    let revealScope: ExcerptRevealScope?
}
