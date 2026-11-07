import XCTest
@testable import DuocordNative

/// Every URL is intercepted; an exhausted script fails closed.
nonisolated private final class SendWire: URLProtocol, @unchecked Sendable {
    struct Stub {
        var body = ""
        var status = 200
        var error: URLError?
        var held = false
        var headers: [String: String] = [:]
    }
    struct Record { var request: URLRequest; var body: Data }
    static let lock = NSLock()
    static var script: [Stub] = []
    static var records: [Record] = []
    static var held: [(SendWire, Stub)] = []
    static func reset(_ stubs: [Stub]) { lock.withLock { script = stubs; records = []; held = [] } }
    static func captured() -> [Record] { lock.withLock { records } }
    static func append(_ stubs: [Stub]) { lock.withLock { script += stubs } }
    static func release() {
        let pending = lock.withLock { let pending = held; held = []; return pending }
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.held.removeAll { $0.0 === self } } }
}

@MainActor
final class OutgoingSendTests: XCTestCase {
    private let channel = MockDiscord.generalChannel
    private func fixture(_ stubs: [SendWire.Stub]) -> AppModel {
        SendWire.reset(stubs)
        let rest = DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "OutgoingRegression"), protocolClasses: [SendWire.self])
        let model = AppModel(notificationAPI: rest)
        var ready = MockDiscord().readyPayload()
        // Upload lifecycle fixtures explicitly grant the payload permission;
        // plain-text eligibility no longer implicitly authorizes files.
        for index in ready.guilds[0].roles.indices {
            let bits = UInt64(ready.guilds[0].roles[index].permissions) ?? 0
            ready.guilds[0].roles[index].permissions = String(bits | Permission.attachFiles)
        }
        model.store.apply(ready: ready)
        return model
    }
    private func settle(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Offline seam did not settle", file: file, line: line)
        throw URLError(.timedOut)
    }
    private func settled(_ model: AppModel) -> Bool {
        let t = model.timeline(for: channel)
        return t.messages.last.map { t.sendState(for: $0) != .sending } ?? false
    }
    private func accepted(_ echo: Message) -> Message {
        var sent = echo; sent.id = 1_000_000_000_000_000_001; return sent
    }
    private func json(_ messages: [Message]) throws -> String { String(decoding: try JSONEncoder().encode(messages), as: UTF8.self) }
    private func gateway(_ model: AppModel, _ message: Message) async throws {
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(["d": message])))
    }
    override func tearDown() { SendWire.release(); super.tearDown() }

    func testAcceptedResponseLostManualRetryNeverPostsAgainAndReadbackConfirmsOriginal() async throws {
        let model = fixture([.init(error: URLError(.timedOut))])
        model.drafts[channel] = Draft(text: "one logical send")
        model.send(in: channel)
        let timeline = model.timeline(for: channel)
        let original = try XCTUnwrap(timeline.messages.last)
        let server = accepted(original) // endpoint accepted this POST before losing its response
        try await settle { self.settled(model) }
        model.drafts[channel] = Draft(text: "leave composer alone")
        SendWire.append([.init(body: try json([server]))])
        model.retry(original)
        try await settle { SendWire.captured().count >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(SendWire.captured().filter { $0.request.httpMethod == "POST" }.count, 1, "A lost response must never authorize a second POST")
        XCTAssertEqual(timeline.messages.map(\.id), [server.id])
        XCTAssertEqual(timeline.messages.last?.nonce, original.nonce)
        XCTAssertTrue(timeline.sendStates.isEmpty)
        XCTAssertEqual(model.drafts[channel]?.text, "leave composer alone")
    }

    func testGatewayConfirmationBeforeLostResponseCannotRegress() async throws {
        let model = fixture([.init(error: URLError(.timedOut), held: true)])
        model.drafts[channel] = Draft(text: "gateway wins")
        let task = try XCTUnwrap(model.send(in: channel))
        let timeline = model.timeline(for: channel)
        let echo = try XCTUnwrap(timeline.messages.last)
        try await settle { SendWire.captured().count == 1 }
        let sent = accepted(echo)
        try await gateway(model, sent)
        SendWire.release()
        let result = await task.value
        XCTAssertEqual(result, true, "A gateway confirmation also resolves the caller's result")
        XCTAssertEqual(timeline.messages.map(\.id), [sent.id])
        XCTAssertTrue(timeline.sendStates.isEmpty)
        model.retry(echo)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(SendWire.captured().count, 1, "Confirmation releases retry payload, including on transport failure")
    }

    func testGatewayAfterLostResponseAndRepeatedRetryCoalescesRead() async throws {
        let model = fixture([.init(error: URLError(.networkConnectionLost)), .init(body: "[]", held: true)])
        model.drafts[channel] = Draft(text: "keep uncertainty")
        model.send(in: channel)
        let timeline = model.timeline(for: channel)
        let echo = try XCTUnwrap(timeline.messages.last)
        try await settle { self.settled(model) }
        model.retry(echo); model.retry(echo); model.retry(echo)
        try await settle { SendWire.captured().count >= 2 }
        let sent = accepted(echo)
        try await gateway(model, sent)
        SendWire.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(SendWire.captured().map { $0.request.httpMethod }, ["POST", "GET"])
        XCTAssertEqual(timeline.messages.map(\.id), [sent.id])
        XCTAssertTrue(timeline.sendStates.isEmpty)
    }

    func testExplicitRefusalRetryPreservesNonceReplyPingFilesAndComposer() async throws {
        let slots = #"{"attachments":[{"id":0,"upload_url":"https://offline.invalid/upload","upload_filename":"slot/file.txt"}]}"#
        let model = fixture([.init(body: slots), .init(), .init(body: #"{"code":50013,"message":"denied"}"#, status: 403)])
        let reply = Message(id: 42, channelID: channel, guildID: nil, author: model.store.me!, content: "reply", timestamp: "")
        let file = DraftAttachment(filename: "file.txt", data: Data("original bytes".utf8), contentType: "text/plain")
        model.drafts[channel] = Draft(text: "retry original", replyTo: reply, attachments: [file])
        model.send(in: channel, pingReply: false)
        let timeline = model.timeline(for: channel)
        let echo = try XCTUnwrap(timeline.messages.last)
        try await settle { self.settled(model) }
        model.drafts[channel] = Draft(text: "new composer", attachments: [file])
        let current = model.drafts[channel]
        let server = accepted(echo)
        SendWire.append([.init(body: slots), .init(), .init(body: String(decoding: try JSONEncoder().encode(server), as: UTF8.self))])
        model.retry(echo); model.retry(echo)
        try await settle { timeline.sendStates.isEmpty }
        let records = SendWire.captured()
        let posts = records.filter { $0.request.url?.path.hasSuffix("/messages") == true }
        XCTAssertEqual(posts.count, 2)
        let bodies = try posts.map { try JSONDecoder().decode([String: JSONValue].self, from: $0.body) }
        XCTAssertEqual(bodies.first, bodies.last, "A safe retry retains the original nonce, text, reply, ping and attachment names")
        XCTAssertEqual(records.filter { $0.request.httpMethod == "PUT" }.map(\.body), [file.data, file.data])
        XCTAssertEqual(model.drafts[channel], current)
        XCTAssertEqual(timeline.messages.map(\.id), [server.id])
    }

    func testAccountAndSameAccountStoreResetFenceOrdinarySendCompletionAndRetry() async throws {
        for changeAccount in [false, true] {
            let model = fixture([.init(error: URLError(.timedOut), held: true)])
            model.drafts[channel] = Draft(text: "old session")
            model.send(in: channel)
            let timeline = model.timeline(for: channel)
            let echo = try XCTUnwrap(timeline.messages.last)
            try await settle { SendWire.captured().count == 1 }
            var ready = MockDiscord().readyPayload()
            if changeAccount { ready.user.id = 999 }
            model.store.apply(ready: ready)
            SendWire.release()
            try await Task.sleep(for: .milliseconds(100))
            model.retry(echo)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(SendWire.captured().count, 1, "Old session cannot retry against a new store/account")
            XCTAssertEqual(timeline.sendState(for: echo), .sending, "Old completion must not publish into the new session")
        }
    }


    func testEmptyReadbackRemainsUnknownAndDoesNotAuthorizeReplay() async throws {
        let model = fixture([.init(error: URLError(.timedOut)), .init(body: "[]"), .init(body: "[]")])
        model.drafts[channel] = Draft(text: "maybe sent")
        let task = try XCTUnwrap(model.send(in: channel))
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        let initial = await task.value
        XCTAssertEqual(initial, false)
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Lost response is unknown") }
        let first = try XCTUnwrap(model.retry(echo)); let firstResult = await first.value; XCTAssertEqual(firstResult, false)
        let second = try XCTUnwrap(model.retry(echo)); let secondResult = await second.value; XCTAssertEqual(secondResult, false)
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Page absence is not a refusal") }
        XCTAssertEqual(SendWire.captured().map { $0.request.httpMethod }, ["POST", "GET", "GET"])
        XCTAssertEqual(t.messages.map(\.id), [echo.id])
    }

    func testCancellationBeforeDispatchRetainsSafeRetryWithOriginalIdentity() async throws {
        let model = fixture([])
        model.drafts[channel] = Draft(text: "cancel locally")
        let task = try XCTUnwrap(model.send(in: channel))
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, false)
        XCTAssertTrue(SendWire.captured().isEmpty)
        guard case .notDispatched = t.sendState(for: echo) else { return XCTFail("Proven non-dispatch remains safe to retry") }
        var server = accepted(echo); server.nonce = nil // HTTP confirmation need not echo nonce
        SendWire.append([.init(body: String(decoding: try JSONEncoder().encode(server), as: UTF8.self))])
        let retry = try XCTUnwrap(model.retry(echo)); let result = await retry.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(t.messages.map(\.id), [server.id])
        XCTAssertEqual(t.messages.last?.nonce, echo.nonce)
        XCTAssertTrue(t.sendStates.isEmpty)
    }

    func testCancellationAfterDispatchStaysUnknown() async throws {
        let model = fixture([.init(held: true)])
        model.drafts[channel] = Draft(text: "cancel on wire")
        let task = try XCTUnwrap(model.send(in: channel))
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        try await settle { SendWire.captured().count == 1 }
        task.cancel(); let result = await task.value
        XCTAssertEqual(result, false)
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Cancellation cannot retract a dispatched POST") }
        try await gateway(model, accepted(echo))
        XCTAssertTrue(t.sendStates.isEmpty)
    }

    func testOverallDeadlineCoversReservationUploadAndFinalHTTP() async throws {
        let slots = #"{"attachments":[{"id":0,"upload_url":"https://offline.invalid/upload","upload_filename":"slot/file.txt"}]}"#
        let scripts: [[SendWire.Stub]] = [
            [.init(body: slots, held: true)],
            [.init(body: slots), .init(held: true)],
            [.init(body: slots), .init(), .init(held: true)]
        ]
        for (index, script) in scripts.enumerated() {
            let model = fixture(script)
            model.outgoingSendTimeout = .milliseconds(120)
            model.drafts[channel] = Draft(text: "deadline", attachments: [DraftAttachment(filename: "file.txt", data: Data([1, 2, 3]), contentType: "text/plain")])
            let began = ContinuousClock.now
            let task = try XCTUnwrap(model.send(in: channel))
            let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
            let result = await task.value
            XCTAssertEqual(result, false)
            XCTAssertLessThan(began.duration(to: .now), .seconds(2), "Must cancel and join the real transport")
            XCTAssertEqual(SendWire.captured().count, index + 1)
            if index == 2 {
                guard case .unknown = t.sendState(for: echo) else { XCTFail("Final POST deadline is uncertain"); continue }
            } else {
                guard case .notDispatched = t.sendState(for: echo) else { XCTFail("Upload does not dispatch a message"); continue }
            }
            XCTAssertEqual(t.messages.last?.attachments.first?.filename, "file.txt")
        }
    }

    func testBucketAdmissionDeadlineAndCancellationNeverDispatchSecondMessage() async throws {
        for cancel in [false, true] {
            let model = fixture([.init(held: true)])
            model.drafts[channel] = Draft(text: "occupy bucket")
            let first = try XCTUnwrap(model.send(in: channel))
            try await settle { SendWire.captured().count == 1 }
            model.outgoingSendTimeout = .milliseconds(100)
            model.drafts[channel] = Draft(text: "wait in queue")
            let second = try XCTUnwrap(model.send(in: channel))
            let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
            if cancel { try await Task.sleep(for: .milliseconds(30)); second.cancel() }
            let result = await second.value
            XCTAssertEqual(result, false)
            guard case .notDispatched = t.sendState(for: echo) else { XCTFail("Admission never dispatched this message"); continue }
            XCTAssertEqual(SendWire.captured().count, 1)
            first.cancel(); _ = await first.value
        }
    }

    func testGlobalRateLimitWaitCountsAgainstWholeActionDeadline() async throws {
        let model = fixture([.init(body: #"{"retry_after":30,"global":true}"#, status: 429)])
        model.drafts[channel] = Draft(text: "rate limited")
        let first = try XCTUnwrap(model.send(in: channel)); _ = await first.value
        let refused = try XCTUnwrap(model.timeline(for: channel).messages.last)
        guard case .failed = model.timeline(for: channel).sendState(for: refused) else { return XCTFail("429 is an explicit refusal") }
        model.outgoingSendTimeout = .milliseconds(100)
        let retry = try XCTUnwrap(model.retry(refused)); _ = await retry.value
        guard case .notDispatched = model.timeline(for: channel).sendState(for: refused) else { return XCTFail("Retry waited but never dispatched") }
        XCTAssertEqual(SendWire.captured().count, 1)
    }

    func testStoreResetDuringUploadPreventsFinalMessagePOST() async throws {
        let slots = #"{"attachments":[{"id":0,"upload_url":"https://offline.invalid/upload","upload_filename":"slot/file.txt"}]}"#
        let model = fixture([.init(body: slots, held: true)])
        model.drafts[channel] = Draft(text: "old upload", attachments: [DraftAttachment(filename: "file.txt", data: Data([42]), contentType: "text/plain")])
        let task = try XCTUnwrap(model.send(in: channel))
        try await settle { SendWire.captured().count == 1 }
        model.store.apply(ready: MockDiscord().readyPayload())
        SendWire.release()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(SendWire.captured().count, 1, "Old reservation cannot authorize an upload or final POST")
    }

    func testReadbackCannotPublishAcrossStoreReset() async throws {
        let model = fixture([.init(error: URLError(.timedOut))])
        model.drafts[channel] = Draft(text: "old readback")
        let task = try XCTUnwrap(model.send(in: channel)); _ = await task.value
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        SendWire.append([.init(body: try json([accepted(echo)]), held: true)])
        let check = try XCTUnwrap(model.retry(echo))
        try await settle { SendWire.captured().count == 2 }
        model.store.apply(ready: MockDiscord().readyPayload())
        SendWire.release(); _ = await check.value
        XCTAssertEqual(t.messages.map(\.id), [echo.id])
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Stale read cannot settle a send") }
    }

    func testReadbackDeadlineLeavesUncertaintyAndReleasesCoalescingSlot() async throws {
        let model = fixture([.init(error: URLError(.timedOut)), .init(held: true), .init(body: "[]")])
        model.outgoingReadbackTimeout = .milliseconds(100)
        model.drafts[channel] = Draft(text: "bounded read")
        let task = try XCTUnwrap(model.send(in: channel)); _ = await task.value
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        let check = try XCTUnwrap(model.retry(echo)); _ = await check.value
        let again = try XCTUnwrap(model.retry(echo)); _ = await again.value
        XCTAssertEqual(SendWire.captured().map { $0.request.httpMethod }, ["POST", "GET", "GET"])
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Read failure preserves uncertainty") }
    }


    func testUnknownGatewayConfirmationPreservesOlderHistoryWindow() async throws {
        let model = fixture([.init(error: URLError(.timedOut))])
        model.drafts[channel] = Draft(text: "send before jump")
        let task = try XCTUnwrap(model.send(in: channel)); _ = await task.value
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        let history = (100...149).map { id in
            Message(id: Snowflake(UInt64(id)), channelID: channel, guildID: nil, author: model.store.me!, content: "history", timestamp: "")
        }
        SendWire.append([.init(body: try json(history))])
        await t.load(around: 125, api: model.api, store: model.store)
        XCTAssertTrue(t.hasMoreAfter)
        XCTAssertEqual(t.messages.last?.id, echo.id)
        try await gateway(model, accepted(echo))
        try await gateway(model, accepted(echo))
        XCTAssertEqual(t.messages.map(\.id), history.map(\.id), "Confirmation must not splice latest history into an older window")
        XCTAssertTrue(t.sendStates.isEmpty)
        XCTAssertNil(model.retry(echo))
        XCTAssertEqual(SendWire.captured().filter { $0.request.httpMethod == "POST" }.count, 1)
    }

    func testReadbackRequiresMatchingAccountAndChannelNotJustNonce() async throws {
        let model = fixture([.init(error: URLError(.timedOut))])
        model.drafts[channel] = Draft(text: "correlate safely")
        let task = try XCTUnwrap(model.send(in: channel)); _ = await task.value
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        var wrongAccount = accepted(echo); wrongAccount.author.id = 999
        var wrongChannel = accepted(echo); wrongChannel.channelID = 999
        SendWire.append([.init(body: try json([wrongAccount, wrongChannel]))])
        let check = try XCTUnwrap(model.retry(echo)); let result = await check.value
        XCTAssertEqual(result, false)
        XCTAssertEqual(t.messages.map(\.id), [echo.id])
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Unrelated messages cannot establish delivery") }
    }

    func testUnknownReadbackRequiresCurrentHistoryAccess() async throws {
        let model = fixture([.init(error: URLError(.timedOut))])
        model.drafts[channel] = Draft(text: "no history access")
        let task = try XCTUnwrap(model.send(in: channel)); _ = await task.value
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        var changed = try XCTUnwrap(model.store.channel(channel))
        changed.permissionOverwrites = [PermissionOverwrite(id: changed.guildID!, type: 0, allow: "0", deny: String(Permission.readHistory))]
        model.store.upsert(channel: changed)
        let check = try XCTUnwrap(model.retry(echo)); let result = await check.value
        XCTAssertNil(result)
        XCTAssertEqual(SendWire.captured().count, 1)
        guard case .unknown = t.sendState(for: echo) else { return XCTFail("Lack of read access cannot establish refusal") }
    }

    func testOrdinarySendCapturesAuthorityBeforePendingPublication() async throws {
        for changeAccount in [false, true] {
            let model = fixture([])
            let t = model.timeline(for: channel)
            var changed = false
            let observer = t.observe { change in
                guard case .appended = change, !changed else { return }
                changed = true
                var ready = MockDiscord().readyPayload()
                if changeAccount { ready.user.id = 999 }
                model.store.apply(ready: ready)
            }
            model.drafts[channel] = Draft(text: "old authority")
            let task = try XCTUnwrap(model.send(in: channel)); let result = await task.value
            t.stopObserving(observer)
            XCTAssertTrue(changed)
            XCTAssertNil(result)
            XCTAssertTrue(SendWire.captured().isEmpty, "Pending publication must not transfer send authority to a new session")
        }
    }

    func testSuccessfulHTTPFromOldAccountCannotConfirmIntoNewStore() async throws {
        let model = fixture([.init(held: true)])
        model.drafts[channel] = Draft(text: "old success")
        let task = try XCTUnwrap(model.send(in: channel))
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        try await settle { SendWire.captured().count == 1 }
        // Replace the held server response without starting a second operation.
        let response = String(decoding: try JSONEncoder().encode(accepted(echo)), as: UTF8.self)
        SendWire.lock.withLock { SendWire.held[0].1.body = response }
        var ready = MockDiscord().readyPayload(); ready.user.id = 999
        model.store.apply(ready: ready)
        SendWire.release(); let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(t.messages.map(\.id), [echo.id])
        XCTAssertEqual(t.sendState(for: echo), .sending)
        XCTAssertNil(model.retry(echo))
    }

    func testDeadlineDoesNotRestartBetweenReservationAndUpload() async throws {
        let slots = #"{"attachments":[{"id":0,"upload_url":"https://offline.invalid/upload","upload_filename":"slot/file.txt"}]}"#
        let model = fixture([.init(body: slots, held: true), .init(held: true)])
        model.outgoingSendTimeout = .milliseconds(300)
        model.drafts[channel] = Draft(text: "one action clock", attachments: [DraftAttachment(filename: "file.txt", data: Data([42]), contentType: "text/plain")])
        let began = ContinuousClock.now
        let task = try XCTUnwrap(model.send(in: channel))
        try await settle { SendWire.captured().count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        SendWire.release()
        let result = await task.value
        XCTAssertEqual(result, false)
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(450), "Upload receives only the action's remaining time")
        XCTAssertEqual(SendWire.captured().map { $0.request.httpMethod }, ["POST", "PUT"])
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        guard case .notDispatched = t.sendState(for: echo) else { return XCTFail("Deadline during upload is still before the message POST") }
    }


    func testDiscardCancelsLocalTransportButCannotRemoveConfirmedHistory() async throws {
        let model = fixture([.init(held: true)])
        model.drafts[channel] = Draft(text: "remove local echo")
        let task = try XCTUnwrap(model.send(in: channel))
        let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
        try await settle { SendWire.captured().count == 1 }
        model.discard(echo)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(t.messages.isEmpty)
        XCTAssertTrue(t.sendStates.isEmpty)
        let server = accepted(echo)
        try await gateway(model, server) // cancellation cannot retract a server commit
        model.discard(server)
        XCTAssertEqual(t.messages.map(\.id), [server.id], "Local echo removal never deletes confirmed history")
        XCTAssertEqual(SendWire.captured().count, 1)
    }


    func testPreConnectionFailureRemainsSafeToRetryWithOriginalNonce() async throws {
        let codes: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed]
        for code in codes {
            // This URL Loading System error establishes no connection was
            // made; unlike the lost-response fixture there is no server commit.
            let model = fixture([.init(error: URLError(code))])
            model.drafts[channel] = Draft(text: "offline but retained")
            let first = try XCTUnwrap(model.send(in: channel)); _ = await first.value
            let t = model.timeline(for: channel), echo = try XCTUnwrap(model.timeline(for: channel).messages.last)
            guard case .notDispatched = t.sendState(for: echo) else { XCTFail("Pre-connection failure must stay usable: \(code)"); continue }
            let server = accepted(echo)
            SendWire.append([.init(body: String(decoding: try JSONEncoder().encode(server), as: UTF8.self))])
            let retry = try XCTUnwrap(model.retry(echo)); let result = await retry.value
            XCTAssertEqual(result, true)
            let bodies = try SendWire.captured().map { try JSONDecoder().decode([String: JSONValue].self, from: $0.body) }
            XCTAssertEqual(bodies.count, 2, "Only explicit retry sends after connectivity returns")
            XCTAssertEqual(bodies.first, bodies.last, "Logical identity and payload survive a proven non-dispatch")
            XCTAssertTrue(t.sendStates.isEmpty)
        }
    }

}
