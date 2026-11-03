import XCTest
import UIKit
@testable import DuocordNative

@MainActor
final class PeopleTests: XCTestCase {
    private let chat = MockDiscord.generalChannel
    private func fixture() -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel(peopleAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        model.select(channel: chat)
        return (model, mock)
    }
    private func event(_ model: AppModel, _ name: String, _ fields: [String: JSONValue]) async throws {
        let data = try JSONEncoder().encode(["d": JSONValue.object(fields)])
        await model.handle(GatewayDispatch(name: name, data: data))
    }
    private func relation(_ model: AppModel, id: Snowflake, type: Int?, name: String = "RELATIONSHIP_UPDATE", extra: [String: JSONValue] = [:]) async throws {
        var fields = extra
        fields["id"] = .string(id.description)
        if let type { fields["type"] = .number(Double(type)) }
        try await event(model, name, fields)
    }
    private func message(_ model: AppModel, author: User? = nil) -> Message {
        Message(id: 555, channelID: chat, guildID: model.store.channel(chat)?.guildID,
                author: author ?? MockDiscord.blockedPerson, content: "secret body <:secret:1004>", timestamp: "2026-11-01T00:00:00Z")
    }
    private func incoming(_ model: AppModel, _ message: Message) async throws {
        struct Envelope: Encodable { var d: Message }
        await model.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: message))))
    }

    func testReadyRelationshipsUnknownTypesResetAndPresence() async throws {
        let (model, mock) = fixture()
        XCTAssertEqual(mock.readyPayload().guilds.count, 8)
        XCTAssertEqual(model.store.friends(.all).count, 2)
        XCTAssertEqual(model.store.friends(.pending).count, 2)
        XCTAssertEqual(model.store.friends(.blocked).map(\.id), [MockDiscord.blockedPerson.id])
        let friend = mock.users[0].id
        try await event(model, "READY_SUPPLEMENTAL", ["merged_presences": .object(["friends": .array([
            .object(["user_id": .string(friend.description), "status": .string("online")]),
            .object(["user_id": .string(mock.users[1].id.description), "status": .string("offline")])])])])
        XCTAssertEqual(model.store.friends(.online).map(\.id), [friend])
        try await event(model, "PRESENCE_UPDATE", ["user": .object(["id": .string(friend.description), "global_name": .string("Renamed")])])
        XCTAssertEqual(model.store.presences[friend], .online, "Absent status does not make a friend offline")
        XCTAssertEqual(model.store.users[friend]?.globalName, "Renamed")
        try await relation(model, id: 777, type: 91, name: "RELATIONSHIP_ADD")
        XCTAssertEqual(model.store.friends(.all).count, 2)
        model.store.reset()
        XCTAssertTrue(model.store.relationships.isEmpty)
        XCTAssertTrue(model.store.presences.isEmpty)
        XCTAssertFalse(model.store.isReady)
    }

    func testPartialFieldsNullUncachedAndMismatchedIdentity() async throws {
        let (model, mock) = fixture()
        let id = mock.users[0].id
        try await relation(model, id: id, type: nil, extra: ["nickname": .string("Friend"), "user": .object(["id": .string(id.description), "avatar": .null])])
        XCTAssertEqual(model.store.relationships[id]?.type, 1)
        XCTAssertEqual(model.store.users[id]?.username, mock.users[0].username)
        XCTAssertEqual(model.store.users[id]?.globalName, mock.users[0].globalName)
        XCTAssertNil(model.store.users[id]?.avatar)
        try await relation(model, id: 888, type: 3, name: "RELATIONSHIP_ADD", extra: ["user": .object(["id": .string("888"), "global_name": .string("Uncached")])])
        XCTAssertNil(model.store.users[888])
        try await relation(model, id: 888, type: nil, extra: ["user": .object(["id": .string("888"), "username": .string("new.friend")])])
        XCTAssertEqual(model.store.users[888]?.globalName, "Uncached")
        try await relation(model, id: 889, type: 1, name: "RELATIONSHIP_ADD", extra: ["user": .object(["id": .string(id.description), "username": .string("wrong")])])
        XCTAssertNil(model.store.users[889])
        XCTAssertEqual(model.store.users[id]?.username, mock.users[0].username)
        try await relation(model, id: 888, type: nil, name: "RELATIONSHIP_REMOVE")
        XCTAssertNil(model.store.relationships[888])
        XCTAssertEqual(model.store.users[888]?.username, "new.friend")
    }

    func testSnapshotIsProvisionalAndFreshReadyReplacesIt() async throws {
        let (model, mock) = fixture()
        let snapshot = try XCTUnwrap(model.store.snapshot())
        let restored = AppModel(peopleAPI: mock)
        restored.store.apply(snapshot: snapshot)
        XCTAssertFalse(restored.store.isReady)
        XCTAssertTrue(restored.store.isBlocked(MockDiscord.blockedPerson.id))
        XCTAssertFalse(restored.canChangeRelationship(mock.users[0].id, action: .remove))
        await restored.messageUser(MockDiscord.uncachedFriend.id).value
        XCTAssertTrue(mock.peopleOperations.isEmpty)
        var ready = mock.readyPayload(); ready.relationships = []
        restored.store.apply(ready: ready)
        XCTAssertTrue(restored.store.isReady)
        XCTAssertTrue(restored.store.relationships.isEmpty)
        XCTAssertFalse(restored.store.isBlocked(MockDiscord.blockedPerson.id))
    }

    func testRequestAcceptDeclineCancelRemoveBlockUnblockThroughAPI() async throws {
        let (model, mock) = fixture()
        let id = MockDiscord.uncachedFriend.id
        await model.changeRelationship(id, action: .request, user: MockDiscord.uncachedFriend).value
        XCTAssertEqual(model.store.relationships[id]?.type, 4)
        await model.changeRelationship(id, action: .cancel).value
        XCTAssertNil(model.store.relationships[id])
        let incoming = mock.users[2].id
        await model.changeRelationship(incoming, action: .accept).value
        XCTAssertEqual(model.store.relationships[incoming]?.type, 1)
        await model.changeRelationship(incoming, action: .remove).value
        XCTAssertNil(model.store.relationships[incoming])
        try await relation(model, id: incoming, type: 3, name: "RELATIONSHIP_ADD")
        await model.changeRelationship(incoming, action: .decline).value
        XCTAssertNil(model.store.relationships[incoming])
        await model.changeRelationship(id, action: .block).value
        XCTAssertTrue(model.store.isBlocked(id))
        await model.changeRelationship(id, action: .unblock).value
        XCTAssertNil(model.store.relationships[id])
        XCTAssertEqual(mock.peopleOperations.count, 7)
        XCTAssertEqual(mock.peopleOperations[0].fields, ["type": .number(-1)])
        XCTAssertEqual(mock.peopleOperations[2].fields, ["type": .number(1)])
        XCTAssertNil(mock.peopleOperations[1].fields)
    }

    func testFailureDoesNotApplyAndExplicitRetrySucceeds() async {
        let (model, mock) = fixture(); let id = mock.users[2].id
        mock.failNextPeople = true
        await model.changeRelationship(id, action: .accept).value
        XCTAssertEqual(model.store.relationships[id]?.type, 3)
        XCTAssertNotNil(model.people.errors[id])
        XCTAssertEqual(mock.peopleOperations.count, 1)
        await model.changeRelationship(id, action: .accept).value
        XCTAssertEqual(model.store.relationships[id]?.type, 1)
        XCTAssertNil(model.people.errors[id])
    }

    func testGatewayPartialFencesHeldSuccess() async throws {
        let (model, mock) = fixture(); let id = mock.users[0].id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.changeRelationship(id, action: .block)
        await gate.waitUntilPaused()
        try await relation(model, id: id, type: nil, extra: ["nickname": .string("newer")])
        await gate.resume(); await task.value
        XCTAssertEqual(model.store.relationships[id]?.type, 1)
        XCTAssertEqual(model.store.relationships[id]?.fields["nickname"], .string("newer"))
    }

    func testGatewayAcceptedStateFencesHeldFailure() async throws {
        let (model, mock) = fixture(); let id = mock.users[2].id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "held failure") }
        let task = model.changeRelationship(id, action: .accept)
        await gate.waitUntilPaused()
        try await relation(model, id: id, type: 1, name: "RELATIONSHIP_ADD")
        try await relation(model, id: id, type: nil, extra: ["user": .object(["id": .string(id.description), "global_name": .string("Fresh")])])
        await gate.resume(); await task.value
        XCTAssertEqual(model.store.relationships[id]?.type, 1)
        XCTAssertEqual(model.store.users[id]?.globalName, "Fresh")
        XCTAssertNil(model.people.errors[id])
    }

    func testHTTPThenGatewayRemoveAndBlockOwnLatestState() async throws {
        let (model, mock) = fixture(); let id = mock.users[2].id
        await model.changeRelationship(id, action: .accept).value
        try await relation(model, id: id, type: nil, name: "RELATIONSHIP_REMOVE")
        XCTAssertNil(model.store.relationships[id])
        await model.changeRelationship(id, action: .request).value
        try await relation(model, id: id, type: 2, name: "RELATIONSHIP_ADD")
        XCTAssertTrue(model.store.isBlocked(id))
        XCTAssertEqual(model.store.friends(.pending).count, 1)
    }

    func testQueuedConflictIsFIFOAndDuplicateTapCoalesces() async throws {
        let (model, mock) = fixture(); let id = mock.users[0].id; let gate = PeopleGate()
        mock.beforePeopleResponse = { record in if record.fields?["type"] == .number(2) { await gate.pause() } }
        let first = model.changeRelationship(id, action: .block)
        let duplicate = model.changeRelationship(id, action: .block)
        await gate.waitUntilPaused()
        let second = model.changeRelationship(id, action: .remove)
        XCTAssertEqual(mock.peopleOperations.count, 1)
        await gate.resume(); await first.value; await duplicate.value; await second.value
        XCTAssertTrue(model.store.isBlocked(id))
        XCTAssertEqual(mock.peopleOperations.count, 1, "Queued Remove is inapplicable after Block succeeds")
        XCTAssertEqual(model.people.saving[id], 0)
    }

    func testQueuedBlockRunsAfterRequestWithoutReordering() async {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { record in if record.fields?["type"] == .number(-1) { await gate.pause() } }
        let request = model.changeRelationship(id, action: .request)
        await gate.waitUntilPaused()
        let block = model.changeRelationship(id, action: .block)
        await gate.resume(); await request.value; await block.value
        XCTAssertTrue(model.store.isBlocked(id))
        XCTAssertEqual(mock.peopleOperations.map { $0.fields?["type"] }, [.number(-1), .number(2)])
    }

    func testOldSessionRelationshipCompletionCannotMutateOrReportError() async {
        let (model, mock) = fixture(); let id = mock.users[0].id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old") }
        let task = model.changeRelationship(id, action: .block)
        await gate.waitUntilPaused()
        model.store.reset(); model.store.apply(ready: mock.readyPayload())
        await gate.resume(); await task.value
        XCTAssertEqual(model.store.relationships[id]?.type, 1)
        XCTAssertTrue(model.people.errors.isEmpty)
        XCTAssertTrue(model.people.saving.isEmpty)
    }

    func testUsernameRequestUsesNullDiscriminatorAndGatewayIdentityOnly() async throws {
        let (model, mock) = fixture()
        await model.addFriend(username: "uncached.friend").value
        XCTAssertEqual(mock.peopleOperations.first?.fields, ["username": .string("uncached.friend"), "discriminator": .null])
        XCTAssertNil(model.store.relationships[MockDiscord.uncachedFriend.id], "204 alone supplies no identity")
        let result = Relationship(id: MockDiscord.uncachedFriend.id, type: 4, user: MockDiscord.uncachedFriend)
        try await event(model, "RELATIONSHIP_ADD", result.fields)
        XCTAssertEqual(model.store.users[result.id]?.username, "uncached.friend")
        XCTAssertEqual(model.store.relationships[result.id]?.type, 4)
        await model.addFriend(username: "does.not.exist").value
        XCTAssertTrue(model.people.usernameFeedback?.contains("Couldn’t") == true)
        let count = mock.peopleOperations.count
        for invalid in ["name#1234", "12345678901234567890@", "UPPER", "a..b", "x", mock.me.username] { await model.addFriend(username: invalid).value }
        XCTAssertEqual(mock.peopleOperations.count, count)
    }

    func testUsernameGatewayAddThenRemoveFencesHeldHTTPFailure() async throws {
        let (model, mock) = fixture(); let gate = PeopleGate(); let user = MockDiscord.uncachedFriend
        mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old failure") }
        let task = model.addFriend(username: user.username)
        await gate.waitUntilPaused()
        try await event(model, "RELATIONSHIP_ADD", Relationship(id: user.id, type: 4, user: user).fields)
        try await relation(model, id: user.id, type: nil, name: "RELATIONSHIP_REMOVE")
        await gate.resume(); await task.value
        XCTAssertNil(model.store.relationships[user.id])
        XCTAssertNil(model.people.usernameFeedback)
        XCTAssertFalse(model.people.requestingUsername)
    }

    func testNotificationOnlyMockRetainedWithoutPeopleOrReadAuthorization() async {
        let mock = MockDiscord(); let model = AppModel(notificationAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        await model.changeRelationship(mock.users[0].id, action: .block).value
        await model.messageUser(MockDiscord.uncachedFriend.id).value
        model.signIn(with: SessionCredentials(token: "never-used", superProperties: nil, userAgent: "offline"), persist: false)
        XCTAssertFalse(model.isMock)
        XCTAssertFalse(model.allowsReadWrites)
        XCTAssertFalse(model.allowsPeopleWrites)
        XCTAssertTrue((model.api as? MockDiscord) === mock)
        XCTAssertTrue(mock.peopleOperations.isEmpty)
    }

    func testExistingDMSelectsWithoutCreateAndPreservesOtherDraftAnchorFocus() async {
        let (model, mock) = fixture(); let user = mock.users[0]
        model.drafts[chat] = Draft(text: "keep me")
        let anchor = ScrollAnchor(itemID: "m10", offset: -12, pinnedToBottom: false)
        model.anchors[chat] = anchor
        await model.messageUser(user.id).value
        XCTAssertEqual(model.selectedChannel, mock.dms[0].id)
        XCTAssertTrue(mock.peopleOperations.isEmpty)
        XCTAssertEqual(model.drafts[chat]?.text, "keep me")
        XCTAssertEqual(model.anchors[chat], anchor)
        XCTAssertNil(model.revealRequest)
    }

    func testRepeatedMessageCoalescesAndCreatesSelectsDM() async {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let first = model.messageUser(id)
        await gate.waitUntilPaused()
        let second = model.messageUser(id)
        XCTAssertEqual(mock.peopleOperations.count, 1)
        await gate.resume(); await first.value; await second.value
        XCTAssertEqual(model.store.directMessage(to: id)?.id, model.selectedChannel)
        XCTAssertNotNil(model.selectedChannel)
        XCTAssertEqual(mock.peopleOperations.first?.fields, ["recipients": .array([.string(id.description)])])
        XCTAssertTrue(model.people.opening.isEmpty)
    }

    func testOlderDMCompletionCannotStealNewSelectionOrFriendsRoute() async {
        let (model, mock) = fixture(); let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.messageUser(MockDiscord.uncachedFriend.id)
        await gate.waitUntilPaused()
        model.select(channel: mock.dms[1].id)
        model.present(.friends)
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, mock.dms[1].id)
        XCTAssertNotNil(model.store.directMessage(to: MockDiscord.uncachedFriend.id))
        XCTAssertTrue(model.sheet == .friends || model.sidebarPanel == .friends)
    }

    func testNewProfileNavigationFencesOlderDMCompletion() async {
        let (model, mock) = fixture(); let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.messageUser(MockDiscord.uncachedFriend.id)
        await gate.waitUntilPaused()
        model.sheet = .user(mock.users[1].id)
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertEqual(model.sheet, .user(mock.users[1].id))
        XCTAssertNotNil(model.store.directMessage(to: MockDiscord.uncachedFriend.id))
    }

    func testNewerRecipientWinsOutOfOrderDMCompletions() async {
        let (model, mock) = fixture(); let gate = PeopleGate(); let id = MockDiscord.uncachedFriend.id
        mock.beforePeopleResponse = { record in if record.fields == ["recipients": .array([.string(id.description)])] { await gate.pause() } }
        let older = model.messageUser(id)
        await gate.waitUntilPaused()
        await model.messageUser(mock.users[9].id).value
        let selected = model.selectedChannel
        await gate.resume(); await older.value
        XCTAssertEqual(model.selectedChannel, selected)
        XCTAssertEqual(model.store.directMessage(to: mock.users[9].id)?.id, selected)
    }

    func testDMFailureKeepsNavigationAndExplicitRetrySucceeds() async {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id
        mock.failNextPeople = true
        await model.messageUser(id).value
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertNil(model.store.directMessage(to: id))
        XCTAssertNotNil(model.people.dmErrors[id])
        await model.messageUser(id).value
        XCTAssertEqual(model.selectedChannel, model.store.directMessage(to: id)?.id)
        XCTAssertNil(model.people.dmErrors[id])
        XCTAssertEqual(mock.peopleOperations.count, 2)
    }

    func testNewerChannelGatewayFencesHeldDMResponse() async throws {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.messageUser(id)
        await gate.waitUntilPaused()
        try await event(model, "CHANNEL_CREATE", ["id": .string("778"), "type": .number(1), "recipient_ids": .array([.string(id.description)])])
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, 778)
        XCTAssertEqual(model.store.directMessage(to: id)?.id, 778)
        XCTAssertNil(model.store.channel(Snowflake(930_000_000_000_000_400)))
    }

    func testNewerChannelCreateFencesHeldDMFailure() async throws {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old failure") }
        let task = model.messageUser(id)
        await gate.waitUntilPaused()
        try await event(model, "CHANNEL_CREATE", ["id": .string("778"), "type": .number(1), "recipient_ids": .array([.string(id.description)])])
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, 778)
        XCTAssertNil(model.people.dmErrors[id])
    }

    func testNewerChannelDeletePreventsOldDMResponseResurrection() async throws {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.messageUser(id)
        await gate.waitUntilPaused()
        try await event(model, "CHANNEL_CREATE", ["id": .string("778"), "type": .number(1), "recipient_ids": .array([.string(id.description)])])
        try await event(model, "CHANNEL_DELETE", ["id": .string("778")])
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertNil(model.store.directMessage(to: id))
    }

    func testOldSessionDMDoesNotUpsertSelectOrClearNewState() async {
        let (model, mock) = fixture(); let gate = PeopleGate(); let id = MockDiscord.uncachedFriend.id
        mock.beforePeopleResponse = { _ in await gate.pause() }
        let task = model.messageUser(id)
        await gate.waitUntilPaused()
        model.signOut()
        model.store.apply(ready: mock.readyPayload())
        model.select(channel: chat)
        await gate.resume(); await task.value
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertNil(model.store.directMessage(to: id))
        XCTAssertTrue(model.people.dmErrors.isEmpty)
        XCTAssertTrue(model.people.opening.isEmpty)
    }

    func testMockInjectionCannotBeReplacedByLiveSignIn() async {
        let (model, mock) = fixture()
        model.signIn(with: SessionCredentials(token: "never-used", superProperties: nil, userAgent: "offline"), persist: false)
        XCTAssertTrue((model.api as? MockDiscord) === mock)
        XCTAssertTrue(model.isMock)
        let real = AppModel(notificationAPI: OfflineAPI())
        real.store.apply(ready: mock.readyPayload())
        await real.changeRelationship(mock.users[0].id, action: .block).value
        await real.messageUser(MockDiscord.uncachedFriend.id).value
        await real.addFriend(username: "uncached.friend").value
        XCTAssertFalse(real.store.isBlocked(mock.users[0].id))
        XCTAssertNotNil(real.people.errors[mock.users[0].id])
        XCTAssertNotNil(real.people.dmErrors[MockDiscord.uncachedFriend.id])
        XCTAssertTrue(mock.peopleOperations.isEmpty)
    }

    func testSelfAndInapplicableActionsDoNotSendOrCreate() async {
        let (model, mock) = fixture()
        for action in RelationshipAction.allCases { await model.changeRelationship(mock.me.id, action: action).value }
        await model.messageUser(mock.me.id).value
        await model.messageUser(MockDiscord.blockedPerson.id).value
        await model.changeRelationship(mock.users[0].id, action: .accept).value
        XCTAssertTrue(mock.peopleOperations.isEmpty)
    }

    func testActualDispatchRoutesOnlyUnblockedNotificationsToService() async throws {
        let (model, _) = fixture()
        let enabled = model.settings.notificationsEnabled
        defer { model.settings.notificationsEnabled = enabled; model.notifications.mockPostObserver = nil }
        model.settings.notificationsEnabled = true
        model.select(channel: nil)
        var deliveries: [Snowflake] = []
        model.notifications.mockPostObserver = { deliveries.append($0) }
        let msg = message(model)
        try await incoming(model, msg)
        XCTAssertTrue(deliveries.isEmpty)
        await model.changeRelationship(msg.author.id, action: .unblock).value
        var next = msg; next.id = 556; next.mentions = [model.store.me!]
        try await incoming(model, next)
        XCTAssertEqual(deliveries, [next.id])
    }

    func testLoadedControllerRefreshesBlockedCellsWithoutChangingAnchorIdentity() async throws {
        let (model, _) = fixture(); let msg = message(model); let timeline = model.timeline(for: chat)
        timeline.seed([msg])
        let controller = MessageListController(timeline: timeline, store: model.store, api: model.api, guildID: msg.guildID,
            title: "offline", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        controller.viewDidLayoutSubviews()
        let hidden = try XCTUnwrap((timeline.renderCache as? ListRenderCache)?.rendered[msg.id])
        XCTAssertTrue(hidden.hidesBlocked)
        model.store.revealBlockedMessage(msg.id)
        let shown = try XCTUnwrap((timeline.renderCache as? ListRenderCache)?.rendered[msg.id])
        XCTAssertFalse(shown.hidesBlocked)
        XCTAssertEqual(shown.id, hidden.id)
        await model.changeRelationship(msg.author.id, action: .unblock).value
        await model.changeRelationship(msg.author.id, action: .block).value
        let blocked = try XCTUnwrap((timeline.renderCache as? ListRenderCache)?.rendered[msg.id])
        XCTAssertTrue(blocked.hidesBlocked)
        XCTAssertEqual(blocked.id, msg.id)
        XCTAssertEqual(timeline.messages.map(\.id), [msg.id])
    }

    func testBlockedIncomingSuppressesNotificationsRetainsHistoryAndUnread() async throws {
        let (model, _) = fixture(); var msg = message(model)
        msg.mentions = [model.store.me!]
        model.select(channel: nil)
        let timeline = model.timeline(for: chat)
        try await incoming(model, msg)
        XCTAssertFalse(model.store.shouldNotify(msg))
        XCTAssertEqual(timeline.messages.map(\.id), [msg.id])
        XCTAssertEqual(model.store.mentionCount(chat), 1, "Blocking does not rewrite reviewed unread authority")
        await model.changeRelationship(msg.author.id, action: .unblock).value
        XCTAssertTrue(model.store.shouldNotify(msg))
    }

    func testBlockedRenderBoundaryMasksBodyAttachmentsEmbedsAccessibilityAndMedia() async throws {
        let (model, _) = fixture(); var msg = message(model)
        msg.attachments = [Attachment(id: 88, filename: "secret-file.png", size: 12, url: "mock://secret/file", width: 50, height: 50)]
        msg.embeds = [Embed(type: "rich", title: "secret embed", description: "secret description", thumbnail: EmbedMedia(url: "mock://secret/thumb", width: 50, height: 50))]
        msg.referencedMessage = MessageBox(msg)
        let builder = MessageBuilder(store: model.store, guildID: msg.guildID)
        let rendered = builder.render(msg, previous: nil, context: builder.context(), sendState: nil)
        XCTAssertEqual(rendered.id, msg.id)
        XCTAssertTrue(rendered.hidesBlocked)
        XCTAssertNil(rendered.avatarURL)
        XCTAssertNil(rendered.reply)
        XCTAssertTrue(rendered.media.isEmpty && rendered.files.isEmpty && rendered.embeds.isEmpty && rendered.reactions.isEmpty)
        XCTAssertFalse(rendered.accessibilityText.contains("secret"))
        XCTAssertFalse(rendered.body?.string.contains("secret") == true)
        let cell = MessageCell(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let layout = MessageLayoutEngine.layout(rendered, width: 400)
        cell.configure(rendered, layout: layout, width: 400)
        XCTAssertFalse(cell.accessibilityLabel?.contains("secret") == true)
        XCTAssertEqual(cell.accessibilityCustomActions?.map(\.name), ["Reveal blocked message"])
    }

    func testRevealUnblockReblockInvalidateLoadedCacheAndPreserveIdentity() async throws {
        let (model, _) = fixture(); let msg = message(model); let timeline = model.timeline(for: chat)
        timeline.seed([msg])
        var updates = 0
        let observer = timeline.observe { _ in updates += 1 }
        defer { timeline.stopObserving(observer) }
        let builder = MessageBuilder(store: model.store, guildID: msg.guildID)
        let hidden = builder.render(msg, previous: nil, context: builder.context(), sendState: nil)
        let cache = ListRenderCache(category: .large); cache.rendered[msg.id] = hidden; timeline.renderCache = cache
        let revision = model.store.privacyRevision
        model.store.revealBlockedMessage(msg.id)
        XCTAssertNil(timeline.renderCache)
        XCTAssertGreaterThan(model.store.privacyRevision, revision)
        let shown = builder.render(msg, previous: nil, context: builder.context(), sendState: nil)
        XCTAssertFalse(shown.hidesBlocked)
        XCTAssertNotEqual(shown.source, hidden.source)
        XCTAssertTrue(shown.body?.string.contains("secret") == true)
        await model.changeRelationship(msg.author.id, action: .unblock).value
        await model.changeRelationship(msg.author.id, action: .block).value
        XCTAssertTrue(model.store.hidesBlockedMessage(msg))
        XCTAssertEqual(timeline.messages.map(\.id), [msg.id])
        XCTAssertGreaterThanOrEqual(updates, 3)
    }

    func testReplyToBlockedAuthorMasksPreviewButKeepsJumpIdentity() async throws {
        let (model, mock) = fixture(); let hidden = message(model)
        var reply = message(model, author: mock.users[0]); reply.id = 556; reply.content = "safe reply"
        reply.referencedMessage = MessageBox(hidden); reply.type = 19
        let builder = MessageBuilder(store: model.store, guildID: reply.guildID)
        let rendered = builder.render(reply, previous: hidden, context: builder.context(), sendState: nil)
        XCTAssertEqual(rendered.reply?.messageID, hidden.id)
        XCTAssertEqual(rendered.reply?.snippet, "Blocked message")
        XCTAssertNil(rendered.reply?.avatarURL)
        XCTAssertFalse(rendered.accessibilityText.contains("secret"))
    }

    func testBlockedRevealReceivesLabelTapsAfterReuse() throws {
        let (model, mock) = fixture()
        let hidden = message(model)
        let builder = MessageBuilder(store: model.store, guildID: hidden.guildID)
        let cell = MessageCell(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let shown = builder.render(message(model, author: mock.users[0]), previous: nil, context: builder.context(), sendState: nil)
        cell.configure(shown, layout: MessageLayoutEngine.layout(shown, width: 400), width: 400)
        let rendered = builder.render(hidden, previous: nil, context: builder.context(), sendState: nil)
        let layout = MessageLayoutEngine.layout(rendered, width: 400)
        cell.frame.size.height = layout.height
        cell.configure(rendered, layout: layout, width: 400)
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Reveal blocked message" })
        let point = cell.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let target = try XCTUnwrap(cell.hitTest(point, with: nil))
        XCTAssertTrue(target === button || target.isDescendant(of: button), "The visible Reveal label must hit its action")
    }

    func testMismatchedRelationshipUserCannotAcquireIdentityThroughSnapshot() async throws {
        let (model, mock) = fixture()
        let id: Snowflake = 42
        try await relation(model, id: id, type: 4, name: "RELATIONSHIP_ADD", extra: ["user": .object([
            "id": .string("99"), "username": .string("wrong.person"), "avatar": .string("wrong-avatar")])])
        XCTAssertNil(model.store.relationships[id]?.fields["user"])
        try await relation(model, id: id, type: nil, extra: ["user": .object(["id": .string(id.description)])])
        XCTAssertNil(model.store.users[id])
        let snapshot = try XCTUnwrap(model.store.snapshot())
        let restored = AppModel(peopleAPI: mock)
        restored.store.apply(snapshot: try JSONDecoder().decode(StoreSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertNil(restored.store.users[id])
        XCTAssertNil(restored.store.relationships[id]?.userFields?["username"])
        try await relation(model, id: id, type: nil, extra: ["user": .object([
            "id": .string(id.description), "username": .string("right.person"), "avatar": .string("right-avatar")])])
        try await relation(model, id: id, type: nil, extra: ["user": .object([
            "id": .string("99"), "username": .string("wrong.again"), "avatar": .null])])
        try await relation(model, id: id, type: nil, extra: ["user": .object(["id": .string(id.description)])])
        let valid = AppModel(peopleAPI: mock)
        valid.store.apply(snapshot: try XCTUnwrap(model.store.snapshot()))
        XCTAssertEqual(valid.store.users[id]?.username, "right.person")
        XCTAssertEqual(valid.store.users[id]?.avatar, "right-avatar")
    }

    func testQueuedBlockClearsPredecessorRequestFailure() async {
        let (model, mock) = fixture(); let id = MockDiscord.uncachedFriend.id; let gate = PeopleGate()
        mock.beforePeopleResponse = { record in
            if record.fields?["type"] == .number(-1) {
                await gate.pause()
                throw DiscordError.http(500, "request failed")
            }
        }
        let request = model.changeRelationship(id, action: .request)
        await gate.waitUntilPaused()
        let block = model.changeRelationship(id, action: .block)
        await gate.resume(); await request.value; await block.value
        XCTAssertTrue(model.store.isBlocked(id))
        XCTAssertNil(model.people.errors[id])
        XCTAssertEqual(model.people.saving[id], 0)
        XCTAssertEqual(mock.peopleOperations.count, 2)
    }

    func testPresenceResolvedRelationshipUsernameFencesHeldRequestFailure() async throws {
        for supplemental in [false, true] {
            let (model, mock) = fixture(); let gate = PeopleGate(); let id: Snowflake = 42
            mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old failure") }
            let task = model.addFriend(username: "new.friend")
            await gate.waitUntilPaused()
            try await relation(model, id: id, type: 4, name: "RELATIONSHIP_ADD")
            let user: JSONValue = .object(["id": .string(id.description), "username": .string("new.friend")])
            if supplemental {
                try await event(model, "READY_SUPPLEMENTAL", ["merged_presences": .object(["friends": .array([
                    .object(["user": user, "status": .string("online")])])])])
            } else {
                try await event(model, "PRESENCE_UPDATE", ["user": user, "status": .string("online")])
            }
            XCTAssertEqual(model.store.users[id]?.username, "new.friend")
            XCTAssertGreaterThan(model.store.usernameVersion("new.friend"), 0)
            await gate.resume(); await task.value
            XCTAssertEqual(model.store.relationships[id]?.type, 4)
            XCTAssertNil(model.people.usernameFeedback)
            XCTAssertFalse(model.people.requestingUsername)
        }
        // A name without relationship activity cannot turn failure into success.
        let (model, mock) = fixture(); let gate = PeopleGate()
        mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "actual failure") }
        let task = model.addFriend(username: "new.friend")
        await gate.waitUntilPaused()
        try await event(model, "PRESENCE_UPDATE", ["user": .object(["id": .string("42"), "username": .string("new.friend")])])
        XCTAssertEqual(model.store.usernameVersion("new.friend"), 0)
        await gate.resume(); await task.value
        XCTAssertTrue(model.people.usernameFeedback?.contains("Couldn’t") == true)
    }

    func testHistoricalRelationshipNameResolutionDoesNotFenceNewRequest() async throws {
        for removed in [false, true] {
            let (model, mock) = fixture(); let gate = PeopleGate(); let id: Snowflake = 42
            try await relation(model, id: id, type: 4, name: "RELATIONSHIP_ADD", extra: ["user": .object([
                "id": .string(id.description), "username": .string("old.friend")])])
            if removed { try await relation(model, id: id, type: nil, name: "RELATIONSHIP_REMOVE") }
            mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "new request failed") }
            let task = model.addFriend(username: "old.friend")
            await gate.waitUntilPaused()
            try await event(model, "PRESENCE_UPDATE", ["user": .object([
                "id": .string(id.description), "username": .string("new.friend")])])
            await gate.resume(); await task.value
            XCTAssertTrue(model.people.usernameFeedback?.contains("Couldn’t") == true,
                "Pre-request relationship activity cannot hide a new request failure")
            XCTAssertEqual(model.store.relationships[id]?.type, removed ? nil : 4)
        }
    }

    func testGatewayNameConfirmationFencesAfterOtherCachePopulation() async throws {
        for channelCache in [false, true] {
            for removed in [false, true] {
                for supplemental in [false, true] {
                    let (model, mock) = fixture(); let gate = PeopleGate(); let id: Snowflake = 42
                    mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old failure") }
                    let task = model.addFriend(username: "new.friend")
                    await gate.waitUntilPaused()
                    try await relation(model, id: id, type: 4, name: "RELATIONSHIP_ADD")
                    if removed { try await relation(model, id: id, type: nil, name: "RELATIONSHIP_REMOVE") }
                    let user: JSONValue = .object(["id": .string(id.description), "username": .string("new.friend")])
                    if channelCache {
                        try await event(model, "CHANNEL_CREATE", ["id": .string("7788"), "type": .number(1), "recipients": .array([user])])
                    } else {
                        model.store.remember(person: User(id: id, username: "new.friend"))
                    }
                    XCTAssertEqual(model.store.users[id]?.username, "new.friend")
                    XCTAssertEqual(model.store.usernameVersion("new.friend"), 0, "General cache data does not establish relationship authority")
                    if supplemental {
                        try await event(model, "READY_SUPPLEMENTAL", ["merged_presences": .object(["friends": .array([
                            .object(["user": user, "status": .string("online")])])])])
                    } else {
                        try await event(model, "PRESENCE_UPDATE", ["user": user, "status": .string("online")])
                    }
                    await gate.resume(); await task.value
                    XCTAssertNil(model.people.usernameFeedback, "Gateway name confirmation owns the post-request relationship event, even after removal")
                    XCTAssertEqual(model.store.relationships[id]?.type, removed ? nil : 4)
                }
            }
        }
    }

    func testGatewayRenameRetainsRequestedNameAuthority() async throws {
        for channelCache in [false, true] {
            for removed in [false, true] {
                for supplemental in [false, true] {
                    let (model, mock) = fixture(); let gate = PeopleGate(); let id: Snowflake = 42
                    mock.beforePeopleResponse = { _ in await gate.pause(); throw DiscordError.http(500, "old failure") }
                    let task = model.addFriend(username: "old.friend")
                    await gate.waitUntilPaused()
                    try await relation(model, id: id, type: 4, name: "RELATIONSHIP_ADD")
                    if removed { try await relation(model, id: id, type: nil, name: "RELATIONSHIP_REMOVE") }
                    if channelCache {
                        try await event(model, "CHANNEL_CREATE", ["id": .string("7788"), "type": .number(1), "recipients": .array([
                            .object(["id": .string(id.description), "username": .string("old.friend")])])])
                    } else {
                        model.store.remember(person: User(id: id, username: "old.friend"))
                    }
                    let generation = model.store.relationshipGeneration
                    let idOnly: JSONValue = .object(["id": .string(id.description)])
                    let renamed: JSONValue = .object(["id": .string(id.description), "username": .string("new.friend")])
                    for user in [idOnly, renamed] {
                        if supplemental {
                            try await event(model, "READY_SUPPLEMENTAL", ["merged_presences": .object(["friends": .array([
                                .object(["user": user, "status": .string("online")])])])])
                        } else {
                            try await event(model, "PRESENCE_UPDATE", ["user": user, "status": .string("online")])
                        }
                        if user == idOnly {
                            XCTAssertEqual(model.store.usernameVersion("old.friend"), 0, "ID-only presence must not adopt a cached name")
                        }
                    }
                    XCTAssertEqual(model.store.relationshipGeneration, generation, "A rename must keep its originating generation")
                    XCTAssertEqual(model.store.usernameVersion("old.friend"), generation)
                    XCTAssertEqual(model.store.usernameVersion("new.friend"), generation)
                    await gate.resume(); await task.value
                    XCTAssertNil(model.people.usernameFeedback)
                    XCTAssertEqual(model.store.relationships[id]?.type, removed ? nil : 4)
                }
            }
        }
    }

    func testFriendsAdaptiveTransferKeepsConversationDraftAndAnchor() {
        let (model, _) = fixture()
        model.drafts[chat] = Draft(text: "preserved")
        let anchor = ScrollAnchor(itemID: "m20", offset: -2, pinnedToBottom: false)
        model.anchors[chat] = anchor
        model.fold.isCompact = false; model.present(.friends)
        XCTAssertEqual(model.sidebarPanel, .friends)
        model.fold.isCompact = true; model.sizeClassChanged(compact: true)
        XCTAssertEqual(model.sheet, .friends); XCTAssertNil(model.sidebarPanel)
        model.fold.isCompact = false; model.sizeClassChanged(compact: false)
        XCTAssertNil(model.sheet); XCTAssertEqual(model.sidebarPanel, .friends)
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertEqual(model.drafts[chat]?.text, "preserved")
        XCTAssertEqual(model.anchors[chat], anchor)
    }
}

private actor PeopleGate {
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

/// Every URL is intercepted; no DNS, socket or authenticated Discord request.
nonisolated private final class PeopleWireNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [(String, String, Data?)] = []
    nonisolated(unsafe) private static var code = 204
    static func reset(_ status: Int) { lock.withLock { records = []; code = status } }
    static var requests: [(String, String, Data?)] { lock.withLock { records } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            body = result
        }
        let status = Self.lock.withLock {
            Self.records.append((request.httpMethod!, request.url!.path, body)); return Self.code
        }
        let response = status == 429 ? #"{"retry_after":0.01}"# : status == 204 ? "" : #"{"id":"778","type":1,"recipients":[{"id":"42","username":"friend"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class PeopleWireTests: XCTestCase {
    private func rest() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "offline-test", superProperties: nil, userAgent: "offline-test"), protocolClasses: [PeopleWireNetwork.self])
    }
    func testTypedRelationshipsAcceptEmpty204AndUseDocumentedBodies() async throws {
        PeopleWireNetwork.reset(204)
        let api = rest()
        for action in RelationshipAction.allCases { try await api.relationship(user: 42, action: action) }
        try await api.requestFriend(username: XCTUnwrap(FriendUsername("new.friend")))
        let requests = PeopleWireNetwork.requests
        XCTAssertEqual(requests.count, 8)
        for (index, action) in RelationshipAction.allCases.enumerated() {
            XCTAssertEqual(requests[index].0, action.method)
            XCTAssertEqual(requests[index].1, "/api/v9/users/@me/relationships/42")
            if let fields = action.body {
                XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(requests[index].2)), fields)
            } else { XCTAssertTrue(requests[index].2 == nil || requests[index].2?.isEmpty == true) }
        }
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(requests.last?.2)),
            ["username": .string("new.friend"), "discriminator": .null])
    }
    func testTypedCreateDMDecodesChannelAndUsesOneRecipient() async throws {
        PeopleWireNetwork.reset(200)
        let channel = try await rest().createDM(recipient: 42)
        XCTAssertEqual(channel.id, 778)
        XCTAssertEqual(channel.type, .dm)
        XCTAssertEqual(channel.recipients?.map(\.id), [42])
        let request = try XCTUnwrap(PeopleWireNetwork.requests.first)
        XCTAssertEqual(request.0, "POST")
        XCTAssertEqual(request.1, "/api/v9/users/@me/channels")
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(request.2)), ["recipients": .array([.string("42")])])
    }
    func testPeopleWritesAreNotRetriedAfter429AndOfflineFailsClosed() async {
        for operation in 0..<3 {
            PeopleWireNetwork.reset(429)
            do {
                if operation == 0 { try await rest().relationship(user: 42, action: .block) }
                else if operation == 1 { try await rest().requestFriend(username: FriendUsername("new.friend")!) }
                else { _ = try await rest().createDM(recipient: 42) }
                XCTFail("429 must fail")
            } catch {}
            XCTAssertEqual(PeopleWireNetwork.requests.count, 1)
        }
        do { try await OfflineAPI().relationship(user: 42, action: .block); XCTFail() } catch {}
        do { try await OfflineAPI().requestFriend(username: FriendUsername("new.friend")!); XCTFail() } catch {}
        do { _ = try await OfflineAPI().createDM(recipient: 42); XCTFail() } catch {}
    }
}
