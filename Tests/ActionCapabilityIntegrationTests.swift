import XCTest
@testable import DuocordNative

/// Catch-all offline endpoint, including unplanned reconciliation reads.
nonisolated private final class ActionWire: URLProtocol, @unchecked Sendable {
    struct Stub { var body = ""; var held = false }
    static let lock = NSLock()
    static var script: [Stub] = []
    static var records: [URLRequest] = []
    static var held: [(ActionWire, Stub)] = []
    static func reset(_ stubs: [Stub]) { lock.withLock { script = stubs; records = []; held = [] } }
    static func captured() -> [URLRequest] { lock.withLock { records } }
    static func release() {
        let pending = lock.withLock { let pending = held; held = []; return pending }
        for (wire, stub) in pending { wire.deliver(stub) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.lock.withLock { () -> Stub? in
            Self.records.append(request)
            let stub = Self.script.isEmpty ? Stub(body: "Unexpected offline request") : Self.script.removeFirst()
            if stub.held { Self.held.append((self, stub)); return nil }
            return stub
        }
        if let stub { deliver(stub) }
    }
    func deliver(_ stub: Stub) {
        let status = stub.body == "Unexpected offline request" ? 599 : stub.body.isEmpty ? 204 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.held.removeAll { $0.0 === self } } }
}

@MainActor
final class ActionCapabilityIntegrationTests: XCTestCase {
    private func fixture(bits: UInt64 = Permission.viewChannel | Permission.sendMessages | Permission.readHistory, api: DiscordAPI? = nil) -> (AppModel, Channel) {
        let mock = MockDiscord()
        var ready = mock.readyPayload()
        ready.guilds[0].ownerID = 999999
        for index in ready.guilds[0].roles.indices { ready.guilds[0].roles[index].permissions = String(bits) }
        let model = api.map { AppModel(notificationAPI: $0) } ?? AppModel(peopleAPI: mock)
        model.store.apply(ready: ready)
        var channel = model.store.channel(MockDiscord.generalChannel)!
        channel.permissionOverwrites = []; channel.rateLimitPerUser = 0
        model.store.upsert(channel: channel)
        return (model, channel)
    }
    private func mine(_ model: AppModel, _ channel: Channel) -> Message {
        Message(id: 900, channelID: channel.id, guildID: channel.guildID, author: model.store.me!, content: "original", timestamp: "")
    }
    private func timeout(_ model: AppModel, _ channel: Channel, stamp: String = "2099-01-01T00:00:00Z") {
        let payload = "{\"d\":{\"guild_id\":\"\(channel.guildID!)\",\"user\":{\"id\":\"\(model.store.me!.id)\",\"username\":\"me\"},\"communication_disabled_until\":\"\(stamp)\"}}"
        model.store.handle(GatewayDispatch(name: "GUILD_MEMBER_UPDATE", data: Data(payload.utf8)))
    }

    func testBlockedAttachmentSendRetainsActualDraftAndDoesNotEnqueue() {
        let (model, channel) = fixture()
        model.drafts[channel.id] = Draft(text: "keep me", attachments: [DraftAttachment(filename: "a.txt", data: Data([1]), contentType: "text/plain")])
        let before = model.drafts[channel.id]
        model.send(in: channel.id)
        XCTAssertEqual(model.drafts[channel.id], before)
        XCTAssertTrue(model.timeline(for: channel.id).messages.isEmpty)
    }

    func testSendRechecksPermissionAfterAffordanceWasRead() {
        let (model, channel) = fixture()
        XCTAssertTrue(model.store.canSend(in: channel))
        var changed = channel
        changed.permissionOverwrites = [PermissionOverwrite(id: channel.guildID!, type: 0, allow: "0", deny: String(Permission.sendMessages))]
        model.store.upsert(channel: changed)
        model.drafts[channel.id] = Draft(text: "keep after permission change")
        model.send(in: channel.id)
        XCTAssertEqual(model.drafts[channel.id]?.text, "keep after permission change")
        XCTAssertTrue(model.timeline(for: channel.id).messages.isEmpty)
    }

    func testBlockedSaveKeepsEditAndStashedDraft() {
        let (model, channel) = fixture()
        let row = mine(model, channel)
        model.timeline(for: channel.id).seed([row])
        model.drafts[channel.id] = Draft(text: "stashed")
        model.beginEdit(row); model.drafts[channel.id]?.text = "changed"
        timeout(model, channel)
        model.saveEdit(in: channel.id)
        XCTAssertEqual(model.drafts[channel.id]?.editing?.id, row.id)
        XCTAssertEqual(model.drafts[channel.id]?.text, "changed")
        XCTAssertEqual(model.timeline(for: channel.id).messages.first?.content, "original")
        model.cancelEdit(in: channel.id)
        XCTAssertEqual(model.drafts[channel.id]?.text, "stashed")
    }

    func testUnknownGuildCannotDeleteOptimistically() {
        let (model, channel) = fixture()
        let row = mine(model, channel)
        model.timeline(for: channel.id).seed([row])
        var unknown = channel; unknown.guildID = 999999
        model.store.upsert(channel: unknown)
        model.delete(row)
        XCTAssertEqual(model.timeline(for: channel.id).messages.map(\.id), [row.id])
    }

    func testOwnDeleteSurvivesTimeoutAndArchivedThread() {
        let (model, channel) = fixture()
        timeout(model, channel)
        var thread = Channel(id: 990, type: .publicThread, guildID: channel.guildID, parentID: channel.id)
        thread.threadMetadata = ThreadMetadata(archived: true, locked: true)
        model.store.upsert(channel: thread)
        XCTAssertTrue(model.store.capability(.deleteMessage, in: channel, messageAuthorID: model.store.me!.id).isAllowed)
        let archived = model.operationDecision(.deleteMessage, in: thread.id, messageAuthorID: model.store.me!.id)
        XCTAssertEqual(archived.state, .unknown, "Archived own-delete is an account hypothesis, not a bot-derived hard refusal")
        XCTAssertTrue(model.permitsExplicitAttempt(.deleteMessage, decision: archived))
        XCTAssertEqual(model.store.capability(.deleteMessage, in: thread, messageAuthorID: 888).state, .denied)
    }

    func testStaleAdministratorTimeoutDoesNotDenySend() {
        let (model, channel) = fixture(bits: Permission.administrator)
        timeout(model, channel)
        XCTAssertTrue(model.store.capability(.send(MessagePayloadFeatures()), in: channel).isAllowed)
    }

    func testTimedOutPrivateThreadManagerDoesNotBypassMembership() {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.manageThreads | Permission.readHistory)
        timeout(model, channel)
        var thread = Channel(id: 990, type: .privateThread, guildID: channel.guildID, parentID: channel.id)
        thread.ownerID = 888; thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread); model.store.setThreadMembership(thread.id, joined: false)
        XCTAssertFalse(model.store.capability(.viewChannel, in: thread).isAllowed)
    }

    private func client(_ script: [ActionWire.Stub]) -> DiscordREST {
        ActionWire.reset(script)
        return DiscordREST(credentials: SessionCredentials(token: "offline-action-fixture", superProperties: nil, userAgent: "ActionRegression"), protocolClasses: [ActionWire.self])
    }
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Offline action seam did not settle")
        throw URLError(.timedOut)
    }
    private func deny(_ bits: UInt64, model: AppModel, channel: Channel) {
        var changed = channel
        changed.permissionOverwrites = [PermissionOverwrite(id: channel.guildID!, type: 0, allow: "0", deny: String(bits))]
        model.store.upsert(channel: changed)
    }
    override func tearDown() { ActionWire.release(); super.tearDown() }

    func testComposerUsesActualTextReplyAndFilePayloadWithoutRequiringAttachFilesForText() {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.sendMessages)
        model.drafts[channel.id] = Draft(text: "plain text")
        XCTAssertTrue(model.composerCapability(in: channel.id).canSubmit)
        XCTAssertFalse(model.composerCapability(in: channel.id).canAttachFiles)
        model.drafts[channel.id]?.attachments = [DraftAttachment(filename: "a", data: Data([1]), contentType: "text/plain")]
        XCTAssertFalse(model.composerCapability(in: channel.id).canSubmit)
        XCTAssertTrue(model.composerCapability(in: channel.id).explanation?.contains("Attach Files") == true)
        model.drafts[channel.id]?.attachments = []
        model.drafts[channel.id]?.replyTo = mine(model, channel)
        XCTAssertFalse(model.composerCapability(in: channel.id).canSubmit)
        XCTAssertTrue(model.composerCapability(in: channel.id).explanation?.contains("Read Message History") == true)
        model.drafts[channel.id]?.replyTo = nil
        XCTAssertTrue(model.composerCapability(in: channel.id).canSubmit)
        XCTAssertEqual(model.composerCapability(in: channel.id).decision, model.operationDecision(model.draftOperation(model.drafts[channel.id]!, in: channel.id), in: channel.id))
    }

    func testComposerAndPreflightTimeoutExpiryAtExactBoundary() {
        let (model, channel) = fixture()
        model.drafts[channel.id] = Draft(text: "after timeout")
        timeout(model, channel, stamp: "1970-01-01T00:20:00Z")
        let before = Date(timeIntervalSince1970: 1199), boundary = Date(timeIntervalSince1970: 1200)
        XCTAssertFalse(model.composerCapability(in: channel.id, now: before).canSubmit)
        XCTAssertTrue(model.composerCapability(in: channel.id, now: before).explanation?.contains("1s") == true)
        XCTAssertFalse(model.preflight(.send(MessagePayloadFeatures()), in: channel.id, now: before))
        XCTAssertTrue(model.composerCapability(in: channel.id, now: boundary).canSubmit)
        XCTAssertTrue(model.preflight(.send(MessagePayloadFeatures()), in: channel.id, now: boundary))
        XCTAssertEqual(model.drafts[channel.id]?.text, "after timeout")
    }

    func testConfirmedSendEvidenceIsAccountExactChannelScopedAndExpires() throws {
        let (model, original) = fixture()
        var channel = original; channel.rateLimitPerUser = 30; channel.lastMessageID = 123
        model.store.upsert(channel: channel)
        model.drafts[channel.id] = Draft(text: "slowmode")
        let scope = try XCTUnwrap(model.operationScope), now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id, now: now).state, .unknown)
        model.noteConfirmedSend(in: channel.id, author: 444, at: now, scope: scope)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id, now: now).state, .unknown)
        model.noteConfirmedSend(in: 555, author: scope.account, at: now, scope: scope)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id, now: now).state, .unknown)
        model.noteConfirmedSend(in: channel.id, author: scope.account, at: now, scope: scope)
        XCTAssertFalse(model.composerCapability(in: channel.id, now: now.addingTimeInterval(29)).canSubmit)
        XCTAssertTrue(model.composerCapability(in: channel.id, now: now.addingTimeInterval(30)).canSubmit)
        model.noteConfirmedSend(in: channel.id, author: scope.account, at: now.addingTimeInterval(-10), scope: scope)
        XCTAssertFalse(model.composerCapability(in: channel.id, now: now.addingTimeInterval(29)).canSubmit, "late older confirmation cannot shorten cooldown")
        model.store.apply(ready: MockDiscord().readyPayload()); model.store.upsert(channel: channel)
        model.noteConfirmedSend(in: channel.id, author: scope.account, at: now, scope: scope)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id, now: now).state, .unknown, "old-store confirmation cannot establish new-store evidence")
    }

    func testUnknownSlowmodeAloneAllowsExplicitSendWithoutClaimingAllowed() async throws {
        let (model, original) = fixture()
        var channel = original; channel.rateLimitPerUser = 30
        model.store.upsert(channel: channel); model.drafts[channel.id] = Draft(text: "explicit attempt")
        let availability = model.composerCapability(in: channel.id)
        XCTAssertEqual(availability.decision.state, .unknown)
        XCTAssertTrue(availability.canSubmit)
        XCTAssertNotNil(availability.explanation)
        let task = try XCTUnwrap(model.send(in: channel.id))
        let sent = await task.value
        XCTAssertEqual(sent, true)
        XCTAssertEqual(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id).state, .denied, "positive HTTP confirmation records slowmode evidence")
    }

    func testUnresolvedGuildMemberParentAndChannelCannotPassDispatch() {
        let (model, channel) = fixture()
        var missingGuild = channel; missingGuild.guildID = 999999
        model.store.upsert(channel: missingGuild); model.drafts[channel.id] = Draft(text: "keep")
        XCTAssertFalse(model.composerCapability(in: channel.id).canSubmit)
        XCTAssertNil(model.send(in: channel.id))
        XCTAssertEqual(model.drafts[channel.id]?.text, "keep")
        var thread = Channel(id: 990, type: .publicThread, guildID: channel.guildID, parentID: 999999)
        thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        model.store.upsert(channel: thread)
        XCTAssertFalse(model.preflight(.send(MessagePayloadFeatures()), in: thread.id))
        XCTAssertEqual(model.operationDecision(.deleteMessage, in: 1234).reasons, [.missing(.channel)])
        var ready = MockDiscord().readyPayload(); ready.mergedMembers = []
        model.store.apply(ready: ready)
        XCTAssertFalse(model.preflight(.send(MessagePayloadFeatures()), in: channel.id))
        XCTAssertTrue(model.operationDecision(.send(MessagePayloadFeatures()), in: channel.id).reasons.contains(.missing(.member)))
    }

    func testReactionVariantsTimeoutAndForeignOwnershipAreDistinct() {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.readHistory)
        XCTAssertEqual(model.operationDecision(.addReaction, in: channel.id).state, .denied)
        XCTAssertTrue(model.operationDecision(.addExistingReaction, in: channel.id).isAllowed)
        timeout(model, channel)
        XCTAssertEqual(model.operationDecision(.addExistingReaction, in: channel.id).state, .denied)
        deny(Permission.readHistory, model: model, channel: channel)
        XCTAssertTrue(model.operationDecision(.removeOwnReaction, in: channel.id).isAllowed)
        XCTAssertTrue(model.operationDecision(.deleteMessage, in: channel.id, messageAuthorID: model.store.me!.id).isAllowed)
        XCTAssertEqual(model.operationDecision(.editMessage, in: channel.id, messageAuthorID: 888).state, .denied)
        XCTAssertEqual(model.operationDecision(.deleteMessage, in: channel.id, messageAuthorID: 888).state, .denied)
    }

    func testExistingReactionDispatchAndOwnRemovalPreservePermissionVariants() async throws {
        let (model, channel) = fixture(api: client([.init(), .init()]))
        let emoji = Emoji(id: nil, name: "👍", animated: false)
        var row = mine(model, channel); row.reactions = [Reaction(count: 2, me: false, emoji: emoji)]
        let timeline = model.timeline(for: channel.id); timeline.seed([row])
        model.react(emoji, add: true, message: row.id, channel: channel.id)
        try await settle { timeline.reactionConfirmations[row.id] == 1 }
        XCTAssertEqual(ActionWire.captured().map(\.httpMethod), ["PUT"])
        timeout(model, channel); deny(Permission.readHistory, model: model, channel: channel)
        model.react(emoji, add: false, message: row.id, channel: channel.id)
        try await settle { timeline.reactionConfirmations[row.id] == 2 }
        XCTAssertEqual(ActionWire.captured().map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(timeline.messages.first?.reactions.first?.me, false)
        let new = Emoji(id: nil, name: "🦑", animated: false)
        model.react(new, add: true, message: row.id, channel: channel.id)
        XCTAssertFalse(timeline.messages[0].reactions.contains { $0.emoji.reactionKey == new.reactionKey })
        XCTAssertEqual(ActionWire.captured().count, 2)
    }

    func testReactionPermissionFlipBeforeDispatchDoesNotWriteOrReadback() async throws {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.readHistory | Permission.addReactions, api: client([]))
        let emoji = Emoji(id: nil, name: "👍", animated: false), row = mine(model, channel)
        let timeline = model.timeline(for: channel.id); timeline.seed([row])
        model.react(emoji, add: true, message: row.id, channel: channel.id)
        XCTAssertFalse(timeline.messages[0].reactions.isEmpty)
        deny(Permission.addReactions, model: model, channel: channel)
        try await settle { timeline.messages[0].reactions.isEmpty }
        XCTAssertTrue(ActionWire.captured().isEmpty, "local refusal cannot trigger uncertain-outcome GET")
        XCTAssertTrue(model.toast?.text.contains("Add Reactions") == true)
    }

    func testQueuedReactionReevaluatesExistingAfterLastOwnRemoval() async throws {
        let (model, channel) = fixture(api: client([.init(held: true)]))
        let emoji = Emoji(id: nil, name: "👍", animated: false)
        var row = mine(model, channel); row.reactions = [Reaction(count: 1, me: true, emoji: emoji)]
        let timeline = model.timeline(for: channel.id); timeline.seed([row])
        model.react(emoji, add: false, message: row.id, channel: channel.id)
        try await settle { ActionWire.captured().count == 1 }
        model.react(emoji, add: true, message: row.id, channel: channel.id)
        ActionWire.release()
        try await settle { timeline.messages[0].reactions.isEmpty && model.toast != nil }
        XCTAssertEqual(ActionWire.captured().map(\.httpMethod), ["DELETE"], "after removing the last reaction, re-add needs Add Reactions")
        XCTAssertTrue(model.toast?.text.contains("Add Reactions") == true)
    }

    func testQueuedEditRechecksEligibilityAndKeepsFirstConfirmedResult() async throws {
        let base = fixture(), row = mine(base.0, base.1)
        var response = row; response.content = "first"; response.editedTimestamp = "2026-11-01T00:00:01Z"
        let body = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let (model, channel) = fixture(api: client([.init(body: body, held: true)]))
        let timeline = model.timeline(for: channel.id); timeline.seed([row])
        model.beginEdit(row); model.drafts[channel.id]?.text = "first"; model.saveEdit(in: channel.id)
        try await settle { ActionWire.captured().count == 1 }
        model.beginEdit(timeline.messages[0]); model.drafts[channel.id]?.text = "second"; model.saveEdit(in: channel.id)
        deny(Permission.viewChannel, model: model, channel: channel)
        ActionWire.release()
        try await settle { timeline.messages[0].content == "first" && model.toast != nil }
        XCTAssertEqual(ActionWire.captured().count, 1)
        XCTAssertTrue(model.toast?.text.contains("View Channel") == true)
    }

    func testPinsRecheckEachPageWithoutChanging103PinPager() async throws {
        let (model, channel) = fixture()
        let owner = OtherListState<String, Message, String>()
        var calls = 0
        let row = mine(model, channel)
        await OtherListConsumers.pins(owner, input: "pins", api: model.api, channel: channel.id, store: model.store, isCurrent: { true }, fetch: { _ in
            calls += 1
            return PinPage(items: [PinPage.Item(message: row, pinnedAt: "2026-11-01T00:00:00Z")], hasMore: true)
        }).value
        XCTAssertEqual(owner.snapshot(for: "pins").rows.count, 1)
        deny(Permission.readHistory, model: model, channel: channel)
        await owner.loadMore("pins")?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(owner.snapshot(for: "pins").rows.count, 1)
        guard case .failed(let error) = owner.snapshot(for: "pins").more else { return XCTFail("page must explain the missing permission") }
        XCTAssertTrue(error.contains("Read Message History"))
    }

    func testThreadJoinAndLeaveUnderTimeoutUseMembershipContract() async throws {
        let (model, channel) = fixture()
        timeout(model, channel)
        let id = MockDiscord.ThreadFixture.bookPose
        XCTAssertTrue(model.operationDecision(.thread(.join), in: id).isAllowed)
        await model.perform(.join, on: id).value
        XCTAssertTrue(model.store.isJoined(thread: id))
        XCTAssertTrue(model.operationDecision(.thread(.leave), in: id).isAllowed)
        await model.perform(.leave, on: id).value
        XCTAssertFalse(model.store.isJoined(thread: id))
        XCTAssertEqual(model.operationDecision(.thread(.rename("changed")), in: id).state, .denied)
    }

    func testVoiceTextWithoutConnectRemainsExplicitAccountHypothesis() {
        let (model, original) = fixture()
        for type: ChannelType in [.voice, .stage] {
            var channel = original; channel.type = type
            model.store.upsert(channel: channel); model.drafts[channel.id] = Draft(text: "voice text")
            let decision = model.composerCapability(in: channel.id)
            XCTAssertEqual(decision.decision.state, .unknown)
            XCTAssertTrue(decision.decision.reasons.contains(.accountValidationRequired(.voiceTextConnect)))
            XCTAssertFalse(decision.canSubmit)
            XCTAssertTrue(decision.explanation?.contains("moderator") == true)
            XCTAssertFalse(decision.explanation?.contains("unverified") == true)
        }
    }

    func testRetainedFilePayloadRechecksAfterUploadBeforeMessagePost() async throws {
        let slots = #"{"attachments":[{"id":0,"upload_url":"https://offline.invalid/upload","upload_filename":"slot/file.txt"}]}"#
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.sendMessages | Permission.readHistory | Permission.attachFiles,
                                      api: client([.init(body: slots), .init(held: true)]))
        let file = DraftAttachment(filename: "file.txt", data: Data([1, 2, 3]), contentType: "text/plain")
        model.drafts[channel.id] = Draft(text: "original payload", attachments: [file])
        let task = try XCTUnwrap(model.send(in: channel.id))
        let timeline = model.timeline(for: channel.id), echo = try XCTUnwrap(model.timeline(for: channel.id).messages.last)
        try await settle { ActionWire.captured().count == 2 }
        model.drafts[channel.id] = Draft(text: "new plain-text draft")
        deny(Permission.attachFiles, model: model, channel: channel)
        XCTAssertTrue(model.composerCapability(in: channel.id).canSubmit, "the new plain draft remains independently usable")
        ActionWire.release()
        let sent = await task.value
        XCTAssertEqual(sent, false)
        guard case .notDispatched = timeline.sendState(for: echo) else { return XCTFail("eligibility changed before final POST") }
        XCTAssertTrue(ActionWire.captured().allSatisfy { $0.url?.path.hasSuffix("/messages") != true })
        XCTAssertEqual(model.drafts[channel.id]?.text, "new plain-text draft")
        let retry = try XCTUnwrap(model.retry(echo))
        let retried = await retry.value
        XCTAssertEqual(retried, false)
        XCTAssertEqual(ActionWire.captured().count, 2, "retry checks retained files, not the current plain draft")
        XCTAssertTrue(model.toast?.text.contains("Attach Files") == true)
    }

    func testForeignDeleteUsesManageMessagesButForeignEditCannotDispatch() async throws {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.manageMessages, api: client([.init()]))
        var row = mine(model, channel); row.author = User(id: 444, username: "other")
        let timeline = model.timeline(for: channel.id); timeline.seed([row])
        XCTAssertFalse(model.preflight(.editMessage, in: channel.id, messageAuthorID: row.author.id))
        model.delete(row)
        try await settle { ActionWire.captured().count == 1 }
        XCTAssertEqual(ActionWire.captured().first?.httpMethod, "DELETE")
        XCTAssertTrue(timeline.messages.isEmpty)
    }

    func testOwnDeleteActuallyDispatchesUnderTimeoutWhileEditKeepsDraft() async throws {
        let (model, channel) = fixture(api: client([.init()]))
        let row = mine(model, channel), timeline = model.timeline(for: channel.id)
        timeline.seed([row]); timeout(model, channel)
        model.drafts[channel.id] = Draft(text: "stashed")
        model.beginEdit(row); model.drafts[channel.id]?.text = "edited"
        model.saveEdit(in: channel.id)
        XCTAssertEqual(model.drafts[channel.id]?.text, "edited")
        XCTAssertEqual(timeline.messages[0].content, row.content)
        model.delete(row)
        try await settle { ActionWire.captured().count == 1 }
        XCTAssertEqual(ActionWire.captured().first?.httpMethod, "DELETE")
        XCTAssertEqual(model.drafts[channel.id]?.text, "stashed")
    }

    func testThreadQueuedActionRechecksPermissionBeforeWriting() async {
        let (model, channel) = fixture(bits: Permission.viewChannel | Permission.manageThreads)
        let id = MockDiscord.ThreadFixture.bookPose
        let blocker = Task { try? await Task.sleep(for: .milliseconds(50)) }
        model.threads.writes[id] = Task { await blocker.value }
        let request = model.perform(.rename("changed"), on: id)
        deny(Permission.manageThreads, model: model, channel: channel)
        await request.value
        XCTAssertEqual((model.api as? MockDiscord)?.threadOperations.count, 0)
        XCTAssertNotEqual(model.store.channel(id)?.name, "changed")
        XCTAssertNotNil(model.toast)
    }
}
