import Foundation

/// Incoming primary content has strict limits before hashing, caching or layout.
/// Unknown/malformed siblings do not erase readable siblings.
nonisolated enum ContentDecoding {
    static let nodeLimit = 96
    static let depthLimit = 5
    static let textLimit = 8_192

    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.count > textLimit ? String(value.prefix(textLimit)) + "\n[Additional text omitted]" : value
    }

    static func list<T: Decodable>(_ type: T.Type, from decoder: Decoder, limit: Int) -> [T] {
        guard var list = try? decoder.unkeyedContainer() else { return [] }
        var result: [T] = []
        var read = 0
        while !list.isAtEnd, read < limit {
            guard let item = try? list.superDecoder() else { break }
            read += 1
            if let value = try? T(from: item) { result.append(value) }
        }
        return result
    }
}

/// Snapshot messages lack the IDs and author required by a normal Message.
/// Decode only the snapshot's content, rather than recursively decoding Message.
nonisolated struct MessageSnapshot: Codable, Hashable, Sendable {
    var content = ""
    var timestamp: String?
    var attachments: [Attachment] = []
    var embeds: [Embed] = []
    var stickerItems: [StickerItem] = []
    var components: [MessageComponent] = []
    var poll: MessagePoll?
    var snapshots: [MessageSnapshot] = []
    var truncated = false

    enum CodingKeys: String, CodingKey { case message }
    enum MessageKeys: String, CodingKey {
        case content, timestamp, attachments, embeds, components, poll, truncated
        case stickerItems = "sticker_items", snapshots = "message_snapshots"
    }

    init(from decoder: Decoder) throws {
        var budget = 8
        self = try Self.decode(from: decoder, depth: 0, budget: &budget)
    }

    static func decodeList(from decoder: Decoder) -> [MessageSnapshot] {
        var budget = 8
        return decodeList(from: decoder, depth: 0, budget: &budget)
    }

    private static func decodeList(from decoder: Decoder, depth: Int, budget: inout Int) -> [MessageSnapshot] {
        guard var list = try? decoder.unkeyedContainer() else { return [] }
        var result: [MessageSnapshot] = []
        while !list.isAtEnd, budget > 0 {
            guard let child = try? list.superDecoder() else { break }
            if let snapshot = try? decode(from: child, depth: depth, budget: &budget) { result.append(snapshot) }
        }
        if !list.isAtEnd { result.append(MessageSnapshot(truncated: true)) }
        return result
    }

    private init(truncated: Bool) { self.truncated = truncated }

    private static func decode(from decoder: Decoder, depth: Int, budget: inout Int) throws -> Self {
        budget -= 1
        guard depth < 3 else { return Self(truncated: true) }
        let wrapper = try decoder.container(keyedBy: CodingKeys.self)
        let c = try wrapper.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        var result = Self(truncated: (try? c.decode(Bool.self, forKey: .truncated)) ?? false)
        result.content = ContentDecoding.text(try? c.decode(String.self, forKey: .content)) ?? ""
        result.timestamp = try? c.decode(String.self, forKey: .timestamp)
        if let d = try? c.superDecoder(forKey: .attachments) { result.attachments = ContentDecoding.list(Attachment.self, from: d, limit: 10) }
        if let d = try? c.superDecoder(forKey: .embeds) { result.embeds = ContentDecoding.list(Embed.self, from: d, limit: 10) }
        if let d = try? c.superDecoder(forKey: .stickerItems) { result.stickerItems = ContentDecoding.list(StickerItem.self, from: d, limit: 3) }
        if let d = try? c.superDecoder(forKey: .components) { result.components = MessageComponent.decodeList(from: d) }
        result.poll = try? c.decode(MessagePoll.self, forKey: .poll)
        if let d = try? c.superDecoder(forKey: .snapshots) { result.snapshots = decodeList(from: d, depth: depth + 1, budget: &budget) }
        return result
    }

    func encode(to encoder: Encoder) throws {
        var wrapper = encoder.container(keyedBy: CodingKeys.self)
        var c = wrapper.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(embeds, forKey: .embeds)
        try c.encode(stickerItems, forKey: .stickerItems)
        try c.encode(components, forKey: .components)
        try c.encodeIfPresent(poll, forKey: .poll)
        try c.encode(snapshots, forKey: .snapshots)
        try c.encode(truncated, forKey: .truncated)
    }
}

nonisolated struct PollMedia: Codable, Hashable, Sendable {
    var text: String?
    var emoji: Emoji?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = ContentDecoding.text(try? c.decode(String.self, forKey: .text))
        emoji = try? c.decode(Emoji.self, forKey: .emoji)
    }
    enum CodingKeys: String, CodingKey { case text, emoji }
}

nonisolated struct PollAnswer: Codable, Hashable, Sendable {
    var answerID: Int
    var media: PollMedia
    enum CodingKeys: String, CodingKey { case answerID = "answer_id", media = "poll_media" }
}

nonisolated struct PollAnswerCount: Codable, Hashable, Sendable {
    var id: Int
    var count: Int
    var meVoted: Bool?
    enum CodingKeys: String, CodingKey { case id, count, meVoted = "me_voted" }
}

nonisolated struct PollResults: Codable, Hashable, Sendable {
    var isFinalized: Bool?
    var answerCounts: [PollAnswerCount]?
    enum CodingKeys: String, CodingKey { case isFinalized = "is_finalized", answerCounts = "answer_counts" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isFinalized = try? c.decode(Bool.self, forKey: .isFinalized)
        if c.contains(.answerCounts), let d = try? c.superDecoder(forKey: .answerCounts), (try? d.unkeyedContainer()) != nil {
            answerCounts = ContentDecoding.list(PollAnswerCount.self, from: d, limit: 10)
        }
    }
}

/// Optional fields also support a results-only MESSAGE_UPDATE poll object.
nonisolated struct MessagePoll: Codable, Hashable, Sendable {
    var question: PollMedia?
    var answers: [PollAnswer]?
    var expiry: String?
    var allowMultiselect: Bool?
    var results: PollResults?
    enum CodingKeys: String, CodingKey { case question, answers, expiry, results, allowMultiselect = "allow_multiselect" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try? c.decode(PollMedia.self, forKey: .question)
        if c.contains(.answers), let d = try? c.superDecoder(forKey: .answers), (try? d.unkeyedContainer()) != nil {
            answers = ContentDecoding.list(PollAnswer.self, from: d, limit: 10)
        }
        expiry = try? c.decode(String.self, forKey: .expiry)
        allowMultiselect = try? c.decode(Bool.self, forKey: .allowMultiselect)
        results = try? c.decode(PollResults.self, forKey: .results)
    }

    func merging(_ update: Self) -> Self {
        var result = self
        if let value = update.question { result.question = value }
        if let value = update.answers { result.answers = value }
        if let value = update.expiry { result.expiry = value }
        if let value = update.allowMultiselect { result.allowMultiselect = value }
        if let value = update.results {
            if result.results == nil { result.results = value }
            else {
                if let finalized = value.isFinalized { result.results?.isFinalized = finalized }
                if let counts = value.answerCounts { result.results?.answerCounts = counts }
            }
        }
        return result
    }
}

/// Incoming vote deltas only; no interaction/voting API is implemented.
nonisolated struct PollVoteEvent: Decodable, Sendable {
    var channelID: Snowflake
    var messageID: Snowflake
    var userID: Snowflake
    var answerID: Int
    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id", messageID = "message_id", userID = "user_id", answerID = "answer_id"
    }
}

nonisolated struct ComponentMedia: Codable, Hashable, Sendable {
    var url: String?
    var proxyURL: String?
    var width: Int?
    var height: Int?
    var contentType: String?
    var attachmentID: Snowflake?
    enum CodingKeys: String, CodingKey {
        case url, width, height, proxyURL = "proxy_url", contentType = "content_type", attachmentID = "attachment_id"
    }
}

nonisolated struct ComponentGalleryItem: Codable, Hashable, Sendable {
    var media: ComponentMedia
    var description: String?
    var spoiler: Bool?
}

nonisolated struct ComponentOption: Codable, Hashable, Sendable {
    var label: String
    var description: String?
    var emoji: Emoji?
}

/// Decode a tree with a shared node budget, not a branching per-level limit.
nonisolated struct MessageComponent: Codable, Hashable, Sendable {
    var type: Int
    var content: String?
    var label: String?
    var placeholder: String?
    var style: Int?
    var url: String?
    var emoji: Emoji?
    var disabled: Bool?
    var spoiler: Bool?
    var components: [MessageComponent] = []
    var accessory: [MessageComponent] = []
    var items: [ComponentGalleryItem] = []
    var options: [ComponentOption] = []
    var media: ComponentMedia?
    var file: ComponentMedia?
    var description: String?
    var truncated = false

    enum CodingKeys: String, CodingKey {
        case type, content, label, placeholder, style, url, emoji, disabled, spoiler, components, accessory, items, options, media, file, description, truncated
    }

    private init(type: Int, truncated: Bool = false) { self.type = type; self.truncated = truncated }

    init(from decoder: Decoder) throws {
        var budget = ContentDecoding.nodeLimit
        self = try Self.decode(from: decoder, depth: 0, budget: &budget)
    }

    static func decodeList(from decoder: Decoder) -> [Self] {
        var budget = ContentDecoding.nodeLimit
        return decodeList(from: decoder, depth: 0, budget: &budget)
    }

    private static func decodeList(from decoder: Decoder, depth: Int, budget: inout Int) -> [Self] {
        guard var list = try? decoder.unkeyedContainer() else { return [] }
        var result: [Self] = []
        while !list.isAtEnd, budget > 0 {
            guard let child = try? list.superDecoder() else { break }
            if let value = try? decode(from: child, depth: depth, budget: &budget) { result.append(value) }
        }
        if !list.isAtEnd { result.append(Self(type: -1, truncated: true)) }
        return result
    }

    private static func decode(from decoder: Decoder, depth: Int, budget: inout Int) throws -> Self {
        budget -= 1
        guard depth < ContentDecoding.depthLimit else { return Self(type: -1, truncated: true) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var result = Self(type: (try? c.decode(Int.self, forKey: .type)) ?? -1)
        result.truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        result.content = ContentDecoding.text(try? c.decode(String.self, forKey: .content))
        result.label = ContentDecoding.text(try? c.decode(String.self, forKey: .label))
        result.placeholder = ContentDecoding.text(try? c.decode(String.self, forKey: .placeholder))
        result.style = try? c.decode(Int.self, forKey: .style)
        result.url = try? c.decode(String.self, forKey: .url)
        result.emoji = try? c.decode(Emoji.self, forKey: .emoji)
        result.disabled = try? c.decode(Bool.self, forKey: .disabled)
        result.spoiler = try? c.decode(Bool.self, forKey: .spoiler)
        result.description = ContentDecoding.text(try? c.decode(String.self, forKey: .description))
        result.media = try? c.decode(ComponentMedia.self, forKey: .media)
        result.file = try? c.decode(ComponentMedia.self, forKey: .file)
        if let d = try? c.superDecoder(forKey: .items) { result.items = ContentDecoding.list(ComponentGalleryItem.self, from: d, limit: 10) }
        if let d = try? c.superDecoder(forKey: .options) { result.options = ContentDecoding.list(ComponentOption.self, from: d, limit: 25) }
        if let d = try? c.superDecoder(forKey: .components) {
            result.components = decodeList(from: d, depth: depth + 1, budget: &budget)
        }
        if c.contains(.accessory), budget > 0, let d = try? c.superDecoder(forKey: .accessory) {
            // The wire accessory is an object; old caches may use an array.
            if let value = try? decode(from: d, depth: depth + 1, budget: &budget) { result.accessory = [value] }
            else { result.accessory = decodeList(from: d, depth: depth + 1, budget: &budget) }
        }
        return result
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(disabled, forKey: .disabled)
        try c.encodeIfPresent(spoiler, forKey: .spoiler)
        try c.encode(components, forKey: .components)
        if let value = accessory.first { try c.encode(value, forKey: .accessory) }
        try c.encode(items, forKey: .items)
        try c.encode(options, forKey: .options)
        try c.encodeIfPresent(media, forKey: .media)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(truncated, forKey: .truncated)
    }
}
