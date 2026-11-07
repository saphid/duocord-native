import XCTest
@testable import DuocordNative

/// Catch-all transport: an exhausted script fails closed instead of reaching a service.
nonisolated private final class RepairWire: URLProtocol, @unchecked Sendable {
    struct Stub {
        var body: String
        var status = 200
        var held = false
        var error: URLError?
    }
    struct Record {
        var request: URLRequest
        var body: Data
    }
    static let lock = NSLock()
    static var script: [Stub] = []
    static var records: [Record] = []
    static var held: [(RepairWire, Stub)] = []

    static func reset(_ responses: [Stub]) {
        lock.withLock { script = responses; records = []; held = [] }
    }
    static func captured() -> [Record] { lock.withLock { records } }
    static func release() {
        let pending = lock.withLock { let value = held; held = []; return value }
        for (wire, stub) in pending { wire.deliver(stub) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let stub: Stub? = Self.lock.withLock {
            Self.records.append(Record(request: request, body: data))
            let next = Self.script.isEmpty ? Stub(body: "Unexpected offline request", status: 599) : Self.script.removeFirst()
            if next.held { Self.held.append((self, next)); return nil }
            return next
        }
        if let stub { deliver(stub) }
    }
    func deliver(_ stub: Stub) {
        if let error = stub.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0.0 === self } }
    }
}

@MainActor
final class FeatureTransportRegressionTests: XCTestCase {
    func testServerDefaultSkipsUnresolvedThreadRows() async throws {
        let mock = MockDiscord(), rest = api([]), model = AppModel(notificationAPI: rest)
        var ready = mock.readyPayload()
        let guild = ready.guilds[0].id
        ready.guilds[0].threads.append(Channel(id: 700, type: .publicThread, guildID: guild, name: "Orphan PR", parentID: 999999, lastMessageID: 900))
        model.store.apply(ready: ready)
        model.fold.isCompact = false
        let expected = try XCTUnwrap(model.store.sections(for: guild).flatMap(\.channels).first {
            !$0.type.isThread && (($0.type.isTextLike && !$0.type.isVoice) || $0.type.isForumLike)
        })
        model.select(guild: guild)
        XCTAssertEqual(model.selectedChannel, expected.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(RepairWire.captured().isEmpty, "selecting a server must not request an orphan's parent")
    }

    func testUnresolvedParentLookupRejectsDeniedHistoryAndStaleNavigation() async throws {
        for stale in [false, true] {
            let mock = MockDiscord(), parentID = MockDiscord.generalChannel
            var ready = mock.readyPayload()
            let guild = ready.guilds[0].id
            var parent = try XCTUnwrap(ready.guilds[0].channels.first { $0.id == parentID })
            if !stale {
                parent.permissionOverwrites = [PermissionOverwrite(id: guild, type: 0, allow: "0", deny: String(Permission.viewChannel))]
            }
            let body = String(decoding: try JSONEncoder().encode(parent), as: UTF8.self)
            let rest = api([.init(body: body, held: true)])
            let model = AppModel(notificationAPI: rest)
            let thread = Channel(id: 700, type: .publicThread, guildID: guild, name: "Unresolved PR", parentID: parentID, lastMessageID: 900)
            ready.guilds[0].channels.removeAll { $0.id == parentID }
            ready.guilds[0].threads = [thread]
            ready.readStates = [ReadState(id: thread.id, lastMessageID: 800, mentionCount: 7)]
            model.store.apply(ready: ready)
            let task = model.resolveParentAndSelect(thread, intent: model.navigationIntent)
            try await waitForRequests(1)
            if stale { model.select(channel: nil) }
            RepairWire.release()
            await task.value
            XCTAssertNil(model.selectedChannel)
            XCTAssertNil(InboxPreviews.Key.current(thread.id, store: model.store, api: ObjectIdentifier(rest)))
            let requests = RepairWire.captured()
            XCTAssertEqual(requests.count, 1, "no history request is authorized by unresolved parent metadata")
            XCTAssertEqual(requests.first?.request.httpMethod, "GET")
            XCTAssertEqual(requests.first?.request.url?.path, "/api/v9/channels/\(parentID)")
            if stale {
                XCTAssertNil(model.store.channel(parentID), "a navigation change fences parent publication too")
                XCTAssertEqual(model.store.badge(for: guild).mentions, 7)
            } else {
                XCTAssertFalse(model.store.canView(thread))
                XCTAssertEqual(model.store.badge(for: guild).mentions, 0, "confirmed denial retires the unresolved activity")
                XCTAssertFalse(InboxLists.unreadChannels(store: model.store).contains { $0.id == thread.id })
            }
        }
    }

    private func message(_ id: UInt64, nonce: String? = nil) -> Message {
        var value = Message(id: Snowflake(id), channelID: 1, guildID: nil,
                            author: User(id: 5, username: "offline"), content: "fixture \(id)", timestamp: "")
        value.nonce = nonce
        return value
    }
    private func page(_ ids: [UInt64]) throws -> String {
        String(decoding: try JSONEncoder().encode(ids.map { message($0) }), as: UTF8.self)
    }
    private func api(_ script: [RepairWire.Stub]) -> DiscordREST {
        RepairWire.reset(script)
        // Baseline production PUT uses URLSession.shared; intercept it too.
        _ = URLProtocol.registerClass(RepairWire.self)
        return client()
    }
    // Independent transports let history responses finish in controlled order; the
    // production REST rate bucket otherwise serializes a channel's GET requests.
    private func client() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil,
                                                            userAgent: "RepairRegression"), protocolClasses: [RepairWire.self])
    }
    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<300 {
            if RepairWire.captured().count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("offline request did not start: expected \(count), got \(RepairWire.captured().count)")
        throw URLError(.timedOut)
    }
    override func tearDown() {
        RepairWire.release()
        URLProtocol.unregisterClass(RepairWire.self)
        super.tearDown()
    }

    func testUnloadedAroundRetainsPendingFailureRetryAndDiscardIdentity() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let pending = message(900, nonce: "pending"), failed = message(901, nonce: "failed")
        t.seed([message(500)])
        t.addPending(pending); t.addPending(failed); t.markFailed(nonce: "failed", error: "offline")
        await t.load(around: 100, api: api([.init(body: try page([100, 200]))]), store: store)
        XCTAssertEqual(t.messages.map(\.id), [100, 200, 900, 901])
        XCTAssertEqual(t.sendState(for: failed), .failed("offline"))
        t.markFailed(nonce: "pending", error: "timeout after jump")
        XCTAssertEqual(t.sendState(for: pending), .failed("timeout after jump"))
        // Retrying needs a visible failed row to discard before adding a fresh send.
        t.discardPending(nonce: "failed"); t.addPending(failed)
        XCTAssertEqual(t.sendState(for: failed), .sending)
        t.discardPending(nonce: "failed"); t.discardPending(nonce: "pending")
        XCTAssertTrue(t.sendStates.isEmpty)
        XCTAssertEqual(t.messages.map(\.id), [100, 200])
    }

    func testOlderTrimPreservesOutgoingTailAndPagesFromConfirmedBoundary() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        t.seed((100...699).map { message(UInt64($0)) })
        let a = message(1000, nonce: "sending"), b = message(1001, nonce: "failed")
        t.addPending(a); t.addPending(b); t.markFailed(nonce: "failed", error: "offline")
        let transport = api([.init(body: try page(Array(50...99))), .init(body: try page(Array(650...699)))])
        await t.loadOlder(api: transport, store: store)
        XCTAssertEqual(Array(t.messages.suffix(2)).map(\.nonce), ["sending", "failed"])
        XCTAssertEqual(t.messages.filter { t.sendState(for: $0) == nil }.count, 600)
        XCTAssertEqual(t.sendState(for: b), .failed("offline"))
        await t.loadNewer(api: transport, store: store)
        let query = URLComponents(url: try XCTUnwrap(RepairWire.captured().last?.request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "after" }?.value, "649")
        XCTAssertEqual(Array(t.messages.suffix(2)).map(\.nonce), ["sending", "failed"])
        XCTAssertTrue(t.messages.contains { $0.id == 699 })
        t.discardPending(nonce: "sending"); t.discardPending(nonce: "failed")
        XCTAssertTrue(t.sendStates.isEmpty)
    }

    func testAroundNonceConfirmationDoesNotDuplicateEcho() async throws {
        let t = MessageTimeline(channelID: 1)
        t.addPending(message(900, nonce: "accepted"))
        let confirmed = message(150, nonce: "accepted")
        let body = String(decoding: try JSONEncoder().encode([message(100), confirmed]), as: UTF8.self)
        await t.load(around: 100, api: api([.init(body: body)]), store: DiscordStore())
        XCTAssertEqual(t.messages.map(\.id), [100, 150]); XCTAssertTrue(t.sendStates.isEmpty)
    }

    func testConfirmationOutsideHistoryClearsRetainedEcho() async throws {
        let t = MessageTimeline(channelID: 1)
        let echo = message(900, nonce: "accepted")
        t.addPending(echo)
        await t.load(around: 125, api: api([.init(body: try page(Array(100...149)))]), store: DiscordStore())
        t.confirm(nonce: "accepted", with: message(901, nonce: "accepted"))
        XCTAssertTrue(t.sendStates.isEmpty)
        XCTAssertFalse(t.messages.contains { $0.nonce == "accepted" })
        XCTAssertTrue(t.hasMoreAfter)
    }

    private func race(firstLatest: Bool, secondLatest: Bool, oldStatus: Int = 200, newStatus: Int = 200) async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page([100, 200]), status: oldStatus, held: true),
                             .init(body: try page([900, 1000]), status: newStatus)])
        let old = Task {
            if firstLatest { await t.loadLatest(api: transport, store: store) }
            else { await t.load(around: 100, api: transport, store: store) }
        }
        try await waitForRequests(1)
        if secondLatest { await t.loadLatest(api: client(), store: store) }
        else { await t.load(around: 900, api: client(), store: store) }
        let state = t.initialState, revision = t.revision
        RepairWire.release(); await old.value
        XCTAssertEqual(t.initialState, state, "obsolete completion changed latest intent's load state")
        XCTAssertEqual(t.revision, revision, "obsolete response published")
        if newStatus == 200 { XCTAssertEqual(t.messages.map(\.id), [900, 1000]); XCTAssertEqual(t.initialState, .idle) }
        else { XCTAssertTrue(t.messages.isEmpty); if case .failed = t.initialState {} else { XCTFail("latest failure was lost") } }
        XCTAssertFalse(t.loadingBefore); XCTAssertFalse(t.loadingAfter)
    }
    func testAroundThenAroundNewestWins() async throws { try await race(firstLatest: false, secondLatest: false) }
    func testLatestThenAroundNewestWins() async throws { try await race(firstLatest: true, secondLatest: false) }
    func testAroundThenLatestNewestWins() async throws { try await race(firstLatest: false, secondLatest: true) }
    func testLatestThenLatestNewestWins() async throws { try await race(firstLatest: true, secondLatest: true) }
    func testStaleAroundFailureCannotResetNewerLatest() async throws { try await race(firstLatest: false, secondLatest: true, oldStatus: 403) }
    func testStaleLatestFailureCannotResetNewerAround() async throws { try await race(firstLatest: true, secondLatest: false, oldStatus: 403) }
    func testStaleAroundSuccessCannotEraseNewerFailure() async throws { try await race(firstLatest: false, secondLatest: false, newStatus: 403) }

    func testCancelledIntentSettlesAndCannotPublish() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page([100, 200]), held: true), .init(body: try page([900, 1000]))])
        let old = Task { await t.load(around: 100, api: transport, store: store) }
        try await waitForRequests(1); old.cancel(); await old.value
        XCTAssertEqual(t.initialState, .idle)
        await t.loadLatest(api: transport, store: store)
        XCTAssertEqual(t.messages.map(\.id), [900, 1000])
    }

    func testLoadedTargetIntentSupersedesHeldJump() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        t.seed([message(900), message(1000)])
        let transport = api([.init(body: try page([100, 200]), held: true)])
        let old = Task { await t.load(around: 100, api: transport, store: store) }
        try await waitForRequests(1)
        await t.load(around: 900, api: transport, store: store)
        RepairWire.release(); await old.value
        XCTAssertEqual(t.messages.map(\.id), [900, 1000]); XCTAssertEqual(t.initialState, .idle)
    }

    private func list(_ timeline: MessageTimeline, store: DiscordStore, api: DiscordAPI) -> MessageListController {
        let list = MessageListController(timeline: timeline, store: store, api: api, guildID: nil,
                                         title: "Offline", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
        list.loadViewIfNeeded()
        list.view.frame = CGRect(x: 0, y: 0, width: 382, height: 588)
        list.viewDidLayoutSubviews()
        return list
    }

    func testControllerLoadedRevealSupersedesHeldUnloadedReveal() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        t.seed([message(900), message(1000)])
        let transport = api([.init(body: try page([100, 200]), held: true)])
        let controller = list(t, store: store, api: transport)
        controller.reveal(100)
        try await waitForRequests(1)
        controller.reveal(900)
        RepairWire.release()
        // In-process URLProtocol completion and controller-owned tasks settle;
        // this is a unit controller check with no window or device interaction.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(t.messages.map(\.id), [900, 1000])
        XCTAssertEqual(t.initialState, .idle)
        XCTAssertEqual(RepairWire.captured().count, 1)
    }

    func testControllerLoadedRevealSupersedesNotYetStartedUnloadedTask() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        t.seed([message(900), message(1000)])
        let transport = api([.init(body: try page([100, 200]))])
        let controller = list(t, store: store, api: transport)
        // No actor yield between actions: the old task has not started yet.
        controller.reveal(100)
        controller.reveal(900)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(t.messages.map(\.id), [900, 1000])
        XCTAssertTrue(RepairWire.captured().isEmpty)
        XCTAssertEqual(t.initialState, .idle)
    }

    func testControllerQueuedJumpToPresentCannotResetNewerLoadedReveal() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page(Array(100...149)))])
        await t.load(around: 125, api: transport, store: store)
        XCTAssertTrue(t.hasMoreAfter)
        let expected = t.messages.map(\.id)
        let controller = list(t, store: store, api: transport)
        // The first navigation task is canceled before its body can run.
        controller.jumpToPresent()
        controller.reveal(130)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(t.messages.map(\.id), expected)
        XCTAssertNotNil(t.index(of: 130))
        XCTAssertEqual(t.initialState, .idle)
        let latestRequests = RepairWire.captured().filter { record in
            let query = URLComponents(url: record.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return !query.contains { ["around", "before", "after"].contains($0.name) }
        }
        XCTAssertTrue(latestRequests.isEmpty, "obsolete jump must not request latest; ordinary history paging remains allowed")
    }

    func testOutgoingTailKeepsEveryVisibleMessageAddressable() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        t.addPending(message(900, nonce: "sending"))
        t.addPending(message(901, nonce: "failed"))
        t.markFailed(nonce: "failed", error: "offline")
        let transport = api([.init(body: try page([1000, 2000, 3000, 4000]))])
        await t.load(around: 3000, api: transport, store: store)
        XCTAssertEqual(t.messages.map(\.id), [1000, 2000, 3000, 4000, 900, 901])
        for (index, message) in t.messages.enumerated() { XCTAssertEqual(t.index(of: message.id), index) }
        XCTAssertNil(t.index(of: 9999))
        t.update(MessageUpdate(id: 4000, channelID: 1, content: "gateway changed"))
        XCTAssertEqual(t.messages[3].content, "gateway changed")
        let emoji = Emoji(id: nil, name: "👍", animated: nil)
        XCTAssertTrue(t.setMyReaction(emoji, on: 4000, add: true))
        XCTAssertEqual(t.messages[3].reactions.first?.count, 1)
        t.clearReactions(message: 4000, emoji: nil)
        XCTAssertTrue(t.messages[3].reactions.isEmpty)
        // Pending and failed echoes remain independently addressable, too.
        XCTAssertEqual(t.index(of: 900), 4)
        XCTAssertEqual(t.index(of: 901), 5)
    }

    func testPagingFromOldWindowCannotPublishAfterNavigationWithSameBoundary() async throws {
        for newer in [false, true] {
            let t = MessageTimeline(channelID: 1), store = DiscordStore()
            let transport = api([.init(body: try page(Array(100...149))),
                                 .init(body: try page(newer ? Array(150...199) : Array(50...99)), held: true),
                                 .init(body: try page(newer ? [100, 125, 149] : [100, 125, 175]))])
            await t.load(around: 125, api: transport, store: store)
            let old = Task { if newer { await t.loadNewer(api: transport, store: store) } else { await t.loadOlder(api: transport, store: store) } }
            try await waitForRequests(2)
            await t.load(around: 175, api: client(), store: store)
            let ids = t.messages.map(\.id), revision = t.revision
            RepairWire.release(); await old.value
            XCTAssertEqual(t.messages.map(\.id), ids); XCTAssertEqual(t.revision, revision)
        }
    }

    func testCachedLatestIntentSupersedesHeldOlderPage() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page(Array(100...149))), .init(body: try page(Array(50...99)), held: true)])
        await t.loadLatest(api: transport, store: store)
        let old = Task { await t.loadOlder(api: transport, store: store) }
        try await waitForRequests(2)
        await t.loadLatest(api: client(), store: store)
        let revision = t.revision
        RepairWire.release(); await old.value
        XCTAssertEqual(t.messages.map(\.id), Array(100...149).map { Snowflake(UInt64($0)) })
        XCTAssertEqual(t.revision, revision); XCTAssertFalse(t.loadingBefore)
        XCTAssertEqual(RepairWire.captured().count, 2, "cached latest should not refetch")
    }

    func testConcurrentOlderNewerPagingRetainsContinuityAndOutgoingTail() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page(Array(100...149))),
                             .init(body: try page(Array(50...99)), held: true), .init(body: try page(Array(150...199)))])
        await t.load(around: 125, api: transport, store: store)
        let pending = message(999, nonce: "retained")
        t.addPending(pending); t.markFailed(nonce: "retained", error: "offline")
        let older = Task { await t.loadOlder(api: transport, store: store) }
        try await waitForRequests(2)
        await t.loadNewer(api: client(), store: store)
        RepairWire.release(); await older.value
        XCTAssertEqual(t.messages.map(\.id), Array(50...199).map { Snowflake(UInt64($0)) } + [999])
        XCTAssertEqual(t.sendState(for: pending), .failed("offline"))
        XCTAssertFalse(t.loadingBefore); XCTAssertFalse(t.loadingAfter)
    }

    func testTombstoneSurvivesUntilAllOverlappingReadsFinish() async throws {
        let t = MessageTimeline(channelID: 1), store = DiscordStore()
        let transport = api([.init(body: try page([100, 200]), held: true), .init(body: try page([900, 1000]))])
        let old = Task { await t.load(around: 100, api: transport, store: store) }
        try await waitForRequests(1); t.remove([900])
        await t.load(around: 1000, api: client(), store: store)
        t.receive(message(900))
        XCTAssertEqual(t.messages.map(\.id), [1000])
        RepairWire.release(); await old.value
        XCTAssertEqual(t.messages.map(\.id), [1000])
    }

    private func slots(_ values: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["attachments": values]), as: UTF8.self)
    }
    private func slot(_ id: Any, url: String = "https://upload.invalid/slot0") -> [String: Any] {
        ["id": id, "upload_url": url, "upload_filename": "reserved-\(id)"]
    }
    private var files: [OutgoingAttachment] {
        [.init(filename: "a.txt", data: Data("alpha".utf8), contentType: "text/plain"),
         .init(filename: "b.png", data: Data([1, 2, 3]), contentType: "image/png")]
    }
    func testInvalidReservationsFailBeforeAnyPutOrMessagePost() async throws {
        var missing = slot(1); missing.removeValue(forKey: "id")
        let cases: [[[String: Any]]] = [[], [slot(0)], [slot(0), slot(0)], [slot(0), missing],
            [slot(0), slot(2)], [slot(-1), slot(1)], [slot(0), slot(1), slot(2)],
            [slot(0), slot("not-an-id")], [slot(0), slot(1, url: "relative/path")],
            [slot(0), slot(1, url: "file:///tmp/upload")], [slot(0), slot(1, url: "https://")],
            [slot(0), slot(1, url: "https://upload.invalid/bad path")],
            [slot(0), slot(1, url: "http://upload.invalid/plaintext")]]
        for (index, value) in cases.enumerated() {
            let transport = api([.init(body: try slots(value)), .init(body: ""), .init(body: "{}")])
            do {
                _ = try await transport.send(channel: 1, content: "with files", replyTo: nil, pingReply: false, attachments: files, nonce: "invalid")
                XCTFail("invalid reservation \(index) succeeded")
            } catch {}
            XCTAssertEqual(RepairWire.captured().count, 1, "reservation \(index) performed a PUT/message POST before complete validation")
        }
    }

    func testReorderedNumericSlotsUploadMatchingBytesAndPreserveReplyNonce() async throws {
        try await successfulUpload(ids: [1, 0])
    }
    func testStringSlotIDsAreAcceptedAndMatched() async throws { try await successfulUpload(ids: ["1", "0"]) }
    private func successfulUpload(ids: [Any]) async throws {
        let response = message(2000, nonce: "stable-nonce")
        let transport = api([.init(body: try slots([slot(ids[0], url: "https://upload.invalid/one"), slot(ids[1], url: "https://upload.invalid/zero")])),
                             .init(body: ""), .init(body: ""), .init(body: String(decoding: try JSONEncoder().encode(response), as: UTF8.self))])
        let sent = try await transport.send(channel: 1, content: "with files", replyTo: 42, pingReply: false, attachments: files, nonce: "stable-nonce")
        XCTAssertEqual(sent.id, 2000); XCTAssertEqual(sent.nonce, "stable-nonce")
        let requests = RepairWire.captured()
        XCTAssertEqual(requests.map { $0.request.httpMethod! }, ["POST", "PUT", "PUT", "POST"])
        let puts = requests.filter { $0.request.httpMethod == "PUT" }
        XCTAssertEqual(puts.first { $0.request.url?.path == "/one" }?.body, files[1].data)
        XCTAssertEqual(puts.first { $0.request.url?.path == "/zero" }?.body, files[0].data)
        XCTAssertEqual(puts.first { $0.request.url?.path == "/one" }?.request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        for put in puts { XCTAssertNil(put.request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(put.request.value(forHTTPHeaderField: "X-Super-Properties")) }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests.last!.body) as? [String: Any])
        XCTAssertEqual(body["nonce"] as? String, "stable-nonce")
        XCTAssertEqual((body["message_reference"] as? [String: Any])?["message_id"] as? String, "42")
        XCTAssertEqual((body["allowed_mentions"] as? [String: Any])?["replied_user"] as? Bool, false)
        let posted = try XCTUnwrap(body["attachments"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 2)
        for (index, file) in files.enumerated() {
            let attachment = try XCTUnwrap(posted.first { $0["id"] as? String == String(index) })
            XCTAssertEqual(attachment["filename"] as? String, file.filename)
            XCTAssertEqual(attachment["uploaded_filename"] as? String, "reserved-\(index)")
        }
    }

    func testFailedPutNeverPostsMessage() async throws {
        let transport = api([.init(body: try slots([slot(0), slot(1)])), .init(body: "refused", status: 500)])
        do {
            _ = try await transport.send(channel: 1, content: "files", replyTo: nil, pingReply: false, attachments: files, nonce: "failed-put")
            XCTFail("failed PUT succeeded")
        } catch {}
        XCTAssertEqual(RepairWire.captured().map { $0.request.httpMethod! }, ["POST", "PUT"])
    }
    func testTextOnlySendDoesNotReserveUploads() async throws {
        let transport = api([.init(body: String(decoding: try JSONEncoder().encode(message(2000)), as: UTF8.self))])
        _ = try await transport.send(channel: 1, content: "text", replyTo: nil, pingReply: false, attachments: [], nonce: "text")
        XCTAssertEqual(RepairWire.captured().count, 1)
        XCTAssertTrue(RepairWire.captured()[0].request.url!.path.hasSuffix("/messages"))
    }

    func testGuildUpdateDistinguishesOmittedNullAndReplacementIcon() throws {
        let mock = MockDiscord(), store = DiscordStore()
        var ready = mock.readyPayload(); ready.guilds[0].icon = "original"
        store.apply(ready: ready)
        let id = ready.guilds[0].id
        func update(_ fields: [String: Any]) throws {
            var payload = fields; payload["id"] = id.description
            store.handle(GatewayDispatch(name: "GUILD_UPDATE", data: try JSONSerialization.data(withJSONObject: ["d": payload])))
        }
        let roles = store.guilds[id]?.roles, level = store.guilds[id]?.defaultMessageNotifications
        try update(["name": "renamed"])
        XCTAssertEqual(store.guilds[id]?.icon, "original"); XCTAssertEqual(store.guilds[id]?.name, "renamed")
        XCTAssertEqual(store.guilds[id]?.roles, roles); XCTAssertEqual(store.guilds[id]?.defaultMessageNotifications, level)
        try update(["icon": NSNull()]); XCTAssertNil(store.guilds[id]?.icon); XCTAssertEqual(store.guilds[id]?.name, "renamed")
        try update(["icon": "replacement"]); XCTAssertEqual(store.guilds[id]?.icon, "replacement")
        try update([:]); XCTAssertEqual(store.guilds[id]?.icon, "replacement")
    }
}

import UIKit
import Observation

/// Releases held mock pin writes, either way, and counts arrivals.
nonisolated private final class PinGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var outcome: Result<Void, Error>?
    private var count = 0
    var arrivals: Int { lock.withLock { count } }
    func pass() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready: Result<Void, Error>? = lock.withLock {
                count += 1
                if outcome == nil { waiters.append(continuation) }
                return outcome
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
    func open(failing error: Error? = nil) {
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        let pending = lock.withLock { outcome = result; let value = waiters; waiters = []; return value }
        pending.forEach { $0.resume(with: result) }
    }
}

nonisolated private final class PinFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var fired: Bool { lock.withLock { value } }
}

nonisolated private final class PinEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GatewayDispatch] = []
    func append(_ event: GatewayDispatch) { lock.withLock { events.append(event) } }
    var all: [GatewayDispatch] { lock.withLock { events } }
}

/// Second MessageListHost conformer: records what reaches the host.
@MainActor
private final class PinRecordingHost: MessageListHost {
    var pins: [(Bool, Snowflake)] = []
    func list(openMedia item: MediaItem, from view: UIView) {}
    func list(openURL url: URL) {}
    func list(openUser user: Snowflake) {}
    func list(openChannel channel: Snowflake) {}
    func list(toggleReaction emoji: Emoji, on message: Snowflake) {}
    func list(showReactions emoji: Emoji, on message: Snowflake) {}
    func list(addReactionTo message: Snowflake) {}
    func list(reply message: Message) {}
    func list(retry message: Message) {}
    func list(discard message: Message) {}
    func list(edit message: Message) {}
    func list(delete message: Message) {}
    func list(setPinned pinned: Bool, message: Message) { pins.append((pinned, message.id)) }
    func listQuickReactions() -> [String] { [] }
    func list(markUnread message: Message) {}
    func listReaderMoved() {}
    func list(firstVisible message: Snowflake?) {}
    func list(didReadUpTo message: Snowflake) {}
    func list(saveAnchor anchor: ScrollAnchor) {}
    func listNearBottomChanged(_ nearBottom: Bool) {}
}

@MainActor
final class PinMessageTests: XCTestCase {
    private let chat = MockDiscord.generalChannel
    private let guild: Snowflake = 910_000_000_000_000_000
    private let refusal = DiscordError.http(403, "Missing Permissions")

    private func row(_ id: UInt64, pinned: Bool = false, type: Int = 0, author: User) -> Message {
        var value = Message(id: Snowflake(id), channelID: chat, guildID: guild, author: author,
                            content: "pin fixture \(id)", timestamp: "2026-11-01T00:00:00Z", type: type)
        value.pinned = pinned
        return value
    }
    /// Guild 0 with every pin grant removed, then (optionally) granted to @everyone only.
    private func ready(_ mock: MockDiscord, pinnable: Bool = true, extra: UInt64 = 0) -> ReadyPayload {
        var ready = mock.readyPayload()
        for index in ready.guilds[0].roles.indices {
            var bits = (UInt64(ready.guilds[0].roles[index].permissions) ?? 0) & ~Permission.pinMessages
            if ready.guilds[0].roles[index].id == guild { bits |= (pinnable ? Permission.pinMessages : 0) | extra }
            ready.guilds[0].roles[index].permissions = String(bits)
        }
        return ready
    }
    private func rows(_ mock: MockDiscord) -> [Message] {
        [row(101, author: mock.users[0]), row(102, pinned: true, author: mock.users[1]), row(103, author: mock.me),
         row(104, author: MockDiscord.blockedPerson), row(105, type: 6, author: mock.users[2])]
    }
    private func fixture(pinnable: Bool = true) -> (AppModel, MockDiscord, MessageTimeline) {
        let mock = MockDiscord()
        let model = AppModel(peopleAPI: mock)
        model.store.apply(ready: ready(mock, pinnable: pinnable))
        model.select(channel: chat)
        mock.setReadHistory(rows(mock), channel: chat)
        let timeline = model.timeline(for: chat)
        timeline.seed(rows(mock))
        return (model, mock, timeline)
    }
    private func current(_ timeline: MessageTimeline, _ id: UInt64) -> Message? {
        timeline.messages.first { $0.id == Snowflake(id) }
    }
    private func pinned(_ timeline: MessageTimeline, _ id: UInt64) -> Bool? { current(timeline, id)?.pinned }
    private func dispatch(_ name: String, _ fields: [String: Any]) throws -> GatewayDispatch {
        GatewayDispatch(name: name, data: try JSONSerialization.data(withJSONObject: ["d": fields]))
    }
    private func wire(_ script: [RepairWire.Stub]) -> DiscordREST {
        RepairWire.reset(script)
        return DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "PinRegression"),
                           protocolClasses: [RepairWire.self])
    }
    private func waitUntil(_ condition: () -> Bool, _ what: String) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
        throw URLError(.timedOut)
    }
    private func list(_ model: AppModel, _ timeline: MessageTimeline) -> MessageListController {
        MessageListController(timeline: timeline, store: model.store, api: model.api, guildID: guild,
                              title: "general", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
    }

    // MARK: Wire

    func testWireUsesDocumentedPinRouteWithoutBodyAndAcceptsEmpty204() async throws {
        let rest = wire([.init(body: "", status: 204), .init(body: "", status: 204)])
        try await rest.setPinned(channel: 42, message: 77, pinned: true)
        try await rest.setPinned(channel: 42, message: 77, pinned: false)
        let records = RepairWire.captured()
        XCTAssertEqual(records.map { $0.request.httpMethod }, ["PUT", "DELETE"])
        XCTAssertEqual(records.map { $0.request.url?.absoluteString },
                       ["https://discord.com/api/v9/channels/42/messages/pins/77", "https://discord.com/api/v9/channels/42/messages/pins/77"])
        XCTAssertTrue(records.allSatisfy { $0.body.isEmpty && $0.request.value(forHTTPHeaderField: "Content-Type") == nil })
        XCTAssertFalse(records.contains { $0.request.url!.path.contains("/channels/42/pins") })
    }

    func testWireRefusalAndRateLimitAreSentOnceAndOldTransportsFailClosed() async throws {
        let refused = wire([.init(body: #"{"code":50013,"message":"Missing Permissions"}"#, status: 403), .init(body: "", status: 204)])
        do {
            try await refused.setPinned(channel: 42, message: 77, pinned: true)
            XCTFail("refused pin succeeded")
        } catch DiscordError.api(let status, let code, let message) {
            XCTAssertEqual(status, 403); XCTAssertEqual(code, 50013); XCTAssertEqual(message, "Missing Permissions")
        }
        XCTAssertEqual(RepairWire.captured().count, 1)
        let limited = wire([.init(body: #"{"retry_after":0.01,"global":false}"#, status: 429), .init(body: "", status: 204)])
        do {
            try await limited.setPinned(channel: 42, message: 78, pinned: false)
            XCTFail("rate-limited unpin succeeded")
        } catch DiscordError.rateLimited {
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(RepairWire.captured().count, 1, "a pin write is never sent again by itself")
        do {
            try await OfflineAPI().setPinned(channel: 42, message: 77, pinned: true)
            XCTFail("offline transport pinned")
        } catch DiscordError.unauthorized {
        }
    }

    // MARK: Permission

    func testPinPermissionIsItsOwnBitAndFollowsOverwritesOwnerAdminAndDMs() throws {
        let mock = MockDiscord()
        func canPin(extra: UInt64 = 0, pinnable: Bool = false, _ edit: (inout ReadyPayload) -> Void = { _ in }) -> Bool {
            var payload = ready(mock, pinnable: pinnable, extra: extra)
            edit(&payload)
            let store = DiscordStore()
            store.apply(ready: payload)
            return store.canPin(in: store.channel(chat)!)
        }
        func overwrite(_ edit: inout ReadyPayload, _ value: PermissionOverwrite) {
            let index = edit.guilds[0].channels.firstIndex { $0.id == chat }!
            edit.guilds[0].channels[index].permissionOverwrites = (edit.guilds[0].channels[index].permissionOverwrites ?? []) + [value]
        }
        let designers = Snowflake(guild.raw + 901)
        XCTAssertEqual(Permission.pinMessages, 0x0008_0000_0000_0000)
        XCTAssertFalse(canPin(extra: 1 << 13), "Manage Messages alone no longer pins")
        XCTAssertTrue(canPin(pinnable: true))
        XCTAssertFalse(canPin(pinnable: true) { overwrite(&$0, PermissionOverwrite(id: designers, type: 0, allow: "0", deny: String(Permission.pinMessages))) })
        XCTAssertTrue(canPin(pinnable: true) {
            overwrite(&$0, PermissionOverwrite(id: designers, type: 0, allow: "0", deny: String(Permission.pinMessages)))
            overwrite(&$0, PermissionOverwrite(id: mock.me.id, type: 1, allow: String(Permission.pinMessages), deny: "0"))
        })
        XCTAssertFalse(canPin(pinnable: true) { overwrite(&$0, PermissionOverwrite(id: self.guild, type: 0, allow: "0", deny: String(Permission.viewChannel))) },
                       "a channel you cannot see")
        XCTAssertTrue(canPin(extra: Permission.administrator))
        XCTAssertTrue(canPin { $0.guilds[0].ownerID = mock.me.id })
        let store = DiscordStore()
        store.apply(ready: ready(mock, pinnable: false))
        XCTAssertTrue(store.canPin(in: try XCTUnwrap(store.channel(mock.dms[0].id))), "DMs have no guild permissions")
        // Mock mode grants pins through your role in the first server only.
        let plain = DiscordStore()
        plain.apply(ready: mock.readyPayload())
        XCTAssertTrue(plain.canPin(in: try XCTUnwrap(plain.channel(chat))))
        let elsewhere = try XCTUnwrap(mock.guilds[1].channels.first { $0.type == .text })
        XCTAssertFalse(plain.canPin(in: try XCTUnwrap(plain.channel(elsewhere.id))))
    }

    func testThreadsInheritParentPinPermissionButArchivedOrLockedRefuse() throws {
        let mock = MockDiscord()
        let threadID: Snowflake = 950_000_000_000_000_001
        func store(pinnable: Bool, archived: Bool = false, locked: Bool = false) -> DiscordStore {
            var payload = ready(mock, pinnable: pinnable)
            var thread = Channel(id: threadID, type: .publicThread, guildID: guild, name: "thread", parentID: chat)
            thread.threadMetadata = ThreadMetadata(archived: archived, locked: locked)
            payload.guilds[0].threads.append(thread)
            let store = DiscordStore()
            store.apply(ready: payload)
            return store
        }
        func canPin(_ store: DiscordStore) throws -> Bool { store.canPin(in: try XCTUnwrap(store.channel(threadID))) }
        XCTAssertTrue(try canPin(store(pinnable: true)))
        XCTAssertFalse(try canPin(store(pinnable: false)))
        XCTAssertFalse(try canPin(store(pinnable: true, archived: true)))
        XCTAssertFalse(try canPin(store(pinnable: true, locked: true)))
    }

    // MARK: Menu

    func testMenuItemFollowsTheCurrentRowAndHidesIneligibleMessages() throws {
        let (model, mock, timeline) = fixture()
        let list = list(model, timeline)
        XCTAssertEqual(list.pinMenuTitle(for: try XCTUnwrap(current(timeline, 101))), "Pin Message")
        XCTAssertEqual(list.pinMenuTitle(for: try XCTUnwrap(current(timeline, 102))), "Unpin Message")
        var stale = try XCTUnwrap(current(timeline, 101)); stale.pinned = true
        XCTAssertEqual(list.pinMenuTitle(for: stale), "Pin Message", "the window's row decides, not the captured copy")
        XCTAssertNil(list.pinMenuTitle(for: try XCTUnwrap(current(timeline, 105))), "system messages cannot be pinned")
        XCTAssertNil(list.pinMenuTitle(for: try XCTUnwrap(current(timeline, 104))), "a concealed blocked message")
        model.store.revealBlockedMessage(104)
        XCTAssertEqual(list.pinMenuTitle(for: try XCTUnwrap(current(timeline, 104))), "Pin Message")
        var pending = row(9001, author: mock.me); pending.nonce = "pin-pending"
        var failed = row(9002, author: mock.me); failed.nonce = "pin-failed"
        timeline.addPending(pending); timeline.addPending(failed)
        timeline.markFailed(nonce: "pin-failed", error: "offline")
        XCTAssertNil(list.pinMenuTitle(for: pending))
        XCTAssertNil(list.pinMenuTitle(for: failed))
        XCTAssertNil(list.pinMenuTitle(for: row(999, author: mock.me)), "not in the window")
        let (refusedModel, _, refusedTimeline) = fixture(pinnable: false)
        XCTAssertNil(self.list(refusedModel, refusedTimeline).pinMenuTitle(for: try XCTUnwrap(current(refusedTimeline, 101))))
    }

    func testConfirmationDoesNothingUntilConfirmed() throws {
        let (model, mock, timeline) = fixture()
        let list = list(model, timeline)
        let host = PinRecordingHost()
        list.host = host
        let message = try XCTUnwrap(current(timeline, 101))
        let pin = list.pinConfirmation(for: message, pinned: true)
        XCTAssertEqual(pin.preferredStyle, .alert)
        XCTAssertEqual(pin.title, "Pin Message")
        XCTAssertEqual(pin.actions.map(\.title), ["Cancel", "Pin"])
        XCTAssertEqual(pin.actions.map(\.style), [.cancel, .default])
        XCTAssertEqual(pin.view.accessibilityIdentifier, "confirmPin")
        let unpin = list.pinConfirmation(for: try XCTUnwrap(current(timeline, 102)), pinned: false)
        XCTAssertEqual(unpin.title, "Unpin Message")
        XCTAssertEqual(unpin.actions.map(\.title), ["Cancel", "Unpin"])
        XCTAssertEqual(unpin.actions.map(\.style), [.cancel, .destructive])
        // No window: nothing is presented, and nothing is sent or shown.
        list.confirmPin(message, pinned: true)
        XCTAssertNil(list.presentedViewController)
        XCTAssertTrue(host.pins.isEmpty)
        XCTAssertTrue(mock.pinOperations.isEmpty)
        XCTAssertEqual(pinned(timeline, 101), false)
        XCTAssertFalse(timeline.isChangingPin(101))
    }

    // MARK: Optimistic writes

    func testConfirmedPinIsOptimisticAndSucceedsWithoutMessageUpdate() async throws {
        let (model, mock, timeline) = fixture()
        let events = PinEventBox()
        mock.echo = { events.append($0) }
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        let before = PinsSubmission.current(model: model, store: model.store, channel: chat)
        let generated = try await mock.pins(channel: chat).map(\.id)
        coordinator.list(setPinned: true, message: try XCTUnwrap(current(timeline, 101)))
        XCTAssertEqual(pinned(timeline, 101), true, "shown at once")
        XCTAssertTrue(timeline.isChangingPin(101))
        try await waitUntil({ !timeline.isChangingPin(101) }, "pin to finish")
        XCTAssertEqual(mock.pinOperations, [MockDiscord.PinRecord(channel: chat, message: 101, pinned: true)])
        XCTAssertEqual(pinned(timeline, 101), true)
        XCTAssertNil(model.toast)
        XCTAssertEqual(events.all.map(\.name), ["CHANNEL_PINS_UPDATE"], "no MESSAGE_UPDATE is needed")
        for event in events.all { await model.handle(event) }
        let after = PinsSubmission.current(model: model, store: model.store, channel: chat)
        XCTAssertNotEqual(after, before, "an open Pins view reloads")
        XCTAssertEqual(after.revision, 1)
        XCTAssertNotNil(model.store.channel(chat)?.lastPinTimestamp)
        let pins = try await mock.pins(channel: chat)
        XCTAssertEqual(pins.map(\.id), [101] + generated, "newest pin first, over the generated ones")
    }

    func testRefusalRollsBackPinAndUnpinWithError() async throws {
        let (model, mock, timeline) = fixture()
        let refusal = refusal
        let generated = try await mock.pins(channel: chat).map(\.id)
        mock.beforePin = { _ in throw refusal }
        let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
        XCTAssertEqual(pinned(timeline, 101), true)
        let pinApplied = await pin.value
        XCTAssertFalse(pinApplied)
        XCTAssertEqual(pinned(timeline, 101), false)
        XCTAssertEqual(model.toast?.text, "Couldn't pin message")
        let unpin = try XCTUnwrap(model.setPinned(false, message: try XCTUnwrap(current(timeline, 102))))
        XCTAssertEqual(pinned(timeline, 102), false)
        let unpinApplied = await unpin.value
        XCTAssertFalse(unpinApplied)
        XCTAssertEqual(pinned(timeline, 102), true)
        XCTAssertEqual(model.toast?.text, "Couldn't unpin message")
        XCTAssertEqual(mock.pinOperations.map(\.pinned), [true, false])
        let pins = try await mock.pins(channel: chat)
        XCTAssertEqual(pins.map(\.id), generated, "a refused write changes no pins")
    }

    func testGatewayDecisionInFlightOutranksTheWrite() async throws {
        let (model, mock, timeline) = fixture()
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
        try await waitUntil({ gate.arrivals == 1 }, "pin request")
        await model.handle(try dispatch("MESSAGE_UPDATE", ["id": "101", "channel_id": chat.description, "pinned": true]))
        gate.open(failing: URLError(.networkConnectionLost))
        let confirmedApplied = await pin.value
        XCTAssertTrue(confirmedApplied, "Discord's matching update confirms a write whose response was lost")
        XCTAssertEqual(pinned(timeline, 101), true)
        XCTAssertNil(model.toast)

        let opposite = PinGate()
        mock.beforePin = { _ in try await opposite.pass() }
        let unpin = try XCTUnwrap(model.setPinned(false, message: try XCTUnwrap(current(timeline, 102))))
        try await waitUntil({ opposite.arrivals == 1 }, "unpin request")
        await model.handle(try dispatch("MESSAGE_UPDATE", ["id": "102", "channel_id": chat.description, "pinned": true]))
        XCTAssertEqual(pinned(timeline, 102), true)
        opposite.open()
        let oppositeApplied = await unpin.value
        XCTAssertTrue(oppositeApplied)
        XCTAssertEqual(pinned(timeline, 102), true, "a newer gateway value is not overwritten by the completed write")
        XCTAssertNil(model.toast)
    }

    func testOneChangePerMessageAndStaleMenuCapturesResolveTheCurrentRow() async throws {
        let (model, mock, timeline) = fixture()
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let captured = try XCTUnwrap(current(timeline, 101))
        let first = try XCTUnwrap(model.setPinned(true, message: captured))
        XCTAssertNil(model.setPinned(false, message: try XCTUnwrap(current(timeline, 101))), "a second change waits for the first")
        XCTAssertNil(model.setPinned(true, message: captured))
        try await waitUntil({ gate.arrivals == 1 }, "pin request")
        gate.open()
        let firstApplied = await first.value
        XCTAssertTrue(firstApplied)
        XCTAssertEqual(mock.pinOperations.count, 1)
        // The menu saw it unpinned; it is pinned now: "Pin" changes nothing.
        XCTAssertNil(model.setPinned(true, message: captured))
        XCTAssertEqual(mock.pinOperations.count, 1)
        let second = try XCTUnwrap(model.setPinned(false, message: captured))
        let secondApplied = await second.value
        XCTAssertTrue(secondApplied)
        XCTAssertEqual(mock.pinOperations.map(\.pinned), [true, false])
        XCTAssertEqual(pinned(timeline, 101), false)
        XCTAssertNil(model.setPinned(true, message: row(999, author: mock.me)), "not in the window")
        XCTAssertNil(model.setPinned(true, message: try XCTUnwrap(current(timeline, 105))), "system message")
        XCTAssertEqual(mock.pinOperations.count, 2)
    }

    func testWindowReplacementInFlightKeepsIntentAndRollsBackToFreshServerState() async throws {
        let (model, mock, timeline) = fixture()
        let refusal = refusal
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
        try await waitUntil({ gate.arrivals == 1 }, "pin request")
        await timeline.loadLatest(api: mock, store: model.store)
        XCTAssertEqual(pinned(timeline, 101), true, "a page read during the write keeps your intent showing")
        gate.open(failing: refusal)
        let pinApplied = await pin.value
        XCTAssertFalse(pinApplied)
        XCTAssertEqual(pinned(timeline, 101), false)

        // Discord no longer has 102 pinned (changed elsewhere); the window still does.
        var server = rows(mock); server[1].pinned = false
        mock.setReadHistory(server, channel: chat)
        let unpinGate = PinGate()
        mock.beforePin = { _ in try await unpinGate.pass() }
        let unpin = try XCTUnwrap(model.setPinned(false, message: try XCTUnwrap(current(timeline, 102))))
        try await waitUntil({ unpinGate.arrivals == 1 }, "unpin request")
        timeline.markNeedsRefresh()
        await timeline.loadLatest(api: mock, store: model.store)
        unpinGate.open(failing: refusal)
        let unpinApplied = await unpin.value
        XCTAssertFalse(unpinApplied)
        XCTAssertEqual(pinned(timeline, 102), false, "rolls back to what Discord last showed, not the obsolete pin")
        XCTAssertEqual(model.toast?.text, "Couldn't unpin message")
    }

    func testDeletionInFlightNeverRestoresObsoletePinMetadata() async throws {
        let (model, mock, timeline) = fixture()
        let refusal = refusal
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
        try await waitUntil({ gate.arrivals == 1 }, "pin request")
        await model.handle(try dispatch("MESSAGE_DELETE", ["id": "101", "channel_id": chat.description]))
        gate.open(failing: refusal)
        _ = await pin.value
        XCTAssertNil(current(timeline, 101), "a deleted message does not come back")

        // Your own delete, refused only after the pin settled while the row was hidden.
        let pinGate = PinGate()
        mock.beforePin = { _ in try await pinGate.pass() }
        let ownPin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 103))))
        try await waitUntil({ pinGate.arrivals == 1 }, "own pin request")
        let held = wire([.init(body: #"{"message":"Missing Permissions"}"#, status: 403, held: true)])
        let delete = try XCTUnwrap(timeline.sendDelete(103, api: held))
        try await waitUntil({ RepairWire.captured().count == 1 }, "delete request")
        XCTAssertNil(current(timeline, 103))
        pinGate.open(failing: refusal)
        let ownApplied = await ownPin.value
        XCTAssertFalse(ownApplied)
        RepairWire.release()
        let deleted = await delete.value
        XCTAssertFalse(deleted)
        XCTAssertEqual(pinned(timeline, 103), false, "the restored row shows the settled pin, not the optimistic one")
    }

    // MARK: Authority

    func testAuthorityLostBeforeTheRequestStartsSendsNothing() async throws {
        func role(_ model: AppModel) throws -> [String: Any] {
            let everyone = try XCTUnwrap(model.store.guilds[guild]?.roles.first { $0.id == guild })
            let bits = (UInt64(everyone.permissions) ?? 0) & ~Permission.pinMessages
            return ["guild_id": guild.description, "role": ["id": guild.description, "name": "@everyone", "permissions": String(bits), "position": 0, "color": 0]]
        }
        // Each interruption lands after the tap but before the request task runs.
        let cases: [(String, (AppModel, MockDiscord, Task<Bool, Never>) throws -> Void)] = [
            ("permission revoked", { model, _, _ in model.store.handle(try self.dispatch("GUILD_ROLE_UPDATE", try role(model))) }),
            ("channel removed", { model, _, _ in model.store.handle(try self.dispatch("CHANNEL_DELETE", ["id": self.chat.description])) }),
            ("cancelled", { _, _, task in task.cancel() }),
            ("store replaced", { model, mock, _ in model.store.apply(ready: self.ready(mock)) }),
        ]
        for (name, interrupt) in cases {
            let (model, mock, timeline) = fixture()
            let task = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))), name)
            XCTAssertEqual(pinned(timeline, 101), true, name)
            try interrupt(model, mock, task)
            let applied = await task.value
            XCTAssertFalse(applied, name)
            XCTAssertTrue(mock.pinOperations.isEmpty, "\(name): no request may start")
            XCTAssertEqual(pinned(timeline, 101), false, "\(name): the optimistic pin goes back")
            XCTAssertEqual(model.toast?.text, "Couldn't pin message", "\(name): same login, so the reader learns it did not happen")
        }
    }

    func testStaleCompletionAfterSessionReplacementNeitherToastsNorTouchesTheNewSession() async throws {
        let (model, mock, timeline) = fixture()
        let refusal = refusal
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let unpin = try XCTUnwrap(model.setPinned(false, message: try XCTUnwrap(current(timeline, 102))))
        try await waitUntil({ gate.arrivals == 1 }, "unpin request")
        model.signOut()
        model.start()
        model.store.apply(ready: ready(mock))
        var replacement = rows(mock); replacement[1].pinned = false
        let fresh = model.timeline(for: chat)
        XCTAssertFalse(fresh === timeline)
        fresh.seed(replacement)
        gate.open(failing: refusal)
        _ = await unpin.value
        XCTAssertNil(model.toast, "an old login's failure is not shown")
        XCTAssertEqual(pinned(fresh, 102), false, "the old login's rollback does not reach the new session")
        XCTAssertFalse(fresh.isChangingPin(102))
    }

    func testDebugRealSessionRefusesBeforeAnyRequestOrLocalChange() async throws {
        let rest = wire([])
        let model = AppModel(notificationAPI: rest)
        let mock = MockDiscord()
        model.store.apply(ready: ready(mock))
        let timeline = model.timeline(for: chat)
        timeline.seed(rows(mock))
        XCTAssertFalse(model.allowsPinWrites)
        XCTAssertNil(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
        XCTAssertEqual(pinned(timeline, 101), false)
        XCTAssertFalse(timeline.isChangingPin(101))
        XCTAssertEqual(model.toast?.text, "Pinning is disabled for real accounts in Debug.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(RepairWire.captured().isEmpty)
    }

    // MARK: CHANNEL_PINS_UPDATE

    func testChannelPinsUpdateTimestampSemanticsScopedRevisionsAndResets() throws {
        let mock = MockDiscord()
        let model = AppModel(peopleAPI: mock)
        let store = model.store
        let payload = ready(mock)
        store.apply(ready: payload)
        let welcome: Snowflake = 910_000_000_000_000_101
        let base = PinsSubmission.current(model: model, store: store, channel: chat)
        XCTAssertEqual(base.revision, 0)
        XCTAssertEqual(PinsSubmission(context: base.context, channel: chat), base)
        let name = store.channel(chat)?.name, last = store.channel(chat)?.lastMessageID
        let flag = PinFlag()
        withObservationTracking { _ = store.pinsRevision(for: chat) } onChange: { flag.set() }
        func pins(_ fields: [String: Any]) throws { store.handle(try dispatch("CHANNEL_PINS_UPDATE", fields)) }
        try pins(["guild_id": guild.description, "channel_id": chat.description, "last_pin_timestamp": "2026-11-03T01:02:03.000000+00:00"])
        XCTAssertTrue(flag.fired, "the revision is observable")
        XCTAssertEqual(store.channel(chat)?.lastPinTimestamp, "2026-11-03T01:02:03.000000+00:00")
        XCTAssertEqual(store.pinsRevision(for: chat), 1)
        XCTAssertEqual(store.pinsRevision(for: welcome), 0)
        XCTAssertNotEqual(PinsSubmission.current(model: model, store: store, channel: chat), base)
        XCTAssertEqual(PinsSubmission.current(model: model, store: store, channel: welcome).revision, 0)
        try pins(["channel_id": chat.description])
        XCTAssertEqual(store.channel(chat)?.lastPinTimestamp, "2026-11-03T01:02:03.000000+00:00", "omitted keeps what is known")
        XCTAssertEqual(store.pinsRevision(for: chat), 2)
        try pins(["channel_id": chat.description, "last_pin_timestamp": NSNull()])
        XCTAssertNil(store.channel(chat)?.lastPinTimestamp, "null: no pins remain")
        XCTAssertEqual(store.pinsRevision(for: chat), 3)
        XCTAssertEqual(store.channel(chat)?.name, name)
        XCTAssertEqual(store.channel(chat)?.lastMessageID, last)
        try pins(["channel_id": "123"])
        XCTAssertNil(store.channel(123), "no channel is invented")
        // Every full replacement starts a new epoch.
        store.apply(ready: payload)
        XCTAssertEqual(store.pinsRevision(for: chat), 0)
        XCTAssertEqual(store.pinsRevision(for: 123), 0)
        try pins(["channel_id": chat.description])
        let snapshot = try XCTUnwrap(store.snapshot())
        store.reset()
        XCTAssertEqual(store.pinsRevision(for: chat), 0)
        try pins(["channel_id": chat.description])
        store.apply(snapshot: snapshot)
        XCTAssertEqual(store.pinsRevision(for: chat), 0)
    }

    func testMockPinWritesRecordOverridesAndEmitOnlyChannelPinsUpdate() async throws {
        let mock = MockDiscord()
        mock.setReadHistory(rows(mock), channel: chat)
        let events = PinEventBox()
        mock.echo = { events.append($0) }
        let generated = try await mock.pins(channel: chat).map(\.id)
        XCTAssertFalse(generated.contains(101))
        try await mock.setPinned(channel: chat, message: 101, pinned: true)
        let pinnedEvent = try XCTUnwrap(events.all.last).decode(ChannelPinsUpdate.self)
        XCTAssertEqual(pinnedEvent.channelID, chat)
        XCTAssertEqual(pinnedEvent.guildID, guild)
        XCTAssertTrue(pinnedEvent.timestampProvided)
        XCTAssertNotNil(pinnedEvent.lastPinTimestamp)
        var pins = try await mock.pins(channel: chat)
        XCTAssertEqual(pins.map(\.id), [101] + generated)
        let history = try await mock.messages(channel: chat, before: nil, after: nil, around: nil, limit: 50)
        XCTAssertEqual(history.first { $0.id == 101 }?.pinned, true)
        try await mock.setPinned(channel: chat, message: 101, pinned: false)
        let untimed = try XCTUnwrap(events.all.last).decode(ChannelPinsUpdate.self)
        XCTAssertFalse(untimed.timestampProvided, "only untimed generated pins remain: omitted, not null")
        pins = try await mock.pins(channel: chat)
        XCTAssertEqual(pins.map(\.id), generated)
        let welcome: Snowflake = 910_000_000_000_000_101
        mock.setReadHistory([Message(id: 201, channelID: welcome, guildID: guild, author: mock.users[0], content: "only", timestamp: "")], channel: welcome)
        try await mock.setPinned(channel: welcome, message: 201, pinned: true)
        try await mock.setPinned(channel: welcome, message: 201, pinned: false)
        let cleared = try XCTUnwrap(events.all.last).decode(ChannelPinsUpdate.self)
        XCTAssertTrue(cleared.timestampProvided)
        XCTAssertNil(cleared.lastPinTimestamp, "null once no pins remain")
        let welcomePins = try await mock.pins(channel: welcome)
        XCTAssertTrue(welcomePins.isEmpty)
        XCTAssertEqual(events.all.map(\.name), Array(repeating: "CHANNEL_PINS_UPDATE", count: 4))
        do {
            try await mock.setPinned(channel: chat, message: 105, pinned: true)
            XCTFail("system message pinned")
        } catch DiscordError.http(let code, _) { XCTAssertEqual(code, 400) }
        let refusal = refusal
        mock.beforePin = { _ in throw refusal }
        do {
            try await mock.setPinned(channel: chat, message: 103, pinned: true)
            XCTFail("hook did not refuse")
        } catch DiscordError.http(let code, _) { XCTAssertEqual(code, 403) }
        XCTAssertEqual(events.all.count, 4, "a refused write emits nothing")
        XCTAssertEqual(mock.pinOperations.map(\.message), [101, 101, 201, 201, 105, 103])
        // Unpinning a generated pin while others remain omits the timestamp.
        mock.beforePin = nil
        let show: Snowflake = 910_000_000_000_000_105
        let showPins = try await mock.pins(channel: show)
        XCTAssertGreaterThan(showPins.count, 1)
        try await mock.setPinned(channel: show, message: showPins[0].id, pinned: false)
        let omitted = try XCTUnwrap(events.all.last).decode(ChannelPinsUpdate.self)
        XCTAssertFalse(omitted.timestampProvided)
        let remaining = try await mock.pins(channel: show)
        XCTAssertEqual(remaining.map(\.id), Array(showPins.dropFirst()).map(\.id))
    }
}

extension PinMessageTests {
    func testPinResultAfterSameAccountStoreReplacementCannotPublish() async throws {
        for failing in [true, false] {
            let (model, mock, timeline) = fixture()
            let gate = PinGate()
            mock.beforePin = { _ in try await gate.pass() }
            let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
            try await waitUntil({ gate.arrivals == 1 }, "pin request")
            model.store.apply(ready: ready(mock))
            let revision = timeline.revision
            gate.open(failing: failing ? refusal : nil)
            _ = await pin.value
            if !failing { XCTAssertEqual(timeline.revision, revision, "an obsolete success cannot publish into the replacement epoch") }
            XCTAssertEqual(pinned(timeline, 101), !failing, "a refusal silently removes only its own optimistic value")
            XCTAssertNil(model.toast, "the same account is insufficient response authority after READY")
            XCTAssertFalse(timeline.isChangingPin(101))
        }
    }

    private func heldHistoryPin(gateway: Bool, settleBeforePage: Bool, around: Bool, id: UInt64) async throws {
        let (model, mock, timeline) = fixture()
        var oldPage = rows(mock)
        if around { oldPage.append(row(999, author: mock.me)) }
        let body = String(decoding: try JSONEncoder().encode(oldPage), as: UTF8.self)
        let history = wire([.init(body: body, held: true)])
        let page = Task {
            if around { await timeline.load(around: 999, api: history, store: model.store) }
            else { await timeline.loadLatest(api: history, store: model.store) }
        }
        try await waitUntil({ RepairWire.captured().count == 1 }, "history request")
        let target = !(try XCTUnwrap(current(timeline, id))).pinned
        let gate = PinGate()
        mock.beforePin = { _ in try await gate.pass() }
        let write = try XCTUnwrap(model.setPinned(target, message: try XCTUnwrap(current(timeline, id))))
        try await waitUntil({ gate.arrivals == 1 }, "pin request")
        if gateway {
            await model.handle(try dispatch("MESSAGE_UPDATE", ["id": String(id), "channel_id": chat.description, "pinned": target]))
        }
        if settleBeforePage {
            gate.open()
            let applied = await write.value
            XCTAssertTrue(applied)
            XCTAssertFalse(timeline.isChangingPin(Snowflake(id)))
        }
        RepairWire.release()
        await page.value
        XCTAssertEqual(pinned(timeline, id), target, "a page captured before the write cannot undo its newer pin authority")
        if !settleBeforePage {
            XCTAssertTrue(timeline.isChangingPin(Snowflake(id)))
            gate.open(failing: refusal)
            let applied = await write.value
            XCTAssertTrue(applied, "the matching gateway confirms a lost response")
            XCTAssertEqual(pinned(timeline, id), target)
        } else {
            // The fence belongs to earlier reads, not a permanent pinned-value cache.
            var later = rows(mock)
            later[later.firstIndex { $0.id == Snowflake(id) }!].pinned = !target
            mock.setReadHistory(later, channel: chat)
            timeline.markNeedsRefresh()
            await timeline.loadLatest(api: mock, store: model.store)
            XCTAssertEqual(pinned(timeline, id), !target, "a later read can learn a newer server value")
        }
    }

    func testHeldHistoryCannotUndoGatewayPinWhileWriteIsPending() async throws {
        for around in [false, true] {
            for id in [UInt64(101), UInt64(102)] {
                try await heldHistoryPin(gateway: true, settleBeforePage: false, around: around, id: id)
            }
        }
    }

    func testHeldHistoryCannotUndoSettledPinWrites() async throws {
        for gateway in [false, true] {
            for around in [false, true] {
                for id in [UInt64(101), UInt64(102)] {
                    try await heldHistoryPin(gateway: gateway, settleBeforePage: true, around: around, id: id)
                }
            }
        }
    }

    func testRefusedDeleteRestoresGatewayPinBeforeWriteSettles() async throws {
        for gateway in [false, true] {
            let (model, mock, timeline) = fixture()
            let gate = PinGate()
            mock.beforePin = { _ in try await gate.pass() }
            let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 103))))
            try await waitUntil({ gate.arrivals == 1 }, "pin request")
            let transport = wire([.init(body: #"{"message":"Missing Permissions"}"#, status: 403, held: true)])
            let delete = try XCTUnwrap(timeline.sendDelete(103, api: transport))
            try await waitUntil({ RepairWire.captured().count == 1 }, "delete request")
            XCTAssertNil(current(timeline, 103))
            await model.handle(try dispatch("MESSAGE_UPDATE", ["id": "103", "channel_id": chat.description, "pinned": gateway]))
            RepairWire.release()
            let deleted = await delete.value
            XCTAssertFalse(deleted)
            XCTAssertTrue(timeline.isChangingPin(103))
            XCTAssertEqual(pinned(timeline, 103), gateway, "delete refusal must use the gateway value even before the pin settles")
            gate.open(failing: refusal)
            _ = await pin.value
            XCTAssertEqual(pinned(timeline, 103), gateway)
        }
    }

    func testReconnectRefreshRetainsServerPinAfterAnObsoleteRefusal() async throws {
        for serverPinned in [false, true] {
            let (model, mock, timeline) = fixture()
            func readyEvent(_ session: String) throws -> GatewayDispatch {
                func object<T: Encodable>(_ value: T) throws -> Any {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                }
                let payload = ready(mock)
                return try dispatch("READY", ["user": try object(payload.user), "guilds": try object(payload.guilds),
                                              "users": try object(payload.users), "private_channels": try object(payload.privateChannels),
                                              "merged_members": try object(payload.mergedMembers), "session_id": session])
            }
            await model.handle(try readyEvent("first-session"))
            XCTAssertTrue(timeline.isSeeded)
            let gate = PinGate()
            mock.beforePin = { _ in try await gate.pass() }
            let pin = try XCTUnwrap(model.setPinned(true, message: try XCTUnwrap(current(timeline, 101))))
            try await waitUntil({ gate.arrivals == 1 }, "pin request")
            var server = rows(mock)
            server[0].pinned = serverPinned
            mock.setReadHistory(server, channel: chat)
            await model.handle(try readyEvent("replacement-session"))
            try await waitUntil({ !timeline.isSeeded }, "the reconnect's refresh read")
            XCTAssertTrue(timeline.isChangingPin(101), "the old request is still held when refresh completes")
            gate.open(failing: refusal)
            let applied = await pin.value
            XCTAssertFalse(applied)
            XCTAssertEqual(pinned(timeline, 101), serverPinned, "the new session's server value survives removal of the old optimism")
            XCTAssertNil(model.toast, "the obsolete response cannot show an error in the new epoch")
            XCTAssertFalse(timeline.isChangingPin(101))
        }
    }
}

/// Real REST failures over an offline URLProtocol: no Discord account actions.
final class DiscordFailureTests: XCTestCase {
    private func rest(status: Int, body: String) -> DiscordREST {
        RepairWire.reset([.init(body: body, status: status)])
        return DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "FailureTests"),
                           protocolClasses: [RepairWire.self])
    }

    func testPermissionFailuresGiveConservativeActionableFeedback() async throws {
        let cases = [
            (50001, "You don't have access to this resource. Check your server or channel access."),
            (50013, "Discord denied this action because you don't have the required permissions. Check your server or channel permissions."),
            (50007, "Discord couldn't deliver a message to this person. Their privacy settings or your relationship may prevent messages."),
        ]
        for (code, expected) in cases {
            let api = rest(status: 403, body: "{\"code\":\(code),\"message\":\"Server refusal\"}")
            do {
                _ = try await api.send(channel: 42, content: "offline", replyTo: nil, pingReply: false, attachments: [], nonce: "failure-test")
                XCTFail("refused send succeeded")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected, "Discord code \(code)")
                XCTAssertFalse(DiscordError.mayHaveApplied(error), "a refusal must not be treated as an uncertain write")
            }
            XCTAssertEqual(RepairWire.captured().count, 1, "a refused send must not be retried")
        }
    }

    private func sendFailure(status: Int, body: String) async throws -> DiscordError {
        let api = rest(status: status, body: body)
        do {
            _ = try await api.send(channel: 42, content: "offline", replyTo: nil, pingReply: false, attachments: [], nonce: "failure-test")
            XCTFail("refused send succeeded")
            throw URLError(.unknown)
        } catch let error as DiscordError {
            XCTAssertEqual(RepairWire.captured().count, 1, "a failed write must not be retried")
            return error
        }
    }

    func testKnownCodesKeepStatusRawMessageAndNamedReason() async throws {
        let reasons: [DiscordFailureReason] = [.missingAccess, .missingPermissions, .cannotMessageUser, .unknownChannel, .unknownMessage]
        for reason in reasons {
            let status = reason == .unknownChannel || reason == .unknownMessage ? 404 : 403
            let error = try await sendFailure(status: status, body: "{\"code\":\(reason.rawValue),\"message\":\"original refusal\"}")
            guard case .api(let actualStatus, let code, let message) = error else { return XCTFail("lost Discord code") }
            XCTAssertEqual(actualStatus, status)
            XCTAssertEqual(code, reason.rawValue)
            XCTAssertEqual(message, "original refusal")
            XCTAssertEqual(error.failureReason, reason)
            XCTAssertEqual(error.httpStatus, status)
            XCTAssertFalse(DiscordError.mayHaveApplied(error))
        }
    }

    func testUnknownCodesAndMalformedFieldsRemainUseful() async throws {
        for code in [0, 99999, -1] {
            let error = try await sendFailure(status: 400, body: "{\"code\":\(code),\"message\":\"new server refusal\"}")
            guard case .api(400, let actualCode, let message) = error else { return XCTFail("unknown code discarded") }
            XCTAssertEqual(actualCode, code)
            XCTAssertEqual(message, "new server refusal")
            XCTAssertNil(error.failureReason)
            XCTAssertEqual(error.localizedDescription, "Discord returned 400 (code \(code)): new server refusal")
            XCTAssertFalse(DiscordError.mayHaveApplied(error))
        }
        for body in [#"{"code":"50013","message":"useful refusal"}"#, #"{"code":{},"message":"useful refusal"}"#,
                     #"{"message":"useful refusal"}"#] {
            let error = try await sendFailure(status: 403, body: body)
            guard case .http(403, let message) = error else { return XCTFail("malformed code must remain an uncoded HTTP refusal") }
            XCTAssertEqual(message, "useful refusal")
            XCTAssertNil(error.failureReason)
        }
        for body in ["not JSON", "[]", #"{"message":null}"#, #"{"message":{}}"#] {
            let error = try await sendFailure(status: 502, body: body)
            guard case .http(502, let message) = error else { return XCTFail("malformed payload lost HTTP status") }
            XCTAssertEqual(message, HTTPURLResponse.localizedString(forStatusCode: 502))
            XCTAssertTrue(DiscordError.mayHaveApplied(error))
        }
        let error = try await sendFailure(status: 403, body: #"{"code":50013,"message":{}}"#)
        guard case .api(403, 50013, let message) = error else { return XCTFail("a malformed message must not discard a valid code") }
        XCTAssertEqual(message, HTTPURLResponse.localizedString(forStatusCode: 403))
        XCTAssertEqual(error.failureReason, .missingPermissions)
    }

    func testServerErrorsNeverClaimADefinitePermissionRefusal() async throws {
        let error = try await sendFailure(status: 503, body: #"{"code":50013,"message":"server unavailable"}"#)
        XCTAssertNil(error.failureReason)
        XCTAssertEqual(error.localizedDescription, "Discord returned 503 (code 50013): server unavailable")
        XCTAssertTrue(DiscordError.mayHaveApplied(error), "a server error can follow an applied write")
    }

    func testSignOutStillOverridesTheBodyCode() async throws {
        let error = try await sendFailure(status: 401, body: #"{"code":50013,"message":"Missing Permissions"}"#)
        guard case .unauthorized = error else { return XCTFail("401 must end the session") }
        XCTAssertFalse(DiscordError.mayHaveApplied(error))
    }

    func testLostResponsesRemainUncertainAndAreNeverRetried() async throws {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet] {
            let api = rest(status: 200, body: "")
            RepairWire.reset([.init(body: "", error: URLError(code))])
            do {
                _ = try await api.send(channel: 42, content: "offline", replyTo: nil, pingReply: false, attachments: [], nonce: "failure-test")
                XCTFail("transport failure succeeded")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, code)
                XCTAssertEqual(DiscordError.mayHaveApplied(error), code != .notConnectedToInternet)
            }
            XCTAssertEqual(RepairWire.captured().count, 1, "an uncertain send must not be retried")
        }
    }

    @MainActor
    func testCodedHistoryRefusalsKeepInboxAccessFeedback() async throws {
        for (status, code) in [(403, 50001), (404, 10003)] {
            let api = rest(status: status, body: "{\"code\":\(code),\"message\":\"refusal\"}")
            let previews = InboxPreviews()
            let key = InboxPreviews.Key(channel: 42, latest: 100, boundary: 10, session: UUID(), account: 1, api: ObjectIdentifier(api))
            previews.appear(key, cached: nil, load: { try await InboxPreviews.latestMessage(api: api, channel: 42) }, isCurrent: { true })
            for _ in 0..<100 where previews.inFlight > 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(previews.entry(for: key), .failed("You can't read this conversation's history."))
            XCTAssertEqual(RepairWire.captured().count, 1)
        }
    }

    @MainActor
    func testCodedReactionRefusalRollsBackWithoutAnUncertainOutcomeRead() async throws {
        let api = rest(status: 403, body: #"{"code":50013,"message":"Missing Permissions"}"#)
        let timeline = MessageTimeline(channelID: 42)
        timeline.receive(Message(id: 10, channelID: 42, guildID: nil, author: User(id: 1, username: "offline"), content: "fixture", timestamp: ""))
        let emoji = Emoji(id: nil, name: "👍", animated: false)
        let pending = try XCTUnwrap(timeline.sendReaction(emoji, on: 10, add: true, api: api))
        XCTAssertEqual(timeline.messages.first?.reactions.first?.me, true, "shown optimistically")
        let outcome = await pending.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(timeline.messages.first?.reactions.isEmpty == true, "definite refusal restores the prior reaction")
        XCTAssertEqual(RepairWire.captured().map { $0.request.httpMethod }, ["PUT"], "neither another write nor an uncertainty read")
    }

    func testAChannelCodeCannotTriggerTheLegacyPinsRouteEvenWithGenericMessage() async throws {
        let api = rest(status: 404, body: #"{"code":10003,"message":"404: Not Found"}"#)
        do {
            _ = try await api.pinPage(channel: 42, before: nil, limit: 50)
            XCTFail("unknown channel succeeded")
        } catch DiscordError.api(404, 10003, _) {
        }
        XCTAssertEqual(RepairWire.captured().count, 1, "the numeric code must prevent a false unknown-route fallback")
    }
}
