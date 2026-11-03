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
        case threads
        case firstMessages = "first_messages"
        case hasMore = "has_more"
    }

    init(threads: [Channel], firstMessages: [Message], hasMore: Bool) {
        self.threads = threads; self.firstMessages = firstMessages; self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decodeIfPresent([Channel].self, forKey: .threads) ?? []
        firstMessages = (try? c.decodeIfPresent([Message].self, forKey: .firstMessages)) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

nonisolated struct ArchivedThreadPage: Decodable, Sendable {
    var threads: [Channel]
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case threads; case hasMore = "has_more" }
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

nonisolated enum DiscordError: Error, LocalizedError {
    case http(Int, String)
    case unauthorized
    case decoding(String)
    /// A write Discord rate limited. It is not sent again by itself: you
    /// retry it (after `retryAfter` seconds).
    case rateLimited(retryAfter: Double)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): "Discord returned \(code): \(message)"
        case .unauthorized: "Your Discord session ended. Sign in again."
        case .decoding(let detail): "Unexpected response from Discord (\(detail))."
        case .rateLimited(let wait): "You're doing that too fast. Try again in \(max(1, Int(wait.rounded(.up)))) s."
        }
    }

    /// Whether Discord may have applied a write that failed with `error`:
    /// a refusal (4xx, rate limit, signed out) or a request that never left
    /// the device did nothing; a lost response or server error might have.
    nonisolated static func mayHaveApplied(_ error: Error) -> Bool {
        switch error {
        case DiscordError.http(let code, _) where (400..<500).contains(code): return false
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
}

extension Emoji {
    /// The reaction key as one URL path segment, encoded the way the web
    /// client's encodeURIComponent does ("👍" → "%F0%9F%91%8D", "name:id" → "name%3Aid").
    nonisolated var reactionPathSegment: String {
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-_.!~*'()")
        return reactionKey.addingPercentEncoding(withAllowedCharacters: unreserved) ?? reactionKey
    }
}

extension DiscordAPI {
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

    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before.description)) }
        if let after { query.append(URLQueryItem(name: "after", value: after.description)) }
        if let around { query.append(URLQueryItem(name: "around", value: around.description)) }
        return try await get("channels/\(channel)/messages", query: query, route: "messages:\(channel)")
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
            return try await request("GET", "channels/\(channel)/messages/pins", query: query, body: nil,
                                     route: "pins:\(channel)", strictQuery: true)
        } catch DiscordError.http(404, let message) where before == nil && message == Self.unknownRouteMessage {
            log.notice("paged pins route unavailable; using the legacy pins list")
            let legacy: [Message] = try await get("channels/\(channel)/pins", route: "pins:\(channel)")
            return PinPage(items: legacy.map { PinPage.Item(message: $0, pinnedAt: nil) }, hasMore: false)
        }
    }

    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult {
        var items = [URLQueryItem(name: "content", value: query)]
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        if let guild {
            if let channel { items.append(URLQueryItem(name: "channel_id", value: channel.description)) }
            return try await get("guilds/\(guild)/messages/search", query: items, route: "search:\(guild)")
        }
        guard let channel else { return SearchResult(totalResults: 0, messages: []) }
        return try await get("channels/\(channel)/messages/search", query: items, route: "search:\(channel)")
    }

    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "roles", value: "true"),
                     URLQueryItem(name: "everyone", value: "true")]
        if let before { query.append(URLQueryItem(name: "before", value: before.description)) }
        return try await get("users/@me/mentions", query: query, route: "mentions")
    }

    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult {
        try await get("channels/\(channel)/threads/search", query: [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(name: "sort_by", value: "last_message_time"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "offset", value: String(offset)),
        ], route: "threads:\(channel)")
    }

    func archivedThreads(channel: Snowflake) async throws -> [Channel] {
        struct Page: Decodable { var threads: [Channel] }
        let page: Page = try await get("channels/\(channel)/threads/archived/public", query: [URLQueryItem(name: "limit", value: "25")], route: "threads:\(channel)")
        return page.threads
    }

    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage {
        var query = [URLQueryItem(name: "limit", value: "25")]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get("channels/\(channel)/threads/archived/public", query: query, route: "threads:\(channel)")
    }

    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message {
        var body = Self.sendBody(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply, nonce: nonce)
        if !attachments.isEmpty {
            body["attachments"] = .array(try await upload(attachments, channel: channel))
        }
        return try await request("POST", "channels/\(channel)/messages", body: body, route: "send:\(channel)")
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
        try await request("PATCH", "channels/\(channel)/messages/\(message)", body: ["content": .string(content)], route: "edit:\(channel)")
    }

    func delete(channel: Snowflake, message: Snowflake) async throws {
        _ = try await raw("DELETE", "channels/\(channel)/messages/\(message)", body: nil, route: "delete:\(channel)")
    }

    /// The documented `messages/pins` route (never the deprecated `pins/{id}`
    /// one). No body; Discord answers 204 with an empty body.
    func setPinned(channel: Snowflake, message: Snowflake, pinned: Bool) async throws {
        _ = try await raw(pinned ? "PUT" : "DELETE", "channels/\(channel)/messages/pins/\(message)", body: nil, route: "pin:\(channel)")
    }

    /// The web client's upload flow: reserve upload URLs, PUT each file, then
    /// reference the uploaded names in the message.
    private func upload(_ files: [OutgoingAttachment], channel: Snowflake) async throws -> [JSONValue] {
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
        let slots: Slots = try await self.request("POST", "channels/\(channel)/attachments", body: request, route: "attachments:\(channel)")
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
        _ = try await raw("POST", "channels/\(read.channel)/messages/\(read.message)/ack",
                          body: read.fields, route: "ack:\(read.channel)")
    }

    func acknowledgeBulk(_ reads: [ReadAcknowledgement]) async throws {
        guard !reads.isEmpty else { return }
        guard reads.allSatisfy({ !$0.manual && $0.message > 0 }) else {
            throw DiscordError.http(0, "Bulk acknowledgements require positive, nonmanual boundaries")
        }
        _ = try await raw("POST", "read-states/ack-bulk", body: ["read_states": .array(reads.map(\.bulkFields))], route: "ack-bulk")
    }

    /// Deprecated by Discord. UI server actions use captured bulk boundaries
    /// instead: the guild endpoint can consume messages arriving after the tap.
    func acknowledgeGuild(_ guild: Snowflake) async throws {
        _ = try await raw("POST", "guilds/\(guild)/ack", body: nil, route: "guild-ack:\(guild)")
    }

    func typing(channel: Snowflake) async throws {
        _ = try await raw("POST", "channels/\(channel)/typing", body: nil, route: "typing:\(channel)")
    }

    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws {
        _ = try await raw(add ? "PUT" : "DELETE", "channels/\(channel)/messages/\(message)/reactions/\(emoji.reactionPathSegment)/@me",
                          body: nil, route: "reactions:\(channel)")
    }

    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] {
        try await get("channels/\(channel)/messages/\(message)/reactions/\(emoji.reactionPathSegment)",
                      query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "type", value: "0")],
                      route: "reactors:\(channel)")
    }

    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate {
        try await request("PATCH", "users/@me/guilds/\(target.routeID)/settings",
                          body: patch.fields(for: target), route: "guild-settings:\(target.routeID)")
    }

    func relationship(user: Snowflake, action: RelationshipAction) async throws {
        _ = try await raw(action.method, "users/@me/relationships/\(user)", body: action.body, route: "relationship:\(user)")
    }

    func requestFriend(username: FriendUsername) async throws {
        _ = try await raw("POST", "users/@me/relationships", body: username.fields, route: "friend-request")
    }

    func createDM(recipient: Snowflake) async throws -> Channel {
        try await request("POST", "users/@me/channels", body: ["recipients": .array([.string(recipient.description)])], route: "create-dm")
    }

    func settingsProto() async throws -> String? {
        struct Settings: Decodable { var settings: String }
        let settings: Settings = try await get("users/@me/settings-proto/1", route: "settings")
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

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], route: String) async throws -> T {
        try await request("GET", path, query: query, body: nil, route: route)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                       body: [String: JSONValue]?, route: String, strictQuery: Bool = false) async throws -> T {
        let data = try await raw(method, path, query: query, body: body, route: route, strictQuery: strictQuery)
        do {
            return try decoder.decode(T.self, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            log.error("decode \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw DiscordError.decoding(path)
        }
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: JSONValue]?,
                     route: String, strictQuery: Bool = false) async throws -> Data {
        var request = URLRequest(url: Self.url(base: base, path: path, query: query, strictQuery: strictQuery))
        request.httpMethod = method
        request.setValue(credentials.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<4 {
            let admitted = try await waitForBucket(route)
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                inFlight[admitted] = max(0, (inFlight[admitted] ?? 1) - 1)
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw DiscordError.http(0, "no response") }
            record(http, route: route, admitted: admitted)
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
                    log.notice("429 on \(route, privacy: .public) (\(method, privacy: .public)), not retried")
                    throw DiscordError.rateLimited(retryAfter: wait)
                }
                guard attempt < 3 else { throw DiscordError.http(429, "rate limited") }
                log.notice("429 on \(route, privacy: .public), waiting \(wait)s")
                continue
            default:
                struct Failure: Decodable { var message: String? }
                let message = (try? decoder.decode(Failure.self, from: data))?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
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
}
