import Foundation

/// A list that may arrive bare or wrapped as `{entries, partial, version}`
/// depending on gateway capabilities.
nonisolated struct Versioned<T: Decodable & Sendable>: Decodable, Sendable {
    var entries: [T]

    init(entries: [T]) { self.entries = entries }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([T].self) {
            entries = list
            return
        }
        entries = (try? decoder.singleValueContainer().decode(VersionedWrapper<T>.self))?.entries ?? []
    }
}

nonisolated struct VersionedWrapper<T: Decodable & Sendable>: Decodable, Sendable { var entries: [T] }

/// Decodes each element on its own so one malformed entry doesn't sink the list.
nonisolated struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
    var items: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [T] = []
        while !container.isAtEnd {
            if let item = try? container.decode(T.self) {
                items.append(item)
            } else {
                _ = try? container.decode(JSONValue.self)
            }
        }
        self.items = items
    }
}

nonisolated struct ReadyPayload: Decodable, Sendable {
    var user: User
    var guilds: [Guild]
    var privateChannels: [Channel]
    var users: [User]
    var mergedMembers: [[Member]]
    var readStates: [ReadState]
    var readStateVersion: Int? = nil
    var guildSettings: [UserGuildSettings]
    var settingsProto: String?
    var relationships: [Relationship]
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case user, guilds, users, relationships
        case privateChannels = "private_channels"
        case mergedMembers = "merged_members"
        case readState = "read_state"
        case guildSettings = "user_guild_settings"
        case settingsProto = "user_settings_proto"
        case sessionID = "session_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        guilds = (try c.decodeIfPresent(Lenient<Guild>.self, forKey: .guilds))?.items ?? []
        privateChannels = (try c.decodeIfPresent(Lenient<Channel>.self, forKey: .privateChannels))?.items ?? []
        users = (try c.decodeIfPresent(Lenient<User>.self, forKey: .users))?.items ?? []
        mergedMembers = (try? c.decodeIfPresent([[Member]].self, forKey: .mergedMembers)) ?? []
        readStates = (try? c.decodeIfPresent(Versioned<ReadState>.self, forKey: .readState))?.entries ?? []
        struct ReadVersionEnvelope: Decodable { var version: Int? }
        readStateVersion = (try? c.decodeIfPresent(ReadVersionEnvelope.self, forKey: .readState))?.version
        guildSettings = (try? c.decodeIfPresent(Versioned<UserGuildSettings>.self, forKey: .guildSettings))?.entries ?? []
        settingsProto = try c.decodeIfPresent(String.self, forKey: .settingsProto)
        relationships = (try c.decodeIfPresent(Lenient<Relationship>.self, forKey: .relationships))?.items ?? []
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
    }

    init(user: User, guilds: [Guild], privateChannels: [Channel], users: [User], mergedMembers: [[Member]],
         readStates: [ReadState], guildSettings: [UserGuildSettings], settingsProto: String?) {
        self.user = user; self.guilds = guilds; self.privateChannels = privateChannels; self.users = users
        self.mergedMembers = mergedMembers; self.readStates = readStates; self.guildSettings = guildSettings
        self.settingsProto = settingsProto; self.relationships = []; self.sessionID = "mock"
    }
}

nonisolated struct ReadySupplemental: Decodable, Sendable {
    struct Presence: Decodable, Sendable {
        var userID: Snowflake?
        var user: PartialUser?
        var status: PresenceStatus?
        enum CodingKeys: String, CodingKey {
            case user, status
            case userID = "user_id"
        }
    }

    var mergedMembers: [[Member]]
    var guildPresences: [[Presence]]
    var friendPresences: [Presence]

    enum CodingKeys: String, CodingKey {
        case mergedMembers = "merged_members"
        case mergedPresences = "merged_presences"
    }

    struct MergedPresences: Decodable, Sendable {
        var guilds: [[Presence]]?
        var friends: [Presence]?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mergedMembers = (try? c.decodeIfPresent([[Member]].self, forKey: .mergedMembers)) ?? []
        let presences = try? c.decodeIfPresent(MergedPresences.self, forKey: .mergedPresences)
        guildPresences = presences?.guilds ?? []
        friendPresences = presences?.friends ?? []
    }
}

nonisolated struct PartialUser: Decodable, Sendable {
    var id: Snowflake
    var fields: [String: JSONValue]
    init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard let value = fields["id"] else { throw DiscordError.decoding("partial user id") }
        id = try JSONDecoder().decode(Snowflake.self, from: JSONEncoder().encode(value))
    }
}

nonisolated struct MessageDelete: Decodable, Sendable {
    var id: Snowflake
    var channelID: Snowflake
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
    }
}

nonisolated struct MessageDeleteBulk: Decodable, Sendable {
    var ids: [Snowflake]
    var channelID: Snowflake
    enum CodingKeys: String, CodingKey {
        case ids
        case channelID = "channel_id"
    }
}

nonisolated struct ReactionEvent: Decodable, Sendable {
    var userID: Snowflake?
    var channelID: Snowflake
    var messageID: Snowflake
    var emoji: Emoji?
    var burst: Bool?
    enum CodingKeys: String, CodingKey {
        case emoji, burst
        case userID = "user_id"
        case channelID = "channel_id"
        case messageID = "message_id"
    }
}

nonisolated struct MessageAck: Decodable, Sendable {
    var channelID: Snowflake
    var messageID: Snowflake?
    var version: Int?
    var ackType: Int?
    var manual: Bool?
    var mentionCount: Int?
    enum CodingKeys: String, CodingKey {
        case manual, version
        case ackType = "ack_type"
        case channelID = "channel_id"
        case messageID = "message_id"
        case mentionCount = "mention_count"
    }
}

nonisolated struct TypingStart: Decodable, Sendable {
    var channelID: Snowflake
    var guildID: Snowflake?
    var userID: Snowflake
    var member: Member?
    enum CodingKeys: String, CodingKey {
        case member
        case channelID = "channel_id"
        case guildID = "guild_id"
        case userID = "user_id"
    }
}

nonisolated struct GuildDelete: Decodable, Sendable {
    var id: Snowflake
    var unavailable: Bool?
}

nonisolated struct GuildRoleEvent: Decodable, Sendable {
    var guildID: Snowflake
    var role: Role?
    var roleID: Snowflake?
    enum CodingKeys: String, CodingKey {
        case role
        case guildID = "guild_id"
        case roleID = "role_id"
    }
}

/// Gateway member updates are patches: omitted is not the same as explicit null.
nonisolated struct GuildMemberUpdate: Decodable, Sendable {
    var guildID: Snowflake
    var user: User
    var nick: String?
    var roles: [Snowflake]?
    var avatar: String?
    var communicationDisabledUntil: String?
    var nickProvided: Bool
    var avatarProvided: Bool
    var timeoutProvided: Bool
    enum CodingKeys: String, CodingKey {
        case user, nick, roles, avatar
        case guildID = "guild_id"
        case communicationDisabledUntil = "communication_disabled_until"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try c.decode(Snowflake.self, forKey: .guildID)
        user = try c.decode(User.self, forKey: .user)
        nick = try c.decodeIfPresent(String.self, forKey: .nick)
        roles = try c.decodeIfPresent([Snowflake].self, forKey: .roles)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        communicationDisabledUntil = try c.decodeIfPresent(String.self, forKey: .communicationDisabledUntil)
        nickProvided = c.contains(.nick); avatarProvided = c.contains(.avatar)
        timeoutProvided = c.contains(.communicationDisabledUntil)
    }
    func applying(to previous: Member?) -> Member {
        var member = previous ?? Member(user: user, nick: nil, roles: [])
        member.user = user; member.userID = user.id
        if let roles { member.roles = roles; member.rolesKnown = true }
        else if previous == nil { member.rolesKnown = false }
        if nickProvided { member.nick = nick }
        if avatarProvided { member.avatar = avatar }
        if timeoutProvided { member.communicationDisabledUntil = communicationDisabledUntil }
        return member
    }
}

nonisolated struct ThreadListSync: Decodable, Sendable {
    struct MemberEntry: Decodable, Sendable {
        var id: Snowflake?
        var joinTimestamp: String?
        /// The thread's notification preference, when the entry carries it.
        var settings = ThreadMemberSettingsUpdate()
        enum CodingKeys: String, CodingKey {
            case id
            case joinTimestamp = "join_timestamp"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Snowflake.self, forKey: .id)
            joinTimestamp = try c.decodeIfPresent(String.self, forKey: .joinTimestamp)
            settings = try ThreadMemberSettingsUpdate(from: decoder)
        }
    }
    var guildID: Snowflake
    var threads: [Channel]
    /// The current user's thread memberships among `threads`.
    var members: [MemberEntry]?
    enum CodingKeys: String, CodingKey {
        case threads, members
        case guildID = "guild_id"
    }
}

nonisolated struct ThreadMembersUpdate: Decodable, Sendable {
    struct Added: Decodable, Sendable {
        var userID: Snowflake?
        var joinTimestamp: String?
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case joinTimestamp = "join_timestamp"
        }
    }
    var id: Snowflake
    var addedMembers: [Added]?
    var removedMemberIDs: [Snowflake]?
    enum CodingKeys: String, CodingKey {
        case id
        case addedMembers = "added_members"
        case removedMemberIDs = "removed_member_ids"
    }
}

nonisolated struct PresenceUpdate: Decodable, Sendable {
    var user: PartialUser
    var guildID: Snowflake?
    var status: PresenceStatus?
    enum CodingKeys: String, CodingKey {
        case user, status
        case guildID = "guild_id"
    }
}

nonisolated struct SettingsProtoUpdate: Decodable, Sendable {
    struct Settings: Decodable, Sendable { var proto: String; var type: Int }
    var settings: Settings
    var partial: Bool?
}

/// GUILD_MEMBER_LIST_UPDATE: the lazily loaded, grouped member sidebar.
nonisolated struct MemberListUpdate: Decodable, Sendable {
    struct Group: Decodable, Sendable, Hashable {
        var id: String
        var count: Int?
    }

    enum Item: Decodable, Sendable, Hashable {
        case group(Group)
        case member(Member, PresenceStatus)

        enum CodingKeys: String, CodingKey { case group, member }
        struct MemberWithPresence: Decodable {
            struct Presence: Decodable { var status: PresenceStatus? }
            var user: User?
            var nick: String?
            var roles: [Snowflake]?
            var presence: Presence?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let group = try c.decodeIfPresent(Group.self, forKey: .group) {
                self = .group(group)
            } else {
                let raw = try c.decode(MemberWithPresence.self, forKey: .member)
                self = .member(Member(user: raw.user, nick: raw.nick, roles: raw.roles ?? []),
                               raw.presence?.status ?? .offline)
            }
        }
    }

    struct Op: Decodable, Sendable {
        var op: String
        var range: [Int]?
        var items: [Item]?
        var index: Int?
        var item: Item?
    }

    var guildID: Snowflake
    var id: String
    var groups: [Group]
    var ops: [Op]
    var memberCount: Int?
    var onlineCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, groups, ops
        case guildID = "guild_id"
        case memberCount = "member_count"
        case onlineCount = "online_count"
    }
}
