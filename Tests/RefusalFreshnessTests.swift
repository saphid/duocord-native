import XCTest
@testable import DuocordNative

nonisolated private final class FreshnessWire: URLProtocol, @unchecked Sendable {
    struct Stub { var body: String; var status = 200; var held = false; var headers: [String: String] = [:] }
    static let lock = NSLock()
    static var routes: [String: [Stub]] = [:]
    static var requests: [URLRequest] = []
    static var pending: [(FreshnessWire, Stub)] = []
    static func reset(_ routes: [String: [Stub]]) { lock.withLock { self.routes = routes; requests = []; pending = [] } }
    static func put(_ key: String, _ stubs: [Stub]) { lock.withLock { routes[key] = stubs } }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    static func release() {
        let old = lock.withLock { let old = pending; pending = []; return old }
        for (wire, stub) in old { wire.deliver(stub) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.lock.withLock { () -> Stub? in
            Self.requests.append(request)
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let stub = Self.routes[key]?.isEmpty == false ? Self.routes[key]!.removeFirst() : Stub(body: "unexpected offline route", status: 599)
            if stub.held { Self.pending.append((self, stub)); return nil }
            return stub
        }
        if let stub { deliver(stub) }
    }
    func deliver(_ stub: Stub) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.pending.removeAll { $0.0 === self } } }
}

@MainActor
final class RefusalFreshnessTests: XCTestCase {
    private var channel: Snowflake { MockDiscord.generalChannel }
    private func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func fixture(code: Int = 50013, deny: UInt64 = 0, held: Bool = false) throws -> AppModel {
        let rest = DiscordREST(credentials: SessionCredentials(token: "offline-freshness", superProperties: nil, userAgent: "FreshnessTests"), protocolClasses: [FreshnessWire.self])
        let model = AppModel(notificationAPI: rest)
        var ready = MockDiscord().readyPayload()
        ready.guilds[0].ownerID = 999999
        let bits = Permission.viewChannel | Permission.sendMessages | Permission.readHistory | Permission.attachFiles | Permission.addReactions
        for i in ready.guilds[0].roles.indices { ready.guilds[0].roles[i].permissions = String(bits) }
        for i in ready.mergedMembers[0].indices where ready.mergedMembers[0][i].userID == ready.user.id { ready.mergedMembers[0][i].roles = [] }
        model.store.apply(ready: ready)
        var current = model.store.channel(channel)!
        current.permissionOverwrites = []; current.rateLimitPerUser = 0
        model.store.upsert(channel: current)
        var refreshed = current
        refreshed.permissionOverwrites = [PermissionOverwrite(id: current.guildID!, type: 0, allow: "0", deny: String(deny))]
        let guild = model.store.guilds[current.guildID!]!
        FreshnessWire.reset([
            "POST /api/v9/channels/\(channel)/messages": [.init(body: "{\"code\":\(code),\"message\":\"original refusal\"}", status: 403)],
            "GET /api/v9/channels/\(channel)": [.init(body: try encoded(refreshed), held: held)],
            "GET /api/v9/guilds/\(guild.id)": [.init(body: try encoded(guild))],
            "GET /api/v9/guilds/\(guild.id)/roles": [.init(body: try encoded(guild.roles))],
            "GET /api/v9/guilds/\(guild.id)/members/\(ready.user.id)": [.init(body: try encoded(model.store.member(ready.user.id, in: guild.id)!))]
        ])
        return model
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Offline freshness seam did not settle"); throw URLError(.timedOut)
    }
    func testRefusedReplyUsesFreshPayloadRequirementAndNeverReplays() async throws {
        let model = try fixture(deny: Permission.readHistory)
        let reply = Message(id: 44, channelID: channel, guildID: nil, author: model.store.me!, content: "reply", timestamp: "")
        model.drafts[channel] = Draft(text: "retain reply", replyTo: reply)
        let task = try XCTUnwrap(model.send(in: channel))
        _ = await task.value
        let timeline = model.timeline(for: channel)
        let echo = try XCTUnwrap(timeline.messages.last)
        if case .failed(let text) = timeline.sendState(for: echo) { XCTAssertTrue(text.contains("Read Message History")) } else { XCTFail("Expected known refusal") }
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.context.nonce, echo.nonce)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "GET" }.count, 4)
        XCTAssertTrue(model.store.canView(model.store.channel(channel)!))
    }
    func testMissingAccessNeverEvictsReadableHistoryAndRefreshes() async throws {
        let model = try fixture(code: 50001)
        let history = mine(model); model.timeline(for: channel).seed([history])
        model.drafts[channel] = Draft(text: "hello")
        _ = await model.send(in: channel)?.value
        XCTAssertNotNil(model.store.channel(channel))
        XCTAssertTrue(model.store.canView(model.store.channel(channel)!))
        XCTAssertTrue(model.timeline(for: channel).messages.contains { $0.id == history.id })
        XCTAssertNil(model.capabilityFreshness.lastRefusal?.decision)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "GET" }.count, 4)
    }
    override func tearDown() { FreshnessWire.release(); super.tearDown() }
    private func event(_ model: AppModel, _ name: String, _ json: String) {
        model.store.handle(GatewayDispatch(name: name, data: Data(("{\"d\":" + json + "}").utf8)))
    }
    private func readCount(_ suffix: String) -> Int { FreshnessWire.captured().filter { $0.httpMethod == "GET" && $0.url!.path.hasSuffix(suffix) }.count }
    private func context(_ model: AppModel, _ operation: DiscordOperation = .send(MessagePayloadFeatures())) -> OperationContext {
        OperationContext(operation: operation, channel: channel, author: model.store.me!.id, text: "original payload")
    }
    private var original: DiscordError { .api(status: 403, code: 50013, message: "raw original refusal") }

    func testUnexplainedRefusalKeepsRawResponseAndOperation() async throws {
        let model = try fixture()
        let refusalValue = await model.attributeRefusal(original, context: context(model))
        let refusal = try XCTUnwrap(refusalValue)
        XCTAssertNil(refusal.decision)
        XCTAssertEqual(refusal.freshness, .refreshed)
        if case .api(let status, let code, let message) = refusal.original { XCTAssertEqual(status, 403); XCTAssertEqual(code, 50013); XCTAssertEqual(message, "raw original refusal") } else { XCTFail("Lost raw response") }
        XCTAssertEqual(refusal.context.text, "original payload")
        XCTAssertEqual(refusal.context.author, model.store.me!.id)
        XCTAssertFalse(refusal.explanation.contains("View Channel"))
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod != "GET" }.count, 0)
    }
    func testActualFileFeaturesAndOwnershipAreRetainedForAttribution() async throws {
        let model = try fixture(deny: Permission.attachFiles)
        var attempted = context(model, .send(MessagePayloadFeatures(fileCount: 1)))
        attempted.files = [OutgoingAttachment(filename: "kept.bin", data: Data([1,2,3]), contentType: "application/octet-stream")]
        attempted.reply = 88; attempted.ping = false
        let refusalValue = await model.attributeRefusal(original, context: attempted)
        let refusal = try XCTUnwrap(refusalValue)
        XCTAssertTrue(refusal.explanation.contains("Attach Files"))
        XCTAssertEqual(refusal.context.files.first?.data, Data([1,2,3]))
        XCTAssertEqual(refusal.context.reply, 88); XCTAssertEqual(refusal.context.ping, false)
        XCTAssertTrue(refusal.decision?.provenance.contains(.refreshedFacts) == true)
    }
    func testFailedReadRetainsOriginalKnownRefusal() async throws {
        let model = try fixture()
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: "read failed", status: 503)])
        let refusalValue = await model.attributeRefusal(original, context: context(model))
        let refusal = try XCTUnwrap(refusalValue)
        XCTAssertEqual(refusal.original.httpStatus, 403)
        XCTAssertEqual(refusal.freshness, .incomplete)
        XCTAssertNil(refusal.decision)
        XCTAssertFalse(refusal.explanation.contains("503"))
    }
    func testExpiredReadRetainsRefusalAndNeverSendsAgain() async throws {
        let model = try fixture(held: true)
        model.capabilityRefreshTimeout = .milliseconds(100)
        model.drafts[channel] = Draft(text: "one attempt")
        let start = ContinuousClock.now
        _ = await model.send(in: channel)?.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.original.httpStatus, 403)
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.freshness, .expired)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" }.count, 1)
        FreshnessWire.release()
    }
    func testUnknownCodeIsRecoverableWithoutAttributionReads() async throws {
        let model = try fixture(code: 987654)
        model.drafts[channel] = Draft(text: "unknown code")
        _ = await model.send(in: channel)?.value
        let refusal = try XCTUnwrap(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(refusal.freshness, .unnecessary)
        XCTAssertTrue(refusal.explanation.contains("987654"))
        XCTAssertEqual(FreshnessWire.captured().count, 1)
    }
    func testConcurrentExactScopeRefreshCoalesces() async throws {
        let model = try fixture(held: true)
        let a = model.refreshEligibility(in: channel), b = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        XCTAssertTrue(model.capabilityFreshness.isRefreshing(channel: channel, scope: model.operationScope))
        FreshnessWire.release(); await a.value; await b.value
        XCTAssertEqual(FreshnessWire.captured().count, 4)
        XCTAssertFalse(model.capabilityFreshness.isRefreshing(channel: channel, scope: model.operationScope))
    }
    func testShorterJoiningDeadlineIncludesSharedQueueWait() async throws {
        let model = try fixture(held: true)
        let a = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        let start = ContinuousClock.now
        let result = await model.capabilityFreshness.refresh(channel: channel, model: model, until: .now + .milliseconds(50))
        XCTAssertEqual(result, .expired)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        FreshnessWire.release(); await a.value
        XCTAssertEqual(FreshnessWire.captured().count, 4)
    }
    func testSiblingChannelsCoalesceExactGuildReads() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        var sibling = model.store.channel(channel)!; sibling.id = 9091
        model.store.upsert(channel: sibling)
        FreshnessWire.put("GET /api/v9/channels/9091", [.init(body: try encoded(sibling))])
        FreshnessWire.put("GET /api/v9/guilds/\(guild)", [.init(body: try encoded(model.store.guilds[guild]!), held: true)])
        let a = model.refreshEligibility(in: channel), b = model.refreshEligibility(in: sibling.id)
        try await wait { self.readCount("/guilds/\(guild)") == 1 && self.readCount("/channels/9091") == 1 }
        FreshnessWire.release(); await a.value; await b.value
        XCTAssertEqual(readCount("/guilds/\(guild)"), 1)
        XCTAssertEqual(readCount("/guilds/\(guild)/roles"), 1)
        XCTAssertEqual(readCount("/guilds/\(guild)/members/\(model.store.me!.id)"), 1)
        XCTAssertEqual(FreshnessWire.captured().count, 5)
    }
    func testChannelOverwriteEventDuringReadWins() async throws {
        let model = try fixture(held: true)
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        var latest = model.store.channel(channel)!
        latest.permissionOverwrites = [PermissionOverwrite(id: latest.guildID!, type: 0, allow: "0", deny: String(Permission.sendMessages))]
        event(model, "CHANNEL_UPDATE", try encoded(latest))
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.channel(channel)?.permissionOverwrites, latest.permissionOverwrites)
    }
    func testRoleEventDuringRoleReadWins() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/roles", [.init(body: try encoded(model.store.guilds[guild]!.roles), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/roles") == 1 }
        var role = model.store.guilds[guild]!.roles.first { $0.id == guild }!
        role.permissions = String(Permission.viewChannel)
        event(model, "GUILD_ROLE_UPDATE", "{\"guild_id\":\"\(guild)\",\"role\":\(try encoded(role))}")
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.role(guild, in: guild)?.permissions, role.permissions)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel).state, .denied)
    }
    func testMemberEventDuringMemberReadWins() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!, me = model.store.me!.id
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/members/\(me)", [.init(body: try encoded(model.store.member(me, in: guild)!), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/members/\(me)") == 1 }
        event(model, "GUILD_MEMBER_UPDATE", "{\"guild_id\":\"\(guild)\",\"user\":{\"id\":\"\(me)\",\"username\":\"me\"},\"communication_disabled_until\":\"2099-01-01T00:00:00Z\"}")
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.member(me, in: guild)?.communicationDisabledUntil, "2099-01-01T00:00:00Z")
    }
    func testDiscoveredParentEventDuringEarlierRootReadWins() async throws {
        let model = try fixture()
        var root = model.store.channel(channel)!
        root.type = .publicThread; root.parentID = 9191; root.threadMetadata = ThreadMetadata(archived: false, locked: false)
        var cachedRoot = root; cachedRoot.parentID = nil
        var ready = MockDiscord().readyPayload()
        let rootIndex = ready.guilds[0].channels.firstIndex { $0.id == channel }!
        ready.guilds[0].channels[rootIndex] = cachedRoot
        model.store.apply(ready: ready)
        XCTAssertEqual(model.operationDecision(.viewChannel, in: channel).state, .unknown)
        var parent = Channel(id: 9191, type: .text, guildID: root.guildID)
        parent.permissionOverwrites = []; parent.rateLimitPerUser = 0
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: try encoded(root), held: true)])
        FreshnessWire.put("GET /api/v9/channels/9191", [.init(body: try encoded(parent))])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        parent.permissionOverwrites = [PermissionOverwrite(id: root.guildID!, type: 0, allow: "0", deny: String(Permission.sendInThreads))]
        event(model, "CHANNEL_UPDATE", try encoded(parent))
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.channel(9191)?.permissionOverwrites, parent.permissionOverwrites)
        XCTAssertEqual(readCount("/channels/9191"), 1)
    }
    func testChannelDeletionTombstonePreventsResurrection() async throws {
        let model = try fixture(held: true)
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        event(model, "CHANNEL_DELETE", "{\"id\":\"\(channel)\"}")
        FreshnessWire.release(); await task.value
        XCTAssertNil(model.store.channel(channel))
        // Even a new explicit refresh cannot resurrect an event-deleted channel.
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: try encoded(Channel(id: channel, type: .dm)))])
        await model.refreshEligibility(in: channel).value
        XCTAssertNil(model.store.channel(channel))
    }
    func testGuildDeletionDuringGuildReadCannotResurrectGuildOrChannels() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        FreshnessWire.put("GET /api/v9/guilds/\(guild)", [.init(body: try encoded(model.store.guilds[guild]!), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/guilds/\(guild)") == 1 }
        event(model, "GUILD_DELETE", "{\"id\":\"\(guild)\"}")
        FreshnessWire.release(); await task.value
        XCTAssertNil(model.store.guilds[guild]); XCTAssertNil(model.store.channel(channel))
    }
    func testGuildRefreshDoesNotReplaceUnrelatedChannelEvent() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        var oldGuild = model.store.guilds[guild]!
        oldGuild.channels = [Channel(id: 9898, type: .text, guildID: guild, name: "stale response")]
        FreshnessWire.put("GET /api/v9/guilds/\(guild)", [.init(body: try encoded(oldGuild), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/guilds/\(guild)") == 1 }
        let unrelated = Channel(id: 9898, type: .text, guildID: guild, name: "gateway survives")
        event(model, "CHANNEL_CREATE", try encoded(unrelated))
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.channel(9898)?.name, "gateway survives")
    }
    func testSameAccountReadyResetFencesHeldReadAndFeedback() async throws {
        let model = try fixture(held: true)
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        let oldEpoch = model.store.readEpoch
        model.store.apply(ready: MockDiscord().readyPayload())
        let expected = model.store.channel(channel)
        FreshnessWire.release(); await task.value
        XCTAssertNotEqual(model.store.readEpoch, oldEpoch)
        XCTAssertEqual(model.store.channel(channel), expected)
        XCTAssertNil(model.toast)
    }
    func testAccountSwitchFencesRefusalPublication() async throws {
        let model = try fixture(held: true)
        model.drafts[channel] = Draft(text: "old account")
        let task = try XCTUnwrap(model.send(in: channel))
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        var next = MockDiscord().readyPayload(); next.user.id = 989898
        model.store.apply(ready: next)
        FreshnessWire.release(); _ = await task.value
        XCTAssertNil(model.capabilityFreshness.lastRefusal)
        XCTAssertNil(model.toast)
    }
    func testUnknownMemberRefreshPreservesDraftAndFilesRequiresExplicitSend() async throws {
        let model = try fixture()
        var ready = MockDiscord().readyPayload(); ready.mergedMembers = []
        model.store.apply(ready: ready)
        var current = model.store.channel(channel)!; current.permissionOverwrites = []; current.rateLimitPerUser = 0; model.store.upsert(channel: current)
        let file = DraftAttachment(filename: "keep.txt", data: Data([1,2,3]), contentType: "text/plain")
        model.drafts[channel] = Draft(text: "keep draft", attachments: [file])
        let before = model.drafts[channel]
        XCTAssertTrue(model.composerCapability(in: channel).canRefresh)
        XCTAssertNil(model.send(in: channel))
        XCTAssertEqual(model.drafts[channel], before)
        await model.refreshEligibility(in: channel).value
        XCTAssertEqual(model.drafts[channel], before)
        XCTAssertTrue(model.composerCapability(in: channel).canSubmit)
        XCTAssertTrue(FreshnessWire.captured().allSatisfy { $0.httpMethod == "GET" })
        // Only a later explicit tap uploads the retained file and sends.
        FreshnessWire.put("POST /api/v9/channels/\(channel)/attachments", [.init(body: "{\"attachments\":[{\"id\":0,\"upload_url\":\"https://offline.invalid/upload\",\"upload_filename\":\"slot/keep.txt\"}]}")])
        FreshnessWire.put("PUT /upload", [.init(body: "")])
        var accepted = mine(model); accepted.id = 1_000_000_000_000_000_099; accepted.content = "keep draft"
        FreshnessWire.put("POST /api/v9/channels/\(channel)/messages", [.init(body: try encoded(accepted))])
        let task = try XCTUnwrap(model.send(in: channel))
        let applied = await task.value
        XCTAssertEqual(applied, true)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/messages") }.count, 1)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "PUT" }.count, 1)
    }
    func testDedicatedReplyCodeOnlyRefreshesRelevantOperation() async throws {
        let model = try fixture(deny: Permission.readHistory)
        let error = DiscordError.api(status: 403, code: 160002, message: "reply refused")
        let plainValue = await model.attributeRefusal(error, context: context(model))
        let plain = try XCTUnwrap(plainValue)
        XCTAssertEqual(plain.freshness, .unnecessary); XCTAssertTrue(FreshnessWire.captured().isEmpty)
        let replyValue = await model.attributeRefusal(error, context: context(model, .send(MessagePayloadFeatures(isReply: true))))
        let reply = try XCTUnwrap(replyValue)
        XCTAssertTrue(reply.explanation.contains("Read Message History"))
        XCTAssertEqual(reply.context.operation, .send(MessagePayloadFeatures(isReply: true)))
    }
    func testLocalPreflightRefusalDoesNotRefresh() async throws {
        let model = try fixture()
        let feedback = OperationFeedback(context(model), model: model)
        await feedback.capture(CapabilityPreflightRefusal(), model: model)
        XCTAssertNil(feedback.refusal); XCTAssertTrue(FreshnessWire.captured().isEmpty)
    }
    func testAddedReadSeamsFailClosedForMockTransport() async throws {
        let mock = MockDiscord()
        do { _ = try await mock.guild(1); XCTFail("Mock must not invent guild facts") } catch { }
        do { _ = try await mock.guildRoles(1); XCTFail("Mock must not invent roles") } catch { }
        do { _ = try await mock.guildMember(1, in: 1); XCTFail("Mock must not invent membership") } catch { }
        do { _ = try await mock.ownThreadMember(1, account: 1); XCTFail("Mock must not invent thread membership") } catch { }
    }

    private func mine(_ model: AppModel) -> Message {
        Message(id: 12345, channelID: channel, guildID: model.store.channel(channel)?.guildID, author: model.store.me!, content: "original", timestamp: "")
    }
    private func refusalStub() -> FreshnessWire.Stub { .init(body: "{\"code\":50013,\"message\":\"original action refusal\"}", status: 403) }
    func testRealWireEditRefusalRetainsTextAndOwnershipAndAttributes() async throws {
        let model = try fixture(deny: Permission.viewChannel)
        let row = mine(model); model.timeline(for: channel).seed([row])
        FreshnessWire.put("PATCH /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.beginEdit(row); model.drafts[channel]?.text = "actually edited"
        model.saveEdit(in: channel)
        try await wait { model.toast != nil }
        XCTAssertTrue(model.toast?.text.contains("View Channel") == true)
        let refusal = try XCTUnwrap(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(refusal.context.operation, .editMessage)
        XCTAssertEqual(refusal.context.text, "actually edited")
        XCTAssertEqual(refusal.context.author, row.author.id)
        XCTAssertEqual(refusal.context.message, row.id)
        XCTAssertEqual(model.timeline(for: channel).messages.first?.content, "original")
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "PATCH" }.count, 1)
    }
    func testRealWireDeleteRefusalRestoresRowAndAttributes() async throws {
        let model = try fixture(deny: Permission.viewChannel)
        let row = mine(model); model.timeline(for: channel).seed([row])
        FreshnessWire.put("DELETE /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.delete(row)
        try await wait { model.toast != nil }
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.context.operation, .deleteMessage)
        XCTAssertEqual(model.timeline(for: channel).messages.map(\.id), [row.id])
        XCTAssertTrue(model.toast?.text.contains("View Channel") == true)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "DELETE" }.count, 1)
    }
    func testRealWireReactionRefusalUsesActualNewEmojiOperation() async throws {
        let model = try fixture(deny: Permission.addReactions)
        let row = mine(model), emoji = Emoji(id: nil, name: "🦑", animated: false)
        model.timeline(for: channel).seed([row])
        FreshnessWire.put("PUT /api/v9/channels/\(channel)/messages/\(row.id)/reactions/🦑/@me", [refusalStub()])
        model.react(emoji, add: true, message: row.id, channel: channel)
        try await wait { model.toast != nil }
        XCTAssertTrue(model.toast?.text.contains("Add Reactions") == true)
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.context.operation, .addReaction)
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.context.emoji, emoji)
        XCTAssertTrue(model.timeline(for: channel).messages.first!.reactions.isEmpty)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.url!.path.hasSuffix("/messages") }.count, 0, "Known refusal must not trigger uncertain reaction reconciliation")
    }
    func testGatewaySendConfirmationDuringAttributionWins() async throws {
        let model = try fixture(held: true)
        model.drafts[channel] = Draft(text: "gateway confirms during attribution")
        let task = try XCTUnwrap(model.send(in: channel))
        let timeline = model.timeline(for: channel)
        let echo = try XCTUnwrap(timeline.messages.last)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        var sent = echo; sent.id = 1_000_000_000_000_000_010
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(["d": sent])))
        FreshnessWire.release()
        let result = await task.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(timeline.messages.map(\.id), [sent.id]); XCTAssertTrue(timeline.sendStates.isEmpty)
        XCTAssertNil(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testGatewayEditConfirmationDuringAttributionWinsWithoutToast() async throws {
        let model = try fixture(held: true)
        let row = mine(model); model.timeline(for: channel).seed([row])
        FreshnessWire.put("PATCH /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.beginEdit(row); model.drafts[channel]?.text = "confirmed edit"; model.saveEdit(in: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        await model.handle(GatewayDispatch(name: "MESSAGE_UPDATE", data: Data("{\"d\":{\"id\":\"\(row.id)\",\"channel_id\":\"\(channel)\",\"content\":\"confirmed edit\",\"edited_timestamp\":\"2099-01-01T00:00:00Z\"}}".utf8)))
        FreshnessWire.release()
        try await wait { !model.capabilityFreshness.isRefreshing(channel: self.channel, scope: model.operationScope) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.timeline(for: channel).messages.first?.content, "confirmed edit")
        XCTAssertNil(model.toast); XCTAssertNil(model.capabilityFreshness.lastRefusal)
    }
    func testGatewayDeleteConfirmationDuringAttributionWinsWithoutToast() async throws {
        let model = try fixture(held: true)
        let row = mine(model); model.timeline(for: channel).seed([row])
        FreshnessWire.put("DELETE /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.delete(row)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        await model.handle(GatewayDispatch(name: "MESSAGE_DELETE", data: Data("{\"d\":{\"id\":\"\(row.id)\",\"channel_id\":\"\(channel)\"}}".utf8)))
        FreshnessWire.release()
        try await wait { !model.capabilityFreshness.isRefreshing(channel: self.channel, scope: model.operationScope) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.timeline(for: channel).messages.isEmpty)
        XCTAssertNil(model.toast); XCTAssertNil(model.capabilityFreshness.lastRefusal)
    }
    func testNavigationAwayAndBackSuppressesLateActionToast() async throws {
        let model = try fixture(held: true)
        let row = mine(model); model.timeline(for: channel).seed([row]); model.selectedChannel = channel
        FreshnessWire.put("DELETE /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.delete(row)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        model.selectedChannel = nil; model.selectedChannel = channel
        FreshnessWire.release()
        try await wait { !model.capabilityFreshness.isRefreshing(channel: self.channel, scope: model.operationScope) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.toast); XCTAssertNil(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(model.timeline(for: channel).messages.map(\.id), [row.id])
    }
    func testNewActionSuppressesOldFailureFeedback() async throws {
        let model = try fixture(held: true)
        let row = mine(model); model.timeline(for: channel).seed([row])
        FreshnessWire.put("DELETE /api/v9/channels/\(channel)/messages/\(row.id)", [refusalStub()])
        model.delete(row)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        // A later intent owns feedback even if it completes while the earlier
        // attribution is still held. The failed delete still rolls back safely.
        _ = OperationFeedback(context(model, .editMessage), model: model)
        FreshnessWire.release()
        try await wait { !model.capabilityFreshness.isRefreshing(channel: self.channel, scope: model.operationScope) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.toast)
    }
    func testMembershipWireAndGatewayLeaveDuringHeldReadWins() async throws {
        let model = try fixture()
        let parent = model.store.channel(channel)!
        var thread = Channel(id: 9092, type: .privateThread, guildID: parent.guildID, parentID: channel)
        thread.ownerID = 98989; thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread)
        FreshnessWire.put("GET /api/v9/channels/9092", [.init(body: try encoded(thread))])
        FreshnessWire.put("GET /api/v9/channels/9092/thread-members/@me", [.init(body: "{\"id\":\"9092\",\"user_id\":\"\(model.store.me!.id)\",\"join_timestamp\":\"2026-01-01T00:00:00Z\",\"flags\":0}", held: true)])
        let task = model.refreshEligibility(in: thread.id)
        try await wait { self.readCount("/thread-members/@me") == 1 }
        event(model, "THREAD_MEMBERS_UPDATE", "{\"id\":\"9092\",\"guild_id\":\"\(parent.guildID!)\",\"removed_member_ids\":[\"\(model.store.me!.id)\"]}")
        FreshnessWire.release(); await task.value
        XCTAssertFalse(model.store.joinedThreads.contains(thread.id))
        XCTAssertEqual(model.operationDecision(.viewChannel, in: thread.id).state, .denied)
        XCTAssertTrue(FreshnessWire.captured().allSatisfy { $0.httpMethod == "GET" })
    }
    func testGuildOwnerEventDuringGuildReadWins() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        FreshnessWire.put("GET /api/v9/guilds/\(guild)", [.init(body: try encoded(model.store.guilds[guild]!), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/guilds/\(guild)") == 1 }
        event(model, "GUILD_UPDATE", "{\"id\":\"\(guild)\",\"owner_id\":\"\(model.store.me!.id)\"}")
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.guilds[guild]?.ownerID, model.store.me!.id)
    }
    func testDeletedRoleAndRemovedMemberDuringHeldReadsStayAbsent() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!, me = model.store.me!.id
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/roles", [.init(body: try encoded(model.store.guilds[guild]!.roles), held: true)])
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/members/\(me)", [.init(body: try encoded(model.store.member(me, in: guild)!), held: true)])
        let task = model.refreshEligibility(in: channel)
        try await wait { self.readCount("/roles") == 1 }
        event(model, "GUILD_ROLE_DELETE", "{\"guild_id\":\"\(guild)\",\"role_id\":\"\(guild)\"}")
        FreshnessWire.release()
        try await wait { self.readCount("/members/\(me)") == 1 }
        event(model, "GUILD_MEMBER_REMOVE", "{\"guild_id\":\"\(guild)\",\"user\":{\"id\":\"\(me)\",\"username\":\"me\"}}")
        FreshnessWire.release(); await task.value
        XCTAssertNil(model.store.role(guild, in: guild)); XCTAssertNil(model.store.member(me, in: guild))
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel).state, .unknown)
    }
    func testRealWirePinRefusalKeepsOptimismAndGatewayAuthority() async throws {
        // AppModel deliberately forbids non-Mock pin writes in DEBUG. Exercise
        // its exact timeline/capture seam against production REST without
        // weakening that shipping guard.
        let model = try fixture(held: true)
        let row = mine(model); let timeline = model.timeline(for: channel); timeline.seed([row])
        FreshnessWire.put("PUT /api/v9/channels/\(channel)/messages/pins/\(row.id)", [refusalStub()])
        let feedback = OperationFeedback(OperationContext(operation: .pinMessage, channel: channel, message: row.id, author: row.author.id), model: model)
        let task = try XCTUnwrap(timeline.sendPin(row.id, pinned: true, api: model.api, failure: { error in await feedback.capture(error, model: model) }, completion: { applied in if !applied { feedback.publish("pin failed", model: model) } }))
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        timeline.update(MessageUpdate(id: row.id, channelID: channel, pinned: true))
        FreshnessWire.release()
        let applied = await task.value
        XCTAssertTrue(applied); XCTAssertEqual(timeline.messages.first?.pinned, true)
        XCTAssertNil(model.toast)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "PUT" }.count, 1)
    }
    func testAppModelMockPinRefusalKeepsOriginalAndDoesNotReplay() async throws {
        let mock = MockDiscord()
        // Use the injected concrete mock for the DEBUG action authorization.
        let actual = AppModel(peopleAPI: mock)
        actual.store.apply(ready: mock.readyPayload())
        let row = mine(actual); actual.timeline(for: channel).seed([row])
        mock.beforePin = { _ in throw DiscordError.api(status: 403, code: 50013, message: "mock original pin refusal") }
        let task = try XCTUnwrap(actual.setPinned(true, message: row))
        let applied = await task.value
        XCTAssertFalse(applied)
        XCTAssertEqual(actual.capabilityFreshness.lastRefusal?.context.operation, .pinMessage)
        XCTAssertEqual(actual.capabilityFreshness.lastRefusal?.original.httpStatus, 403)
        XCTAssertEqual(mock.pinOperations.count, 1)
        XCTAssertFalse(actual.timeline(for: channel).messages.first!.pinned)
    }

    func testAttributionReadRateLimitWaitIsInsideTotalBudget() async throws {
        let model = try fixture()
        model.capabilityRefreshTimeout = .milliseconds(100)
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: "{\"retry_after\":10,\"global\":false}", status: 429)])
        model.drafts[channel] = Draft(text: "one write only")
        let start = ContinuousClock.now
        _ = await model.send(in: channel)?.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.original.httpStatus, 403)
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.freshness, .expired)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "GET" }.count, 1)
    }
    func testFailedAttributionReadNeverTurnsKnownSendRefusalIntoUncertainWrite() async throws {
        let model = try fixture()
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: "read network failed", status: 503)])
        model.drafts[channel] = Draft(text: "keep original refusal")
        _ = await model.send(in: channel)?.value
        let row = try XCTUnwrap(model.timeline(for: channel).messages.last)
        guard case .failed = model.timeline(for: channel).sendState(for: row) else { return XCTFail("Read failure changed a known-refused outcome") }
        XCTAssertEqual(model.capabilityFreshness.lastRefusal?.original.httpStatus, 403)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testIncompleteGuildAndMemberFactsStayUnknown() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!, me = model.store.me!.id
        FreshnessWire.put("GET /api/v9/guilds/\(guild)", [.init(body: "{\"id\":\"\(guild)\"}")])
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/members/\(me)", [.init(body: "{\"user\":{\"id\":\"\(me)\",\"username\":\"me\"}}")])
        let result = await model.capabilityFreshness.refresh(channel: channel, model: model)
        XCTAssertEqual(result, .incomplete)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel).state, .unknown)
    }
    func testEmptyRolesResponseDoesNotInventEveryonePermissions() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!
        FreshnessWire.put("GET /api/v9/guilds/\(guild)/roles", [.init(body: "[]")])
        await model.refreshEligibility(in: channel).value
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel).state, .unknown)
    }
    func testSuccessfulAddedReadRoutesHaveExactScopeAndDecodeProductionBodies() async throws {
        let model = try fixture()
        let guild = model.store.channel(channel)!.guildID!, me = model.store.me!.id
        FreshnessWire.put("GET /api/v9/channels/9092/thread-members/@me", [.init(body: "{\"id\":\"9092\",\"user_id\":\"\(me)\",\"join_timestamp\":\"2026-01-01T00:00:00Z\",\"flags\":1}")])
        let gotGuild = try await model.api.guild(guild)
        let roles = try await model.api.guildRoles(guild)
        let member = try await model.api.guildMember(me, in: guild)
        let threadMember = try await model.api.ownThreadMember(9092, account: me)
        XCTAssertEqual(gotGuild.id, guild); XCTAssertNotNil(gotGuild.ownerID)
        XCTAssertTrue(roles.contains { $0.id == guild }); XCTAssertEqual(member.userID, me); XCTAssertTrue(member.rolesKnown)
        XCTAssertEqual(threadMember.flags, 1)
        XCTAssertEqual(FreshnessWire.captured().map { $0.url!.path }, ["/api/v9/guilds/\(guild)", "/api/v9/guilds/\(guild)/roles", "/api/v9/guilds/\(guild)/members/\(me)", "/api/v9/channels/9092/thread-members/@me"])
        XCTAssertTrue(FreshnessWire.captured().allSatisfy { $0.httpMethod == "GET" })
    }
    func testThreadMembershipMismatchedIdentityFailsClosed() async throws {
        let model = try fixture()
        FreshnessWire.put("GET /api/v9/channels/9092/thread-members/@me", [.init(body: "{\"id\":\"9092\",\"user_id\":\"999\",\"join_timestamp\":\"2026-01-01T00:00:00Z\"}")])
        do { _ = try await model.api.ownThreadMember(9092, account: model.store.me!.id); XCTFail("Wrong account membership") } catch { }
    }
    func testThreadMembershipAuthoritativeAbsenceCanResolveUnknown() async throws {
        let model = try fixture()
        let parent = model.store.channel(channel)!
        var thread = Channel(id: 9092, type: .privateThread, guildID: parent.guildID, parentID: channel)
        thread.ownerID = 98989; thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread)
        FreshnessWire.put("GET /api/v9/channels/9092", [.init(body: try encoded(thread))])
        FreshnessWire.put("GET /api/v9/channels/9092/thread-members/@me", [.init(body: "{\"code\":10007,\"message\":\"Unknown Member\"}", status: 404)])
        XCTAssertEqual(model.operationDecision(.viewChannel, in: thread.id).state, .unknown)
        await model.refreshEligibility(in: thread.id).value
        XCTAssertEqual(model.operationDecision(.viewChannel, in: thread.id).state, .denied)
        XCTAssertFalse(model.store.joinedThreads.contains(thread.id))
    }
    func testThreadDedicatedStateRefusalUsesFreshThreadFactsWithoutWrite() async throws {
        let model = try fixture()
        let parent = model.store.channel(channel)!
        var thread = Channel(id: 9092, type: .publicThread, guildID: parent.guildID, parentID: channel)
        thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread)
        var fresh = thread; fresh.threadMetadata?.archived = true
        FreshnessWire.put("GET /api/v9/channels/9092", [.init(body: try encoded(fresh))])
        let refusalValue = await model.attributeRefusal(DiscordError.api(status: 400, code: 50083, message: "thread archived"), context: OperationContext(operation: .send(MessagePayloadFeatures()), channel: thread.id))
        let refusal = try XCTUnwrap(refusalValue)
        XCTAssertTrue(refusal.decision?.reasons.contains(.threadArchived) == true)
        XCTAssertTrue(refusal.decision?.provenance.contains(.refreshedFacts) == true)
        XCTAssertTrue(FreshnessWire.captured().allSatisfy { $0.httpMethod == "GET" })
    }
    func testAppModelThreadCodedRefusalRetainsActualPatchAndNoReplay() async throws {
        let mock = MockDiscord()
        let actual = AppModel(peopleAPI: mock)
        actual.store.apply(ready: mock.readyPayload())
        let id = MockDiscord.ThreadFixture.hinge
        mock.beforeThreadWrite = { _ in throw DiscordError.api(status: 403, code: 50013, message: "original thread refusal") }
        await actual.perform(.rename("requested name"), on: id).value
        let refusal = try XCTUnwrap(actual.capabilityFreshness.lastRefusal)
        XCTAssertEqual(refusal.context.operation, .thread(.rename("requested name")))
        XCTAssertEqual(refusal.original.httpStatus, 403)
        XCTAssertEqual(mock.threadOperations.count, 1)
        XCTAssertEqual(mock.threadOperations.first?.fields, ["name": .string("requested name")])
        XCTAssertNotEqual(actual.store.channel(id)?.name, "requested name")
    }
    func testAppModelThreadGatewayConfirmationBeforeRefusalWins() async throws {
        let mock = MockDiscord()
        let model = AppModel(peopleAPI: mock); model.store.apply(ready: mock.readyPayload())
        let id = MockDiscord.ThreadFixture.hinge
        mock.beforeThreadWrite = { _ in
            await MainActor.run {
                var thread = model.store.channel(id)!; thread.name = "confirmed name"
                model.store.upsert(channel: thread)
            }
            throw DiscordError.api(status: 403, code: 50013, message: "late refusal")
        }
        await model.perform(.rename("confirmed name"), on: id).value
        XCTAssertNil(model.toast); XCTAssertNil(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(model.store.channel(id)?.name, "confirmed name")
        XCTAssertEqual(mock.threadOperations.count, 1)
    }

    func testGatewayReactionConfirmationDuringAttributionWinsWithoutToast() async throws {
        let model = try fixture(held: true)
        let row = mine(model), emoji = Emoji(id: nil, name: "🦑", animated: false)
        model.timeline(for: channel).seed([row])
        FreshnessWire.put("PUT /api/v9/channels/\(channel)/messages/\(row.id)/reactions/🦑/@me", [refusalStub()])
        model.react(emoji, add: true, message: row.id, channel: channel)
        try await wait { self.readCount("/channels/\(self.channel)") == 1 }
        await model.handle(GatewayDispatch(name: "MESSAGE_REACTION_ADD", data: Data("{\"d\":{\"channel_id\":\"\(channel)\",\"message_id\":\"\(row.id)\",\"user_id\":\"\(model.store.me!.id)\",\"emoji\":{\"name\":\"🦑\"}}}".utf8)))
        FreshnessWire.release()
        try await wait { !model.capabilityFreshness.isRefreshing(channel: self.channel, scope: model.operationScope) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.timeline(for: channel).messages.first?.reactions.first?.me, true)
        XCTAssertNil(model.toast); XCTAssertNil(model.capabilityFreshness.lastRefusal)
        XCTAssertEqual(FreshnessWire.captured().filter { $0.httpMethod == "PUT" }.count, 1)
    }
    func testThreadUpdateDuringHeldRootReadWins() async throws {
        let model = try fixture()
        let parent = model.store.channel(channel)!
        var thread = Channel(id: 9092, type: .publicThread, guildID: parent.guildID, parentID: channel)
        thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread)
        FreshnessWire.put("GET /api/v9/channels/9092", [.init(body: try encoded(thread), held: true)])
        let task = model.refreshEligibility(in: thread.id)
        try await wait { self.readCount("/channels/9092") == 1 }
        thread.threadMetadata = ThreadMetadata(archived: true, locked: true)
        event(model, "THREAD_UPDATE", try encoded(thread))
        FreshnessWire.release(); await task.value
        XCTAssertEqual(model.store.channel(thread.id)?.threadMetadata, thread.threadMetadata)
    }

    func testAttributionRetainsAccountHypothesisWithoutClaimingItExplainsRefusal() async throws {
        let model = try fixture()
        var voice = model.store.channel(channel)!; voice.type = .voice
        model.store.upsert(channel: voice)
        FreshnessWire.put("GET /api/v9/channels/\(channel)", [.init(body: try encoded(voice))])
        let value = await model.attributeRefusal(original, context: context(model))
        let refusal = try XCTUnwrap(value)
        XCTAssertEqual(refusal.freshness, .refreshed)
        XCTAssertNil(refusal.decision)
        XCTAssertTrue(refusal.evaluation?.reasons.contains(.accountValidationRequired(.voiceTextConnect)) == true)
        XCTAssertTrue(refusal.evaluation?.provenance.contains(.accountHypothesis) == true)
        XCTAssertFalse(refusal.explanation.contains("unverified")); XCTAssertFalse(refusal.explanation.contains("Connect"))
        XCTAssertNotNil(refusal.facts)
    }

}
