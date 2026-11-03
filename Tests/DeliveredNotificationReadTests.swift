import XCTest
import UserNotifications
@testable import DuocordNative

@MainActor
private final class NotificationReadGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !released else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class FakeReadNotificationDelivery: NotificationDelivery {
    var records: [UNNotificationRequest] = []
    var removals: [[String]] = []
    var adds: [UNNotificationRequest] = []
    var fetchGate: NotificationReadGate?
    var addGate: NotificationReadGate?
    var fetches = 0
    func setBadge(_ count: Int) {}
    func deliveredRequests() async -> [UNNotificationRequest] {
        fetches += 1
        let captured = records
        if let fetchGate { await fetchGate.pause() }
        return captured
    }
    func add(_ request: UNNotificationRequest) async throws {
        adds.append(request)
        if let addGate { await addGate.pause() }
        records.removeAll { $0.identifier == request.identifier }
        records.append(request)
    }
    func removeDelivered(_ identifiers: [String]) {
        removals.append(identifiers)
        records.removeAll { identifiers.contains($0.identifier) }
    }
}

@MainActor
final class DeliveredNotificationReadTests: XCTestCase {
    private let chat = MockDiscord.generalChannel
    private let guild: Snowflake = 910_000_000_000_000_000

    private func fixture() -> (AppModel, MockDiscord, FakeReadNotificationDelivery) {
        let mock = MockDiscord(), center = FakeReadNotificationDelivery()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in nil })
        let model = AppModel(readAPI: mock, notifications: service)
        var ready = mock.readyPayload()
        for g in ready.guilds.indices {
            for c in ready.guilds[g].channels.indices { ready.guilds[g].channels[c].lastMessageID = 100 }
            for t in ready.guilds[g].threads.indices { ready.guilds[g].threads[t].lastMessageID = 100 }
        }
        for c in ready.privateChannels.indices { ready.privateChannels[c].lastMessageID = 100 }
        ready.readStates = (ready.guilds.flatMap { $0.channels + $0.threads } + ready.privateChannels)
            .map { ReadState(id: $0.id, lastMessageID: 10, mentionCount: 0) }
        mock.setReadStates(ready.readStates)
        model.store.apply(ready: ready)
        model.selectedChannel = chat
        model.store.visibleChannel = chat
        return (model, mock, center)
    }
    private func record(_ id: Snowflake, _ model: AppModel, channel: Snowflake? = nil,
                        account: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = (channel ?? chat).description
        let session = model.store.readEpoch.uuidString
        content.userInfo = ["channel": (channel ?? chat).description, "message": id.description,
                            "duocordAccount": account ?? model.store.me!.id.description,
                            "duocordSession": session, "duocordLocal": "1"]
        return UNNotificationRequest(identifier: "msg-\(id)-\(session)", content: content, trigger: nil)
    }
    private func message(_ id: Snowflake, _ model: AppModel, avatar: Bool = false) -> Message {
        Message(id: id, channelID: chat, guildID: guild,
                author: User(id: 6, username: "offline", globalName: nil, discriminator: nil,
                             avatar: avatar ? "offline-avatar" : nil, bot: nil), content: "", timestamp: "", mentions: [])
    }
    private func ack(_ model: AppModel, message: Snowflake? = nil, version: Int? = nil,
                     manual: Bool = false, count: Int? = nil) async throws {
        var fields: [String: JSONValue] = ["channel_id": .string(chat.description)]
        if let message { fields["message_id"] = .string(message.description) }
        if let version { fields["version"] = .number(Double(version)) }
        if manual { fields["manual"] = .bool(true) }
        if let count { fields["mention_count"] = .number(Double(count)) }
        await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: try JSONEncoder().encode(["d": JSONValue.object(fields)])))
    }
    private func settle() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<3000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Controlled seam did not arrive", file: file, line: line)
    }

    func testLocalReadPreferenceOffClearsOnlyAcceptedExtentWithoutWrite() async {
        let (model, mock, center) = fixture()
        let old = model.settings.markReadOnServer; defer { model.settings.markReadOnServer = old }
        model.settings.markReadOnServer = false
        center.records = [record(50, model), record(200, model)]
        model.drafts[chat] = Draft(text: "preserved")
        model.didRead(channel: chat, upTo: 100)
        await settle()
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
        XCTAssertTrue(mock.readOperations.isEmpty)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 100)
        XCTAssertEqual(model.drafts[chat]?.text, "preserved")
    }

    func testLocalReadPreferenceOnClearsBeforeAutomaticHTTPThenCurrentWrite() async {
        let (model, mock, center) = fixture()
        let old = model.settings.markReadOnServer; defer { model.settings.markReadOnServer = old }
        model.settings.markReadOnServer = true
        center.records = [record(50, model), record(200, model)]
        model.didRead(channel: chat, upTo: 100)
        await settle()
        XCTAssertEqual(center.records.count, 1)
        XCTAssertTrue(mock.readOperations.isEmpty)
        await wait { !mock.readOperations.isEmpty } // production debounce is 1.5s, handled below
        await model.readQueue?.value
        XCTAssertEqual(mock.readOperations.first?.reads.first?.message, 100)
        XCTAssertEqual(center.records.first?.content.userInfo["message"] as? String, "200")
    }

    func testExplicitSingleCurrentHTTPUsesCapturedBoundary() async {
        let (model, mock, center) = fixture()
        center.records = [record(50, model), record(200, model)]
        await model.markAsRead(channel: chat).value
        await settle()
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
        XCTAssertEqual(mock.readOperations.first?.reads.first?.message, 100)
    }

    func testServerReadClearsOnlyItsAcceptedChannels() async {
        let (model, _, center) = fixture()
        let dm = model.store.channels.values.first { $0.type.isPrivate }!.id
        center.records = [record(50, model), record(200, model), record(60, model, channel: dm)]
        await model.markServerAsRead(guild).value; await settle()
        XCTAssertEqual(Set(center.records.map { $0.content.threadIdentifier }), Set([chat.description, dm.description]))
        XCTAssertEqual(center.records.count, 2)
    }

    func testAllReadClearsEligibleDMAndGuildButPreservesNewer() async {
        let (model, _, center) = fixture()
        let dm = model.store.channels.values.first { $0.type.isPrivate }!.id
        center.records = [record(50, model), record(60, model, channel: dm), record(200, model)]
        await model.markAllAsRead().value; await settle()
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
    }

    func testManualUnreadAndHeldAutomaticReadNeverClear() async {
        let (model, mock, center) = fixture()
        mock.setReadHistory([message(20, model), message(100, model)], channel: chat)
        center.records = [record(15, model)]
        await model.markUnread(message(100, model)).value
        model.didRead(channel: chat, upTo: 100)
        try? await ack(model, message: 100)
        await settle()
        XCTAssertEqual(center.records.count, 1)
        XCTAssertTrue(center.removals.isEmpty)
        XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
    }

    func testGatewayAcceptedCurrentBoundaryClearsButStaleCountAndManualDoNot() async throws {
        let (model, _, center) = fixture()
        center.records = [record(50, model), record(200, model)]
        try await ack(model, message: 100, version: 10)
        await settle(); XCTAssertEqual(center.records.count, 1)
        center.records.append(record(75, model))
        let fetches = center.fetches
        try await ack(model, message: 300, version: 9)
        try await ack(model, version: 11, count: 0)
        try await ack(model, message: 20, version: 12, manual: true)
        await settle()
        XCTAssertEqual(center.fetches, fetches)
        XCTAssertEqual(center.records.count, 2)
    }

    func testFailedExplicitHTTPDoesNotClear() async {
        let (model, mock, center) = fixture()
        center.records = [record(50, model)]
        mock.failNextRead = true
        await model.markAsRead(channel: chat).value; await settle()
        XCTAssertEqual(center.records.count, 1); XCTAssertTrue(center.removals.isEmpty)
    }

    func testSupersededHTTPAndObsoleteEchoCannotClear() async throws {
        let (model, mock, center) = fixture()
        let gate = NotificationReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        center.records = [record(50, model)]
        let task = model.markAsRead(channel: chat)
        await wait { gate.entered }
        try await ack(model, message: 20, version: 20, manual: true)
        gate.resume(); await task.value
        try await ack(model, message: 100) // known superseded versionless fingerprint
        await settle()
        XCTAssertEqual(center.records.count, 1); XCTAssertTrue(center.removals.isEmpty)
    }

    func testAcceptedEchoBeforeLostHTTPResponseClearsOnce() async throws {
        let (model, mock, center) = fixture()
        center.records = [record(50, model), record(200, model)]
        mock.beforeReadResponse = { _ in
            try await self.ack(model, message: 100, version: 10)
            throw DiscordError.http(0, "offline lost response")
        }
        await model.markAsRead(channel: chat).value; await settle()
        XCTAssertEqual(center.records.count, 1)
        XCTAssertEqual(center.removals.flatMap { $0 }.count, 1)
    }

    func testHeldEnumerationPreservesNewArrivalAndPartialBoundary() async {
        let (model, _, center) = fixture()
        let gate = NotificationReadGate(); center.fetchGate = gate
        center.records = [record(50, model), record(200, model)]
        model.didRead(channel: chat, upTo: 100)
        await wait { gate.entered }
        center.records.append(record(300, model))
        gate.resume(); await settle()
        XCTAssertEqual(Set(center.records.compactMap { $0.content.userInfo["message"] as? String }), Set(["200", "300"]))
        model.cancelAutomaticAck(chat)
    }

    func testResetFencesHeldEnumerationEvenWithSameAccount() async {
        let (model, _, center) = fixture()
        let gate = NotificationReadGate(); center.fetchGate = gate
        center.records = [record(50, model)]
        model.didRead(channel: chat, upTo: 100)
        await wait { gate.entered }
        model.store.apply(ready: MockDiscord().readyPayload())
        gate.resume(); await settle()
        XCTAssertEqual(center.records.count, 1); XCTAssertTrue(center.removals.isEmpty)
    }

    func testAccountReplacementFencesHeldEnumeration() async {
        let (model, _, center) = fixture()
        let gate = NotificationReadGate(); center.fetchGate = gate
        center.records = [record(50, model)]
        model.didRead(channel: chat, upTo: 100); await wait { gate.entered }
        var ready = MockDiscord().readyPayload()
        ready.user.id = 999
        model.store.apply(ready: ready)
        gate.resume(); await settle()
        XCTAssertEqual(center.records.count, 1); XCTAssertTrue(center.removals.isEmpty)
    }

    func testUnknownLegacyMalformedAndForeignRecordsRemain() async {
        let (model, _, center) = fixture()
        let valid = record(50, model)
        let legacy = UNMutableNotificationContent()
        legacy.threadIdentifier = chat.description
        legacy.userInfo = ["channel": chat.description, "message": "40"]
        let malformed = record(60, model).content.mutableCopy() as! UNMutableNotificationContent
        malformed.userInfo["message"] = "invalid"
        center.records = [valid, record(30, model, account: "foreign"), record(35, model, channel: 999),
                          UNNotificationRequest(identifier: "msg-40", content: legacy, trigger: nil),
                          UNNotificationRequest(identifier: "foreign", content: valid.content, trigger: nil),
                          UNNotificationRequest(identifier: record(60, model).identifier, content: malformed, trigger: nil)]
        model.didRead(channel: chat, upTo: 100); await settle()
        XCTAssertEqual(center.records.count, 5)
        XCTAssertEqual(center.removals.flatMap { $0 }, [valid.identifier])
        model.cancelAutomaticAck(chat)
    }

    func testEqualAndDuplicateCleanupIsIdempotentAndCountOnlyOwnsNoBoundary() async throws {
        let (model, _, center) = fixture()
        center.records = [record(50, model)]
        await model.markAsRead(channel: chat).value; await settle()
        await model.markAsRead(channel: chat).value
        try await ack(model, message: 100, version: 50)
        try await ack(model, version: 51, count: 0)
        model.didRead(channel: chat, upTo: 100)
        await settle()
        XCTAssertTrue(center.records.isEmpty)
        XCTAssertEqual(center.removals.flatMap { $0 }.count, 1)
    }

    func testReadDuringHeldAddRemovesOnlyThatReadPostAfterCompletion() async {
        let (model, _, center) = fixture()
        let gate = NotificationReadGate(); center.addGate = gate
        model.notifications.post(message: message(50, model), store: model.store)
        await wait { gate.entered }
        model.didRead(channel: chat, upTo: 100); await settle()
        gate.resume(); await settle()
        XCTAssertEqual(center.adds.count, 1)
        XCTAssertTrue(center.records.isEmpty)
        center.addGate = nil
        model.notifications.post(message: message(200, model), store: model.store)
        await settle()
        XCTAssertEqual(center.records.count, 1)
        XCTAssertEqual(center.records.first?.content.userInfo["message"] as? String, "200")
        model.cancelAutomaticAck(chat)
    }

    func testResetDuringHeldAddCannotRemoveReplacementRecord() async {
        let (model, _, center) = fixture()
        let gate = NotificationReadGate(); center.addGate = gate
        model.notifications.post(message: message(50, model), store: model.store)
        await wait { gate.entered }
        model.store.apply(ready: MockDiscord().readyPayload())
        let replacement = record(50, model)
        center.records = [replacement]
        gate.resume(); await settle()
        XCTAssertTrue(center.records.contains { $0.identifier == replacement.identifier })
        XCTAssertEqual(center.records.count, 1, "Obsolete post must be retired with only its session-qualified identifier")
    }

    func testAvatarCompletionAfterReadCannotPublishAndNewArrivalCan() async {
        let mock = MockDiscord(), center = FakeReadNotificationDelivery(), gate = NotificationReadGate()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in await gate.pause(); return nil })
        let model = AppModel(readAPI: mock, notifications: service)
        model.store.apply(ready: mock.readyPayload()); model.selectedChannel = chat
        // Establish a low accepted read using a manual authority event first.
        try? await ack(model, message: 10, version: 10, manual: true)
        model.store.resumeAutomaticReading(chat)
        model.notifications.post(message: message(50, model, avatar: true), store: model.store)
        await wait { gate.entered }
        model.didRead(channel: chat, upTo: 100)
        gate.resume(); await settle()
        XCTAssertTrue(center.adds.isEmpty)
        model.notifications.post(message: message(200, model), store: model.store); await settle()
        XCTAssertEqual(center.adds.count, 1)
        model.cancelAutomaticAck(chat)
    }

    func testNoOpLocalAndMentionOnlyGatewayDoNotInventBoundaryAuthority() async throws {
        let (model, _, center) = fixture()
        center.records = [record(5, model)]
        model.didRead(channel: chat, upTo: 10)
        try await ack(model, version: 10, count: 2)
        model.didRead(channel: chat, upTo: 5) // mention consumption, no boundary advance
        await settle()
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
        XCTAssertEqual(center.records.count, 1)
        XCTAssertEqual(center.fetches, 0)
        model.cancelAutomaticAck(chat)
    }

    func testAcceptedVersionedGatewayReleaseClearsOnlyCurrentStoreBoundary() async throws {
        let (model, _, center) = fixture()
        try await ack(model, message: 20, version: 10, manual: true)
        center.records = [record(15, model), record(50, model), record(200, model)]
        try await ack(model, message: 100, version: 11)
        await settle()
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
        let fetches = center.fetches
        // Accepted monotonic ACK below the current state owns only that state,
        // never a newly invented extent beyond it.
        try await ack(model, message: 50, version: 12)
        await settle()
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 100)
        XCTAssertEqual(center.fetches, fetches)
        XCTAssertEqual(center.records.count, 1)
    }

    func testResetDuringAvatarLoadPreventsAnyAddToNewSession() async {
        let mock = MockDiscord(), center = FakeReadNotificationDelivery(), gate = NotificationReadGate()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in await gate.pause(); return nil })
        let model = AppModel(readAPI: mock, notifications: service)
        model.store.apply(ready: mock.readyPayload())
        model.notifications.post(message: message(50, model), store: model.store)
        await wait { gate.entered }
        model.store.reset()
        model.store.apply(ready: mock.readyPayload())
        gate.resume(); await settle()
        XCTAssertTrue(center.adds.isEmpty)
        XCTAssertTrue(center.removals.isEmpty)
    }

    func testManualUnreadCannotRecreateReadAlertsButNewerMessageStillPosts() async {
        let (model, mock, center) = fixture()
        center.records = [record(50, model)]
        await model.markAsRead(channel: chat).value; await settle()
        XCTAssertTrue(center.records.isEmpty)
        mock.setReadHistory([message(20, model), message(100, model)], channel: chat)
        await model.markUnread(message(100, model)).value
        model.notifications.post(message: message(50, model), store: model.store)
        model.notifications.post(message: message(200, model), store: model.store)
        await settle()
        XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(center.adds.count, 1)
        XCTAssertEqual(center.records.first?.content.userInfo["message"] as? String, "200")
    }

    func testOwnMessageAcceptedReadClearsThroughPublishedBoundary() async throws {
        let (model, _, center) = fixture()
        center.records = [record(40, model), record(200, model)]
        var own = message(100, model); own.author = model.store.me!
        struct Envelope: Encodable { var d: Message }
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: own))))
        await settle()
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 100)
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
        let fetches = center.fetches
        model.didRead(channel: chat, upTo: 100); await settle()
        XCTAssertEqual(center.fetches, fetches, "Equal reader callback must not be required to repair own-message cleanup")
    }

    func testOwnMessageUnderManualOrPendingUnreadRetainsAlerts() async throws {
        for pending in [false, true] {
            let (model, _, center) = fixture()
            if pending { model.store.pendingUnreadChannels.insert(chat) }
            else { try await ack(model, message: 20, version: 10, manual: true) }
            center.records = [record(40, model)]
            var own = message(100, model); own.author = model.store.me!
            struct Envelope: Encodable { var d: Message }
            await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: own))))
            await settle()
            XCTAssertEqual(center.records.count, 1)
            XCTAssertEqual(center.fetches, 0)
            XCTAssertNotEqual(model.store.readStates[chat]?.lastMessageID, 100)
        }
    }

    func testReadDuringHeldAddSurvivesChannelPruningAndRecreation() async throws {
        for recreate in [false, true] {
            let (model, _, center) = fixture()
            let saved = model.store.channel(chat)!
            let gate = NotificationReadGate(); center.addGate = gate
            model.notifications.post(message: message(50, model), store: model.store)
            await wait { gate.entered }
            model.didRead(channel: chat, upTo: 100); await settle()
            model.store.handle(GatewayDispatch(name: "CHANNEL_DELETE", data: Data(("{\"d\":{\"id\":\"" + chat.description + "\"}}").utf8)))
            XCTAssertNil(model.store.channel(chat))
            let other = model.store.channels.values.first { $0.type.isPrivate }!.id
            var arrival = message(200, model); arrival.channelID = other
            center.addGate = nil
            model.notifications.post(message: arrival, store: model.store); await settle()
            if recreate {
                struct Envelope: Encodable { var d: Channel }
                model.store.handle(GatewayDispatch(name: "CHANNEL_CREATE", data: try JSONEncoder().encode(Envelope(d: saved))))
                XCTAssertNotNil(model.store.channel(chat))
            }
            gate.resume(); await settle()
            XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["200"])
            XCTAssertTrue(center.removals.flatMap { $0 }.contains(center.adds[0].identifier))
            model.cancelAutomaticAck(chat)
        }
    }

    func testReadDuringAvatarSurvivesChannelPruningAndRecreation() async throws {
        let mock = MockDiscord(), center = FakeReadNotificationDelivery(), gate = NotificationReadGate()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in await gate.pause(); return nil })
        let model = AppModel(readAPI: mock, notifications: service)
        model.store.apply(ready: mock.readyPayload()); model.selectedChannel = chat
        try await ack(model, message: 10, version: 10, manual: true)
        model.store.resumeAutomaticReading(chat)
        let saved = model.store.channel(chat)!
        model.notifications.post(message: message(50, model, avatar: true), store: model.store)
        await wait { gate.entered }
        model.didRead(channel: chat, upTo: 100); await settle()
        model.store.handle(GatewayDispatch(name: "CHANNEL_DELETE", data: Data(("{\"d\":{\"id\":\"" + chat.description + "\"}}").utf8)))
        XCTAssertNil(model.store.channel(chat))
        let other = model.store.channels.values.first { $0.type.isPrivate }!.id
        var arrival = message(200, model); arrival.channelID = other
        model.notifications.post(message: arrival, store: model.store); await settle()
        struct Envelope: Encodable { var d: Channel }
        model.store.handle(GatewayDispatch(name: "CHANNEL_CREATE", data: try JSONEncoder().encode(Envelope(d: saved))))
        gate.resume(); await settle()
        XCTAssertEqual(center.adds.map { $0.content.userInfo["message"] as? String }, ["200"])
        model.cancelAutomaticAck(chat)
    }

}
