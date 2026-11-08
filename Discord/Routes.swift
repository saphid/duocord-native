import Foundation

/// Route-bound resource identity. Conversion from legacy model Snowflakes is
/// explicit at the REST boundary. Identity is not a permission or ownership proof.
nonisolated struct ResourceID<Kind>: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64
    init(_ raw: UInt64) { self.raw = raw }
    var description: String { String(raw) }
}
nonisolated enum ChannelResource: Sendable {}
nonisolated enum MessageResource: Sendable {}
nonisolated enum UserResource: Sendable {}
nonisolated enum GuildResource: Sendable {}
typealias ChannelID = ResourceID<ChannelResource>
typealias MessageID = ResourceID<MessageResource>
typealias UserID = ResourceID<UserResource>
typealias GuildID = ResourceID<GuildResource>

/// All Discord-authenticated physical routes. Signed storage PUTs deliberately
/// stay outside this registry and use the header-free upload session.
nonisolated enum DiscordEndpoint: Sendable {
    case channel(ChannelID), guild(GuildID), guildRoles(GuildID), guildMember(GuildID, UserID)
    case ownThreadMember(ChannelID), messages(ChannelID), pins(ChannelID), legacyPins(ChannelID)
    case guildSearch(GuildID), channelSearch(ChannelID), mentions, forumThreads(ChannelID), publicArchives(ChannelID)
    case send(ChannelID), edit(ChannelID, MessageID), delete(ChannelID, MessageID)
    case pin(ChannelID, MessageID, pinned: Bool), attachments(ChannelID), ack(ChannelID, MessageID), ackBulk, guildAck(GuildID)
    case typing(ChannelID), reaction(ChannelID, MessageID, emoji: String, add: Bool), reactions(ChannelID, MessageID, emoji: String)
    case notificationSettings(GuildID?), relationship(UserID, removing: Bool), requestFriend, createDM, settingsProto
    case saveSettingsProto, leaveGuild(GuildID)
    case modifyThread(ChannelID), deleteThread(ChannelID), joinThread(ChannelID), leaveThread(ChannelID), threadSettings(ChannelID)

    var descriptor: DiscordRoute {
        switch self {
        case .channel(let c): return route("GET", [.word("channels"), .channel(c)], "channel", c.description)
        case .guild(let g): return route("GET", [.word("guilds"), .guild(g)], "guild", g.description)
        case .guildRoles(let g): return route("GET", [.word("guilds"), .guild(g), .word("roles")], "roles", g.description)
        case .guildMember(let g, let u): return route("GET", [.word("guilds"), .guild(g), .word("members"), .user(u)], "member", "\(g):\(u)")
        case .ownThreadMember(let c): return route("GET", [.word("channels"), .channel(c), .word("thread-members/@me")], "thread-member", c.description)
        case .messages(let c): return route("GET", [.word("channels"), .channel(c), .word("messages")], "messages", c.description)
        case .pins(let c): return route("GET", [.word("channels"), .channel(c), .word("messages/pins")], "pins", c.description)
        case .legacyPins(let c): return route("GET", [.word("channels"), .channel(c), .word("pins")], "pins", c.description)
        case .guildSearch(let g): return route("GET", [.word("guilds"), .guild(g), .word("messages/search")], "search", g.description)
        case .channelSearch(let c): return route("GET", [.word("channels"), .channel(c), .word("messages/search")], "search", c.description)
        case .mentions: return route("GET", [.word("users/@me/mentions")], "mentions")
        case .forumThreads(let c): return route("GET", [.word("channels"), .channel(c), .word("threads/search")], "threads", c.description)
        case .publicArchives(let c): return route("GET", [.word("channels"), .channel(c), .word("threads/archived/public")], "threads", c.description)
        case .send(let c): return route("POST", [.word("channels"), .channel(c), .word("messages")], "send", c.description)
        case .edit(let c, let m): return route("PATCH", [.word("channels"), .channel(c), .word("messages"), .message(m)], "edit", c.description)
        case .delete(let c, let m): return route("DELETE", [.word("channels"), .channel(c), .word("messages"), .message(m)], "delete", c.description)
        case .pin(let c, let m, let pinned): return route(pinned ? "PUT" : "DELETE", [.word("channels"), .channel(c), .word("messages/pins"), .message(m)], "pin", c.description)
        case .attachments(let c): return route("POST", [.word("channels"), .channel(c), .word("attachments")], "attachments", c.description)
        case .ack(let c, let m): return route("POST", [.word("channels"), .channel(c), .word("messages"), .message(m), .word("ack")], "ack", c.description)
        case .ackBulk: return route("POST", [.word("read-states/ack-bulk")], "ack-bulk")
        case .guildAck(let g): return route("POST", [.word("guilds"), .guild(g), .word("ack")], "guild-ack", g.description)
        case .typing(let c): return route("POST", [.word("channels"), .channel(c), .word("typing")], "typing", c.description)
        case .reaction(let c, let m, let emoji, let add): return route(add ? "PUT" : "DELETE", [.word("channels"), .channel(c), .word("messages"), .message(m), .word("reactions"), .emoji(emoji), .word("@me")], "reactions", c.description)
        case .reactions(let c, let m, let emoji): return route("GET", [.word("channels"), .channel(c), .word("messages"), .message(m), .word("reactions"), .emoji(emoji)], "reactors", c.description)
        case .notificationSettings(let g): return route("PATCH", [.word("users/@me/guilds"), g.map(Segment.guild) ?? .word("@me"), .word("settings")], "guild-settings", g?.description ?? "@me")
        case .relationship(let u, let removing): return route(removing ? "DELETE" : "PUT", [.word("users/@me/relationships"), .user(u)], "relationship", u.description)
        case .requestFriend: return route("POST", [.word("users/@me/relationships")], "friend-request")
        case .createDM: return route("POST", [.word("users/@me/channels")], "create-dm")
        case .saveSettingsProto: return route("PATCH", [.word("users/@me/settings-proto/1")], "settings")
        case .leaveGuild(let g): return route("DELETE", [.word("users/@me/guilds"), .guild(g)], "leave-guild", g.description)
        case .settingsProto: return route("GET", [.word("users/@me/settings-proto/1")], "settings")
        case .modifyThread(let c): return route("PATCH", [.word("channels"), .channel(c)], "thread", c.description)
        case .deleteThread(let c): return route("DELETE", [.word("channels"), .channel(c)], "thread", c.description)
        case .joinThread(let c): return route("PUT", [.word("channels"), .channel(c), .word("thread-members/@me")], "thread-members", c.description)
        case .leaveThread(let c): return route("DELETE", [.word("channels"), .channel(c), .word("thread-members/@me")], "thread-members", c.description)
        case .threadSettings(let c): return route("PATCH", [.word("channels"), .channel(c), .word("thread-members/@me/settings")], "thread-settings", c.description)
        }
    }

    private enum Segment {
        case word(String), channel(ChannelID), message(MessageID), user(UserID), guild(GuildID), emoji(String)
        var path: String {
            switch self {
            case .word(let s): s
            case .channel(let id): id.description
            case .message(let id): id.description
            case .user(let id): id.description
            case .guild(let id): id.description
            case .emoji(let key): DiscordRoute.encodeSegment(key)
            }
        }
        var template: String {
            switch self {
            case .word(let s): s
            case .channel: "{channel}"
            case .message: "{message}"
            case .user: "{user}"
            case .guild: "{guild}"
            case .emoji: "{emoji}"
            }
        }
    }
    private func route(_ method: String, _ segments: [Segment], _ family: String, _ major: String = "") -> DiscordRoute {
        DiscordRoute(method: method, path: segments.map(\.path).joined(separator: "/"),
                     template: "/" + segments.map(\.template).joined(separator: "/"),
                     bucketIdentity: family + (major.isEmpty ? "" : ":" + major))
    }
}

nonisolated struct DiscordRoute: Sendable {
    let method: String
    /// Already encoded; never use for diagnostics.
    let path: String
    let template: String
    /// Existing admission identity, including the existing major parameter scope.
    /// Private transport state, never a diagnostic field.
    let bucketIdentity: String
    fileprivate init(method: String, path: String, template: String, bucketIdentity: String) {
        self.method = method; self.path = path; self.template = template; self.bucketIdentity = bucketIdentity
    }
    static func encodeSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()"))!
    }
}

/// A bounded in-memory diagnostic value, with no arbitrary string/error/body
/// fields. Templates come only from the closed endpoint registry.
nonisolated struct DiscordRequestDiagnostic: Equatable, Sendable {
    enum Outcome: String, Sendable { case confirmed, refused, unknown, notDispatched, readFailed }
    enum Source: String, Sendable { case httpResponse, transport, operationError }
    let source: Source
    let method: String
    let template: String
    let status: Int?
    let code: Int?
    let outcome: Outcome
    init(endpoint: DiscordEndpoint, status: Int? = nil, code: Int? = nil, outcome: Outcome, source: Source = .httpResponse) {
        let route = endpoint.descriptor
        method = route.method; template = route.template
        self.status = status; self.code = code; self.outcome = outcome; self.source = source
    }
}
