import XCTest
@testable import DuocordNative

/// A privacy change redraws every open conversation, so one READY or gateway
/// event announces it once, however many relationships or channels it changes.
/// Announcing each one froze the app for seconds after launch.
@MainActor
final class PrivacyChangeBatchingTests: XCTestCase {
    private typealias F = MockDiscord.ThreadFixture

    private func ready(blocked: Int) -> ReadyPayload {
        let chat = Channel(id: 300, type: .text, guildID: 100, name: "general", lastMessageID: 20)
        let everyone = Role(id: 100, name: "@everyone", color: 0, position: 0, permissions: String(Permission.viewChannel))
        var payload = ReadyPayload(user: User(id: 1, username: "me"), guilds: [Guild(id: 100, name: "Fixture", roles: [everyone], channels: [chat])],
                                   privateChannels: [], users: [], mergedMembers: [], readStates: [], guildSettings: [], settingsProto: nil)
        payload.relationships = (0..<blocked).map { Relationship(id: Snowflake(5_000 + UInt64($0)), type: 2) }
        return payload
    }

    private func threadSync(guild: Snowflake, parent: Snowflake, count: Int) -> GatewayDispatch {
        let threads = (0..<count).map { #"{"id":"\#(7_000 + $0)","type":11,"parent_id":"\#(parent)","name":"Thread \#($0)","thread_metadata":{"archived":false}}"# }
        return GatewayDispatch(name: "THREAD_LIST_SYNC", data: Data(#"{"d":{"guild_id":"\#(guild)","threads":[\#(threads.joined(separator: ","))]}}"#.utf8))
    }

    func testReadyWithBlockedPeopleAnnouncesOnePrivacyChange() {
        let store = DiscordStore()
        var announcements = 0
        var blockedWhenAnnounced: [Bool] = []
        store.onPrivacyChange = {
            announcements += 1
            blockedWhenAnnounced.append(store.isBlocked(5_000) && store.isBlocked(5_019))
        }
        store.apply(ready: ready(blocked: 20))
        XCTAssertEqual(announcements, 1)
        XCTAssertEqual(blockedWhenAnnounced, [true], "listeners redraw from the finished state, not a half-applied READY")
    }

    func testThreadListSyncOfUnseenThreadsAnnouncesOnePrivacyChange() {
        let store = DiscordStore()
        store.apply(ready: ready(blocked: 0))
        var announcements = 0
        store.onPrivacyChange = { announcements += 1 }
        store.handle(threadSync(guild: 100, parent: 300, count: 120))
        XCTAssertEqual(store.threads(in: 300).count, 120)
        XCTAssertEqual(announcements, 1)
    }

    func testThreadsLoadedOverRESTAnnounceOnePrivacyChange() {
        let store = DiscordStore()
        store.apply(ready: ready(blocked: 0))
        var announcements = 0
        store.onPrivacyChange = { announcements += 1 }
        store.remember(threads: (0..<25).map { Channel(id: Snowflake(8_000 + UInt64($0)), type: .publicThread, guildID: 100, parentID: 300) })
        XCTAssertEqual(store.threads(in: 300).count, 25)
        XCTAssertEqual(announcements, 1)
    }

    func testThreadListSyncRedrawsAnOpenConversationOnce() async {
        let mock = MockDiscord()
        let model = AppModel(readAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        let timeline = model.timeline(for: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: model.store)
        XCTAssertFalse(timeline.messages.isEmpty)
        var redraws = 0
        let observer = timeline.observe { change in
            if case .updated = change { redraws += 1 }
        }
        defer { timeline.stopObserving(observer) }
        await model.handle(threadSync(guild: F.guild, parent: MockDiscord.generalChannel, count: 120))
        XCTAssertEqual(redraws, 1)
    }

    func testOneBlockIsStillAnnouncedAsItHappens() {
        let store = DiscordStore()
        store.apply(ready: ready(blocked: 0))
        var announcements = 0
        store.onPrivacyChange = { announcements += 1 }
        store.handle(GatewayDispatch(name: "RELATIONSHIP_ADD", data: Data(#"{"d":{"id":"5000","type":2}}"#.utf8)))
        XCTAssertTrue(store.isBlocked(5_000))
        XCTAssertEqual(announcements, 1)
        store.revealBlockedMessage(42)
        XCTAssertEqual(announcements, 2)
    }
}
