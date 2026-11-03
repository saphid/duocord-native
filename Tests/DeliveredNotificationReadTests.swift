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

// MARK: - Alert Reply and Mark as Read (round 8, appended)

/// Every request is intercepted. This transport cannot reach Discord.
nonisolated private final class AlertActionWireNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    static func reset() { lock.withLock { paths = [] } }
    static var requests: [String] { lock.withLock { paths } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.withLock { Self.paths.append(request.url?.path ?? "") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class NotificationAlertActionTests: XCTestCase {
    private let chat = MockDiscord.generalChannel
    private let guild: Snowflake = 910_000_000_000_000_000
    private let me: Snowflake = 900_000_000_000_000_001
    private let sendDenied: Snowflake = 940_000_000_000_000_001
    private let viewDenied: Snowflake = 940_000_000_000_000_002
    private let threadParent: Snowflake = 940_000_000_000_000_003
    private let openThread: Snowflake = 940_000_000_000_000_004
    private let lockedThread: Snowflake = 940_000_000_000_000_005
    private let archivedThread: Snowflake = 940_000_000_000_000_006
    private let foreignPrivateThread: Snowflake = 940_000_000_000_000_007
    private let noLatest: Snowflake = 940_000_000_000_000_008
    private let blockedDM: Snowflake = 920_000_000_000_000_000
    private let openDM: Snowflake = 920_000_000_000_000_001

    private func payload(_ mock: MockDiscord, blockDM: Bool = false) -> ReadyPayload {
        var ready = mock.readyPayload()
        func restricted(_ id: Snowflake, allow: UInt64 = 0, deny: UInt64 = 0) -> Channel {
            var channel = Channel(id: id, type: .text, guildID: guild, name: "restricted")
            channel.permissionOverwrites = [PermissionOverwrite(id: guild, type: 0, allow: String(allow), deny: String(deny))]
            return channel
        }
        func thread(_ id: Snowflake, _ type: ChannelType = .publicThread, archived: Bool = false, locked: Bool = false) -> Channel {
            var thread = Channel(id: id, type: type, guildID: guild, name: "thread", parentID: threadParent)
            thread.ownerID = 6
            thread.threadMetadata = ThreadMetadata(archived: archived, locked: locked)
            return thread
        }
        ready.guilds[0].channels += [restricted(sendDenied, deny: Permission.sendMessages),
                                     restricted(viewDenied, deny: Permission.viewChannel),
                                     restricted(threadParent, allow: Permission.sendInThreads)]
        ready.guilds[0].threads += [thread(openThread), thread(lockedThread, locked: true),
                                    thread(archivedThread, archived: true), thread(foreignPrivateThread, .privateThread)]
        for g in ready.guilds.indices {
            for c in ready.guilds[g].channels.indices { ready.guilds[g].channels[c].lastMessageID = 100 }
            for t in ready.guilds[g].threads.indices { ready.guilds[g].threads[t].lastMessageID = 100 }
        }
        for c in ready.privateChannels.indices { ready.privateChannels[c].lastMessageID = 100 }
        ready.guilds[0].channels.append(Channel(id: noLatest, type: .text, guildID: guild, name: "no latest"))
        ready.readStates = (ready.guilds.flatMap { $0.channels + $0.threads } + ready.privateChannels)
            .map { ReadState(id: $0.id, lastMessageID: 10, mentionCount: 0) }
        if blockDM { ready.relationships.append(Relationship(id: mock.users[0].id, type: 2)) }
        return ready
    }
    private func fixture(ready: Bool = true, blockDM: Bool = false)
        -> (AppModel, MockDiscord, FakeReadNotificationDelivery, NotificationService) {
        let mock = MockDiscord(), center = FakeReadNotificationDelivery()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in nil })
        let model = AppModel(readAPI: mock, notifications: service)
        model.connectAlertActions(service)
        let initial = payload(mock, blockDM: blockDM)
        mock.setReadStates(initial.readStates)
        if ready { model.store.apply(ready: initial) }
        return (model, mock, center, service)
    }
    private func response(_ action: String, message: Snowflake = 50, channel: Snowflake? = nil, account: String? = nil,
                          session: String = UUID().uuidString, identifier: String? = nil, text: String? = nil,
                          edit: (inout [AnyHashable: Any]) -> Void = { _ in }) -> NotificationActionResponse {
        var info: [AnyHashable: Any] = ["channel": (channel ?? chat).description, "message": message.description,
                                        "duocordAccount": account ?? me.description, "duocordSession": session, "duocordLocal": "1"]
        edit(&info)
        return NotificationActionResponse(actionIdentifier: action, identifier: identifier ?? "msg-\(message)-\(session)",
                                          userInfo: info, text: text)
    }
    private func record(_ id: Snowflake) -> UNNotificationRequest {
        let content = UNMutableNotificationContent(), session = UUID().uuidString
        content.threadIdentifier = chat.description
        content.userInfo = ["channel": chat.description, "message": id.description, "duocordAccount": me.description,
                            "duocordSession": session, "duocordLocal": "1"]
        return UNNotificationRequest(identifier: "msg-\(id)-\(session)", content: content, trigger: nil)
    }
    private func message(_ id: Snowflake, channel: Snowflake? = nil, author: User? = nil) -> Message {
        Message(id: id, channelID: channel ?? chat, guildID: guild,
                author: author ?? User(id: 6, username: "offline", globalName: nil, discriminator: nil, avatar: nil, bot: nil),
                content: "offline \(id)", timestamp: "", mentions: [])
    }
    private func pending(_ model: AppModel, _ channel: Snowflake) -> [Message] {
        guard let timeline = model.messages.existingTimeline(for: channel) else { return [] }
        return timeline.messages.filter { timeline.sendState(for: $0) != nil }
    }
    private func mockReady(_ model: AppModel) async {
        await model.handle(GatewayDispatch(name: "MOCK_READY", data: Data()))
    }
    private func settle() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<3000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Controlled seam did not arrive", file: file, line: line)
    }
    private var reply: String { MessageAlertAction.reply }
    private var markRead: String { MessageAlertAction.markRead }

    func testPostedCategoryFollowsReplyAuthorityAndActionsNeedUnlockWithoutForeground() async throws {
        let categories = MessageAlertAction.categories
        XCTAssertEqual(Set(categories.map(\.identifier)), [MessageAlertAction.category, MessageAlertAction.readOnlyCategory])
        let writable = try XCTUnwrap(categories.first { $0.identifier == MessageAlertAction.category })
        let readOnly = try XCTUnwrap(categories.first { $0.identifier == MessageAlertAction.readOnlyCategory })
        XCTAssertEqual(writable.actions.map(\.identifier), [reply, markRead])
        XCTAssertEqual(readOnly.actions.map(\.identifier), [markRead])
        let text = try XCTUnwrap(writable.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(text.title, "Reply")
        XCTAssertEqual(text.textInputPlaceholder, "Message")
        XCTAssertFalse(readOnly.actions[0] is UNTextInputNotificationAction)
        XCTAssertEqual(readOnly.actions[0].title, "Mark as Read")
        for action in categories.flatMap(\.actions) {
            XCTAssertTrue(action.options.contains(.authenticationRequired), action.identifier)
            XCTAssertFalse(action.options.contains(.foreground), action.identifier)
        }

        let (model, _, center, _) = fixture()
        let cases: [(Snowflake, String)] = [(chat, MessageAlertAction.category), (openThread, MessageAlertAction.category),
                                            (sendDenied, MessageAlertAction.readOnlyCategory), (viewDenied, MessageAlertAction.readOnlyCategory),
                                            (lockedThread, MessageAlertAction.readOnlyCategory), (archivedThread, MessageAlertAction.readOnlyCategory),
                                            (foreignPrivateThread, MessageAlertAction.readOnlyCategory), (999, MessageAlertAction.readOnlyCategory)]
        for (index, (channel, category)) in cases.enumerated() {
            model.notifications.post(message: message(Snowflake(UInt64(50 + index)), channel: channel), store: model.store)
            await settle()
            let posted = try XCTUnwrap(center.adds.last, "\(channel)")
            XCTAssertEqual(posted.content.userInfo["channel"] as? String, channel.description)
            XCTAssertEqual(posted.content.categoryIdentifier, category, "\(channel)")
            XCTAssertEqual(posted.content.body, "offline \(50 + index)")
            XCTAssertEqual(posted.content.userInfo["duocordLocal"] as? String, "1")
        }
        XCTAssertEqual(center.adds.count, cases.count)
    }

    func testReplySendsTrimmedPlainMessageOnceAndLeavesComposerUntouched() async throws {
        let (model, mock, center, service) = fixture()
        center.records = [record(50)]
        let quoted = message(40)
        var own = message(45); own.author = model.store.me!
        let original = Draft(text: "half-written", replyTo: quoted,
                             attachments: [DraftAttachment(filename: "a.png", data: Data([1]), contentType: "image/png")])
        model.drafts[chat] = original
        model.drafts[openDM] = Draft(text: "other draft")
        model.beginEdit(own) // stashes `original`; the composer now edits `own`
        let editing = model.drafts[chat], other = model.drafts[openDM]
        let focus = (model.composerContinuity.focusedChannel, model.composerContinuity.focusRevision)
        model.pingReplies = false
        let outcome = await service.handle(response(reply, text: "  hello there \n"))
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(mock.sent, [MockDiscord.SentRecord(channel: chat, content: "hello there", replyTo: nil, pingReply: false)])
        XCTAssertEqual(model.drafts[chat], editing)
        XCTAssertEqual(model.drafts[openDM], other)
        XCTAssertFalse(model.pingReplies)
        XCTAssertEqual(model.composerContinuity.focusedChannel, focus.0)
        XCTAssertEqual(model.composerContinuity.focusRevision, focus.1)
        let timeline = model.timeline(for: chat)
        let sent = try XCTUnwrap(timeline.messages.last { $0.content == "hello there" })
        XCTAssertNil(timeline.sendState(for: sent))
        XCTAssertNil(sent.referencedMessage)
        XCTAssertNotEqual(sent.type, 19)
        XCTAssertTrue(pending(model, chat).isEmpty)
        XCTAssertEqual(center.records.count, 1, "Success clears alerts only through the existing accepted-read path")
        model.cancelEdit(in: chat)
        XCTAssertEqual(model.drafts[chat], original, "The stashed draft, reply target and attachment survive")
    }

    func testUnownedMalformedAndNonWritingResponsesNeverWriteOrOpen() async {
        let (model, mock, _, service) = fixture()
        var opened = 0
        service.onOpen = { _, _ in opened += 1 }
        model.drafts[chat] = Draft(text: "kept")
        let session = UUID().uuidString
        var cases: [(String, (String) -> NotificationActionResponse)] = [
            ("foreign account", { self.response($0, account: "900000000000000002", text: "x") }),
            ("legacy", { action in NotificationActionResponse(actionIdentifier: action, identifier: "msg-50",
                                                               userInfo: ["channel": self.chat.description, "message": "50"], text: "x") }),
            ("not local", { self.response($0, text: "x") { $0["duocordLocal"] = "0" } }),
            ("padded channel", { self.response($0, text: "x") { $0["channel"] = "0" + self.chat.description } }),
            ("signed message", { self.response($0, session: session, identifier: "msg-+50-\(session)", text: "x") { $0["message"] = "+50" } }),
            ("zero message", { self.response($0, message: 0, text: "x") }),
            ("padded account", { self.response($0, account: " " + self.me.description, text: "x") }),
            ("bad session", { self.response($0, session: "not-a-uuid", text: "x") }),
            ("lowercase session", { self.response($0, session: session.lowercased(), text: "x") }),
            ("mismatched identifier", { self.response($0, session: session, identifier: "msg-51-\(session)", text: "x") }),
            ("bare identifier", { self.response($0, identifier: "foreign", text: "x") }),
            ("non-string message", { self.response($0, text: "x") { $0["message"] = 50 } }),
            ("unknown channel", { self.response($0, channel: 999, text: "x") }),
        ]
        cases.append(("unknown action", { _ in self.response("duocord.message.other", text: "x") }))
        cases.append(("dismiss", { _ in self.response(UNNotificationDismissActionIdentifier, text: "x") }))
        for (name, build) in cases {
            for action in [reply, markRead] {
                let outcome = await service.handle(build(action))
                XCTAssertTrue([.refused, .ignored].contains(outcome), "\(name) \(action): \(outcome)")
            }
        }
        await settle()
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertTrue(mock.readOperations.isEmpty)
        XCTAssertTrue(pending(model, chat).isEmpty)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(model.drafts[chat], Draft(text: "kept"))
        // Control: same current account, another posting session, is an explicit user action.
        let other = UUID().uuidString
        let replied = await service.handle(response(reply, session: other, text: "x"))
        let read = await service.handle(response(markRead, session: other))
        XCTAssertEqual(replied, .sent)
        XCTAssertEqual(read, .markedRead)
        XCTAssertEqual(mock.sent.count, 1)
        XCTAssertEqual(mock.readOperations.count, 1)
    }

    func testReplyRefusedWithoutCurrentSendAuthority() async {
        let (model, mock, _, service) = fixture(blockDM: true)
        for channel in [sendDenied, viewDenied, lockedThread, archivedThread, foreignPrivateThread, blockedDM, Snowflake(999)] {
            let outcome = await service.handle(response(reply, channel: channel, text: "blocked"))
            XCTAssertEqual(outcome, .refused, "\(channel)")
            XCTAssertTrue(pending(model, channel).isEmpty, "\(channel)")
        }
        XCTAssertTrue(mock.sent.isEmpty)
        // Controls: an open thread and an unblocked DM accept the same reply.
        let thread = await service.handle(response(reply, channel: openThread, text: "allowed"))
        let dm = await service.handle(response(reply, channel: openDM, text: "allowed"))
        XCTAssertEqual(thread, .sent)
        XCTAssertEqual(dm, .sent)
        XCTAssertEqual(mock.sent.map(\.channel), [openThread, openDM])
    }

    func testEmptyOrWhitespaceReplyIsNoOp() async {
        let (model, mock, _, service) = fixture()
        model.drafts[chat] = Draft(text: "kept")
        for text in ["", "   ", "\n\t "] {
            let outcome = await service.handle(response(reply, text: text))
            XCTAssertEqual(outcome, .unchanged)
        }
        let missing = await service.handle(response(reply))
        XCTAssertEqual(missing, .unchanged)
        await settle()
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertTrue(pending(model, chat).isEmpty)
        XCTAssertEqual(model.drafts[chat], Draft(text: "kept"))
    }

    func testColdActionWaitsForThisLoginsFirstReadyThenSends() async {
        let (model, mock, _, service) = fixture(ready: false)
        XCTAssertFalse(model.store.isReady)
        let action = Task { await service.handle(self.response(self.reply, text: " after ready ")) }
        await settle()
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertTrue(pending(model, chat).isEmpty)
        await mockReady(model) // production READY path, including its store resets
        let outcome = await action.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(mock.sent, [MockDiscord.SentRecord(channel: chat, content: "after ready", replyTo: nil, pingReply: model.pingReplies)])
    }

    func testColdActionTimeoutAndCancellationFailClosed() async {
        let (model, mock, _, service) = fixture(ready: false)
        model.notificationReadyTimeout = .milliseconds(50)
        let timedOut = await service.handle(response(reply, text: "late"))
        let readTimedOut = await service.handle(response(markRead))
        XCTAssertEqual(timedOut, .refused)
        XCTAssertEqual(readTimedOut, .refused)
        model.notificationReadyTimeout = .seconds(30)
        let cancelled = Task { await service.handle(self.response(self.reply, text: "cancelled")) }
        await settle()
        let start = ContinuousClock.now
        cancelled.cancel()
        let outcome = await cancelled.value
        XCTAssertEqual(outcome, .refused)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        // A READY after those actions ended cannot revive any of them.
        await mockReady(model)
        await settle(); try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertTrue(mock.readOperations.isEmpty)
        XCTAssertTrue(pending(model, chat).isEmpty)
    }

    func testColdActionRejectsSignOutResetAndOtherAccountReady() async {
        for scenario in ["sign out", "reset before ready", "other account", "reset after ready"] {
            let (model, mock, _, service) = fixture(ready: false)
            let account = scenario == "other account" ? "900000000000000777" : me.description
            let action = Task { await service.handle(self.response(self.reply, account: account, text: "stale")) }
            await settle()
            switch scenario {
            case "sign out": model.signOut()
            case "reset before ready": model.store.reset(); await mockReady(model)
            case "other account": await mockReady(model)
            default:
                await mockReady(model)
                model.store.apply(ready: mock.readyPayload()) // replaces READY before the waiter resumes
            }
            let outcome = await action.value
            XCTAssertEqual(outcome, .refused, scenario)
            try? await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(mock.sent.isEmpty, scenario)
            XCTAssertTrue(pending(model, chat).isEmpty, scenario)
        }
    }

    func testDeferredSendStartAndStaleCompletionCannotAdoptChangedAuthority() async throws {
        let (model, mock, _, service) = fixture()
        // Epoch change after authority was checked, before the request starts.
        let startGate = NotificationReadGate()
        mock.beforeSend = { _ in await startGate.pause() }
        let early = Task { await service.handle(self.response(self.reply, text: "stale start")) }
        await Task.yield()
        XCTAssertEqual(pending(model, chat).count, 1, "Action enqueued its echo")
        XCTAssertFalse(startGate.entered)
        model.store.apply(ready: payload(mock))
        let earlyOutcome = await early.value
        XCTAssertEqual(earlyOutcome, .refused)
        XCTAssertFalse(startGate.entered)
        XCTAssertTrue(pending(model, chat).isEmpty)
        // Account replaced while the request is in flight: its success is not adopted.
        let flightGate = NotificationReadGate()
        mock.beforeSend = { _ in await flightGate.pause() }
        let late = Task { await service.handle(self.response(self.reply, text: "stale result")) }
        await wait { flightGate.entered }
        let timeline = model.timeline(for: chat)
        var other = payload(mock); other.user.id = 900_000_000_000_000_777
        model.store.apply(ready: other)
        flightGate.resume()
        let lateOutcome = await late.value
        XCTAssertEqual(lateOutcome, .refused)
        XCTAssertEqual(mock.sent.map(\.content), ["stale result"])
        let echo = try XCTUnwrap(timeline.messages.last { $0.content == "stale result" })
        XCTAssertEqual(timeline.sendState(for: echo), .sending)
        // Signed out while in flight: a failure is not adopted either.
        let (model2, mock2, _, service2) = fixture()
        let failGate = NotificationReadGate()
        mock2.beforeSend = { _ in await failGate.pause(); throw DiscordError.http(500, "offline refused") }
        let failed = Task { await service2.handle(self.response(self.reply, text: "stale failure")) }
        await wait { failGate.entered }
        model2.signOut()
        failGate.resume()
        let failedOutcome = await failed.value
        XCTAssertEqual(failedOutcome, .refused)
        XCTAssertTrue(mock2.sent.isEmpty)
    }

    func testFailedReplyKeepsRetryableEchoAndAlertWithoutComposerMutation() async throws {
        let (model, mock, center, service) = fixture()
        center.records = [record(50)]
        model.drafts[chat] = Draft(text: "keep me", replyTo: message(40))
        let before = model.drafts[chat]
        mock.beforeSend = { _ in throw DiscordError.http(500, "offline refused") }
        let outcome = await service.handle(response(reply, text: "retry me"))
        XCTAssertEqual(outcome, .sendFailed)
        let timeline = model.timeline(for: chat)
        let failed = try XCTUnwrap(timeline.messages.last)
        XCTAssertEqual(failed.content, "retry me")
        guard case .failed = timeline.sendState(for: failed) else { return XCTFail("Failed echo must stay retryable") }
        await settle()
        XCTAssertEqual(center.records.count, 1)
        XCTAssertTrue(center.removals.isEmpty)
        XCTAssertTrue(center.adds.isEmpty, "No failure notification")
        XCTAssertEqual(model.drafts[chat], before)
        mock.beforeSend = nil
        model.retry(failed)
        await wait { mock.sent.count == 1 }
        await settle()
        XCTAssertEqual(mock.sent, [MockDiscord.SentRecord(channel: chat, content: "retry me", replyTo: nil, pingReply: model.pingReplies)])
        XCTAssertEqual(model.drafts[chat], before)
        mock.beforeSend = { _ in throw DiscordError.http(500, "offline refused") }
        let second = await service.handle(response(reply, text: "discard me"))
        XCTAssertEqual(second, .sendFailed)
        let discarded = try XCTUnwrap(timeline.messages.last)
        model.discard(discarded)
        XCTAssertFalse(timeline.messages.contains { $0.nonce == discarded.nonce })
        XCTAssertEqual(mock.sent.count, 1)
        XCTAssertEqual(model.drafts[chat], before)
    }

    func testMarkAsReadAcknowledgesOnlyThroughNotifiedMessage() async {
        let (model, mock, center, service) = fixture()
        center.records = [record(40), record(50), record(70), record(150)]
        let first = await service.handle(response(markRead, message: 50))
        XCTAssertEqual(first, .markedRead)
        XCTAssertEqual(mock.readOperations.map(\.route), ["channels/\(chat)/messages/50/ack"])
        XCTAssertEqual(mock.readOperations.first?.reads, [ReadAcknowledgement(channel: chat, message: 50)])
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 50)
        await settle()
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["70", "150"])
        // Already read at or past the notified message, or no known latest: no write.
        let equal = await service.handle(response(markRead, message: 50))
        let older = await service.handle(response(markRead, message: 45))
        let missing = await service.handle(response(markRead, channel: noLatest))
        XCTAssertEqual([equal, older, missing], [.unchanged, .unchanged, .unchanged])
        XCTAssertEqual(mock.readOperations.count, 1)
        // A notified ID beyond the known latest acknowledges only the latest.
        let beyond = await service.handle(response(markRead, message: 500))
        XCTAssertEqual(beyond, .markedRead)
        XCTAssertEqual(mock.readOperations.last?.reads, [ReadAcknowledgement(channel: chat, message: 100)])
        await settle()
        XCTAssertEqual(center.records.map { $0.content.userInfo["message"] as? String }, ["150"])
    }

    func testMarkAsReadInDebugRealSessionIsRefusedBeforeAnyWireRequest() async {
        AlertActionWireNetwork.reset()
        let center = FakeReadNotificationDelivery()
        let service = NotificationService(delivery: center, authorized: true, loadAttachment: { _ in nil })
        let rest = DiscordREST(credentials: SessionCredentials(token: "offline-test", superProperties: nil, userAgent: "offline-test"),
                               protocolClasses: [AlertActionWireNetwork.self])
        let model = AppModel(notificationAPI: rest, notifications: service)
        model.connectAlertActions(service)
        model.store.apply(ready: payload(MockDiscord()))
        center.records = [record(50)]
        XCTAssertFalse(model.allowsReadWrites)
        let outcome = await service.handle(response(markRead, message: 50))
        await settle()
        XCTAssertEqual(outcome, .readFailed)
        XCTAssertTrue(AlertActionWireNetwork.requests.isEmpty)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
        XCTAssertNotNil(model.readErrors[chat])
        XCTAssertEqual(center.records.count, 1)
        XCTAssertTrue(center.removals.isEmpty)
    }

    func testDeferredReplyRefusesEligibilityChangesFromPendingPublication() async {
        for scenario in ["block", "permission", "delete"] {
            let (model, mock, _, service) = fixture()
            let channel = scenario == "block" ? blockedDM : chat
            model.drafts[channel] = Draft(text: "keep draft")
            let timeline = model.timeline(for: channel)
            var changed = false
            // The real timeline publishes its pending row synchronously before
            // the network task starts. No scheduling assumption or test hook.
            let observer = timeline.observe { change in
                guard case .appended = change, !changed else { return }
                changed = true
                if scenario == "block" {
                    let json = "{\"d\":{\"id\":\"\(mock.users[0].id)\",\"type\":2}}"
                    model.store.handle(GatewayDispatch(name: "RELATIONSHIP_ADD", data: Data(json.utf8)))
                } else if scenario == "permission" {
                    var info = model.store.channel(channel)!
                    info.permissionOverwrites = [PermissionOverwrite(id: self.guild, type: 0, allow: "0", deny: String(Permission.sendMessages))]
                    model.store.upsert(channel: info)
                } else {
                    let json = "{\"d\":{\"id\":\"\(channel)\"}}"
                    model.store.handle(GatewayDispatch(name: "CHANNEL_DELETE", data: Data(json.utf8)))
                }
            }
            let outcome = await service.handle(response(reply, channel: channel, text: "do not send"))
            timeline.stopObserving(observer)
            XCTAssertTrue(changed, scenario)
            XCTAssertEqual(outcome, .refused, scenario)
            XCTAssertTrue(mock.sent.isEmpty, scenario)
            XCTAssertTrue(pending(model, channel).isEmpty, scenario)
            XCTAssertEqual(model.drafts[channel], Draft(text: "keep draft"), scenario)
        }
    }

    func testCancelledReplyCannotStartAfterPendingPublication() async {
        let (model, mock, _, service) = fixture()
        let timeline = model.timeline(for: chat)
        var cancelled = false
        let observer = timeline.observe { change in
            guard case .appended = change, !cancelled else { return }
            cancelled = true
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let action = Task { await service.handle(self.response(self.reply, text: "cancel before send")) }
        let outcome = await action.value
        timeline.stopObserving(observer)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertTrue(pending(model, chat).isEmpty)
    }

    func testCancelledReadyActionsCannotStartWrites() async {
        for cold in [false, true] {
            for identifier in [reply, markRead] {
                let (model, mock, _, service) = fixture(ready: !cold)
                let action = Task {
                    if !cold { withUnsafeCurrentTask { $0?.cancel() } }
                    return await service.handle(self.response(identifier, text: "cancelled"))
                }
                if cold {
                    await settle()
                    await mockReady(model)
                    // Cancel before the READY continuation can resume its action.
                    action.cancel()
                }
                let outcome = await action.value
                XCTAssertEqual(outcome, .refused, "cold=\(cold), \(identifier)")
                XCTAssertTrue(mock.sent.isEmpty)
                XCTAssertTrue(mock.readOperations.isEmpty)
                XCTAssertTrue(pending(model, chat).isEmpty)
            }
        }
    }

    func testCancelledQueuedAlertReadDoesNotStartAcknowledgement() async {
        let (model, mock, _, service) = fixture()
        let gate = NotificationReadGate()
        mock.beforeReadResponse = { record in
            if record.reads.first?.channel == self.openDM { await gate.pause() }
        }
        let previous = model.markAsRead(channel: openDM)
        await wait { gate.entered }
        let action = Task { await service.handle(self.response(self.markRead)) }
        await wait { model.readSaves[self.chat] == 1 }
        action.cancel()
        gate.resume()
        await previous.value
        let outcome = await action.value
        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(mock.readOperations.allSatisfy { $0.reads.allSatisfy { $0.channel != chat } })
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
        XCTAssertEqual(model.readSaves[chat], 0)
        XCTAssertFalse(model.store.pendingReadChannels.contains(chat))
    }

    func testPartialAlertReadPreservesNewerMentionBadgesThroughHTTPAndEcho() async {
        for channel in [chat, blockedDM] {
            for echo in [false, true] {
                let (model, mock, _, service) = fixture()
                var ready = payload(mock)
                for index in ready.readStates.indices where ready.readStates[index].id == channel {
                    ready.readStates[index].mentionCount = 2
                }
                model.store.apply(ready: ready)
                mock.setReadStates(ready.readStates)
                if echo {
                    mock.beforeReadResponse = { record in
                        let read = record.reads[0]
                        let json = "{\"d\":{\"channel_id\":\"\(read.channel)\",\"message_id\":\"\(read.message)\",\"mention_count\":0,\"version\":\(1000 + read.message.raw)}}"
                        await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: Data(json.utf8)))
                    }
                }
                let outcome = await service.handle(response(markRead, message: 50, channel: channel))
                XCTAssertEqual(outcome, .markedRead)
                XCTAssertEqual(model.store.readStates[channel]?.lastMessageID, 50)
                XCTAssertEqual(model.store.mentionCount(channel), 2, "channel=\(channel), echo=\(echo)")
                XCTAssertNil(mock.readOperations[0].reads[0].mentionCount, "Do not invent a server count")
                if channel == blockedDM { XCTAssertTrue(model.store.unreadDMs.contains { $0.id == channel }) }
                // A full-boundary read still clears counts and the DM badge.
                let full = await service.handle(response(markRead, message: 100, channel: channel))
                XCTAssertEqual(full, .markedRead)
                XCTAssertEqual(model.store.mentionCount(channel), 0)
                if channel == blockedDM { XCTAssertFalse(model.store.unreadDMs.contains { $0.id == channel }) }
            }
        }
    }

    func testFullReadsClearCapturedMentionsAfterPlainArrivalButPreserveNewMentions() async throws {
        for route in ["channel", "server", "all", "notification"] {
            for mentioned in [false, true] {
                let (model, mock, _, service) = fixture()
                var ready = payload(mock)
                for index in ready.readStates.indices where ready.readStates[index].id == chat {
                    ready.readStates[index].mentionCount = 3
                }
                model.store.apply(ready: ready)
                mock.setReadStates(ready.readStates)
                var incoming = message(101)
                incoming.mentions = mentioned ? [model.store.me!] : []
                struct Envelope: Encodable { var d: Message }
                let data = try JSONEncoder().encode(Envelope(d: incoming))
                mock.beforeReadResponse = { _ in
                    await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: data))
                }
                switch route {
                case "channel": await model.markAsRead(channel: chat).value
                case "server": await model.markServerAsRead(guild).value
                case "all": await model.markAllAsRead().value
                default:
                    let result = await service.handle(response(markRead, message: 100))
                    XCTAssertEqual(result, .markedRead)
                }
                XCTAssertEqual(model.store.channel(chat)?.lastMessageID, 101)
                XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 100)
                let expected = mentioned ? 4 : 0
                XCTAssertEqual(model.store.mentionCount(chat), expected, "\(route), mentioned=\(mentioned)")
                // A later versioned echo must not undo the accepted HTTP result
                // or consume the mention that arrived after the captured read.
                let json = "{\"d\":{\"channel_id\":\"\(chat)\",\"message_id\":\"100\",\"mention_count\":0,\"version\":10000}}"
                await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: Data(json.utf8)))
                XCTAssertEqual(model.store.mentionCount(chat), expected, "echo: \(route), mentioned=\(mentioned)")
            }
        }
    }

    func testDefaultTapStillOpensAndOnlyDefaultOpens() async {
        let (model, mock, _, service) = fixture()
        defer { withExtendedLifetime(model) {} }
        var opened: [Snowflake] = []
        service.onOpen = { _, message in opened.append(message) }
        // Default taps keep today's behavior, including records without local provenance.
        let legacy = NotificationActionResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, identifier: "msg-40",
                                                userInfo: ["channel": chat.description, "message": "40"])
        let legacyOutcome = await service.handle(legacy)
        service.flushPendingTap()
        let ownOutcome = await service.handle(response(UNNotificationDefaultActionIdentifier, message: 60))
        service.flushPendingTap()
        XCTAssertEqual([legacyOutcome, ownOutcome], [.opened, .opened])
        XCTAssertEqual(opened, [40, 60])
        let readOnly = await service.handle(response(markRead, message: 5)) // already read: no write
        let refused = await service.handle(response(reply, channel: viewDenied, text: "x"))
        let dismissed = await service.handle(response(UNNotificationDismissActionIdentifier))
        service.flushPendingTap()
        XCTAssertEqual([readOnly, refused, dismissed], [.unchanged, .refused, .ignored])
        XCTAssertEqual(opened, [40, 60])
        XCTAssertTrue(mock.sent.isEmpty)
        // Typed text is routed only for Reply.
        XCTAssertEqual(response(reply, text: "hi").action, .reply("hi"))
        XCTAssertEqual(response(markRead, text: "hi").action, .markRead)
        XCTAssertEqual(response(UNNotificationDefaultActionIdentifier, text: "hi").action, .open)
    }
}
