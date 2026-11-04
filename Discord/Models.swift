import Foundation

/// A Discord ID. Sent as a JSON string; ordered by creation time.
nonisolated struct Snowflake: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    let raw: UInt64

    init(_ raw: UInt64) { self.raw = raw }
    init(integerLiteral value: UInt64) { raw = value }
    init?(_ string: String) {
        guard let value = UInt64(string) else { return nil }
        raw = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let value = UInt64(string) {
            raw = value
        } else {
            raw = try container.decode(UInt64.self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(raw))
    }

    static func < (a: Snowflake, b: Snowflake) -> Bool { a.raw < b.raw }
    var description: String { String(raw) }

    /// Milliseconds since 1970 encoded in the ID.
    var date: Date { Date(timeIntervalSince1970: Double((raw >> 22) + 1_420_070_400_000) / 1000) }

    /// The smallest snowflake created at `date`, for `after`/`before` queries.
    static func at(_ date: Date) -> Snowflake {
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000 - 1_420_070_400_000))
        return Snowflake(ms << 22)
    }
}

nonisolated enum ChannelType: Int, Codable, Sendable {
    case text = 0, dm = 1, voice = 2, groupDM = 3, category = 4, announcement = 5
    case announcementThread = 10, publicThread = 11, privateThread = 12
    case stage = 13, directory = 14, forum = 15, media = 16
    case unknown = -1

    init(from decoder: Decoder) throws {
        self = ChannelType(rawValue: try decoder.singleValueContainer().decode(Int.self)) ?? .unknown
    }

    var isThread: Bool { [.announcementThread, .publicThread, .privateThread].contains(self) }
    var isTextLike: Bool { [.text, .announcement, .dm, .groupDM, .announcementThread, .publicThread, .privateThread, .voice, .stage].contains(self) }
    var isVoice: Bool { self == .voice || self == .stage }
    var isForumLike: Bool { self == .forum || self == .media }
    var isPrivate: Bool { self == .dm || self == .groupDM }
}

nonisolated struct User: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var username: String
    var globalName: String?
    var discriminator: String?
    var avatar: String?
    var bot: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, discriminator, avatar, bot
        case globalName = "global_name"
    }

    var displayName: String { globalName?.nonEmpty ?? username }

    func avatarURL(size: Int) -> URL? {
        let size = cdnSize(size)
        if let avatar {
            if avatar == "mock-animated" { return URL(string: "mock://animation/pulse.gif") }
            if avatar.hasPrefix("mock") { return URL(string: "mock://avatar/\(id)") }
            let ext = avatar.hasPrefix("a_") ? "gif" : "webp"
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).\(ext)?size=\(size)")
        }
        // Default avatars: (id >> 22) % 6 for new usernames.
        let index = (id.raw >> 22) % 6
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }
}

nonisolated struct Member: Codable, Hashable, Sendable {
    var user: User?
    var userID: Snowflake?
    var nick: String?
    var roles: [Snowflake]
    var avatar: String?

    enum CodingKeys: String, CodingKey {
        case user, nick, roles, avatar
        case userID = "user_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(User.self, forKey: .user)
        userID = try c.decodeIfPresent(Snowflake.self, forKey: .userID) ?? user?.id
        nick = try c.decodeIfPresent(String.self, forKey: .nick)
        roles = try c.decodeIfPresent([Snowflake].self, forKey: .roles) ?? []
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
    }

    init(user: User?, nick: String?, roles: [Snowflake]) {
        self.user = user
        self.userID = user?.id
        self.nick = nick
        self.roles = roles
    }
}

nonisolated struct Role: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var name: String
    var color: Int
    var position: Int
    var permissions: String
    var hoist: Bool
    /// Anyone may @mention it (otherwise only with Mention Everyone).
    var mentionable: Bool

    enum CodingKeys: String, CodingKey { case id, name, color, position, permissions, hoist, mentionable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        permissions = try c.decodeIfPresent(String.self, forKey: .permissions) ?? "0"
        hoist = try c.decodeIfPresent(Bool.self, forKey: .hoist) ?? false
        mentionable = try c.decodeIfPresent(Bool.self, forKey: .mentionable) ?? false
    }

    init(id: Snowflake, name: String, color: Int, position: Int, permissions: String = "0", hoist: Bool = false, mentionable: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.position = position
        self.permissions = permissions; self.hoist = hoist; self.mentionable = mentionable
    }
}

nonisolated struct PermissionOverwrite: Codable, Hashable, Sendable {
    var id: Snowflake
    var type: Int // 0 role, 1 member
    var allow: String
    var deny: String
}

nonisolated struct ThreadMetadata: Codable, Hashable, Sendable {
    var archived: Bool?
    var locked: Bool?
    var archiveTimestamp: String?
    var createTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case archived, locked
        case archiveTimestamp = "archive_timestamp"
        case createTimestamp = "create_timestamp"
    }
}

nonisolated struct ThreadMemberRef: Codable, Hashable, Sendable {
    var joinTimestamp: String?
    enum CodingKeys: String, CodingKey { case joinTimestamp = "join_timestamp" }
}

nonisolated struct ForumTag: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var name: String
    var emojiName: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case emojiName = "emoji_name"
    }
}

nonisolated struct Channel: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var type: ChannelType
    var guildID: Snowflake?
    var name: String?
    var topic: String?
    var position: Int?
    var parentID: Snowflake?
    var nsfw: Bool?
    var lastMessageID: Snowflake?
    var recipients: [User]?
    var recipientIDs: [Snowflake]?
    var permissionOverwrites: [PermissionOverwrite]?
    var ownerID: Snowflake?
    var icon: String?
    var threadMetadata: ThreadMetadata?
    var messageCount: Int?
    var memberCount: Int?
    var appliedTags: [Snowflake]?
    var availableTags: [ForumTag]?
    var rateLimitPerUser: Int?
    var flags: Int?
    var lastPinTimestamp: String?
    /// Present on threads the current user has joined.
    var member: ThreadMemberRef?

    enum CodingKeys: String, CodingKey {
        case id, type, name, topic, position, nsfw, recipients, icon, flags, member
        case guildID = "guild_id"
        case parentID = "parent_id"
        case lastMessageID = "last_message_id"
        case recipientIDs = "recipient_ids"
        case permissionOverwrites = "permission_overwrites"
        case ownerID = "owner_id"
        case threadMetadata = "thread_metadata"
        case messageCount = "message_count"
        case memberCount = "member_count"
        case appliedTags = "applied_tags"
        case availableTags = "available_tags"
        case rateLimitPerUser = "rate_limit_per_user"
        case lastPinTimestamp = "last_pin_timestamp"
    }

    init(id: Snowflake, type: ChannelType, guildID: Snowflake? = nil, name: String? = nil, topic: String? = nil,
         position: Int? = nil, parentID: Snowflake? = nil, lastMessageID: Snowflake? = nil, recipients: [User]? = nil) {
        self.id = id; self.type = type; self.guildID = guildID; self.name = name; self.topic = topic
        self.position = position; self.parentID = parentID; self.lastMessageID = lastMessageID
        self.recipients = recipients
    }
}

nonisolated struct Emoji: Codable, Hashable, Sendable {
    var id: Snowflake?
    var name: String?
    var animated: Bool?

    /// The path component Discord's reaction endpoints expect.
    var reactionKey: String {
        if let id { return "\(name ?? "_"):\(id)" }
        return name ?? ""
    }

    func url(size: Int) -> URL? {
        guard let id else { return nil }
        // Mock data's custom emoji (IDs no real Discord object can have).
        if id.raw < 1_000_000 { return URL(string: animated == true ? "mock://animation/pulse.gif" : "mock://emoji/\(id)") }
        let ext = animated == true ? "gif" : "webp"
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).\(ext)?size=\(cdnSize(size))&quality=lossless")
    }
}

nonisolated struct GuildProperties: Codable, Hashable, Sendable {
    var name: String?
    var icon: String?
    var ownerID: Snowflake?
    var defaultMessageNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case name, icon
        case ownerID = "owner_id"
        case defaultMessageNotifications = "default_message_notifications"
    }
}

nonisolated struct Guild: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var name: String
    var icon: String?
    var ownerID: Snowflake?
    var defaultMessageNotifications: Int?
    var roles: [Role]
    var channels: [Channel]
    var threads: [Channel]
    var emojis: [Emoji]
    var memberCount: Int?
    var unavailable: Bool
    var voiceStates: [VoiceState]

    enum CodingKeys: String, CodingKey {
        case id, name, icon, roles, channels, threads, emojis, unavailable, properties
        case ownerID = "owner_id"
        case defaultMessageNotifications = "default_message_notifications"
        case memberCount = "member_count"
        case voiceStates = "voice_states"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        let properties = try c.decodeIfPresent(GuildProperties.self, forKey: .properties)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? properties?.name ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? properties?.icon
        ownerID = try c.decodeIfPresent(Snowflake.self, forKey: .ownerID) ?? properties?.ownerID
        defaultMessageNotifications = try c.decodeIfPresent(Int.self, forKey: .defaultMessageNotifications) ?? properties?.defaultMessageNotifications
        roles = try c.decodeIfPresent([Role].self, forKey: .roles) ?? []
        channels = try c.decodeIfPresent([Channel].self, forKey: .channels) ?? []
        threads = try c.decodeIfPresent([Channel].self, forKey: .threads) ?? []
        emojis = (try? c.decodeIfPresent([Emoji].self, forKey: .emojis)) ?? []
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount)
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        voiceStates = (try? c.decodeIfPresent([VoiceState].self, forKey: .voiceStates)) ?? []
        // Channels inside a guild payload omit guild_id.
        for index in channels.indices { channels[index].guildID = id }
        for index in threads.indices { threads[index].guildID = id }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(ownerID, forKey: .ownerID)
        try c.encodeIfPresent(defaultMessageNotifications, forKey: .defaultMessageNotifications)
        try c.encode(roles, forKey: .roles)
        try c.encode(channels, forKey: .channels)
        try c.encode(threads, forKey: .threads)
        try c.encode(emojis, forKey: .emojis)
        try c.encodeIfPresent(memberCount, forKey: .memberCount)
        try c.encode(unavailable, forKey: .unavailable)
        try c.encode(voiceStates, forKey: .voiceStates)
    }

    init(id: Snowflake, name: String, icon: String? = nil, roles: [Role] = [], channels: [Channel] = [], emojis: [Emoji] = []) {
        self.id = id; self.name = name; self.icon = icon; self.roles = roles; self.channels = channels
        self.threads = []; self.emojis = emojis; self.unavailable = false; self.voiceStates = []
    }

    func iconURL(size: Int) -> URL? {
        let size = cdnSize(size)
        guard let icon else { return nil }
        if icon.hasPrefix("mock") { return URL(string: "mock://icon/\(id)") }
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).webp?size=\(size)")
    }

    /// Initials for guilds without an icon, as Discord draws them.
    var initials: String {
        name.split(separator: " ").compactMap(\.first).prefix(3).map(String.init).joined()
    }
}

// MARK: - Messages

nonisolated struct Attachment: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var filename: String
    var size: Int
    var url: String
    var proxyURL: String?
    var width: Int?
    var height: Int?
    var contentType: String?
    var description: String?
    var flags: Int?
    var durationSecs: Double?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, url, width, height, description, flags
        case proxyURL = "proxy_url"
        case contentType = "content_type"
        case durationSecs = "duration_secs"
    }

    var isImage: Bool {
        if let contentType { return contentType.hasPrefix("image/") }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif"].contains(ext)
    }
    var isVideo: Bool { contentType?.hasPrefix("video/") ?? false }
    var isSpoiler: Bool { filename.hasPrefix("SPOILER_") || ((flags ?? 0) & 8) != 0 }
}

nonisolated struct EmbedMedia: Codable, Hashable, Sendable {
    var url: String?
    var proxyURL: String?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case url, width, height
        case proxyURL = "proxy_url"
    }
}

nonisolated struct EmbedField: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var inline: Bool?
}

nonisolated struct EmbedFooter: Codable, Hashable, Sendable {
    var text: String
    var iconURL: String?
    enum CodingKeys: String, CodingKey {
        case text
        case iconURL = "proxy_icon_url"
    }
}

nonisolated struct EmbedAuthor: Codable, Hashable, Sendable {
    var name: String
    var url: String?
    var iconURL: String?
    enum CodingKeys: String, CodingKey {
        case name, url
        case iconURL = "proxy_icon_url"
    }
}

nonisolated struct EmbedProvider: Codable, Hashable, Sendable {
    var name: String?
    var url: String?
}

nonisolated struct Embed: Codable, Hashable, Sendable {
    var type: String?
    var title: String?
    var description: String?
    var url: String?
    var color: Int?
    var footer: EmbedFooter?
    var image: EmbedMedia?
    var thumbnail: EmbedMedia?
    var video: EmbedMedia?
    var provider: EmbedProvider?
    var author: EmbedAuthor?
    var fields: [EmbedField]?

    /// Image and gifv embeds that Discord renders as a bare picture.
    var isMediaOnly: Bool {
        (type == "image" || type == "gifv") && thumbnail != nil
    }
}

nonisolated struct ReactionCountDetails: Codable, Hashable, Sendable {
    var burst: Int?
    var normal: Int?
}

nonisolated struct Reaction: Codable, Hashable, Sendable {
    var count: Int
    var me: Bool
    var emoji: Emoji
}

nonisolated struct MessageReference: Codable, Hashable, Sendable {
    var type: Int? = nil
    var messageID: Snowflake?
    var channelID: Snowflake?
    var guildID: Snowflake?

    enum CodingKeys: String, CodingKey {
        case type
        case messageID = "message_id"
        case channelID = "channel_id"
        case guildID = "guild_id"
    }
}

nonisolated struct StickerItem: Codable, Hashable, Sendable {
    var id: Snowflake
    var name: String
    var formatType: Int?
    var rasterURL: URL? {
        guard formatType != 3 else { return nil }
        if id.raw < 1_000_000 { return URL(string: "mock://animation/pulse.png") }
        let ext = formatType == 4 ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/stickers/\(id).\(ext)?size=256")
    }
    enum CodingKeys: String, CodingKey {
        case id, name
        case formatType = "format_type"
    }
}

/// A referenced message, boxed so `Message` can contain one.
nonisolated final class MessageBox: Codable, Hashable, @unchecked Sendable {
    let message: Message
    init(_ message: Message) { self.message = message }
    required init(from decoder: Decoder) throws { message = try Message(from: decoder) }
    func encode(to encoder: Encoder) throws { try message.encode(to: encoder) }
    static func == (a: MessageBox, b: MessageBox) -> Bool { a.message == b.message }
    func hash(into hasher: inout Hasher) { hasher.combine(message.id) }
}

nonisolated struct Message: Codable, Hashable, Sendable, Identifiable {
    var id: Snowflake
    var channelID: Snowflake
    var guildID: Snowflake?
    var author: User
    var member: Member?
    var content: String
    var timestamp: String
    var editedTimestamp: String?
    var mentions: [User]
    var mentionRoles: [Snowflake]
    var mentionEveryone: Bool
    var attachments: [Attachment]
    var embeds: [Embed]
    var reactions: [Reaction]
    var messageReference: MessageReference?
    var referencedMessage: MessageBox?
    var type: Int
    var flags: Int
    var stickerItems: [StickerItem]
    var pinned: Bool
    var nonce: String?
    var messageSnapshots: [MessageSnapshot] = []
    var poll: MessagePoll?
    var components: [MessageComponent] = []
    /// The thread started from this message (Discord sends it with HAS_THREAD).
    var thread: Channel?

    enum CodingKeys: String, CodingKey {
        case id, author, member, content, timestamp, mentions, attachments, embeds, reactions, type, flags, pinned, nonce, poll, components, thread
        case channelID = "channel_id"
        case guildID = "guild_id"
        case editedTimestamp = "edited_timestamp"
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case messageReference = "message_reference"
        case referencedMessage = "referenced_message"
        case stickerItems = "sticker_items"
        case messageSnapshots = "message_snapshots"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        channelID = try c.decode(Snowflake.self, forKey: .channelID)
        guildID = try c.decodeIfPresent(Snowflake.self, forKey: .guildID)
        author = try c.decode(User.self, forKey: .author)
        member = try? c.decodeIfPresent(Member.self, forKey: .member)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        editedTimestamp = try c.decodeIfPresent(String.self, forKey: .editedTimestamp)
        mentions = (try? c.decodeIfPresent([User].self, forKey: .mentions)) ?? []
        mentionRoles = (try? c.decodeIfPresent([Snowflake].self, forKey: .mentionRoles)) ?? []
        mentionEveryone = try c.decodeIfPresent(Bool.self, forKey: .mentionEveryone) ?? false
        attachments = (try? c.decodeIfPresent([Attachment].self, forKey: .attachments)) ?? []
        embeds = (try? c.decodeIfPresent([Embed].self, forKey: .embeds)) ?? []
        reactions = (try? c.decodeIfPresent([Reaction].self, forKey: .reactions)) ?? []
        messageReference = try? c.decodeIfPresent(MessageReference.self, forKey: .messageReference)
        referencedMessage = try? c.decodeIfPresent(MessageBox.self, forKey: .referencedMessage)
        if let d = try? c.superDecoder(forKey: .messageSnapshots) { messageSnapshots = MessageSnapshot.decodeList(from: d) }
        poll = try? c.decode(MessagePoll.self, forKey: .poll)
        if let d = try? c.superDecoder(forKey: .components) { components = MessageComponent.decodeList(from: d) }
        thread = try? c.decodeIfPresent(Channel.self, forKey: .thread)
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        flags = try c.decodeIfPresent(Int.self, forKey: .flags) ?? 0
        stickerItems = (try? c.decodeIfPresent([StickerItem].self, forKey: .stickerItems)) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        if let string = try? c.decodeIfPresent(String.self, forKey: .nonce) {
            nonce = string
        } else if let number = try? c.decodeIfPresent(Int64.self, forKey: .nonce) {
            nonce = String(number)
        }
    }

    init(id: Snowflake, channelID: Snowflake, guildID: Snowflake?, author: User, content: String,
         timestamp: String, attachments: [Attachment] = [], embeds: [Embed] = [], reactions: [Reaction] = [],
         mentions: [User] = [], type: Int = 0, referencedMessage: Message? = nil) {
        self.id = id; self.channelID = channelID; self.guildID = guildID; self.author = author
        self.content = content; self.timestamp = timestamp; self.mentions = mentions
        self.mentionRoles = []; self.mentionEveryone = false; self.attachments = attachments
        self.embeds = embeds; self.reactions = reactions; self.type = type; self.flags = 0
        self.stickerItems = []; self.pinned = false
        self.referencedMessage = referencedMessage.map(MessageBox.init)
        self.messageReference = referencedMessage.map { MessageReference(messageID: $0.id, channelID: channelID, guildID: guildID) }
    }

    /// The snowflake's creation time: the same instant as `timestamp`, without parsing.
    var date: Date { id.date }
    var isEdited: Bool { editedTimestamp != nil }
    /// Default and reply messages show content; others render as system lines.
    var isSystem: Bool { ![0, 19, 20, 23, 46].contains(type) }
    var isReply: Bool { type == 19 }
}

/// A partial message from MESSAGE_UPDATE: only present fields change.
/// CHANNEL_PINS_UPDATE. It names no message, and is not sent when a pinned
/// message is deleted. A null timestamp (no pins left) differs from an omitted one.
nonisolated struct ChannelPinsUpdate: Decodable, Sendable {
    var guildID: Snowflake?
    var channelID: Snowflake
    var lastPinTimestamp: String?
    var timestampProvided: Bool

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case channelID = "channel_id"
        case lastPinTimestamp = "last_pin_timestamp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try c.decodeIfPresent(Snowflake.self, forKey: .guildID)
        channelID = try c.decode(Snowflake.self, forKey: .channelID)
        timestampProvided = c.contains(.lastPinTimestamp)
        lastPinTimestamp = try c.decodeIfPresent(String.self, forKey: .lastPinTimestamp)
    }
}

nonisolated struct MessageUpdate: Decodable, Sendable {
    var id: Snowflake
    var channelID: Snowflake
    var content: String?
    var editedTimestamp: String?
    var embeds: [Embed]?
    var attachments: [Attachment]?
    var pinned: Bool?
    var flags: Int?
    var messageSnapshots: [MessageSnapshot]?
    var components: [MessageComponent]?
    var poll: MessagePoll?
    /// Missing retains the poll; explicit null clears it.
    var pollWasProvided = false

    enum CodingKeys: String, CodingKey {
        case id, content, embeds, attachments, pinned, flags, components, poll
        case channelID = "channel_id"
        case editedTimestamp = "edited_timestamp"
        case messageSnapshots = "message_snapshots"
    }

    init(id: Snowflake, channelID: Snowflake, content: String? = nil, editedTimestamp: String? = nil,
         embeds: [Embed]? = nil, attachments: [Attachment]? = nil, pinned: Bool? = nil, flags: Int? = nil,
         messageSnapshots: [MessageSnapshot]? = nil, components: [MessageComponent]? = nil,
         poll: MessagePoll? = nil, pollWasProvided: Bool = false) {
        self.id = id; self.channelID = channelID; self.content = content; self.editedTimestamp = editedTimestamp
        self.embeds = embeds; self.attachments = attachments; self.pinned = pinned; self.flags = flags
        self.messageSnapshots = messageSnapshots; self.components = components; self.poll = poll
        self.pollWasProvided = pollWasProvided || poll != nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        channelID = try c.decode(Snowflake.self, forKey: .channelID)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        editedTimestamp = try c.decodeIfPresent(String.self, forKey: .editedTimestamp)
        embeds = try c.decodeIfPresent([Embed].self, forKey: .embeds)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
        flags = try c.decodeIfPresent(Int.self, forKey: .flags)
        if c.contains(.messageSnapshots), let d = try? c.superDecoder(forKey: .messageSnapshots),
           (try? d.unkeyedContainer()) != nil {
            messageSnapshots = MessageSnapshot.decodeList(from: d)
        }
        if c.contains(.components), let d = try? c.superDecoder(forKey: .components),
           (try? d.unkeyedContainer()) != nil {
            components = MessageComponent.decodeList(from: d)
        }
        if c.contains(.poll) {
            if try c.decodeNil(forKey: .poll) { pollWasProvided = true }
            else if let value = try? c.decode(MessagePoll.self, forKey: .poll) {
                poll = value; pollWasProvided = true
            }
        }
    }
}

// MARK: - State objects

nonisolated struct ReadState: Codable, Hashable, Sendable {
    var id: Snowflake
    var lastMessageID: Snowflake?
    var mentionCount: Int
    var readStateType: Int

    enum CodingKeys: String, CodingKey {
        case id
        case lastMessageID = "last_message_id"
        case mentionCount = "mention_count"
        case readStateType = "read_state_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        // last_message_id is a string, or 0 for "never read".
        lastMessageID = try? c.decodeIfPresent(Snowflake.self, forKey: .lastMessageID)
        mentionCount = try c.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        readStateType = try c.decodeIfPresent(Int.self, forKey: .readStateType) ?? 0
    }

    init(id: Snowflake, lastMessageID: Snowflake?, mentionCount: Int) {
        self.id = id; self.lastMessageID = lastMessageID; self.mentionCount = mentionCount; self.readStateType = 0
    }
}

nonisolated struct MuteConfig: Codable, Hashable, Sendable {
    var endTime: String?
    var selectedTimeWindow: Int? = nil
    enum CodingKeys: String, CodingKey {
        case endTime = "end_time"
        case selectedTimeWindow = "selected_time_window"
    }

    init(endTime: String?, selectedTimeWindow: Int? = nil) {
        self.endTime = endTime
        self.selectedTimeWindow = selectedTimeWindow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endTime = (try? c.decode(String.self, forKey: .endTime)).flatMap { DiscordDate.parse($0) != nil ? $0 : nil }
        selectedTimeWindow = (try? c.decode(Int.self, forKey: .selectedTimeWindow)).flatMap { $0 >= -1 ? $0 : nil }
    }
}

nonisolated struct ChannelOverride: Codable, Hashable, Sendable {
    var channelID: Snowflake
    var muted: Bool = false
    var messageNotifications: Int = 3
    var muteConfig: MuteConfig?
    enum CodingKeys: String, CodingKey {
        case muted
        case channelID = "channel_id"
        case messageNotifications = "message_notifications"
        case muteConfig = "mute_config"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decode(Snowflake.self, forKey: .channelID)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        messageNotifications = try c.decodeIfPresent(Int.self, forKey: .messageNotifications) ?? 3
        muteConfig = try? c.decodeIfPresent(MuteConfig.self, forKey: .muteConfig)
    }
}

/// Per-guild notification settings. message_notifications: 0 all, 1 mentions, 2 nothing, 3 inherit.
nonisolated struct UserGuildSettings: Codable, Hashable, Sendable {
    var guildID: Snowflake?
    var muted: Bool
    var messageNotifications: Int
    var suppressEveryone: Bool
    var suppressRoles: Bool
    var channelOverrides: [ChannelOverride]
    var muteConfig: MuteConfig?

    enum CodingKeys: String, CodingKey {
        case muted
        case guildID = "guild_id"
        case messageNotifications = "message_notifications"
        case suppressEveryone = "suppress_everyone"
        case suppressRoles = "suppress_roles"
        case channelOverrides = "channel_overrides"
        case muteConfig = "mute_config"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try? c.decodeIfPresent(Snowflake.self, forKey: .guildID)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        messageNotifications = try c.decodeIfPresent(Int.self, forKey: .messageNotifications) ?? 3
        suppressEveryone = try c.decodeIfPresent(Bool.self, forKey: .suppressEveryone) ?? false
        suppressRoles = try c.decodeIfPresent(Bool.self, forKey: .suppressRoles) ?? false
        channelOverrides = (try? c.decodeIfPresent([ChannelOverride].self, forKey: .channelOverrides)) ?? []
        if let keyed = try? c.decode([String: JSONValue].self, forKey: .channelOverrides) {
            channelOverrides = keyed.compactMap { id, value in
                guard case .object(var fields) = value else { return nil }
                fields["channel_id"] = .string(id)
                return try? JSONDecoder().decode(ChannelOverride.self, from: JSONEncoder().encode(fields))
            }
        }
        muteConfig = try? c.decodeIfPresent(MuteConfig.self, forKey: .muteConfig)
    }
}

nonisolated struct VoiceState: Codable, Hashable, Sendable {
    var guildID: Snowflake?
    var channelID: Snowflake?
    var userID: Snowflake
    var sessionID: String?
    var selfMute: Bool
    var selfDeaf: Bool
    var mute: Bool
    var deaf: Bool
    var selfVideo: Bool?
    var selfStream: Bool?
    var member: Member?

    enum CodingKeys: String, CodingKey {
        case mute, deaf, member
        case guildID = "guild_id"
        case channelID = "channel_id"
        case userID = "user_id"
        case sessionID = "session_id"
        case selfMute = "self_mute"
        case selfDeaf = "self_deaf"
        case selfVideo = "self_video"
        case selfStream = "self_stream"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try? c.decodeIfPresent(Snowflake.self, forKey: .guildID)
        channelID = try? c.decodeIfPresent(Snowflake.self, forKey: .channelID)
        userID = try c.decode(Snowflake.self, forKey: .userID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        selfMute = try c.decodeIfPresent(Bool.self, forKey: .selfMute) ?? false
        selfDeaf = try c.decodeIfPresent(Bool.self, forKey: .selfDeaf) ?? false
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        deaf = try c.decodeIfPresent(Bool.self, forKey: .deaf) ?? false
        selfVideo = try c.decodeIfPresent(Bool.self, forKey: .selfVideo)
        selfStream = try c.decodeIfPresent(Bool.self, forKey: .selfStream)
        member = try? c.decodeIfPresent(Member.self, forKey: .member)
    }

    init(guildID: Snowflake?, channelID: Snowflake?, userID: Snowflake, selfMute: Bool, selfDeaf: Bool) {
        self.guildID = guildID; self.channelID = channelID; self.userID = userID
        self.selfMute = selfMute; self.selfDeaf = selfDeaf; self.mute = false; self.deaf = false
    }
}

nonisolated enum PresenceStatus: String, Codable, Sendable {
    case online, idle, dnd, offline, invisible
    init(from decoder: Decoder) throws {
        self = PresenceStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .offline
    }
}

// MARK: - Helpers

nonisolated enum DiscordDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Discord's CDN only serves power-of-two sizes from 16 to 4096.
nonisolated func cdnSize(_ size: Int) -> Int {
    var value = 16
    while value < size && value < 4096 { value *= 2 }
    return value
}

extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}

/// A JSON value for loosely typed payloads (gateway envelopes, unknown fields).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
