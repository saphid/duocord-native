import XCTest
import Observation
@testable import DuocordNative

@MainActor
final class ServerBadgeObservationTests: XCTestCase {
    private func fixture(hasRole: Bool) throws -> DiscordStore {
        let store = DiscordStore()
        let everyone = Role(id: 100, name: "@everyone", color: 0, position: 0, permissions: "0")
        let reader = Role(id: 400, name: "Readers", color: 0, position: 1, permissions: String(Permission.viewChannel))
        let chat = Channel(id: 300, type: .text, guildID: 100, name: "general", lastMessageID: 20)
        var guild = Guild(id: 100, name: "Fixture", roles: [everyone, reader], channels: [chat])
        guild.ownerID = 2
        let roles = hasRole ? #"["400"]"# : "[]"
        let member = try JSONDecoder().decode(Member.self, from: Data("{\"user_id\":\"1\",\"roles\":\(roles)}".utf8))
        store.apply(ready: ReadyPayload(user: User(id: 1, username: "me"), guilds: [guild], privateChannels: [], users: [],
                                        mergedMembers: [[member]], readStates: [ReadState(id: 300, lastMessageID: 10, mentionCount: 3)],
                                        guildSettings: [], settingsProto: nil))
        return store
    }

    private func updateRole(_ store: DiscordStore, granted: Bool) {
        let roles = granted ? #"["400"]"# : "[]"
        store.handle(GatewayDispatch(name: "GUILD_MEMBER_UPDATE", data: Data(
            "{\"d\":{\"guild_id\":\"100\",\"user\":{\"id\":\"1\",\"username\":\"me\"},\"roles\":\(roles)}}".utf8)))
    }

    func testCachedServerBadgeRefreshesWhenMentionedChannelBecomesVisible() throws {
        let store = try fixture(hasRole: false)
        XCTAssertEqual(store.badge(for: 100), DiscordStore.GuildBadge(unread: false, mentions: 0))
        let refreshed = expectation(description: "server badge refreshes after permission grant")
        withObservationTracking {
            _ = store.badge(for: 100)
        } onChange: { refreshed.fulfill() }
        updateRole(store, granted: true)
        XCTAssertEqual(store.badge(for: 100), DiscordStore.GuildBadge(unread: true, mentions: 3))
        wait(for: [refreshed], timeout: 0.1)
    }

    func testCachedServerBadgeAndChannelListRefreshWhenPermissionIsRemoved() throws {
        let store = try fixture(hasRole: true)
        XCTAssertEqual(store.badge(for: 100).mentions, 3)
        XCTAssertEqual(store.sections(for: 100).flatMap(\.channels).map(\.id), [300])
        let badgeRefreshed = expectation(description: "server badge refreshes after permission removal")
        let channelsRefreshed = expectation(description: "channel list refreshes after permission removal")
        withObservationTracking {
            _ = store.badge(for: 100)
        } onChange: { badgeRefreshed.fulfill() }
        withObservationTracking {
            _ = store.sections(for: 100)
        } onChange: { channelsRefreshed.fulfill() }
        updateRole(store, granted: false)
        XCTAssertEqual(store.badge(for: 100), DiscordStore.GuildBadge(unread: false, mentions: 0))
        XCTAssertTrue(store.sections(for: 100).isEmpty)
        wait(for: [badgeRefreshed, channelsRefreshed], timeout: 0.1)
    }

    func testControlStripAndServerBadgeRefreshTogetherWhenStartupRolesArrive() throws {
        let store = try fixture(hasRole: false)
        // The channel list can fill its cache before READY_SUPPLEMENTAL arrives.
        XCTAssertTrue(store.sections(for: 100).isEmpty)
        XCTAssertEqual(store.badge(for: 100).mentions, 0)
        XCTAssertEqual(store.totalBadge, 0)
        let controlRefreshed = expectation(description: "Inbox control strip refreshes")
        let serverRefreshed = expectation(description: "owning server icon refreshes")
        withObservationTracking {
            _ = store.totalBadge
        } onChange: { controlRefreshed.fulfill() }
        withObservationTracking {
            _ = store.badge(for: 100)
        } onChange: { serverRefreshed.fulfill() }
        let supplemental = try JSONDecoder().decode(ReadySupplemental.self, from: Data(
            #"{"merged_members":[[{"user_id":"1","roles":["400"]}]]}"#.utf8))
        store.apply(supplemental: supplemental)
        XCTAssertEqual(store.totalBadge, 3)
        XCTAssertEqual(store.badge(for: 100).mentions, store.totalBadge)
        wait(for: [controlRefreshed, serverRefreshed], timeout: 0.1)
    }

    func testCachedServerBadgeRefreshesWhenRolePermissionsChange() throws {
        let store = try fixture(hasRole: false)
        XCTAssertEqual(store.badge(for: 100).mentions, 0)
        let refreshed = expectation(description: "server badge refreshes after role permission update")
        withObservationTracking {
            _ = store.badge(for: 100)
        } onChange: { refreshed.fulfill() }
        store.handle(GatewayDispatch(name: "GUILD_ROLE_UPDATE", data: Data(
            #"{"d":{"guild_id":"100","role":{"id":"100","name":"@everyone","color":0,"position":0,"permissions":"1024"}}}"#.utf8)))
        XCTAssertEqual(store.badge(for: 100).mentions, 3)
        XCTAssertEqual(store.badge(for: 100).mentions, store.totalBadge)
        wait(for: [refreshed], timeout: 0.1)
    }

}
