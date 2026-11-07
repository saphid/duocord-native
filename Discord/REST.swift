import Foundation
import os

nonisolated struct SearchResult: Decodable, Sendable {
    var totalResults: Int
    var messages: [Message]
    /// Raw hit groups consumed, including groups without a decoded first row.
    var consumedCount: Int

    enum CodingKeys: String, CodingKey {
        case messages
        case totalResults = "total_results"
    }

    init(totalResults: Int, messages: [Message]) {
        self.totalResults = totalResults
        self.messages = messages
        self.consumedCount = messages.count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalResults = try c.decodeIfPresent(Int.self, forKey: .totalResults) ?? 0
        // Each hit arrives as an array holding the matching message.
        let groups = try c.decodeIfPresent([[Message]].self, forKey: .messages) ?? []
        consumedCount = groups.count
        messages = groups.compactMap(\.first)
    }
}

nonisolated struct ThreadSearchResult: Decodable, Sendable {
    var threads: [Channel]
    var firstMessages: [Message]
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case threads, members
        case firstMessages = "first_messages"
        case hasMore = "has_more"
    }

    init(threads: [Channel], firstMessages: [Message], hasMore: Bool) {
        self.threads = threads; self.firstMessages = firstMessages; self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try ThreadListMembers.hydrate(c.decodeIfPresent([Channel].self, forKey: .threads) ?? [],
                                               members: c.decodeIfPresent([ThreadListSync.MemberEntry].self, forKey: .members) ?? [])
        firstMessages = (try? c.decodeIfPresent([Message].self, forKey: .firstMessages)) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

nonisolated struct ArchivedThreadPage: Decodable, Sendable {
    var threads: [Channel]
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case threads, members; case hasMore = "has_more" }

    init(threads: [Channel], hasMore: Bool) {
        self.threads = threads; self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try ThreadListMembers.hydrate(c.decode([Channel].self, forKey: .threads),
                                               members: c.decodeIfPresent([ThreadListSync.MemberEntry].self, forKey: .members) ?? [])
        hasMore = try c.decode(Bool.self, forKey: .hasMore)
    }
}

/// REST thread lists return the current user's memberships separately from
/// the channels. Keep them attached through page validation and publication.
nonisolated private enum ThreadListMembers {
    static func hydrate(_ threads: [Channel], members: [ThreadListSync.MemberEntry]) -> [Channel] {
        var byID: [Snowflake: ThreadListSync.MemberEntry] = [:]
        for member in members { if let id = member.id { byID[id] = member } }
        return threads.map { thread in
            guard let entry = byID[thread.id] else { return thread }
            var thread = thread
            var member = entry.settings.applied(to: thread.member ?? ThreadMemberRef())
            member.joinTimestamp = entry.joinTimestamp ?? member.joinTimestamp
            thread.member = member
            return thread
        }
    }
}

/// One page of `GET channels/{id}/messages/pins`: newest pin first, each
/// with the `pinned_at` string Discord sent, plus whether older pins remain.
/// `pinned_at` is kept exactly as received; it is the next page's `before`.
nonisolated struct PinPage: Decodable, Sendable {
    nonisolated struct Item: Decodable, Sendable {
        var message: Message
        /// Optional so a page can still be shown; a continuation without it is rejected.
        var pinnedAt: String?
        enum CodingKeys: String, CodingKey { case message; case pinnedAt = "pinned_at" }
    }
    var items: [Item]
    /// Required: a page that omits it is a decoding failure, never a false end.
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case items; case hasMore = "has_more" }
}

nonisolated struct OutgoingAttachment: Sendable {
    var filename: String
    var data: Data
    var contentType: String
}

/// Named server refusals, not permission preflight: gateway state can be stale.
nonisolated enum DiscordFailureReason: Int, Sendable {
    case unknownChannel = 10003
    case unknownMessage = 10008
    case missingAccess = 50001
    case cannotMessageUser = 50007
    case missingPermissions = 50013
}

nonisolated enum DiscordError: Error, LocalizedError {
    case http(Int, String)
    /// Preserve both status and Discord's code, including codes not yet known.
    case api(status: Int, code: Int, message: String)
    case unauthorized
    case decoding(String)
    /// A write Discord rate limited. It is not sent again by itself: you
    /// retry it (after `retryAfter` seconds).
    case rateLimited(retryAfter: Double)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): "Discord returned \(code): \(message)"
        case .api(let status, let code, let message):
            switch failureReason {
            case .missingAccess: "Discord refused access for this action. Refresh eligibility and try again."
            case .missingPermissions: "Discord denied this action because you don't have the required permissions. Check your server or channel permissions."
            case .cannotMessageUser: "Discord couldn't deliver a message to this person. Their privacy settings or your relationship may prevent messages."
            case .unknownChannel: "This channel is unavailable. It may have been deleted or you may no longer have access."
            case .unknownMessage: "This message is unavailable. It may have been deleted."
            case nil: "Discord returned \(status) (code \(code)): \(message)"
            }
        case .unauthorized: "Your Discord session ended. Sign in again."
        case .decoding(let detail): "Unexpected response from Discord (\(detail))."
        case .rateLimited(let wait): "You're doing that too fast. Try again in \(max(1, Int(wait.rounded(.up)))) s."
        }
    }

    /// HTTP-based callers keep working for coded and uncoded failures alike.
    var httpStatus: Int? {
        switch self {
        case .http(let status, _), .api(let status, _, _): status
        case .unauthorized: 401
        case .rateLimited: 429
        case .decoding: nil
        }
    }

    var failureReason: DiscordFailureReason? {
        guard case .api(let status, let code, _) = self, (400..<500).contains(status) else { return nil }
        return DiscordFailureReason(rawValue: code)
    }

    /// Code zero is Discord's generic unknown route, never Unknown Channel.
    var isUnknownRoute: Bool {
        switch self {
        case .http(404, let message), .api(404, 0, let message): message == DiscordREST.unknownRouteMessage
        default: false
        }
    }

    /// Whether Discord may have applied a write that failed with `error`:
    /// a refusal (4xx, rate limit, signed out) or a request that never left
    /// the device did nothing; a lost response or server error might have.
    nonisolated static func mayHaveApplied(_ error: Error) -> Bool {
        switch error {
        case let error as DiscordError where error.httpStatus.map({ (400..<500).contains($0) }) == true: return false
        case DiscordError.unauthorized, DiscordError.rateLimited: return false
        case let error as URLError:
            return ![.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                     .internationalRoamingOff, .dataNotAllowed].contains(error.code)
        default: return true
        }
    }
}

/// Everything the app asks of Discord's HTTP API. Live and mock
/// implementations conform; nothing else talks to the network directly.
nonisolated protocol DiscordAPI: Sendable {
    func channel(_ id: Snowflake) async throws -> Channel
    func guild(_ id: Snowflake) async throws -> Guild
    func guildRoles(_ id: Snowflake) async throws -> [Role]
    func guildMember(_ user: Snowflake, in guild: Snowflake) async throws -> Member
    func ownThreadMember(_ thread: Snowflake, account: Snowflake) async throws -> ThreadMemberRef
    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message]
    /// The first page of pins only (up to 50). Lists use `pinPage`.
    func pins(channel: Snowflake) async throws -> [Message]
    /// One page of pins older than `before` (a `pinned_at` string, sent as received).
    func pinPage(channel: Snowflake, before: String?, limit: Int) async throws -> PinPage
    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult
    func mentions(limit: Int, before: Snowflake?) async throws -> [Message]
    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult
    func archivedThreads(channel: Snowflake) async throws -> [Channel]
    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage
    /// `pingReply` is whether a reply mentions the replied-to author (the "@ On/Off" toggle).
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String, attempt: SendAttempt) async throws -> Message
    /// Replaces the text of one of your messages; returns the edited message.
    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message
    func delete(channel: Snowflake, message: Snowflake) async throws
    /// Pins (`pinned`) or unpins a message. Discord posts a system message for a pin.
    func setPinned(channel: Snowflake, message: Snowflake, pinned: Bool) async throws
    func ack(channel: Snowflake, message: Snowflake) async throws
    func acknowledge(_ read: ReadAcknowledgement) async throws
    func acknowledgeBulk(_ reads: [ReadAcknowledgement]) async throws
    func acknowledgeGuild(_ guild: Snowflake) async throws
    func typing(channel: Snowflake) async throws
    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws
    /// Who reacted with `emoji` (normal reactions, up to `limit`).
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User]
    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate
    func relationship(user: Snowflake, action: RelationshipAction) async throws
    func requestFriend(username: FriendUsername) async throws
    func createDM(recipient: Snowflake) async throws -> Channel
    func settingsProto() async throws -> String?
    /// `PATCH channels/{thread}`: rename, close/reopen, lock/unlock. Returns the updated thread.
    func modifyThread(_ thread: Snowflake, patch: ThreadPatch) async throws -> Channel
    func deleteThread(_ thread: Snowflake) async throws
    func joinThread(_ thread: Snowflake) async throws
    func leaveThread(_ thread: Snowflake) async throws
    /// `PATCH channels/{thread}/thread-members/@me/settings`. Returns the
    /// updated thread member's settings, or nil for 204 (nothing changed).
    func modifyThreadSettings(_ thread: Snowflake, fields: [String: JSONValue]) async throws -> ThreadMemberSettingsUpdate?
}

extension Emoji {
    /// The reaction key as one URL path segment, encoded the way the web
    /// client's encodeURIComponent does ("👍" → "%F0%9F%91%8D", "name:id" → "name%3Aid").
    nonisolated var reactionPathSegment: String {
        DiscordRoute.encodeSegment(reactionKey)
    }
}

extension DiscordAPI {
    /// Legacy/mock transports cannot report their dispatch boundary, so once
    /// entered they are conservatively treated as dispatched.
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String, attempt: SendAttempt) async throws -> Message {
        try await attempt.run {
            try await attempt.check()
            attempt.markDispatched()
            return try await self.send(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply, attachments: attachments, nonce: nonce)
        }
    }

    func channel(_ id: Snowflake) async throws -> Channel {
        throw DiscordError.decoding("Channel lookup is unavailable for this transport")
    }
    func guild(_ id: Snowflake) async throws -> Guild { throw DiscordError.decoding("Guild lookup unavailable") }
    func guildRoles(_ id: Snowflake) async throws -> [Role] { throw DiscordError.decoding("Role lookup unavailable") }
    func guildMember(_ user: Snowflake, in guild: Snowflake) async throws -> Member { throw DiscordError.decoding("Member lookup unavailable") }
    func ownThreadMember(_ thread: Snowflake, account: Snowflake) async throws -> ThreadMemberRef { throw DiscordError.decoding("Thread membership lookup unavailable") }

    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage {
        throw DiscordError.decoding("Public archived-thread paging is unavailable for this transport")
    }

    /// Older transports without paging: their one list is a complete, final page.
    func pinPage(channel: Snowflake, before: String?, limit: Int) async throws -> PinPage {
        guard before == nil else { return PinPage(items: [], hasMore: false) }
        return PinPage(items: try await pins(channel: channel).map { PinPage.Item(message: $0, pinnedAt: nil) }, hasMore: false)
    }
}

/// Discord's REST API as the web client uses it (v9), with per-route rate
/// limit buckets and 429 handling. Only reads are retried after a 429:
/// a write goes out once per tap, and a rate-limited one fails so you can
/// retry it yourself.
actor DiscordREST: DiscordAPI {
    private let credentials: SessionCredentials
    private let session: URLSession
    private let uploadSession: URLSession
    private let base = URL(string: "https://discord.com/api/v9")!
    private var blockedUntil: [String: ContinuousClock.Instant] = [:]
    private var globalBlockedUntil: ContinuousClock.Instant?
    private var remaining: [String: Int] = [:]
    private var bucketIDs: [String: String] = [:]
    private var resetAt: [String: Double] = [:]
    private var inFlight: [String: Int] = [:]
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "rest")
    private let decoder = JSONDecoder()
    private(set) var lastRequestDiagnostic: DiscordRequestDiagnostic?

    /// `protocolClasses` stand in for the network in tests.
    init(credentials: SessionCredentials, protocolClasses: [AnyClass]? = nil) {
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpAdditionalHeaders = [
            "User-Agent": credentials.userAgent,
            "X-Super-Properties": credentials.superPropertiesHeader,
            "X-Discord-Locale": Locale.preferredLanguages.first ?? "en-US",
            "X-Discord-Timezone": TimeZone.current.identifier,
            "Accept-Language": Locale.preferredLanguages.first ?? "en-US",
        ]
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        // Signed upload URLs use a separate session without Discord headers or
        // cookies. Tests intercept the actual PUT path with the same fixture.
        let uploadConfig = URLSessionConfiguration.ephemeral
        if let protocolClasses { uploadConfig.protocolClasses = protocolClasses }
        uploadSession = URLSession(configuration: uploadConfig)
    }

    // MARK: Endpoints

    func channel(_ id: Snowflake) async throws -> Channel {
        try await get(.channel(ChannelID(id.raw)))
    }

    func guild(_ id: Snowflake) async throws -> Guild {
        let value: Guild = try await get(.guild(GuildID(id.raw)))
        guard value.id == id, value.ownerID != nil else { throw DiscordError.decoding("Incomplete guild capability facts") }
        return value
    }
    func guildRoles(_ id: Snowflake) async throws -> [Role] { try await get(.guildRoles(GuildID(id.raw))) }
    func guildMember(_ user: Snowflake, in guild: Snowflake) async throws -> Member {
        try await get(.guildMember(GuildID(guild.raw), UserID(user.raw)))
    }
    func ownThreadMember(_ thread: Snowflake, account: Snowflake) async throws -> ThreadMemberRef {
        struct Membership: Decodable {
            let id: Snowflake
            let user_id: Snowflake
            let join_timestamp: String
            let flags: Int?
        }
        let value: Membership = try await get(.ownThreadMember(ChannelID(thread.raw)))
        guard value.id == thread, value.user_id == account, !value.join_timestamp.isEmpty else {
            throw DiscordError.decoding("Thread membership identity")
        }
        return ThreadMemberRef(joinTimestamp: value.join_timestamp, flags: value.flags)
    }

    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before.description)) }
        if let after { query.append(URLQueryItem(name: "after", value: after.description)) }
        if let around { query.append(URLQueryItem(name: "around", value: around.description)) }
        return try await get(.messages(ChannelID(channel.raw)), query: query)
    }

    func pins(channel: Snowflake) async throws -> [Message] {
        try await pinPage(channel: channel, before: nil, limit: 50).items.map(\.message)
    }

    /// Discord's generic body for a route it does not serve (JSON code 0),
    /// as opposed to e.g. "Unknown Channel" (code 10003) for a real 404.
    nonisolated static let unknownRouteMessage = "404: Not Found"

    /// Every failure of the paged route (401, 403, 429 after the usual GET
    /// retries, 5xx, decoding, transport) is surfaced. The only fallback is
    /// the first page when Discord says the paged route itself does not exist
    /// (404 "404: Not Found"): then the deprecated `channels/{id}/pins` list,
    /// which returns every pin of the channel at once, is a complete final page.
    func pinPage(channel: Snowflake, before: String?, limit: Int) async throws -> PinPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        do {
            return try await request(.pins(ChannelID(channel.raw)), query: query, body: nil, strictQuery: true)
        } catch let error as DiscordError where before == nil && error.isUnknownRoute {
            log.notice("paged pins route unavailable; using the legacy pins list")
            let legacy: [Message] = try await get(.legacyPins(ChannelID(channel.raw)))
            return PinPage(items: legacy.map { PinPage.Item(message: $0, pinnedAt: nil) }, hasMore: false)
        }
    }

    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult {
        var items = [URLQueryItem(name: "content", value: query)]
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        if let guild {
            if let channel { items.append(URLQueryItem(name: "channel_id", value: channel.description)) }
            return try await get(.guildSearch(GuildID(guild.raw)), query: items)
        }
        guard let channel else { return SearchResult(totalResults: 0, messages: []) }
        return try await get(.channelSearch(ChannelID(channel.raw)), query: items)
    }

    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "roles", value: "true"),
                     URLQueryItem(name: "everyone", value: "true")]
        if let before { query.append(URLQueryItem(name: "before", value: before.description)) }
        return try await get(.mentions, query: query)
    }

    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult {
        try await get(.forumThreads(ChannelID(channel.raw)), query: [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(name: "sort_by", value: "last_message_time"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    func archivedThreads(channel: Snowflake) async throws -> [Channel] {
        struct Page: Decodable { var threads: [Channel] }
        let page: Page = try await get(.publicArchives(ChannelID(channel.raw)), query: [URLQueryItem(name: "limit", value: "25")])
        return page.threads
    }

    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage {
        var query = [URLQueryItem(name: "limit", value: "25")]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get(.publicArchives(ChannelID(channel.raw)), query: query)
    }

    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message {
        try await send(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply,
                       attachments: attachments, nonce: nonce, attempt: SendAttempt())
    }

    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String, attempt: SendAttempt) async throws -> Message {
        try await attempt.run {
            var body = Self.sendBody(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply, nonce: nonce)
            if !attachments.isEmpty {
                body["attachments"] = .array(try await self.upload(attachments, channel: channel, attempt: attempt))
            }
            return try await self.request(.send(ChannelID(channel.raw)), body: body, sendAttempt: attempt, dispatchMessage: true)
        }
    }

    /// The message body the web client posts. A reply carries
    /// `allowed_mentions` so the author is pinged only when `pingReply` is on;
    /// everything else in the text still mentions as usual.
    nonisolated static func sendBody(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, nonce: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "content": .string(content),
            "nonce": .string(nonce),
            "tts": .bool(false),
            "flags": .number(0),
        ]
        if let replyTo {
            body["message_reference"] = .object(["message_id": .string(replyTo.description),
                                                 "channel_id": .string(channel.description)])
            body["allowed_mentions"] = .object(["parse": .array([.string("users"), .string("roles"), .string("everyone")]),
                                                "replied_user": .bool(pingReply)])
        }
        return body
    }

    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message {
        try await request(.edit(ChannelID(channel.raw), MessageID(message.raw)), body: ["content": .string(content)])
    }

    func delete(channel: Snowflake, message: Snowflake) async throws {
        _ = try await raw(.delete(ChannelID(channel.raw), MessageID(message.raw)), body: nil)
    }

    /// The documented `messages/pins` route (never the deprecated `pins/{id}`
    /// one). No body; Discord answers 204 with an empty body.
    func setPinned(channel: Snowflake, message: Snowflake, pinned: Bool) async throws {
        _ = try await raw(.pin(ChannelID(channel.raw), MessageID(message.raw), pinned: pinned), body: nil)
    }

    /// The web client's upload flow: reserve upload URLs, PUT each file, then
    /// reference the uploaded names in the message.
    private func upload(_ files: [OutgoingAttachment], channel: Snowflake, attempt: SendAttempt) async throws -> [JSONValue] {
        struct Slot: Decodable {
            var id: Int
            var uploadURL: String
            var uploadFilename: String
            enum CodingKeys: String, CodingKey {
                case id
                case uploadURL = "upload_url"
                case uploadFilename = "upload_filename"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Discord responses use numeric IDs or decimal strings.
                if let value = try? c.decode(Int.self, forKey: .id) { id = value }
                else {
                    let raw = try c.decode(String.self, forKey: .id)
                    guard let value = Int(raw), String(value) == raw else {
                        throw DiscordError.decoding("invalid upload slot ID")
                    }
                    id = value
                }
                uploadURL = try c.decode(String.self, forKey: .uploadURL)
                uploadFilename = try c.decode(String.self, forKey: .uploadFilename)
            }
        }
        struct Slots: Decodable { var attachments: [Slot] }
        let request: [String: JSONValue] = ["files": .array(files.enumerated().map { index, file in
            .object(["filename": .string(file.filename), "file_size": .number(Double(file.data.count)),
                     "id": .string(String(index))])
        })]
        let slots: Slots = try await self.request(.attachments(ChannelID(channel.raw)), body: request, sendAttempt: attempt)
        guard slots.attachments.count == files.count,
              Set(slots.attachments.map(\.id)) == Set(files.indices) else {
            throw DiscordError.decoding("incomplete or ambiguous upload slots")
        }
        // Validate the entire reservation before transferring even the first file.
        let validated = try slots.attachments.sorted { $0.id < $1.id }.map { slot -> (Slot, URL) in
            guard !slot.uploadURL.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  let url = URL(string: slot.uploadURL, encodingInvalidCharacters: false),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.fragment == nil,
                  components.port.map({ (1...65535).contains($0) }) ?? true,
                  !slot.uploadFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DiscordError.decoding("invalid upload reservation URL or filename")
            }
            return (slot, url)
        }
        var result: [JSONValue] = []
        for (slot, url) in validated {
            let index = slot.id
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.setValue(files[index].contentType, forHTTPHeaderField: "Content-Type")
            try await attempt.check()
            let (_, response) = try await uploadSession.upload(for: put, from: files[index].data)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw DiscordError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "upload failed")
            }
            result.append(.object(["id": .string(String(index)), "filename": .string(files[index].filename),
                                   "uploaded_filename": .string(slot.uploadFilename)]))
        }
        return result
    }

    func ack(channel: Snowflake, message: Snowflake) async throws {
        try await acknowledge(ReadAcknowledgement(channel: channel, message: message))
    }

    func acknowledge(_ read: ReadAcknowledgement) async throws {
        // The endpoint returns an ack-token JSON object; accepting raw success
        // also handles empty successful responses without a decoding failure.
        _ = try await raw(.ack(ChannelID(read.channel.raw), MessageID(read.message.raw)),
                          body: read.fields)
    }

    func acknowledgeBulk(_ reads: [ReadAcknowledgement]) async throws {
        guard !reads.isEmpty else { return }
        guard reads.allSatisfy({ !$0.manual && $0.message > 0 }) else {
            throw DiscordError.http(0, "Bulk acknowledgements require positive, nonmanual boundaries")
        }
        _ = try await raw(.ackBulk, body: ["read_states": .array(reads.map(\.bulkFields))])
    }

    /// Deprecated by Discord. UI server actions use captured bulk boundaries
    /// instead: the guild endpoint can consume messages arriving after the tap.
    func acknowledgeGuild(_ guild: Snowflake) async throws {
        _ = try await raw(.guildAck(GuildID(guild.raw)), body: nil)
    }

    func typing(channel: Snowflake) async throws {
        _ = try await raw(.typing(ChannelID(channel.raw)), body: nil)
    }

    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws {
        _ = try await raw(.reaction(ChannelID(channel.raw), MessageID(message.raw), emoji: emoji.reactionKey, add: add),
                          body: nil)
    }

    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] {
        try await get(.reactions(ChannelID(channel.raw), MessageID(message.raw), emoji: emoji.reactionKey),
                      query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "type", value: "0")])
    }

    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate {
        try await request(.notificationSettings(target.resource == 0 ? nil : GuildID(target.resource.raw)),
                          body: patch.fields(for: target))
    }

    func relationship(user: Snowflake, action: RelationshipAction) async throws {
        _ = try await raw(.relationship(UserID(user.raw), removing: action.method == "DELETE"), body: action.body)
    }

    func requestFriend(username: FriendUsername) async throws {
        _ = try await raw(.requestFriend, body: username.fields)
    }

    func createDM(recipient: Snowflake) async throws -> Channel {
        try await request(.createDM, body: ["recipients": .array([.string(recipient.description)])])
    }

    func modifyThread(_ thread: Snowflake, patch: ThreadPatch) async throws -> Channel {
        try await request(.modifyThread(ChannelID(thread.raw)), body: patch.fields)
    }

    func deleteThread(_ thread: Snowflake) async throws {
        _ = try await raw(.deleteThread(ChannelID(thread.raw)), body: nil)
    }

    func joinThread(_ thread: Snowflake) async throws {
        _ = try await raw(.joinThread(ChannelID(thread.raw)), body: nil)
    }

    func leaveThread(_ thread: Snowflake) async throws {
        _ = try await raw(.leaveThread(ChannelID(thread.raw)), body: nil)
    }

    func modifyThreadSettings(_ thread: Snowflake, fields: [String: JSONValue]) async throws -> ThreadMemberSettingsUpdate? {
        let data = try await raw(.threadSettings(ChannelID(thread.raw)), body: fields)
        // 204: Discord changed nothing.
        guard !data.isEmpty else { return nil }
        do {
            return try decoder.decode(ThreadMemberSettingsUpdate.self, from: data)
        } catch {
            throw DiscordError.decoding(DiscordEndpoint.threadSettings(ChannelID(thread.raw)).descriptor.template)
        }
    }

    func settingsProto() async throws -> String? {
        struct Settings: Decodable { var settings: String }
        let settings: Settings = try await get(.settingsProto)
        return settings.settings
    }

    // MARK: Transport

    /// `path` is already percent-encoded (IDs, fixed words, and segments such
    /// as `Emoji.reactionPathSegment`); it is appended as is, never encoded twice.
    /// `strictQuery` also percent-encodes "+" in values (URLComponents leaves
    /// it bare, and servers decode a bare "+" as a space), so an opaque cursor
    /// such as "2026-11-02T11:22:33.123000+00:00" arrives exactly as received.
    nonisolated static func url(base: URL, path: String, query: [URLQueryItem] = [], strictQuery: Bool = false) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += "/" + path
        if !query.isEmpty { components.queryItems = query }
        if strictQuery, let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func get<T: Decodable>(_ endpoint: DiscordEndpoint, query: [URLQueryItem] = []) async throws -> T {
        try await request(endpoint, query: query, body: nil)
    }

    private func request<T: Decodable>(_ endpoint: DiscordEndpoint, query: [URLQueryItem] = [],
                                       body: [String: JSONValue]?, strictQuery: Bool = false,
                                       sendAttempt: SendAttempt? = nil, dispatchMessage: Bool = false) async throws -> T {
        let data = try await raw(endpoint, query: query, body: body, strictQuery: strictQuery, sendAttempt: sendAttempt, dispatchMessage: dispatchMessage)
        do {
            return try decoder.decode(T.self, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            // Decoder descriptions can contain response values and coding keys.
            log.error("decode \(endpoint.descriptor.template, privacy: .public)")
            throw DiscordError.decoding(endpoint.descriptor.template)
        }
    }

    private func raw(_ endpoint: DiscordEndpoint, query: [URLQueryItem] = [], body: [String: JSONValue]?,
                     strictQuery: Bool = false, sendAttempt: SendAttempt? = nil, dispatchMessage: Bool = false) async throws -> Data {
        let descriptor = endpoint.descriptor
        let method = descriptor.method, route = descriptor.bucketIdentity
        var request = URLRequest(url: Self.url(base: base, path: descriptor.path, query: query, strictQuery: strictQuery))
        request.httpMethod = method
        request.setValue(credentials.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<4 {
            let admitted = try await waitForBucket(route)
            let data: Data, response: URLResponse
            var handedOff = false
            do {
                try Task.checkCancellation()
                if let sendAttempt { try await sendAttempt.check() }
                if dispatchMessage { sendAttempt?.markDispatched() }
                handedOff = true
                (data, response) = try await session.data(for: request)
            } catch {
                inFlight[admitted] = max(0, (inFlight[admitted] ?? 1) - 1)
                lastRequestDiagnostic = DiscordRequestDiagnostic(endpoint: endpoint,
                    outcome: method == "GET" ? .readFailed : !handedOff || !DiscordError.mayHaveApplied(error) ? .notDispatched : .unknown, source: .transport)
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                inFlight[admitted] = max(0, (inFlight[admitted] ?? 1) - 1)
                lastRequestDiagnostic = DiscordRequestDiagnostic(endpoint: endpoint,
                    outcome: method == "GET" ? .readFailed : .unknown, source: .transport)
                throw DiscordError.http(0, "no response")
            }
            record(http, route: route, admitted: admitted)
            // Only the numeric code enters safe metadata, never response text.
            struct DiagnosticCode: Decodable { let code: Int? }
            let code = (try? decoder.decode(DiagnosticCode.self, from: data))?.code
            lastRequestDiagnostic = DiscordRequestDiagnostic(endpoint: endpoint, status: http.statusCode, code: code,
                outcome: (200..<300).contains(http.statusCode) ? .confirmed : method == "GET" ? .readFailed : (400..<500).contains(http.statusCode) ? .refused : .unknown)
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                throw DiscordError.unauthorized
            case 429:
                struct Limited: Decodable { var retry_after: Double?; var global: Bool? }
                let limited = try? decoder.decode(Limited.self, from: data)
                let wait = max(0.25, limited?.retry_after ?? 1)
                let until = ContinuousClock.now + .milliseconds(Int(wait * 1000))
                if limited?.global == true { globalBlockedUntil = until } else { blockedUntil[bucketKey(route)] = until }
                // Nothing is sent without a tap: a write is never sent again by itself.
                guard method == "GET" else {
                    log.notice("429 on \(descriptor.template, privacy: .public) (\(method, privacy: .public)), not retried")
                    throw DiscordError.rateLimited(retryAfter: wait)
                }
                guard attempt < 3 else { throw DiscordError.http(429, "rate limited") }
                log.notice("429 on \(descriptor.template, privacy: .public), waiting \(wait)s")
                continue
            default:
                // Decode fields independently: a malformed code must not discard
                // a useful message, nor a malformed message a valid numeric code.
                struct Failure: Decodable {
                    var code: Int?
                    var message: String?
                    enum CodingKeys: String, CodingKey { case code, message }
                    init(from decoder: Decoder) throws {
                        let fields = try decoder.container(keyedBy: CodingKeys.self)
                        code = try? fields.decode(Int.self, forKey: .code)
                        message = try? fields.decode(String.self, forKey: .message)
                    }
                }
                let failure = try? decoder.decode(Failure.self, from: data)
                let message = failure?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                if let code = failure?.code { throw DiscordError.api(status: http.statusCode, code: code, message: message) }
                throw DiscordError.http(http.statusCode, message)
            }
        }
        throw DiscordError.http(429, "rate limited")
    }

    /// Waits until neither the route's bucket nor the global limit is
    /// exhausted, rechecking after every sleep (deadlines can move while
    /// suspended), then reserves the slot so concurrent callers queue.
    @discardableResult
    private func waitForBucket(_ route: String) async throws -> String {
        while true {
            try Task.checkCancellation()
            // Recomputed after every sleep: a response may have mapped the route
            // to Discord's shared bucket meanwhile.
            let key = bucketKey(route)
            let until = [blockedUntil[key], globalBlockedUntil].compactMap { $0 }.max()
            if let until, until > ContinuousClock.now {
                try await Task.sleep(until: until, clock: .continuous)
                continue
            }
            if inFlight[key, default: 0] >= (remaining[key] ?? 1).clamped(1, 5) {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            inFlight[key, default: 0] += 1
            return key
        }
    }

    /// Discord's shared bucket (X-RateLimit-Bucket) plus the route's major
    /// parameter (the part after ":", e.g. the channel), once known.
    private func bucketKey(_ route: String) -> String {
        guard let bucket = bucketIDs[route] else { return route }
        let major = route.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return "\(bucket):\(major)"
    }

    private func record(_ response: HTTPURLResponse, route: String, admitted: String) {
        // Release exactly the reservation this request took.
        inFlight[admitted] = max(0, (inFlight[admitted] ?? 1) - 1)
        if let bucket = response.value(forHTTPHeaderField: "X-RateLimit-Bucket") { bucketIDs[route] = bucket }
        let key = bucketKey(route)
        guard let left = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) else { return }
        // Responses can arrive out of order: within one reset window only
        // ever lower the remaining count; a later reset starts a new window.
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) ?? 0
        if reset > (resetAt[key] ?? 0) {
            resetAt[key] = reset
            remaining[key] = left
        } else {
            remaining[key] = min(remaining[key] ?? left, left)
        }
        guard left == 0, let resetAfter = response.value(forHTTPHeaderField: "X-RateLimit-Reset-After").flatMap(Double.init) else { return }
        blockedUntil[bucketKey(route)] = ContinuousClock.now + .milliseconds(Int(resetAfter * 1000))
    }
}

extension Int {
    nonisolated func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

extension DiscordAPI {
    func acknowledge(_ read: ReadAcknowledgement) async throws { throw DiscordError.http(0, "Read operations unavailable") }
    func acknowledgeBulk(_ reads: [ReadAcknowledgement]) async throws { throw DiscordError.http(0, "Read operations unavailable") }
    func acknowledgeGuild(_ guild: Snowflake) async throws { throw DiscordError.http(0, "Read operations unavailable") }
}

// Older test transports and offline implementations fail closed.
extension DiscordAPI {
    func relationship(user: Snowflake, action: RelationshipAction) async throws { throw DiscordError.unauthorized }
    func requestFriend(username: FriendUsername) async throws { throw DiscordError.unauthorized }
    func createDM(recipient: Snowflake) async throws -> Channel { throw DiscordError.unauthorized }
    func setPinned(channel: Snowflake, message: Snowflake, pinned: Bool) async throws { throw DiscordError.unauthorized }
    func modifyThread(_ thread: Snowflake, patch: ThreadPatch) async throws -> Channel { throw DiscordError.unauthorized }
    func deleteThread(_ thread: Snowflake) async throws { throw DiscordError.unauthorized }
    func joinThread(_ thread: Snowflake) async throws { throw DiscordError.unauthorized }
    func leaveThread(_ thread: Snowflake) async throws { throw DiscordError.unauthorized }
    func modifyThreadSettings(_ thread: Snowflake, fields: [String: JSONValue]) async throws -> ThreadMemberSettingsUpdate? {
        throw DiscordError.unauthorized
    }
}
