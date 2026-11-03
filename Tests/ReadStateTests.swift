import XCTest
import UIKit
@testable import DuocordNative

@MainActor
final class ReadStateTests: XCTestCase {
    private let chat = MockDiscord.generalChannel
    private let guild: Snowflake = 910_000_000_000_000_000

    private func fixture() -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel(readAPI: mock)
        var ready = mock.readyPayload()
        for index in ready.guilds.indices {
            for c in ready.guilds[index].channels.indices where ready.guilds[index].channels[c].type.isTextLike || ready.guilds[index].channels[c].type.isForumLike {
                ready.guilds[index].channels[c].lastMessageID = 300
            }
            for t in ready.guilds[index].threads.indices { ready.guilds[index].threads[t].lastMessageID = 300 }
        }
        for offset in 0..<10 {
            ready.guilds[0].channels.append(Channel(id: Snowflake(940_000_000_000_000_000 + UInt64(offset)), type: .text,
                guildID: guild, name: "additional-\(offset)", lastMessageID: 300))
        }
        for index in ready.privateChannels.indices { ready.privateChannels[index].lastMessageID = 300 }
        ready.readStates = (ready.guilds.flatMap { $0.channels + $0.threads } + ready.privateChannels)
            .filter { $0.type.isTextLike }.map { ReadState(id: $0.id, lastMessageID: 10, mentionCount: 2) }
        mock.setReadStates(ready.readStates)
        model.store.apply(ready: ready)
        model.selectedChannel = chat
        model.store.visibleChannel = chat
        return (model, mock)
    }
    private func message(_ id: Snowflake, model: AppModel, channel: Snowflake? = nil, own: Bool = false) -> Message {
        Message(id: id, channelID: channel ?? chat, guildID: guild,
                author: own ? model.store.me! : User(id: 6, username: "other", globalName: nil, discriminator: nil, avatar: nil, bot: nil),
                content: "offline", timestamp: "", mentions: own ? [] : [model.store.me!])
    }
    private func ack(_ model: AppModel, _ json: String) async {
        await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: Data(("{\"d\":" + json + "}").utf8)))
    }
    private func incoming(_ model: AppModel, _ message: Message) async throws {
        struct Envelope: Encodable { var d: Message }
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: message))))
    }
    private func controller(_ model: AppModel) -> MessageListController {
        MessageListController(timeline: model.timeline(for: chat), store: model.store, api: model.api, guildID: guild,
                              title: "test", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
    }

    func testChannelReadKeepsSelectionDraftAnchorAndPreference() async throws {
        let (model, mock) = fixture()
        let old = model.settings.markReadOnServer
        defer { model.settings.markReadOnServer = old }
        model.settings.markReadOnServer = false
        model.drafts[chat] = Draft(text: "unfinished 👩🏽‍💻")
        let anchor = ScrollAnchor(itemID: "m100", offset: -12, pinnedToBottom: false)
        model.anchors[chat] = anchor
        await model.markAsRead(channel: chat).value
        XCTAssertEqual(mock.readOperations.first?.route, "channels/\(chat)/messages/300/ack")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertEqual(model.store.mentionCount(chat), 0)
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertEqual(model.drafts[chat]?.text, "unfinished 👩🏽‍💻")
        XCTAssertEqual(model.anchors[chat], anchor)
        XCTAssertNil(model.revealRequest)
        XCTAssertEqual(model.readSaves[chat], 0)
    }

    func testServerCapturedBulkIncludesAccessibleThreads() async throws {
        let (model, mock) = fixture()
        let expected = Set(model.eligibleReadChannels.filter { $0.guildID == guild && $0.lastMessageID != nil }.map(\.id))
        XCTAssertTrue(model.eligibleReadChannels.contains { $0.guildID == guild && $0.type.isThread })
        await model.markServerAsRead(guild).value
        let operation = try XCTUnwrap(mock.readOperations.first)
        XCTAssertEqual(operation.route, "read-states/ack-bulk")
        XCTAssertEqual(Set(operation.reads.map(\.channel)), expected)
        XCTAssertTrue(operation.reads.allSatisfy { !$0.manual && $0.message == 300 })
        XCTAssertFalse(model.store.badge(for: guild).unread)
    }

    func testAllReadIncludesFullSetBeyondFiftyAndDMs() async throws {
        let (model, mock) = fixture()
        let expected = Set(model.eligibleReadChannels.compactMap { $0.lastMessageID == nil ? nil : $0.id })
        XCTAssertGreaterThan(expected.count, 50)
        await model.markAllAsRead().value
        XCTAssertEqual(Set(mock.readOperations.first!.reads.map(\.channel)), expected)
        XCTAssertTrue(mock.readOperations.first!.reads.contains { model.store.channel($0.channel)?.type.isPrivate == true })
        XCTAssertEqual(model.store.totalBadge, 0)
    }

    func testMissingLatestAndEmptyChannelsAreSafeNoOps() async {
        let (model, mock) = fixture()
        await model.markAsRead(channel: 0).value
        let empty = model.store.channels.values.first { $0.lastMessageID == nil }!
        await model.markAsRead(channel: empty.id).value
        XCTAssertTrue(mock.readOperations.isEmpty)
    }

    func testManualUnreadFetchesActualPredecessorAndHoldsAtBottom() async throws {
        let (model, mock) = fixture()
        let history = [message(20, model: model), message(100, model: model), message(300, model: model)]
        mock.setReadHistory(history, channel: chat)
        await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
        await model.markAsRead(channel: chat).value
        await model.markUnread(history[1]).value
        let op = try XCTUnwrap(mock.readOperations.last)
        XCTAssertEqual(op.reads.first?.message, 20, "Actual predecessor, not 99")
        XCTAssertEqual(op.reads.first?.mentionCount, 2)
        XCTAssertEqual(model.unreadBoundary(for: chat), 20)
        XCTAssertTrue(model.store.isUnread(model.store.channel(chat)!))
        let list = controller(model)
        list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.unreadTargets[chat])
        XCTAssertEqual(list.unreadTarget, 100)
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        coordinator.list(didReadUpTo: 300)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        try await incoming(model, message(400, model: model, own: true))
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20, "Own message cannot undo deliberate hold")
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"300\",\"mention_count\":0}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20, "Late nonmanual echo cannot undo hold")
        model.selectedChannel = nil
        model.select(channel: chat)
        model.didRead(channel: chat, upTo: 400)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 400, "Leaving/reentering resumes automatic local reading")
    }

    func testFirstMessageUsesZeroSentinelIncludingOwnMessage() async throws {
        let (model, mock) = fixture()
        let first = message(100, model: model, own: true)
        mock.setReadHistory([first, message(300, model: model)], channel: chat)
        await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
        await model.markUnread(first).value
        XCTAssertEqual(mock.readOperations.last?.reads.first?.message, 0)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 0)
        let list = controller(model)
        list.setUnreadBoundary(0, target: 100)
        XCTAssertEqual(list.unreadTarget, 100)
        await model.markAsRead(channel: chat).value
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertNil(model.unreadBoundary(for: chat))
    }

    func testUnloadedPredecessorAndPartialCountPreserved() async throws {
        let (model, mock) = fixture()
        let history = [message(20, model: model), message(100, model: model), message(300, model: model)]
        mock.setReadHistory(history, channel: chat)
        await model.markUnread(history[1]).value
        XCTAssertEqual(mock.readOperations.last?.reads.first?.message, 20)
        XCTAssertNil(mock.readOperations.last?.reads.first?.mentionCount, "Unknown total must be omitted")
        XCTAssertEqual(model.store.mentionCount(chat), 2, "Omitted count preserves prior authority")
    }

    func testJumpUsesFirstActualUnreadOutsideCachedWindow() async throws {
        let (model, mock) = fixture()
        let history = (1...120).map { message(Snowflake(UInt64($0 * 10)), model: model) }
        mock.setReadHistory(history, channel: chat)
        await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
        model.unreadMarkers[chat] = 20
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        coordinator.list(firstVisible: 900)
        XCTAssertTrue(model.unreadIsAboveViewport(chat))
        await model.jumpToUnread(chat).value
        XCTAssertEqual(model.revealRequest?.message, 30)
        await model.timeline(for: chat).load(around: 30, api: mock, store: model.store)
        XCTAssertNotNil(model.timeline(for: chat).index(of: 30))
        let list = controller(model); list.setUnreadBoundary(20, target: nil)
        XCTAssertEqual(list.unreadTarget, 30)
        coordinator.list(firstVisible: 30)
        XCTAssertFalse(model.unreadIsAboveViewport(chat))
    }

    func testPartialAndManualGatewaySemantics() async {
        let (model, _) = fixture()
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"200\"}")
        XCTAssertEqual(model.store.mentionCount(chat), 2)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"mention_count\":5}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 200)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\"}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 200)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true}")
        XCTAssertEqual(model.unreadBoundary(for: chat), 20)
        XCTAssertEqual(model.store.mentionCount(chat), 5)
        model.didRead(channel: chat, upTo: 300)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
    }

    func testHTTPFailureAppliesNoSuccessAndReleasesPendingHold() async {
        let (model, mock) = fixture()
        mock.failNextRead = true
        await model.markAsRead(channel: chat).value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
        XCTAssertNotNil(model.readErrors[chat])
        XCTAssertEqual(model.readSaves[chat], 0)
        mock.setReadHistory([], channel: chat)
        mock.failNextRead = true
        await model.markUnread(message(100, model: model)).value
        XCTAssertFalse(model.store.pendingUnreadChannels.contains(chat))
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
    }

    func testNewIncomingMentionDuringPendingReadSurvivesCapturedBoundary() async throws {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        model.store.visibleIsLive = true
        try await incoming(model, message(400, model: model))
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"300\",\"mention_count\":0}")
        await gate.resume(); await save.value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertTrue(model.store.isUnread(model.store.channel(chat)!))
        XCTAssertGreaterThan(model.store.mentionCount(chat), 0)
    }

    func testNewerManualEchoOutranksLateHTTP() async {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"mention_count\":7}")
        await gate.resume(); await save.value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        XCTAssertEqual(model.store.mentionCount(chat), 7)
        XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
    }

    func testQueuedChannelServerAllOperationsSerializeAndCaptureTargets() async throws {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let first = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        let second = model.markServerAsRead(guild)
        let third = model.markAllAsRead()
        try await incoming(model, message(400, model: model))
        XCTAssertEqual(mock.readOperations.count, 1)
        mock.beforeReadResponse = nil
        await gate.resume(); await first.value; await second.value; await third.value
        XCTAssertEqual(mock.readOperations.count, 3)
        XCTAssertEqual(mock.readOperations[1].reads.first { $0.channel == chat }?.message, 300)
        XCTAssertEqual(mock.readOperations[2].reads.first { $0.channel == chat }?.message, 300)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertTrue(model.store.isUnread(model.store.channel(chat)!))
        XCTAssertGreaterThan(model.store.mentionCount(chat), 0)
        XCTAssertEqual(model.readSaves[chat], 0)
    }

    func testResetAndReadyFenceHeldResponsesAndQueuedBulk() async {
        for reset in [true, false] {
            let (model, mock) = fixture()
            let gate = ReadGate()
            mock.beforeReadResponse = { _ in await gate.pause() }
            let first = model.markAsRead(channel: chat)
            await gate.waitUntilPaused()
            let queued = model.markAllAsRead()
            if reset { model.signOut() } else { model.store.apply(ready: mock.readyPayload()) }
            let state = model.store.readStates[chat]
            mock.beforeReadResponse = nil
            await gate.resume(); await first.value; await queued.value
            XCTAssertEqual(model.store.readStates[chat], state)
            XCTAssertEqual(mock.readOperations.count, 1)
            XCTAssertTrue(model.readSaves.isEmpty)
        }
    }

    func testInjectedNotificationMockDoesNotAuthorizeDebugReadWrites() async {
        let mock = MockDiscord()
        let model = AppModel(notificationAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        model.selectedChannel = chat
        XCTAssertFalse(model.isMock)
        await model.markAsRead(channel: chat).value
        await model.markAllAsRead().value
        await model.markUnread(message(100, model: model)).value
        XCTAssertTrue(mock.readOperations.isEmpty)
        XCTAssertNotNil(model.readErrors[chat])
        model.didRead(channel: chat, upTo: Snowflake(UInt64.max))
        XCTAssertTrue(mock.readOperations.isEmpty)
    }
    func testMessageMenuCoordinatorRunsManualOperation() async throws {
        let (model, mock) = fixture()
        let first = message(100, model: model)
        mock.setReadHistory([message(20, model: model), first, message(300, model: model)], channel: chat)
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        coordinator.list(markUnread: first)
        await model.readQueue?.value
        XCTAssertEqual(mock.readOperations.last?.reads.first?.message, 20)
        XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
    }

    func testOldDebouncedAutomaticAckCannotUndoManualUnread() async throws {
        let (model, mock) = fixture()
        let old = model.settings.markReadOnServer
        defer { model.settings.markReadOnServer = old }
        model.settings.markReadOnServer = true
        model.didRead(channel: chat, upTo: 300)
        mock.setReadHistory([message(20, model: model), message(100, model: model), message(300, model: model)], channel: chat)
        await model.markUnread(message(100, model: model)).value
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertEqual(mock.readOperations.count, 1)
        XCTAssertEqual(mock.readOperations[0].reads[0].manual, true)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
    }

    func testLateObsoleteManualEchoCannotUndoNewerExplicitRead() async {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        await model.markUnread(message(100, model: model)).value
        await model.markAsRead(channel: chat).value
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"mention_count\":4}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(model.store.mentionCount(chat), 0)
    }

    func testManualEchoSurvivesLostHTTPResponse() async throws {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        mock.beforeReadResponse = { record in
            let read = record.reads[0]
            let fields: [String: JSONValue] = ["channel_id": .string(read.channel.description), "message_id": .string(read.message.description), "manual": .bool(true)]
            let data = try JSONEncoder().encode(["d": JSONValue.object(fields)])
            await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: data))
            throw DiscordError.http(0, "Lost mock response after echo")
        }
        await model.markUnread(message(100, model: model)).value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        XCTAssertEqual(model.explicitUnreadTarget(for: chat), 100)
        XCTAssertNotNil(model.readErrors[chat])
        XCTAssertFalse(model.store.pendingUnreadChannels.contains(chat))
    }

    func testLeavingAndReenteringWhileManualRequestIsHeldResumesReading() async {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markUnread(message(100, model: model))
        await gate.waitUntilPaused()
        model.selectedChannel = nil; model.selectedChannel = chat
        await gate.resume(); await save.value
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        model.didRead(channel: chat, upTo: 300)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
    }

    func testSelectedChannelChangeDoesNotApplyPendingUnreadJump() async {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        model.unreadMarkers[chat] = 20
        let jump = model.jumpToUnread(chat)
        model.selectedChannel = model.store.privateChannels[0].id
        await jump.value
        XCTAssertNil(model.revealRequest)
        XCTAssertNil(model.unreadMarkers[chat])
    }

    func testReadBoundaryRebuildPreservesVisibleRowAndOffset() async throws {
        let (model, mock) = fixture()
        let history = (1...50).map { message(Snowflake(UInt64($0 * 10)), model: model) }
        mock.setReadHistory(history, channel: chat)
        let timeline = model.timeline(for: chat)
        await timeline.loadLatest(api: mock, store: model.store)
        let anchor = ScrollAnchor(itemID: "m300", offset: -10, pinnedToBottom: false)
        let list = MessageListController(timeline: timeline, store: model.store, api: mock, guildID: guild,
            title: "test", subtitle: "", icon: "number", anchor: anchor, unreadAfter: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 588))
        window.rootViewController = list; window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let before = try XCTUnwrap(list.captureAnchor())
        list.setUnreadBoundary(20, target: 30)
        let marked = try XCTUnwrap(list.captureAnchor())
        XCTAssertEqual(marked.itemID, before.itemID)
        XCTAssertEqual(marked.offset, before.offset, accuracy: 0.5)
        list.setUnreadBoundary(nil, target: nil)
        let read = try XCTUnwrap(list.captureAnchor())
        XCTAssertEqual(read.itemID, before.itemID)
        XCTAssertEqual(read.offset, before.offset, accuracy: 0.5)
        XCTAssertNil(model.revealRequest)
    }

    func testAroundPageDoesNotPretendItsFirstRowIsFirstUnread() async {
        let (model, mock) = fixture()
        let history = (1...120).map { message(Snowflake(UInt64($0 * 10)), model: model) }
        mock.setReadHistory(history, channel: chat)
        await model.timeline(for: chat).load(around: 900, api: mock, store: model.store)
        let list = controller(model); list.setUnreadBoundary(20, target: nil)
        XCTAssertNil(list.unreadTarget)
        list.setUnreadBoundary(890, target: nil)
        XCTAssertEqual(list.unreadTarget, 900)
    }

    func testReadTargetsExcludePermissionDeniedAndMissingLatest() async throws {
        let (model, mock) = fixture()
        var ready = mock.readyPayload()
        let denied: Snowflake = 930_000_000_000_000_000
        var hidden = Channel(id: denied, type: .text, guildID: guild, name: "hidden", lastMessageID: 300)
        hidden.permissionOverwrites = [PermissionOverwrite(id: guild, type: 0, allow: "0", deny: String(Permission.viewChannel))]
        ready.guilds[0].channels.append(hidden)
        ready.guilds[0].threads.append(Channel(id: 930_000_000_000_000_002, type: .privateThread, guildID: guild,
            name: "not joined", parentID: chat, lastMessageID: 300))
        ready.guilds[0].channels.append(Channel(id: 930_000_000_000_000_001, type: .text, guildID: guild, name: "empty"))
        model.store.apply(ready: ready)
        await model.markServerAsRead(guild).value
        let ids = Set(mock.readOperations[0].reads.map(\.channel))
        XCTAssertFalse(ids.contains(denied))
        XCTAssertFalse(ids.contains(930_000_000_000_000_002))
        XCTAssertFalse(ids.contains(930_000_000_000_000_001))
    }

    func testVersionedGatewayRejectsOldEchoAndAcceptsFreshSameBoundary() async {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        await model.markUnread(message(100, model: model)).value
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":10}")
        await model.markAsRead(channel: chat).value
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"300\",\"version\":11,\"mention_count\":0}")
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":10,\"mention_count\":4}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":12,\"mention_count\":4}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        XCTAssertEqual(model.store.mentionCount(chat), 4)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"ack_type\":1,\"message_id\":\"1000\",\"version\":13}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
    }

    func testReadyVersionFencesOlderGatewayReadState() async {
        let (model, mock) = fixture()
        var ready = mock.readyPayload(); ready.readStateVersion = 40
        model.store.apply(ready: ready)
        let state = model.store.readStates[chat]
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":39}")
        XCTAssertEqual(model.store.readStates[chat], state)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":41}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
    }

    func testNewerPartialManualBoundaryProtectsMentionCountFromOldHTTP() async {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true}")
        await gate.resume(); await save.value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        XCTAssertEqual(model.store.mentionCount(chat), 2)
    }

    func testCapturedReadDoesNotConsumeArrivalOnIncidentalDidRead() async throws {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        try await incoming(model, message(400, model: model))
        await gate.resume(); await save.value
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        coordinator.list(didReadUpTo: 400)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        coordinator.listReaderMoved()
        coordinator.list(didReadUpTo: 400)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 400)
    }

    func testSnapshotResetFencesHTTPAndClearsReadPresentation() async throws {
        let (model, mock) = fixture()
        let snapshot = try XCTUnwrap(model.store.snapshot())
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        model.store.reset(); model.store.apply(snapshot: snapshot)
        let restored = model.store.readStates[chat]
        await gate.resume(); await save.value
        XCTAssertEqual(model.store.readStates[chat], restored)
        XCTAssertTrue(model.readSaves.isEmpty)
        XCTAssertTrue(model.unreadTargets.isEmpty)
    }

    func testMockEchoTravelsThroughActualAppDispatch() async throws {
        let (model, mock) = fixture()
        let received = expectation(description: "real mock read echo")
        mock.echo = { dispatch in
            Task { @MainActor in
                await model.handle(dispatch)
                received.fulfill()
            }
        }
        await model.markAsRead(channel: chat).value
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertEqual(model.store.mentionCount(chat), 0)
    }

    func testQueuedFailureRetainsEarlierConfirmedManualSuccess() async {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let first = model.markUnread(message(100, model: model))
        await gate.waitUntilPaused()
        let second = model.markAsRead(channel: chat)
        mock.beforeReadResponse = nil; mock.failNextRead = true
        await gate.resume(); await first.value; await second.value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
        XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(model.explicitUnreadTarget(for: chat), 100)
        XCTAssertNotNil(model.readErrors[chat])
        XCTAssertFalse(model.store.pendingUnreadChannels.contains(chat))
    }

    func testExplicitReadEchoReleasesHoldEvenWhenHTTPResponseIsLost() async throws {
        let (model, mock) = fixture()
        mock.setReadHistory([message(20, model: model), message(100, model: model)], channel: chat)
        await model.markUnread(message(100, model: model)).value
        mock.beforeReadResponse = { record in
            let read = record.reads[0]
            let fields: [String: JSONValue] = ["channel_id": .string(read.channel.description), "message_id": .string(read.message.description), "mention_count": .number(0), "version": .number(10)]
            await model.handle(GatewayDispatch(name: "MESSAGE_ACK", data: try JSONEncoder().encode(["d": JSONValue.object(fields)])))
            throw DiscordError.http(0, "Mock response lost")
        }
        await model.markAsRead(channel: chat).value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertEqual(model.store.mentionCount(chat), 0)
        XCTAssertNil(model.unreadMarkers[chat])
        XCTAssertNil(model.unreadTargets[chat])
        XCTAssertNotNil(model.readErrors[chat])
    }

    func testMockReadyRetainsConfirmedReadStateAndVersion() async throws {
        let (model, mock) = fixture()
        await model.markAsRead(channel: chat).value
        let ready = mock.readyPayload()
        XCTAssertEqual(ready.readStates.first { $0.id == chat }?.lastMessageID, 300)
        XCTAssertEqual(ready.readStates.first { $0.id == chat }?.mentionCount, 0)
        XCTAssertEqual(ready.readStateVersion, 1)
        model.store.apply(ready: ready)
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":1}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
    }

    func testQueuedAutomaticReadRevalidatesAfterFIFO() async {
        for change in ["manual", "conversation", "authority"] {
            let (model, mock) = fixture()
            let old = model.settings.markReadOnServer
            model.settings.markReadOnServer = true
            let gate = ReadGate()
            mock.beforeReadResponse = { _ in await gate.pause() }
            let blocking = model.markAsRead(channel: model.store.privateChannels[0].id)
            await gate.waitUntilPaused()
            let automatic = model.enqueueRead([ReadAcknowledgement(channel: chat, message: 300)], automatic: true)
            if change == "manual" {
                await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":10}")
            } else if change == "conversation" {
                model.selectedChannel = nil
                model.selectedChannel = chat
            } else {
                await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"200\",\"version\":10}")
            }
            mock.beforeReadResponse = nil
            await gate.resume(); await blocking.value; await automatic.value
            XCTAssertEqual(mock.readOperations.count, 1, change)
            XCTAssertEqual(model.readSaves[chat], 0, change)
            if change == "manual" {
                XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 20)
                XCTAssertTrue(model.store.manualUnreadChannels.contains(chat))
            }
            model.settings.markReadOnServer = old
        }
    }

    func testFreshExternalReadReleasesManualHoldAndPresentation() async {
        let (model, _) = fixture()
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"mention_count\":4,\"version\":10}")
        model.unreadMarkers[chat] = 20; model.unreadTargets[chat] = 100
        // A distinct, newer version is external authority, not an old local echo.
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"300\",\"mention_count\":0,\"version\":11}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
        XCTAssertEqual(model.store.mentionCount(chat), 0)
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertNil(model.unreadBoundary(for: chat))
        XCTAssertNil(model.explicitUnreadTarget(for: chat))
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"version\":10}")
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 300)
    }

    func testDelayedManualCountMergesArrivalsAndPreservesNewAuthority() async throws {
        for confirmation in ["echo", "http", "newer-count"] {
            let (model, mock) = fixture()
            let history = [message(20, model: model), message(100, model: model), message(300, model: model)]
            mock.setReadHistory(history, channel: chat)
            await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
            await model.markAsRead(channel: chat).value
            let gate = ReadGate()
            mock.beforeReadResponse = { _ in await gate.pause() }
            let save = model.markUnread(history[1])
            await gate.waitUntilPaused()
            XCTAssertEqual(mock.readOperations.last?.reads.first?.mentionCount, 2)
            try await incoming(model, message(400, model: model))
            if confirmation == "newer-count" {
                await ack(model, "{\"channel_id\":\"\(chat)\",\"mention_count\":7}")
            }
            if confirmation != "http" {
                await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"20\",\"manual\":true,\"mention_count\":2}")
                XCTAssertEqual(model.store.mentionCount(chat), confirmation == "newer-count" ? 7 : 3, confirmation)
            }
            await gate.resume(); await save.value
            XCTAssertEqual(model.store.mentionCount(chat), confirmation == "newer-count" ? 7 : 3, confirmation)
        }
    }

    func testConfirmedUnreadTargetDeletionMovesDividerToSurvivor() async throws {
        for bulk in [false, true] {
            let (model, mock) = fixture()
            let history = [message(20, model: model), message(100, model: model), message(300, model: model)]
            mock.setReadHistory(history, channel: chat)
            await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
            await model.markUnread(history[1]).value
            let list = controller(model)
            list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
            XCTAssertEqual(list.unreadTarget, 100)
            let fields: [String: JSONValue] = bulk
                ? ["channel_id": .string(chat.description), "ids": .array([.string("100")])]
                : ["channel_id": .string(chat.description), "id": .string("100")]
            await model.handle(GatewayDispatch(name: bulk ? "MESSAGE_DELETE_BULK" : "MESSAGE_DELETE",
                data: try JSONEncoder().encode(["d": JSONValue.object(fields)])))
            // The representable delivers this same updated model boundary.
            list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
            XCTAssertEqual(model.explicitUnreadTarget(for: chat), 300)
            XCTAssertEqual(list.unreadTarget, 300)
        }
    }

    func testAbsentUnreadTargetInPartialCacheIsRetained() async throws {
        let (model, mock) = fixture()
        mock.setReadHistory((1...120).map { message(Snowflake(UInt64($0 * 10)), model: model) }, channel: chat)
        await model.markUnread(message(100, model: model)).value
        await model.timeline(for: chat).load(around: 900, api: mock, store: model.store)
        let list = controller(model)
        list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
        XCTAssertNil(model.timeline(for: chat).index(of: 100))
        XCTAssertEqual(model.explicitUnreadTarget(for: chat), 100)
        XCTAssertEqual(list.unreadTarget, 100, "Absence alone is not confirmed deletion")
    }

    func testJumpToPresentReleasesCapturedReadCeiling() async throws {
        let (model, mock) = fixture()
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        try await incoming(model, message(400, model: model))
        await gate.resume(); await save.value
        XCTAssertEqual(model.automaticReadCeilings[chat], 300)
        let list = controller(model)
        let coordinator = ListCoordinator(); coordinator.model = model; coordinator.channel = model.store.channel(chat)
        list.host = coordinator
        list.loadViewIfNeeded()
        list.jumpToPresent()
        coordinator.list(didReadUpTo: 400)
        XCTAssertNil(model.automaticReadCeilings[chat])
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 400)
    }

    func testExternalAuthoritySupersedesOlderLocalFingerprints() async {
        for manual in [true, false] {
            let (model, mock) = fixture()
            mock.setReadHistory([message(20, model: model), message(100, model: model), message(300, model: model)], channel: chat)
            if manual { await model.markUnread(message(100, model: model)).value }
            else { await model.markAsRead(channel: chat).value }
            let localID = manual ? 20 : 300, externalID = manual ? 300 : 20
            await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"\(externalID)\",\"manual\":\(!manual),\"version\":11,\"mention_count\":4}")
            await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"\(localID)\",\"manual\":\(manual),\"mention_count\":0}")
            XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, Snowflake(UInt64(externalID)))
            XCTAssertEqual(model.store.manualUnreadChannels.contains(chat), !manual)
            XCTAssertEqual(model.store.mentionCount(chat), 4)
            // A genuinely newer version can reuse an older fingerprint.
            await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"\(localID)\",\"manual\":\(manual),\"version\":12}")
            XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, Snowflake(UInt64(localID)))
            XCTAssertEqual(model.store.manualUnreadChannels.contains(chat), manual)
        }
    }

    func testPendingManualReadCannotReinstallDeletedTarget() async throws {
        let (model, mock) = fixture()
        let history = [message(20, model: model), message(100, model: model), message(300, model: model)]
        mock.setReadHistory(history, channel: chat)
        await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markUnread(history[1])
        await gate.waitUntilPaused()
        await model.handle(GatewayDispatch(name: "MESSAGE_DELETE", data: Data("{\"d\":{\"channel_id\":\"\(chat)\",\"id\":\"100\"}}".utf8)))
        await gate.resume(); await save.value
        XCTAssertEqual(model.explicitUnreadTarget(for: chat), 300)
        XCTAssertTrue(model.unreadTargetOperations.isEmpty)
        let list = controller(model)
        list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
        XCTAssertEqual(list.unreadTarget, 300)
    }

    func testSuspendedUnreadJumpRejectsDeletedResponseIdentity() async {
        for loaded in [true, false] {
            let (model, mock) = fixture()
            mock.setReadHistory([message(20, model: model), message(100, model: model), message(300, model: model)], channel: chat)
            if loaded { await model.timeline(for: chat).loadLatest(api: mock, store: model.store) }
            model.unreadMarkers[chat] = 20
            let gate = ReadGate()
            mock.beforeReadHistoryResponse = { await gate.pause() }
            let jump = model.jumpToUnread(chat)
            await gate.waitUntilPaused()
            await model.handle(GatewayDispatch(name: "MESSAGE_DELETE", data: Data("{\"d\":{\"channel_id\":\"\(chat)\",\"id\":\"100\"}}".utf8)))
            mock.beforeReadHistoryResponse = nil
            await gate.resume(); await jump.value
            XCTAssertTrue(model.unreadTargetOperations.isEmpty)
            XCTAssertNotEqual(model.explicitUnreadTarget(for: chat), 100)
            XCTAssertNotEqual(model.revealRequest?.message, 100)
            if loaded { XCTAssertEqual(model.revealRequest?.message, 300) }
        }
    }

    func testDeletedFirstLoadedUnreadTransfersContiguousSuccessor() async throws {
        let (model, mock) = fixture()
        let history = [message(20, model: model), message(100, model: model)] +
            (3...51).map { message(Snowflake(UInt64($0 * 100)), model: model) }
        mock.setReadHistory(history, channel: chat)
        await model.timeline(for: chat).loadLatest(api: mock, store: model.store)
        XCTAssertEqual(model.timeline(for: chat).messages.first?.id, 100)
        XCTAssertTrue(model.timeline(for: chat).hasMoreBefore)
        await model.markUnread(history[1]).value
        XCTAssertEqual(model.unreadBoundary(for: chat), 20, "Actual predecessor lies outside the cached page")
        await model.handle(GatewayDispatch(name: "MESSAGE_DELETE", data: Data("{\"d\":{\"channel_id\":\"\(chat)\",\"id\":\"100\"}}".utf8)))
        let list = controller(model)
        list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
        XCTAssertEqual(list.unreadTarget, 300)
        XCTAssertNil(model.timeline(for: chat).index(of: 20))
    }

    func testSupersededHTTPDoesNotInstallReadPresentation() async throws {
        let (model, mock) = fixture()
        let old = model.settings.markReadOnServer
        defer { model.settings.markReadOnServer = old }
        model.settings.markReadOnServer = false
        let gate = ReadGate()
        mock.beforeReadResponse = { _ in await gate.pause() }
        let save = model.markAsRead(channel: chat)
        await gate.waitUntilPaused()
        try await incoming(model, message(500, model: model))
        await ack(model, "{\"channel_id\":\"\(chat)\",\"message_id\":\"400\",\"version\":11}")
        await gate.resume(); await save.value
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 400)
        XCTAssertNil(model.automaticReadCeilings[chat])
        model.didRead(channel: chat, upTo: 500)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 500)
    }

    func testUnreadSuccessorDoesNotCrossPendingDeleteRollback() async throws {
        for outstanding in [false, true] {
            let (model, mock) = fixture()
            let history = [message(20, model: model), message(100, model: model),
                           message(200, model: model, own: true), message(300, model: model)]
            mock.setReadHistory(history, channel: chat)
            let timeline = model.timeline(for: chat)
            await timeline.loadLatest(api: mock, store: model.store)
            let gate = ReadGate()
            if outstanding { mock.beforeReadResponse = { _ in await gate.pause() } }
            let read = model.markUnread(history[1])
            if outstanding { await gate.waitUntilPaused() } else { await read.value }
            let writes = ScriptedWrites()
            let deletion = try XCTUnwrap(timeline.sendDelete(200, api: writes))
            for _ in 0..<100 where writes.deletes == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(writes.deletes, 1)
            await model.handle(GatewayDispatch(name: "MESSAGE_DELETE",
                data: Data("{\"d\":{\"channel_id\":\"\(chat)\",\"id\":\"100\"}}".utf8)))
            if outstanding { await gate.resume(); await read.value }
            writes.answerDelete(0, failing: true)
            let removed = await deletion.value
            XCTAssertFalse(removed)
            XCTAssertEqual(timeline.messages.map(\.id), [20, 200, 300])
            let list = controller(model)
            list.setUnreadBoundary(model.unreadBoundary(for: chat), target: model.explicitUnreadTarget(for: chat))
            XCTAssertNotEqual(model.explicitUnreadTarget(for: chat), 300)
            XCTAssertEqual(list.unreadTarget, 200, "The restored unread row must precede the divider's successor")
        }
    }

    func testPredecessorFetchFailureDoesNotSendOrChangeBoundary() async {
        let (model, mock) = fixture()
        mock.failNextReadHistory = true
        await model.markUnread(message(100, model: model)).value
        XCTAssertTrue(mock.readOperations.isEmpty)
        XCTAssertEqual(model.store.readStates[chat]?.lastMessageID, 10)
        XCTAssertFalse(model.store.pendingUnreadChannels.contains(chat))
        XCTAssertFalse(model.store.manualUnreadChannels.contains(chat))
        XCTAssertNotNil(model.readErrors[chat])
        XCTAssertEqual(model.readSaves[chat], 0)
    }

}

private actor ReadGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var answer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            answer = continuation; paused = true
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { answer?.resume(); answer = nil }
}

/// Every request is intercepted, including 429s. This transport cannot reach Discord.
nonisolated private final class ReadWireNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [(String, String, Data?)] = []
    nonisolated(unsafe) private static var code = 200
    static func reset(_ status: Int) { lock.withLock { records = []; code = status } }
    static var requests: [(String, String, Data?)] { lock.withLock { records } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        }
        let code = Self.lock.withLock {
            Self.records.append((request.httpMethod!, request.url!.path, data)); return Self.code
        }
        let body = code == 429 ? #"{"retry_after":0.01}"# : (code == 204 ? "" : #"{"token":null}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                                            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class ReadWireTests: XCTestCase {
    private func rest() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "offline-test", superProperties: nil, userAgent: "offline-test"), protocolClasses: [ReadWireNetwork.self])
    }
    func testManualStandaloneJSONAndZeroSentinelWire() async throws {
        ReadWireNetwork.reset(200)
        try await rest().acknowledge(ReadAcknowledgement(channel: 42, message: 0, manual: true, mentionCount: 3))
        let record = try XCTUnwrap(ReadWireNetwork.requests.first)
        XCTAssertEqual(record.0, "POST")
        XCTAssertEqual(record.1, "/api/v9/channels/42/messages/0/ack")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(record.2)) as! [String: Any]
        XCTAssertEqual(body["manual"] as? Bool, true)
        XCTAssertEqual(body["mention_count"] as? Int, 3)
        XCTAssertTrue(body["token"] is NSNull)
        XCTAssertEqual(Set(body.keys), ["token", "manual", "mention_count"])
    }
    func testBulkAndGuildEmptySuccessSemantics() async throws {
        ReadWireNetwork.reset(204)
        let api = rest()
        try await api.acknowledgeBulk([ReadAcknowledgement(channel: 42, message: 100), ReadAcknowledgement(channel: 43, message: 200)])
        try await api.acknowledgeGuild(50)
        XCTAssertEqual(ReadWireNetwork.requests.map { $0.1 }, ["/api/v9/read-states/ack-bulk", "/api/v9/guilds/50/ack"])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(ReadWireNetwork.requests.first?.2)) as! [String: Any]
        let reads = body["read_states"] as! [[String: Any]]
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[0]["channel_id"] as? String, "42")
        XCTAssertEqual(reads[0]["message_id"] as? String, "100")
        XCTAssertEqual(reads[0]["read_state_type"] as? Int, 0)
        XCTAssertNil(reads[0]["manual"])
    }
    func testReadMutationsAreNotRetriedAfter429() async throws {
        for operation in 0..<3 {
            ReadWireNetwork.reset(429)
            let api = rest()
            do {
                if operation == 0 { try await api.acknowledge(ReadAcknowledgement(channel: 42, message: 100)) }
                else if operation == 1 { try await api.acknowledgeBulk([ReadAcknowledgement(channel: 42, message: 100)]) }
                else { try await api.acknowledgeGuild(50) }
                XCTFail("429 must fail")
            } catch {}
            XCTAssertEqual(ReadWireNetwork.requests.count, 1)
        }
    }
}
