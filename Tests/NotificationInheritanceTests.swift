import XCTest
@testable import DuocordNative

@MainActor
final class NotificationInheritanceTests: XCTestCase {
    private func store(defaultLevel: Int, nested: Bool = false, settings: [String: Any]? = nil) throws -> DiscordStore {
        var guild: [String: Any] = [
            "id": "1", "name": "Notification fixture",
            "channels": [
                ["id": "10", "type": 4, "name": "Category"],
                ["id": "11", "type": 0, "name": "chat", "parent_id": "10"],
                ["id": "12", "type": 11, "name": "thread", "parent_id": "11"]
            ]
        ]
        if nested { guild["properties"] = ["default_message_notifications": defaultLevel] }
        else { guild["default_message_notifications"] = defaultLevel }
        var payload: [String: Any] = ["user": ["id": "5", "username": "me"], "guilds": [guild]]
        if let settings { payload["user_guild_settings"] = [settings] }
        let ready = try JSONDecoder().decode(ReadyPayload.self, from: JSONSerialization.data(withJSONObject: payload))
        let store = DiscordStore()
        store.apply(ready: ready)
        return store
    }

    private func message(channel: Snowflake = 11, mention: Bool = false) -> Message {
        Message(id: 100, channelID: channel, guildID: 1,
                author: User(id: 6, username: "someone", globalName: nil, discriminator: nil, avatar: nil, bot: nil),
                content: "hello", timestamp: "",
                mentions: mention ? [User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)] : [])
    }

    func testMissingUserSettingsFollowGuildDefault() throws {
        for nested in [false, true] {
            XCTAssertTrue(try store(defaultLevel: 0, nested: nested).shouldNotify(message()))
            XCTAssertFalse(try store(defaultLevel: 1, nested: nested).shouldNotify(message()))
            XCTAssertTrue(try store(defaultLevel: 1, nested: nested).shouldNotify(message(mention: true)))
        }
    }

    func testInheritedAndExplicitGuildSettings() throws {
        let inherited: [String: Any] = ["guild_id": "1", "message_notifications": 3]
        XCTAssertTrue(try store(defaultLevel: 0, settings: inherited).shouldNotify(message()))
        let explicit: [String: Any] = ["guild_id": "1", "message_notifications": 1]
        XCTAssertFalse(try store(defaultLevel: 0, settings: explicit).shouldNotify(message()))
        XCTAssertTrue(try store(defaultLevel: 0, settings: explicit).shouldNotify(message(mention: true)))
    }

    func testChannelAndCategoryOverridesAndMutes() throws {
        let category: [String: Any] = ["channel_id": "10", "message_notifications": 0, "muted": false]
        let silent: [String: Any] = ["channel_id": "11", "message_notifications": 2, "muted": false]
        let inherited: [String: Any] = ["channel_id": "11", "message_notifications": 3, "muted": false]
        for channel: Snowflake in [11, 12] {
            XCTAssertTrue(try store(defaultLevel: 1, settings: ["guild_id": "1", "channel_overrides": [category, inherited]]).shouldNotify(message(channel: channel)))
            XCTAssertFalse(try store(defaultLevel: 0, settings: ["guild_id": "1", "channel_overrides": [category, silent]]).shouldNotify(message(channel: channel, mention: true)))
        }
        XCTAssertFalse(try store(defaultLevel: 0, settings: ["guild_id": "1", "muted": true]).shouldNotify(message(mention: true)))
        let muted: [String: Any] = ["channel_id": "11", "message_notifications": 0, "muted": true]
        XCTAssertFalse(try store(defaultLevel: 0, settings: ["guild_id": "1", "channel_overrides": [muted]]).shouldNotify(message(mention: true)))
    }

    func testGuildDefaultSurvivesCacheAndPartialUpdate() throws {
        let store = try store(defaultLevel: 0)
        let guild = try XCTUnwrap(store.guilds[1])
        let cached = try JSONDecoder().decode(Guild.self, from: JSONEncoder().encode(guild))
        store.upsert(guild: cached)
        XCTAssertTrue(store.shouldNotify(message()), "cache must preserve the inherited default")
        let partial = try JSONDecoder().decode(Guild.self, from: Data(#"{"id":"1","name":"renamed"}"#.utf8))
        store.upsert(guild: partial)
        XCTAssertTrue(store.shouldNotify(message()), "an omitted partial field must not reset notification policy")
    }

    func testGatewayGuildDefaultChangesAndPartialUpdates() throws {
        let store = try store(defaultLevel: 0)
        store.handle(GatewayDispatch(name: "GUILD_UPDATE", data: Data(#"{"d":{"id":"1","default_message_notifications":1}}"#.utf8)))
        XCTAssertFalse(store.shouldNotify(message()), "server default changes take effect without reconnecting")
        store.handle(GatewayDispatch(name: "GUILD_UPDATE", data: Data(#"{"d":{"id":"1","name":"renamed"}}"#.utf8)))
        XCTAssertFalse(store.shouldNotify(message()), "omitted policy preserves the last gateway value")
        store.handle(GatewayDispatch(name: "GUILD_UPDATE", data: Data(#"{"d":{"id":"1","properties":{"default_message_notifications":0}}}"#.utf8)))
        XCTAssertTrue(store.shouldNotify(message()))
    }
}
