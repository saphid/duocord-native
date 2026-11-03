import XCTest
@testable import DuocordNative

/// Catch-all transport: an exhausted script fails closed instead of reaching a service.
nonisolated private final class RepairWire: URLProtocol, @unchecked Sendable {
    struct Stub {
        var body: String
        var status = 200
        var held = false
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
