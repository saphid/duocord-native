import XCTest
@testable import DuocordNative

/// Inbox unread rows: location, per-visible-row previews with held loads,
/// fences, failure fallback, no acknowledgement and excerpt concealment.
@MainActor
final class InboxUnreadPreviewTests: XCTestCase {
    private final class Held {
        var started: [InboxPreviews.Key] = []
        private var waiting: [InboxPreviews.Key: CheckedContinuation<[Message], Error>] = [:]
        func load(_ key: InboxPreviews.Key) -> InboxPreviews.Load {
            { [self] in
                started.append(key)
                return try await withCheckedThrowingContinuation { waiting[key] = $0 }
            }
        }
        func finish(_ key: InboxPreviews.Key, _ result: Result<[Message], Error>) {
            waiting.removeValue(forKey: key)?.resume(with: result)
        }
        func finishAll() { for key in Array(waiting.keys) { finish(key, .success([])) } }
    }

    private let session = UUID()
    private let api = ObjectIdentifier(InboxUnreadPreviewTests.self)

    private func key(_ channel: UInt64, latest: UInt64 = 100, boundary: UInt64 = 10) -> InboxPreviews.Key {
        InboxPreviews.Key(channel: Snowflake(channel), latest: Snowflake(latest), boundary: Snowflake(boundary),
                          session: session, account: 1, api: api)
    }

    private func message(_ id: UInt64, channel: UInt64, author: User = User(id: 7, username: "pr-bot"),
                         content: String = "review requested ||private-branch||") -> Message {
        Message(id: Snowflake(id), channelID: Snowflake(channel), guildID: 100, author: author, content: content, timestamp: "")
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: Location

    func testThreadRowsNameTheirParentChannelAndServer() {
        let store = DiscordStore()
        var server = Guild(id: 100, name: "T3Code", channels: [Channel(id: 300, type: .text, guildID: 100, name: "prs")])
        server.threads = [Channel(id: 400, type: .publicThread, guildID: 100, name: "Fix sidebar threads", parentID: 300)]
        store.upsert(guild: server)
        XCTAssertEqual(InboxRowLocation.describe(store.channel(400)!, store: store).title, "Fix sidebar threads")
        XCTAssertEqual(InboxRowLocation.describe(store.channel(400)!, store: store).detail, "Thread in #prs · T3Code")
        XCTAssertEqual(InboxRowLocation.describe(store.channel(300)!, store: store).detail, "T3Code")
        let orphan = Channel(id: 401, type: .publicThread, guildID: 100, name: "orphan", parentID: 999)
        XCTAssertEqual(InboxRowLocation.describe(orphan, store: store).detail, "Parent channel unavailable · T3Code")
    }

    // MARK: Loading

    func testOnlyVisibleRowsLoadAFewAtATime() async {
        let previews = InboxPreviews(concurrency: 2), held = Held()
        let keys = (1...10).map { key($0) }
        for key in keys { previews.appear(key, cached: nil, load: held.load(key), isCurrent: { true }) }
        await settle()
        XCTAssertEqual(held.started, [keys[0], keys[1]])
        XCTAssertEqual(previews.inFlight, 2)

        // Scrolling away stops an in-flight load and frees its slot.
        previews.disappear(keys[0])
        XCTAssertNil(previews.entry(for: keys[0]))
        await settle()
        XCTAssertEqual(held.started, [keys[0], keys[1], keys[2]])

        // A queued row that leaves never requests.
        previews.disappear(keys[4])
        held.finish(keys[1], .success([message(50, channel: 2)]))
        await settle()
        XCTAssertEqual(previews.entry(for: keys[1]), .loaded(message(50, channel: 2)))
        XCTAssertEqual(held.started.last, keys[3])

        // The stopped load's late answer publishes nothing.
        held.finish(keys[0], .success([message(60, channel: 1)]))
        await settle()
        XCTAssertNil(previews.entry(for: keys[0]))

        // A finished preview survives scrolling.
        previews.disappear(keys[1])
        XCTAssertNotNil(previews.entry(for: keys[1]))
        for _ in 0..<10 { held.finishAll(); await settle() }
        XCTAssertFalse(held.started.contains(keys[4]))
        XCTAssertLessThanOrEqual(held.started.count, 9)
    }

    func testLoadedNewestMessageNeedsNoRequest() async {
        let previews = InboxPreviews(), held = Held(), key = key(3)
        previews.appear(key, cached: message(100, channel: 3), load: held.load(key), isCurrent: { true })
        await settle()
        XCTAssertTrue(held.started.isEmpty)
        XCTAssertEqual(previews.entry(for: key)?.message?.id, 100)
        // An older cached message cannot stand in for the newest unread one.
        let newer = self.key(3, latest: 120)
        previews.appear(newer, cached: message(100, channel: 3), load: held.load(newer), isCurrent: { true })
        await settle()
        XCTAssertEqual(held.started, [newer])
        XCTAssertNil(previews.entry(for: key), "the obsolete preview for this channel is dropped")
        held.finishAll()
    }

    func testStaleSupersededAndForeignResponsesAreDiscarded() async {
        let previews = InboxPreviews(concurrency: 4), held = Held()
        var current = true
        let fenced = key(1)
        previews.appear(fenced, cached: nil, load: held.load(fenced), isCurrent: { current })
        let filtered = key(2)
        previews.appear(filtered, cached: nil, load: held.load(filtered), isCurrent: { true })
        let superseded = key(3)
        previews.appear(superseded, cached: nil, load: held.load(superseded), isCurrent: { true })
        await settle()

        // The session, account, read boundary or newest message changed.
        current = false
        held.finish(fenced, .success([message(50, channel: 1)]))
        // Another channel, an already read message and one newer than the key.
        held.finish(filtered, .success([message(70, channel: 9), message(5, channel: 2), message(200, channel: 2)]))
        // A new message arrived before the old request answered.
        let replacement = key(3, latest: 150)
        previews.appear(replacement, cached: nil, load: held.load(replacement), isCurrent: { true })
        held.finish(superseded, .success([message(100, channel: 3)]))
        await settle()
        XCTAssertNil(previews.entry(for: fenced))
        XCTAssertEqual(previews.entry(for: filtered), .empty)
        XCTAssertNil(previews.entry(for: superseded))
        XCTAssertEqual(previews.entry(for: replacement), .loading)
        held.finish(replacement, .success([message(150, channel: 3)]))
        await settle()
        XCTAssertEqual(previews.entry(for: replacement)?.message?.id, 150)

        // Closing the Inbox fences everything in flight.
        let late = key(4)
        previews.appear(late, cached: nil, load: held.load(late), isCurrent: { true })
        await settle()
        previews.invalidate()
        held.finish(late, .success([message(90, channel: 4)]))
        await settle()
        XCTAssertNil(previews.entry(for: late))
        XCTAssertEqual(previews.inFlight, 0)
    }

    func testFailureExplainsAndRetryReloads() async {
        let previews = InboxPreviews(), held = Held(), key = key(5)
        previews.appear(key, cached: nil, load: held.load(key), isCurrent: { true })
        await settle()
        held.finish(key, .failure(DiscordError.http(403, "Missing Access")))
        await settle()
        XCTAssertEqual(previews.entry(for: key), .failed("You can't read this conversation's history."))
        previews.appear(key, cached: nil, load: held.load(key), isCurrent: { true })
        await settle()
        XCTAssertEqual(held.started.count, 1, "appearing again does not hammer a failed request")
        previews.retry(key, load: held.load(key), isCurrent: { true })
        await settle()
        XCTAssertEqual(previews.entry(for: key), .loading)
        held.finish(key, .success([message(80, channel: 5)]))
        await settle()
        XCTAssertEqual(previews.entry(for: key)?.message?.id, 80)
    }

    // MARK: Production transport and fences

    func testReconnectAndSeededTimelinesCannotSupplyStalePreviewText() async throws {
        for seeded in [false, true] {
            let mock = MockDiscord(), model = AppModel(readAPI: mock)
            let chat = MockDiscord.generalChannel
            let stale = Message(id: 100, channelID: chat, guildID: mock.guilds[0].id,
                                author: mock.users[0], content: "Before disconnect", timestamp: "")
            var edited = stale
            edited.content = "Edited while disconnected"
            var ready = mock.readyPayload()
            for i in ready.guilds.indices {
                for j in ready.guilds[i].channels.indices where ready.guilds[i].channels[j].id == chat {
                    ready.guilds[i].channels[j].lastMessageID = stale.id
                }
            }
            ready.readStates = [ReadState(id: chat, lastMessageID: 10, mentionCount: 1)]
            model.store.apply(ready: ready)
            let timeline = model.messages.timeline(for: chat)
            if seeded {
                timeline.seed([stale])
            } else {
                timeline.receive(stale)
                XCTAssertEqual(timeline.cachedPreviewMessage(stale.id)?.content, stale.content)
                model.store.apply(ready: ready)
                model.messages.markAllNeedRefresh()
            }
            mock.setReadHistory([edited], channel: chat)
            let apiID = ObjectIdentifier(model.api as AnyObject)
            let key = try XCTUnwrap(InboxPreviews.Key.current(chat, store: model.store, api: apiID))
            let previews = InboxPreviews()
            previews.appear(key, cached: timeline.cachedPreviewMessage(key.latest),
                            load: { try await InboxPreviews.latestMessage(api: mock, channel: chat) },
                            isCurrent: { InboxPreviews.Key.current(chat, store: model.store, api: apiID) == key })
            for _ in 0..<200 where previews.entry(for: key) == .loading { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(previews.entry(for: key)?.message?.content, edited.content, "seeded: \(seeded)")
            XCTAssertEqual(timeline.messages.last?.content, stale.content, "the unselected timeline remains stale")
            XCTAssertTrue(mock.readOperations.isEmpty, "preview refresh never acknowledges")
        }
    }

    func testProductionPreviewReadsHistoryWithoutAcknowledging() async throws {
        let mock = MockDiscord(), model = AppModel(readAPI: mock)
        let chat = MockDiscord.generalChannel
        let page = try await mock.messages(channel: chat, before: nil, after: nil, around: nil, limit: 1)
        let newest = try XCTUnwrap(page.first)
        var ready = mock.readyPayload()
        for index in ready.guilds.indices {
            for c in ready.guilds[index].channels.indices where ready.guilds[index].channels[c].id == chat {
                ready.guilds[index].channels[c].lastMessageID = newest.id
            }
        }
        ready.readStates = [ReadState(id: chat, lastMessageID: 1, mentionCount: 2)]
        mock.setReadStates(ready.readStates)
        model.store.apply(ready: ready)
        let before = model.store.readStates, selected = model.selectedChannel
        let apiID = ObjectIdentifier(model.api as AnyObject)
        let key = try XCTUnwrap(InboxPreviews.Key.current(chat, store: model.store, api: apiID))
        XCTAssertTrue(InboxLists.unreadChannels(store: model.store).contains { $0.id == chat })

        let previews = InboxPreviews(), api = model.api, store = model.store
        previews.appear(key, cached: nil, load: { try await InboxPreviews.latestMessage(api: api, channel: chat) },
                        isCurrent: { InboxPreviews.Key.current(chat, store: store, api: apiID) == key })
        for _ in 0..<200 where previews.entry(for: key) == .loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(previews.entry(for: key)?.message?.id, newest.id)
        XCTAssertTrue(mock.readOperations.isEmpty, "a preview must never acknowledge")
        XCTAssertEqual(model.store.readStates, before)
        XCTAssertEqual(model.selectedChannel, selected)

        // A new message, a read, or a new session each change the fence.
        let other = User(id: 6, username: "other")
        struct Envelope: Encodable { var d: Message }
        let next = Message(id: Snowflake(newest.id.raw + 1), channelID: chat, guildID: newest.guildID, author: other, content: "next", timestamp: "")
        model.store.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: next))))
        let moved = try XCTUnwrap(InboxPreviews.Key.current(chat, store: model.store, api: apiID))
        XCTAssertNotEqual(moved, key)
        model.store.apply(ready: ready)
        XCTAssertNotEqual(InboxPreviews.Key.current(chat, store: model.store, api: apiID)?.session, key.session)
        model.store.markRead(chat, upTo: next.id)
        XCTAssertNil(InboxPreviews.Key.current(chat, store: model.store, api: apiID), "a read row has no unread preview")
    }

    func testMentionOnlyRowsHaveNoPreviewRequest() {
        let store = DiscordStore()
        store.upsert(guild: Guild(id: 100, name: "T3Code", channels: [Channel(id: 300, type: .text, guildID: 100, name: "prs", lastMessageID: 50)]))
        store.markRead(300, upTo: 50)
        XCTAssertNil(InboxPreviews.Key.current(300, store: store, api: api))
    }

    // MARK: Privacy

    func testUnresolvedThreadActivityResolvesParentBeforeOpeningHistory() async throws {
        let mock = MockDiscord(), model = AppModel(readAPI: mock)
        var ready = mock.readyPayload()
        let parentID = MockDiscord.generalChannel
        let guild = ready.guilds[0].id
        let id: Snowflake = 700
        var row = Channel(id: id, type: .publicThread, guildID: guild, name: "Missing parent PR", parentID: parentID, lastMessageID: 900)
        row.member = ThreadMemberRef()
        ready.guilds[0].channels.removeAll { $0.id == parentID }
        ready.guilds[0].threads = [row]
        ready.readStates = [ReadState(id: id, lastMessageID: 800, mentionCount: 7)]
        model.store.apply(ready: ready)
        let apiID = ObjectIdentifier(model.api as AnyObject)
        XCTAssertTrue(model.store.isUnresolvedThread(row))
        XCTAssertEqual(model.store.badge(for: guild).mentions, 7)
        XCTAssertTrue(model.store.channelList(for: guild).flatMap(\.entries).contains { $0.id == id })
        XCTAssertNil(InboxPreviews.Key.current(id, store: model.store, api: apiID), "unknown parent permissions cannot authorize a history preview")
        model.sheet = .inbox
        model.open(channel: id, message: 900)
        XCTAssertNil(model.selectedChannel, "selection waits for parent resolution")
        for _ in 0..<100 where model.selectedChannel != id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedChannel, id)
        XCTAssertNotNil(model.store.channel(parentID))
        XCTAssertEqual(model.revealRequest?.message, 900)
        XCTAssertNotNil(InboxPreviews.Key.current(id, store: model.store, api: apiID))
        XCTAssertFalse(model.store.channelList(for: guild).flatMap(\.entries).contains { $0.id == id }, "resolved thread moves under its parent without a duplicate")
        XCTAssertEqual(model.store.badge(for: guild).mentions, 7)
    }

    func testJoinedBoundaryAgreesAcrossInboxSelectionJumpAndLiveArrival() async throws {
        let mock = MockDiscord(), model = AppModel(readAPI: mock)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func sf(_ offset: Double) -> Snowflake { Snowflake.at(base.addingTimeInterval(offset)) }
        let id = sf(100), boundary = sf(200), latest = sf(300)
        var row = Channel(id: id, type: .publicThread, guildID: mock.guilds[0].id, name: "joined PR", parentID: MockDiscord.generalChannel, lastMessageID: latest)
        row.member = ThreadMemberRef(joinTimestamp: ISO8601DateFormatter().string(from: base.addingTimeInterval(200)))
        var ready = mock.readyPayload()
        ready.guilds[0].threads = [row]
        ready.readStates.removeAll { $0.id == id }
        model.store.apply(ready: ready)
        let prior = Message(id: sf(150), channelID: id, guildID: row.guildID, author: mock.users[0], content: "before joining", timestamp: "")
        let unread = Message(id: latest, channelID: id, guildID: row.guildID, author: mock.users[0], content: "after joining", timestamp: "")
        mock.setReadHistory([prior, unread], channel: id)
        let apiID = ObjectIdentifier(model.api as AnyObject)
        let key = try XCTUnwrap(InboxPreviews.Key.current(id, store: model.store, api: apiID))
        XCTAssertEqual(key.boundary, boundary)
        XCTAssertFalse(InboxPreviews.accepts(prior, for: key))
        model.select(channel: id)
        XCTAssertEqual(model.unreadBoundary(for: id), boundary)
        await model.jumpToUnread(id).value
        XCTAssertEqual(model.revealRequest?.message, latest)
        struct Envelope: Encodable { var d: Message }
        let incoming = Message(id: sf(400), channelID: id, guildID: row.guildID, author: mock.users[0], content: "new mention", timestamp: "", mentions: [mock.me])
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: incoming))))
        XCTAssertEqual(model.store.readStates[id]?.lastMessageID, boundary)
        XCTAssertEqual(model.unreadBoundary(for: id), boundary)
    }

    func testMessageEditsAndDeletesRetireLoadedAndHeldPreviews() async throws {
        for (event, payload) in [("MESSAGE_UPDATE", #"{"id":"100","channel_id":"910000000000000102","content":"edited"}"#),
                                 ("MESSAGE_DELETE", #"{"id":"100","channel_id":"910000000000000102"}"#),
                                 ("MESSAGE_DELETE_BULK", #"{"ids":["100"],"channel_id":"910000000000000102"}"#)] {
            let mock = MockDiscord(), model = AppModel(readAPI: mock)
            var ready = mock.readyPayload()
            let chat = MockDiscord.generalChannel
            for i in ready.guilds.indices {
                for j in ready.guilds[i].channels.indices where ready.guilds[i].channels[j].id == chat { ready.guilds[i].channels[j].lastMessageID = 100 }
            }
            ready.readStates = [ReadState(id: chat, lastMessageID: 10, mentionCount: 1)]
            model.store.apply(ready: ready)
            let apiID = ObjectIdentifier(model.api as AnyObject)
            let old = try XCTUnwrap(InboxPreviews.Key.current(chat, store: model.store, api: apiID))
            let stale = Message(id: 100, channelID: chat, guildID: ready.guilds[0].id, author: mock.users[0], content: "obsolete body", timestamp: "")
            let loaded = InboxPreviews(), pending = InboxPreviews(), held = Held()
            loaded.appear(old, cached: stale, load: held.load(old), isCurrent: { true })
            pending.appear(old, cached: nil, load: held.load(old), isCurrent: {
                InboxPreviews.Key.current(chat, store: model.store, api: apiID) == old
            })
            await settle()
            await model.handle(GatewayDispatch(name: event, data: Data(("{\"d\":" + payload + "}").utf8)))
            let current = try XCTUnwrap(InboxPreviews.Key.current(chat, store: model.store, api: apiID))
            XCTAssertNotEqual(current, old, event)
            XCTAssertNil(loaded.entry(for: current), "edited/deleted content must disappear synchronously")
            held.finish(old, .success([stale]))
            await settle()
            XCTAssertNil(pending.entry(for: old), "a pre-event response cannot restore stale text")
        }
    }

    func testBlockedAndSpoilerPreviewsStayConcealed() {
        let store = DiscordStore()
        let blocked = User(id: 8, username: "blocked")
        store.applyRelationship(Relationship(id: blocked.id, type: 2, user: blocked))
        let hidden = message(90, channel: 1, author: blocked, content: "leak")
        let concealed = MessageExcerptPresentation(message: hidden, store: store, reveal: nil)
        XCTAssertTrue(concealed.concealed)
        XCTAssertNil(concealed.avatarUser)
        XCTAssertFalse(concealed.text.contains("leak"))
        let revealed = MessageExcerptPresentation(message: hidden, store: store, reveal: concealed.scope)
        XCTAssertFalse(revealed.concealed)
        // A relationship change retires the old reveal.
        store.applyRelationship(Relationship(id: blocked.id, type: 2, user: blocked))
        XCTAssertTrue(MessageExcerptPresentation(message: hidden, store: store, reveal: concealed.scope).concealed)
        let spoiler = MessageExcerptPresentation(message: message(91, channel: 1), store: store, reveal: nil)
        XCTAssertFalse(spoiler.concealed)
        XCTAssertFalse(spoiler.text.contains("private-branch"))
    }
}
