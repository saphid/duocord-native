import XCTest
@testable import DuocordNative

/// Catch-all transport: an exhausted script fails closed (599) instead of reaching a service.
nonisolated private final class PinsWire: URLProtocol, @unchecked Sendable {
    struct Stub { var status: Int; var body: Data }
    static let lock = NSLock()
    static var script: [Stub] = []
    static var requests: [URLRequest] = []
    static func reset(_ values: [Stub]) { lock.withLock { script = values; requests = [] } }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.lock.withLock { () -> Stub in
            Self.requests.append(request)
            return Self.script.isEmpty ? Stub(status: 599, body: Data("Unexpected offline request".utf8)) : Self.script.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// An older transport that only knows the single pins list.
nonisolated private struct OnePage: DiscordAPI {
    let rows: [Message]
    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] { [] }
    func pins(channel: Snowflake) async throws -> [Message] { rows }
    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult { SearchResult(totalResults: 0, messages: []) }
    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] { [] }
    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult { ThreadSearchResult(threads: [], firstMessages: [], hasMore: false) }
    func archivedThreads(channel: Snowflake) async throws -> [Channel] { [] }
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message { throw DiscordError.unauthorized }
    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message { throw DiscordError.unauthorized }
    func delete(channel: Snowflake, message: Snowflake) async throws {}
    func ack(channel: Snowflake, message: Snowflake) async throws {}
    func typing(channel: Snowflake) async throws {}
    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws {}
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] { [] }
    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate { throw DiscordError.unauthorized }
    func settingsProto() async throws -> String? { nil }
}

/// Pins beyond the first 50: typed pages, exact `pinned_at` cursors, the
/// shared OtherListState paging owner, and errors that surface instead of a
/// silent legacy fallback. Offline only (URLProtocol fixtures and fakes).
@MainActor
final class PinsPaginationTests: XCTestCase {
    private final class Held<Value> {
        var response: CheckedContinuation<Value, Error>?
        var arrival: CheckedContinuation<Void, Never>?
        func load() async throws -> Value {
            try await withCheckedThrowingContinuation { response = $0; arrival?.resume(); arrival = nil }
        }
        func started() async { if response == nil { await withCheckedContinuation { arrival = $0 } } }
        func finish(_ result: Result<Value, Error>) { response!.resume(with: result); response = nil }
    }

    private let channel: Snowflake = 42
    private let legacyPath = "/api/v9/channels/42/pins"
    private let pagedPath = "/api/v9/channels/42/messages/pins"
    private let ended = LookupPageProgress.finished("All results returned by these pages are loaded.")

    private func client() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-only", superProperties: nil, userAgent: "PinsPaging"),
                    protocolClasses: [PinsWire.self])
    }
    private func message(_ id: Int, channel: Snowflake? = nil) -> Message {
        Message(id: Snowflake(UInt64(id)), channelID: channel ?? self.channel, guildID: 10,
                author: User(id: Snowflake(UInt64(id + 10_000)), username: "offline"), content: "pinned \(id)", timestamp: "")
    }
    /// Discord's own shape: microseconds and a "+00:00" offset, newest first.
    private func stamp(_ index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_790_000_000 - Double(index))) + ".123456+00:00"
    }
    private func item(_ index: Int, id: Int? = nil) -> PinPage.Item {
        PinPage.Item(message: message(id ?? 1_000 + index), pinnedAt: stamp(index))
    }
    private func page(_ range: Range<Int>, more: Bool) -> PinPage {
        PinPage(items: range.map { item($0) }, hasMore: more)
    }
    private func body(_ page: PinPage) throws -> Data {
        let items = try page.items.map { item -> [String: Any] in
            var object: [String: Any] = ["message": try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.message))]
            if let pinnedAt = item.pinnedAt { object["pinned_at"] = pinnedAt }
            return object
        }
        return try JSONSerialization.data(withJSONObject: ["items": items, "has_more": page.hasMore])
    }
    private func ok(_ page: PinPage) throws -> PinsWire.Stub { PinsWire.Stub(status: 200, body: try body(page)) }
    private func status(_ code: Int, _ json: String) -> PinsWire.Stub { PinsWire.Stub(status: code, body: Data(json.utf8)) }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }
    private func legacy(_ requests: [URLRequest]) -> [URLRequest] { requests.filter { $0.url?.path == legacyPath } }
    private func pins(_ owner: OtherListState<String, Message, String>, input: String = "pins", api: DiscordAPI? = nil,
                      store: DiscordStore? = nil, fetch: (@MainActor (String?) async throws -> PinPage)? = nil,
                      current: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never> {
        OtherListConsumers.pins(owner, input: input, api: api ?? OfflineAPI(), channel: channel, store: store ?? DiscordStore(),
                                isCurrent: current, fetch: fetch)
    }

    // MARK: Wire (production DiscordREST over URLProtocol)

    func testPagesOf50And50And3Reach103UniqueRowsWithExactCursorsOnTheWire() async throws {
        PinsWire.reset([try ok(page(0..<50, more: true)), try ok(page(50..<100, more: true)), try ok(page(100..<103, more: false))])
        let owner = OtherListState<String, Message, String>(), store = DiscordStore()
        await pins(owner, api: client(), store: store).value
        XCTAssertEqual(owner.snapshot(for: "pins").rows.count, 50)
        XCTAssertEqual(owner.snapshot(for: "pins").more, .ready)
        await owner.loadMore("pins")?.value
        await owner.loadMore("pins")?.value
        let snapshot = owner.snapshot(for: "pins")
        XCTAssertEqual(snapshot.rows.count, 103)
        XCTAssertEqual(Set(snapshot.rows.map(\.id)).count, 103)
        XCTAssertEqual(snapshot.rows.map(\.id), (0..<103).map { Snowflake(UInt64(1_000 + $0)) }, "newest pin first, in wire order")
        XCTAssertEqual(snapshot.more, ended, "has_more=false is an honest end")
        XCTAssertNil(owner.loadMore("pins"), "nothing is requested after the end")
        let requests = PinsWire.captured()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == pagedPath && query($0)["limit"] == "50" })
        XCTAssertEqual(requests.map { query($0)["before"] }, [nil, stamp(49), stamp(99)], "before is the previous last pinned_at")
        // "+" must not be sent bare (a server decodes it as a space).
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "limit=50&before=\(stamp(49).replacingOccurrences(of: "+", with: "%2B"))")
        XCTAssertFalse(requests.contains { (URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "").contains("+") })
        XCTAssertTrue(legacy(requests).isEmpty)
        XCTAssertNotNil(store.users[11_102], "row authors are remembered")
    }

    func testTransportKeepsPinnedAtAndHasMoreAndRequiresHasMore() async throws {
        PinsWire.reset([try ok(page(0..<2, more: true))])
        let first = try await client().pinPage(channel: channel, before: nil, limit: 50)
        XCTAssertEqual(first.items.map(\.pinnedAt), [stamp(0), stamp(1)])
        XCTAssertTrue(first.hasMore)
        PinsWire.reset([status(200, #"{"items":[]}"#)])
        do { _ = try await client().pinPage(channel: channel, before: nil, limit: 50); XCTFail("missing has_more must not read as the end") }
        catch DiscordError.decoding {} catch { XCTFail("unexpected \(error)") }
        XCTAssertTrue(legacy(PinsWire.captured()).isEmpty)
    }

    func testSecondPageFailureKeepsFirstPageAndRetrySameCursorSucceeds() async throws {
        PinsWire.reset([try ok(page(0..<50, more: true)), status(500, #"{"message":"boom"}"#), try ok(page(50..<53, more: false))])
        let owner = OtherListState<String, Message, String>()
        await pins(owner, api: client()).value
        await owner.loadMore("pins")?.value
        var snapshot = owner.snapshot(for: "pins")
        XCTAssertEqual(snapshot.rows.count, 50, "loaded rows survive a failed page")
        XCTAssertEqual(snapshot.status, .done)
        guard case .failed = snapshot.more else { return XCTFail("page 2 failure must be retryable, got \(snapshot.more)") }
        await owner.loadMore("pins")?.value
        snapshot = owner.snapshot(for: "pins")
        XCTAssertEqual(snapshot.rows.count, 53)
        XCTAssertEqual(snapshot.more, ended)
        let requests = PinsWire.captured()
        XCTAssertEqual(requests.map { query($0)["before"] }, [nil, stamp(49), stamp(49)], "the retry repeats the same cursor")
        XCTAssertTrue(legacy(requests).isEmpty)
    }

    func testHasMoreFalseOnFirstPageEndsWithOneRequest() async throws {
        PinsWire.reset([try ok(page(0..<3, more: false))])
        let owner = OtherListState<String, Message, String>()
        await pins(owner, api: client()).value
        XCTAssertEqual(owner.snapshot(for: "pins").rows.count, 3)
        XCTAssertEqual(owner.snapshot(for: "pins").more, ended)
        XCTAssertNil(owner.loadMore("pins"))
        XCTAssertEqual(PinsWire.captured().count, 1)
    }

    func testServerErrorSurfacesWithZeroLegacyRequests() async {
        PinsWire.reset([status(500, #"{"message":"boom"}"#), status(200, "[]")])
        do { _ = try await client().pins(channel: 42); XCTFail("a 500 must surface") }
        catch DiscordError.http(let code, _) { XCTAssertEqual(code, 500) } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(legacy(PinsWire.captured()).count, 0, "no silent legacy fallback")
    }

    func testRateLimitSurfacesWithZeroLegacyRequests() async {
        let limited = status(429, #"{"retry_after":0.01,"global":false}"#)
        PinsWire.reset([limited, limited, limited, limited, status(200, "[]")])
        do { _ = try await client().pins(channel: 42); XCTFail("a persistent 429 must surface") }
        catch DiscordError.http(let code, _) { XCTAssertEqual(code, 429) } catch { XCTFail("unexpected \(error)") }
        let requests = PinsWire.captured()
        XCTAssertEqual(requests.count, 4, "only the usual GET retries")
        XCTAssertEqual(legacy(requests).count, 0, "no silent legacy fallback")
    }

    func testMalformedPageSurfacesWithZeroLegacyRequests() async {
        PinsWire.reset([status(200, "{}"), status(200, "[]")])
        do { _ = try await client().pins(channel: 42); XCTFail("a malformed page must surface") } catch {}
        XCTAssertEqual(legacy(PinsWire.captured()).count, 0, "no silent legacy fallback")
    }

    func testListSurfacesServerAndAuthErrorsWithoutLegacyRequests() async {
        for (stub, expected) in [(status(500, #"{"message":"boom"}"#), "500"), (status(401, "{}"), "session ended"),
                                 (status(404, #"{"message":"Unknown Channel","code":10003}"#), "This channel is unavailable")] {
            PinsWire.reset([stub, status(200, "[]")])
            let owner = OtherListState<String, Message, String>()
            await pins(owner, api: client()).value
            let snapshot = owner.snapshot(for: "pins")
            guard case .failed(let error) = snapshot.status else { XCTFail("\(expected): \(snapshot.status)"); continue }
            XCTAssertTrue(error.contains(expected), "\(expected) in \(error)")
            XCTAssertTrue(snapshot.rows.isEmpty)
            XCTAssertEqual(PinsWire.captured().count, 1, expected)
            XCTAssertTrue(legacy(PinsWire.captured()).isEmpty, expected)
        }
    }

    func testOnlyAnUnknownRoute404OnTheFirstPageUsesTheLegacyListAsACompletePage() async throws {
        let legacyRows = try JSONEncoder().encode([message(7), message(8), message(9)])
        PinsWire.reset([status(404, #"{"message":"404: Not Found","code":0}"#), PinsWire.Stub(status: 200, body: legacyRows)])
        let owner = OtherListState<String, Message, String>()
        await pins(owner, api: client()).value
        XCTAssertEqual(owner.snapshot(for: "pins").rows.map(\.id), [7, 8, 9])
        XCTAssertEqual(owner.snapshot(for: "pins").more, ended)
        XCTAssertEqual(PinsWire.captured().map { $0.url?.path }, [pagedPath, legacyPath])
        // A later page never falls back: the paged route already answered.
        PinsWire.reset([status(404, #"{"message":"404: Not Found","code":0}"#)])
        do { _ = try await client().pinPage(channel: channel, before: stamp(49), limit: 50); XCTFail("must surface") } catch {}
        XCTAssertTrue(legacy(PinsWire.captured()).isEmpty)
    }

    // MARK: Paging owner (held/fake loads)

    func testDuplicatesAcrossPagesAreDroppedByMessageID() async {
        let owner = OtherListState<String, Message, String>()
        await pins(owner) { before in
            before == nil ? self.page(0..<50, more: true)
                : PinPage(items: [self.item(50, id: 1_000), self.item(51, id: 1_001)] + (52..<55).map { self.item($0) }, hasMore: false)
        }.value
        await owner.loadMore("pins")?.value
        let rows = owner.snapshot(for: "pins").rows
        XCTAssertEqual(rows.count, 53)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testNonAdvancingOrMalformedCursorsStopSafely() async {
        let pages: [String: PinPage] = [
            "same cursor": PinPage(items: [item(49, id: 2_000)], hasMore: true),
            "same cursor, unordered": PinPage(items: [item(50, id: 2_000), item(49, id: 2_001)], hasMore: true),
            "newer cursor": PinPage(items: [item(10, id: 2_000)], hasMore: true),
            "missing cursor": PinPage(items: [PinPage.Item(message: message(2_000), pinnedAt: nil)], hasMore: true),
            "garbage cursor": PinPage(items: [PinPage.Item(message: message(2_000), pinnedAt: "yesterday")], hasMore: true),
            "unordered": PinPage(items: [item(60, id: 2_000), item(55, id: 2_001)], hasMore: true),
            "empty continuation": PinPage(items: [], hasMore: true),
        ]
        for (name, second) in pages {
            let owner = OtherListState<String, Message, String>()
            var cursors: [String?] = []
            await pins(owner) { before in
                cursors.append(before)
                return before == nil ? self.page(0..<50, more: true) : second
            }.value
            await owner.loadMore("pins")?.value
            let snapshot = owner.snapshot(for: "pins")
            XCTAssertEqual(snapshot.rows.count, 50, "\(name): the bad page adds nothing")
            guard case .finished(let reason) = snapshot.more else { XCTFail("\(name): \(snapshot.more)"); continue }
            XCTAssertTrue(reason.contains("cursor") || reason.contains("No new rows"), "\(name): \(reason)")
            XCTAssertNil(owner.loadMore("pins"), "\(name): no request loop")
            XCTAssertEqual(cursors, [nil, stamp(49)], name)
        }
    }

    func testMalformedFirstPageCursorStopsWithoutRequestingMore() async {
        let owner = OtherListState<String, Message, String>()
        await pins(owner) { _ in PinPage(items: [PinPage.Item(message: self.message(1), pinnedAt: nil)], hasMore: true) }.value
        guard case .finished(let reason) = owner.snapshot(for: "pins").more else { return XCTFail("must stop") }
        XCTAssertTrue(reason.contains("cursor"))
        XCTAssertNil(owner.loadMore("pins"))
    }

    func testRowsFromAnotherChannelAreNotShown() async {
        let owner = OtherListState<String, Message, String>()
        await pins(owner) { _ in
            PinPage(items: [self.item(0), PinPage.Item(message: self.message(5_000, channel: 99), pinnedAt: self.stamp(1))], hasMore: false)
        }.value
        XCTAssertEqual(owner.snapshot(for: "pins").rows.map(\.id), [1_000])
    }

    func testStaleSecondPageIsIgnoredAfterPinsRevisionChange() async throws {
        let model = AppModel(), store = DiscordStore(), api = MockDiscord()
        model.selectedGuild = 10; model.selectedChannel = channel
        let presentation = UUID()
        func identity() -> PinsListIdentity {
            let list = OtherListIdentity(context: LookupContext(model: model, store: store), route: .pins, parent: nil,
                                         api: ObjectIdentifier(api), presentation: presentation, sidebar: false,
                                         navigation: model.navigationIntent)
            return PinsListIdentity(list: list, pins: PinsSubmission(context: LookupContext(model: model, store: store), channel: channel,
                                                                     revision: store.pinsRevision(for: channel)))
        }
        let owner = OtherListState<PinsListIdentity, Message, String>(), held = Held<PinPage>()
        let before = identity()
        await OtherListConsumers.pins(owner, input: before, api: api, channel: channel, store: store,
                                      isCurrent: { identity() == before }, fetch: { cursor in
            cursor == nil ? self.page(0..<50, more: true) : try await held.load()
        }).value
        let append = try XCTUnwrap(owner.loadMore(before))
        await held.started()
        // A Pin/Unpin (yours or anyone's) arrives as CHANNEL_PINS_UPDATE.
        store.handle(GatewayDispatch(name: "CHANNEL_PINS_UPDATE",
                                     data: Data(#"{"d":{"channel_id":"42","last_pin_timestamp":"2026-11-03T01:02:03.000000+00:00"}}"#.utf8)))
        let after = identity()
        XCTAssertNotEqual(after, before, "the pins revision is part of the list identity")
        held.finish(.success(PinPage(items: [PinPage.Item(message: message(9_999), pinnedAt: stamp(60))], hasMore: false)))
        await append.value
        XCTAssertTrue(owner.snapshot(for: after).rows.isEmpty, "the new revision starts from the newest pin")
        XCTAssertEqual(owner.snapshot(for: before).status, .idle, "the stale response wrote nothing")
        XCTAssertNil(store.users[19_999], "nor any author")
        XCTAssertNil(owner.loadMore(before))
        // The fresh list starts again without a cursor.
        var cursors: [String?] = []
        await OtherListConsumers.pins(owner, input: after, api: api, channel: channel, store: store,
                                      isCurrent: { identity() == after }, fetch: { cursor in
            cursors.append(cursor); return self.page(0..<3, more: false)
        }).value
        XCTAssertEqual(cursors, [nil])
        XCTAssertEqual(owner.snapshot(for: after).rows.count, 3)
    }

    func testStaleResponseIgnoredWhenAReloadOrChannelChangeReplacesIt() async {
        let owner = OtherListState<String, Message, String>(), store = DiscordStore(), old = Held<PinPage>()
        let first = pins(owner, input: "channel-a", store: store) { _ in try await old.load() }
        await old.started()
        await pins(owner, input: "channel-b", store: store) { _ in self.page(0..<2, more: false) }.value
        old.finish(.success(PinPage(items: [PinPage.Item(message: message(8_888), pinnedAt: stamp(0))], hasMore: false)))
        await first.value
        XCTAssertEqual(owner.snapshot(for: "channel-b").rows.map(\.id), [1_000, 1_001])
        XCTAssertTrue(owner.snapshot(for: "channel-a").rows.isEmpty)
        XCTAssertNil(store.users[18_888])
    }

    // MARK: Mock and older transports

    func testMockPagesItsPinsWithExactCursorsAndWrittenPinsFirst() async throws {
        let mock = MockDiscord(), chat = MockDiscord.generalChannel
        let generated = try await mock.pins(channel: chat)
        let first = try await mock.pinPage(channel: chat, before: nil, limit: 50)
        XCTAssertEqual(first.items.map(\.message.id), generated.map(\.id))
        XCTAssertFalse(first.hasMore)
        let small = try await mock.pinPage(channel: chat, before: nil, limit: 3)
        XCTAssertTrue(small.hasMore)
        let next = try await mock.pinPage(channel: chat, before: try XCTUnwrap(small.items.last?.pinnedAt), limit: 50)
        XCTAssertEqual(small.items.map(\.message.id) + next.items.map(\.message.id), generated.map(\.id))
        let target = try await mock.messages(channel: chat, before: nil, after: nil, around: nil, limit: 50)
            .last { !$0.isSystem && !generated.map(\.id).contains($0.id) }
        let written = try XCTUnwrap(target)
        try await mock.setPinned(channel: chat, message: written.id, pinned: true)
        let refreshed = try await mock.pinPage(channel: chat, before: nil, limit: 50)
        XCTAssertEqual(refreshed.items.first?.message.id, written.id, "a write is newest")
        XCTAssertEqual(refreshed.items.count, generated.count + 1)
    }

    func testMockManyPinsLaunchArgumentPagesBeyond50ThroughTheList() async throws {
        UserDefaults.standard.set(true, forKey: "DuocordMockManyPins")
        defer { UserDefaults.standard.removeObject(forKey: "DuocordMockManyPins") }
        let mock = MockDiscord(), chat = MockDiscord.generalChannel
        let all = try await mock.pins(channel: chat)
        XCTAssertGreaterThan(all.count, 100)
        let owner = OtherListState<String, Message, String>()
        await OtherListConsumers.pins(owner, input: "mock", api: mock, channel: chat, store: DiscordStore(), isCurrent: { true }).value
        XCTAssertEqual(owner.snapshot(for: "mock").rows.count, 50)
        while let more = owner.loadMore("mock") { await more.value }
        XCTAssertEqual(owner.snapshot(for: "mock").rows.map(\.id), all.map(\.id))
        XCTAssertEqual(owner.snapshot(for: "mock").more, ended)
    }

    func testOlderTransportsWithoutPagingReturnOneFinalPage() async throws {
        do { _ = try await OfflineAPI().pinPage(channel: channel, before: nil, limit: 50); XCTFail("signed out fails closed") }
        catch DiscordError.unauthorized {} catch { XCTFail("unexpected \(error)") }
        let api = OnePage(rows: [message(1), message(2)])
        let first = try await api.pinPage(channel: channel, before: nil, limit: 50)
        XCTAssertEqual(first.items.map(\.message.id), [1, 2]); XCTAssertFalse(first.hasMore)
        let later = try await api.pinPage(channel: channel, before: stamp(0), limit: 50)
        XCTAssertTrue(later.items.isEmpty); XCTAssertFalse(later.hasMore)
    }
}
