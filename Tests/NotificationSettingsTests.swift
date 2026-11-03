import XCTest
import SwiftUI
import Observation
@testable import DuocordNative

@MainActor
final class NotificationSettingsTests: XCTestCase {
    private let guild: Snowflake = 910_000_000_000_000_000
    private let chat = MockDiscord.generalChannel
    private var target: NotificationTarget { .channel(guild: guild, channel: chat) }

    private func fixture(store: DiscordStore? = nil) -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel(notificationAPI: mock, store: store)
        model.store.apply(ready: mock.readyPayload())
        return (model, mock)
    }

    private func update(_ model: AppModel, _ json: String) async {
        await model.handle(GatewayDispatch(name: "USER_GUILD_SETTINGS_UPDATE", data: Data(("{\"d\":" + json + "}").utf8)))
    }

    private func message(_ model: AppModel, channel: Snowflake? = nil, mention: Bool = false) -> Message {
        Message(id: 999, channelID: channel ?? chat, guildID: guild,
                author: User(id: 6, username: "other", globalName: nil, discriminator: nil, avatar: nil, bot: nil),
                content: "test", timestamp: "", mentions: mention ? [model.store.me!] : [])
    }

    func testChannelMuteWireAndExpiryThroughAppModel() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DiscordStore(notificationClock: { now })
        let (model, mock) = fixture(store: store)
        await model.changeNotifications(target, patch: .mute(.hour, now: now)).value
        let op = try XCTUnwrap(mock.notificationOperations.first)
        XCTAssertEqual(op.route, "users/@me/guilds/\(guild)/settings")
        XCTAssertEqual(Set(op.fields.keys), ["channel_overrides"])
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op.fields)) as! [String: Any]
        let entry = (wire["channel_overrides"] as! [String: Any])[chat.description] as! [String: Any]
        XCTAssertEqual(Set(entry.keys), ["muted", "mute_config"])
        XCTAssertEqual((entry["mute_config"] as! [String: Any])["selected_time_window"] as? Int, 3600)
        XCTAssertEqual(store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.selectedTimeWindow, 3600)
        XCTAssertTrue(store.isMuted(try XCTUnwrap(store.channel(chat))))
        XCTAssertFalse(store.shouldNotify(message(model, mention: true)))
        let revision = store.notificationTimeRevision
        now.addTimeInterval(3601)
        store.refreshMuteExpirations() // injected clock equivalent of the shared deadline wake
        XCTAssertGreaterThan(store.notificationTimeRevision, revision)
        XCTAssertFalse(store.isMuted(try XCTUnwrap(store.channel(chat))))
        XCTAssertTrue(store.shouldNotify(message(model, mention: true)))
        XCTAssertEqual(model.notificationSaves[guild], 0)
    }

    func testEveryDurationForeverAndExplicitUnmute() async throws {
        let (model, mock) = fixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for duration in MuteDuration.allCases {
            await model.changeNotifications(.guild(guild), patch: .mute(duration, now: now)).value
            let config = try XCTUnwrap(model.store.guildSettings[guild]?.muteConfig)
            XCTAssertEqual(config.selectedTimeWindow, duration.rawValue)
            if duration == .forever { XCTAssertNil(config.endTime) }
            else { XCTAssertEqual(try XCTUnwrap(config.endTime.flatMap(DiscordDate.parse)).timeIntervalSince(now), Double(duration.rawValue), accuracy: 0.01) }
        }
        await model.changeNotifications(.guild(guild), patch: .mute(nil, now: now)).value
        XCTAssertFalse(model.store.isMuted(guild: guild))
        XCTAssertEqual(mock.notificationOperations.last?.fields["muted"], .bool(false))
        guard case .object(let config) = mock.notificationOperations.last?.fields["mute_config"] else { return XCTFail("explicit unmute config") }
        XCTAssertEqual(config["end_time"], .null)
        XCTAssertEqual(config["selected_time_window"], .number(-1))
    }

    func testServerAndNestedInheritanceAndSelectivePreservation() async throws {
        let (model, _) = fixture()
        let category: Snowflake = 910_000_000_000_000_001
        let thread: Snowflake = 910_000_000_000_000_500
        await model.changeNotifications(.guild(guild), patch: NotificationPatch(level: .nothing)).value
        XCTAssertFalse(model.store.shouldNotify(message(model, mention: true)))
        await model.changeNotifications(.channel(guild: guild, channel: category), patch: NotificationPatch(level: .all)).value
        XCTAssertTrue(model.store.shouldNotify(message(model)))
        XCTAssertTrue(model.store.shouldNotify(message(model, channel: thread)))
        await model.changeNotifications(target, patch: NotificationPatch(level: .mentions)).value
        XCTAssertFalse(model.store.shouldNotify(message(model, channel: thread)))
        XCTAssertTrue(model.store.shouldNotify(message(model, channel: thread, mention: true)))
        await model.changeNotifications(target, patch: .mute(.forever, now: .now)).value
        XCTAssertEqual(model.store.notificationLevel(target), .mentions, "mute must preserve the independent channel preference")
        await model.changeNotifications(target, patch: NotificationPatch(level: .inherit)).value
        XCTAssertEqual(model.store.effectiveNotificationLevel(target).level, .all)
        XCTAssertTrue(model.store.isDirectlyMuted(target), "level edit must preserve the mute")
        XCTAssertEqual(model.store.notificationLevel(.guild(guild)), .nothing)
        XCTAssertEqual(model.store.notificationLevel(.channel(guild: guild, channel: category)), .all)
        XCTAssertFalse(model.store.shouldNotify(message(model, channel: thread, mention: true)))
        await model.changeNotifications(target, patch: .mute(nil, now: .now)).value
        await model.changeNotifications(.channel(guild: guild, channel: category), patch: .mute(.forever, now: .now)).value
        XCTAssertTrue(model.store.isMuted(try XCTUnwrap(model.store.channel(thread))), "category mute reaches nested threads")
    }

    func testPrivateTargetsHonorActualLevelsAndMutes() async throws {
        let (model, mock) = fixture()
        let dm = try XCTUnwrap(mock.dms.first { $0.type == .dm })
        let group = try XCTUnwrap(mock.dms.first { $0.type == .groupDM })
        for channel in [dm, group] {
            let target = NotificationTarget.channel(guild: nil, channel: channel.id)
            await model.changeNotifications(target, patch: NotificationPatch(level: .nothing)).value
            XCTAssertFalse(model.store.shouldNotify(message(model, channel: channel.id, mention: true)))
            await model.changeNotifications(target, patch: NotificationPatch(level: .all)).value
            XCTAssertTrue(model.store.shouldNotify(message(model, channel: channel.id)))
            await model.changeNotifications(target, patch: .mute(.forever, now: .now)).value
            XCTAssertFalse(model.store.shouldNotify(message(model, channel: channel.id, mention: true)))
            await model.changeNotifications(target, patch: .mute(nil, now: .now)).value
            await model.changeNotifications(target, patch: NotificationPatch(level: .inherit)).value
            XCTAssertTrue(model.store.shouldNotify(message(model, channel: channel.id)))
        }
        await model.changeNotifications(.channel(guild: nil, channel: group.id), patch: NotificationPatch(level: .mentions)).value
        XCTAssertFalse(model.store.shouldNotify(message(model, channel: group.id)))
        XCTAssertTrue(model.store.shouldNotify(message(model, channel: group.id, mention: true)))
        XCTAssertTrue(mock.notificationOperations.allSatisfy { $0.route == "users/@me/guilds/@me/settings" })
        XCTAssertEqual(model.store.guildSettings[0]?.channelOverrides.count, 2)
    }

    func testSuppressionAndDirectMentionsThroughAppAPI() async {
        let (model, _) = fixture()
        await model.changeNotifications(.guild(guild), patch: NotificationPatch(level: .mentions)).value
        var everyone = message(model)
        everyone.mentionEveryone = true
        var role = message(model)
        role.mentionRoles = [Snowflake(guild.raw + 901)]
        XCTAssertTrue(model.store.shouldNotify(everyone))
        XCTAssertTrue(model.store.shouldNotify(role))
        await model.changeNotifications(.guild(guild), patch: NotificationPatch(suppressEveryone: true)).value
        XCTAssertFalse(model.store.shouldNotify(everyone))
        XCTAssertTrue(model.store.shouldNotify(role))
        await model.changeNotifications(.guild(guild), patch: NotificationPatch(suppressRoles: true)).value
        XCTAssertFalse(model.store.shouldNotify(role))
        XCTAssertTrue(model.store.shouldNotify(message(model, mention: true)))
        XCTAssertTrue(model.store.guildSettings[guild]?.suppressEveryone == true)
        XCTAssertEqual(model.store.notificationLevel(.guild(guild)), .mentions)
    }

    func testPartialGatewayShapesPreserveIndependentFieldsAndDecodeWindows() async throws {
        let (model, _) = fixture()
        await model.changeNotifications(target, patch: .mute(.hour, now: .now)).value
        await model.changeNotifications(.guild(guild), patch: NotificationPatch(suppressRoles: true)).value
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":[{\"channel_id\":\"\(chat)\",\"message_notifications\":2}]}")
        XCTAssertTrue(model.store.isDirectlyMuted(target))
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.guildSettings[guild]?.suppressRoles == true)
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":{\"\(chat)\":{\"mute_config\":{\"selected_time_window\":900}}}}")
        let entry = try XCTUnwrap(model.store.guildSettings[guild]?.channelOverrides.first)
        XCTAssertEqual(entry.muteConfig?.selectedTimeWindow, 900)
        XCTAssertNotNil(entry.muteConfig?.endTime, "partial mute_config retains its expiry")
        let cached = try JSONDecoder().decode(UserGuildSettings.self, from: JSONEncoder().encode(model.store.guildSettings[guild]!))
        XCTAssertEqual(cached.channelOverrides, model.store.guildSettings[guild]?.channelOverrides)
        let privateID = model.store.privateChannels[0].id
        await update(model, "{\"guild_id\":null,\"channel_overrides\":{\"\(privateID)\":{\"message_notifications\":2}}}")
        XCTAssertEqual(model.store.notificationLevel(.channel(guild: nil, channel: privateID)), .nothing)
    }

    func testNullAndMalformedOverridePartialsCannotEraseExistingSettings() async {
        let (model, _) = fixture()
        let other = NotificationTarget.channel(guild: guild, channel: Snowflake(chat.raw + 1))
        await model.changeNotifications(target, patch: NotificationPatch(level: .nothing)).value
        await model.changeNotifications(other, patch: .mute(.forever, now: .now)).value
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":null,\"suppress_roles\":true}")
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(other))
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.count, 2)
        XCTAssertTrue(model.store.guildSettings[guild]?.suppressRoles == true)
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":{\"\(chat)\":null,\"\(chat.raw + 1)\":{\"muted\":null,\"message_notifications\":null},\"invalid-id\":{\"muted\":true}}}")
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(other))
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.count, 2)
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":[{\"channel_id\":\"\(chat)\",\"message_notifications\":null}]}")
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(other))
    }

    func testPartialMuteEchoAllowsHTTPToFillUnconfirmedExpiry() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, mock) = fixture(store: DiscordStore(notificationClock: { now }))
        await model.changeNotifications(target, patch: .mute(.forever, now: now)).value
        let gate = NotificationGate()
        mock.beforeNotificationResponse = { _ in await gate.pause() }
        let save = model.changeNotifications(target, patch: .mute(.hour, now: now))
        await gate.waitUntilPaused()
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":{\"\(chat)\":{\"muted\":true,\"mute_config\":{\"selected_time_window\":3600}}}}")
        await gate.resume()
        await save.value
        let config = try XCTUnwrap(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig)
        XCTAssertEqual(config.endTime.flatMap(DiscordDate.parse), now.addingTimeInterval(3600))
        XCTAssertEqual(config.selectedTimeWindow, 3600)
        XCTAssertNil(model.notificationErrors[guild])
        now.addTimeInterval(3601)
        model.store.refreshMuteExpirations()
        XCTAssertFalse(model.store.isDirectlyMuted(target), "A successful finite mute must expire")
    }

    func testNewerMuteClearsFenceOlderHTTPAtTheClearedMember() async throws {
        for changedTarget in [NotificationTarget.guild(guild), target] {
            for clearWholeConfig in [true, false] {
                let (model, mock) = fixture()
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                await model.changeNotifications(changedTarget, patch: .mute(.forever, now: now)).value
                let gate = NotificationGate()
                mock.beforeNotificationResponse = { _ in await gate.pause() }
                let save = model.changeNotifications(changedTarget, patch: .mute(.hour, now: now))
                await gate.waitUntilPaused()
                let cleared: JSONValue = clearWholeConfig ? .null : .object(["end_time": .null])
                var fields: [String: JSONValue] = ["guild_id": .string(guild.description)]
                if let id = changedTarget.channelID { fields["channel_overrides"] = .object([id.description: .object(["mute_config": cleared])]) }
                else { fields["mute_config"] = cleared }
                let data = try JSONEncoder().encode(JSONValue.object(["d": .object(fields)]))
                await model.handle(GatewayDispatch(name: "USER_GUILD_SETTINGS_UPDATE", data: data))
                await gate.resume()
                await save.value
                let settings = model.store.guildSettings[guild]
                let config = changedTarget.channelID == nil ? settings?.muteConfig : settings?.channelOverrides.first?.muteConfig
                XCTAssertNil(config?.endTime, "Older HTTP cannot resurrect a cleared expiry")
                if clearWholeConfig { XCTAssertNil(config, "A whole-config clear owns both members") }
                else { XCTAssertEqual(config?.selectedTimeWindow, 3600, "HTTP may fill the unconfirmed window") }
                XCTAssertNil(model.notificationErrors[guild])
            }
        }
    }

    func testMalformedNestedMuteMembersPreserveGuildAndChannelSettings() async throws {
        let (model, _) = fixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await model.changeNotifications(.guild(guild), patch: .mute(.hour, now: now)).value
        await model.changeNotifications(target, patch: .mute(.hour, now: now)).value
        await model.changeNotifications(target, patch: NotificationPatch(level: .nothing)).value
        let end = model.store.guildSettings[guild]?.muteConfig?.endTime
        await update(model, "{\"guild_id\":\"\(guild)\",\"mute_config\":{\"selected_time_window\":\"bad\"},\"channel_overrides\":{\"\(chat)\":{\"mute_config\":{\"selected_time_window\":\"bad\"}}}}")
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.endTime, end)
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.selectedTimeWindow, 3600)
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.endTime, end)
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(target))
        await update(model, "{\"guild_id\":\"\(guild)\",\"mute_config\":{\"end_time\":false,\"selected_time_window\":900},\"channel_overrides\":{\"\(chat)\":{\"mute_config\":{\"end_time\":\"not-a-date\",\"selected_time_window\":900}}}}")
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.endTime, end)
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.selectedTimeWindow, 900)
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.endTime, end)
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.selectedTimeWindow, 900)
        await update(model, "{\"guild_id\":\"\(guild)\",\"mute_config\":{\"end_time\":\"2027-01-15T10:00:00Z\",\"selected_time_window\":-2},\"channel_overrides\":{\"\(chat)\":{\"mute_config\":{\"end_time\":\"2027-01-15T10:00:00Z\",\"selected_time_window\":\"bad\"}}}}")
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.endTime, "2027-01-15T10:00:00Z")
        XCTAssertEqual(model.store.guildSettings[guild]?.muteConfig?.selectedTimeWindow, 900)
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.endTime, "2027-01-15T10:00:00Z")
        XCTAssertEqual(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig?.selectedTimeWindow, 900)
        await update(model, "{\"guild_id\":\"\(guild)\",\"mute_config\":null,\"channel_overrides\":{\"\(chat)\":{\"mute_config\":null}}}")
        XCTAssertNil(model.store.guildSettings[guild]?.muteConfig)
        XCTAssertNil(model.store.guildSettings[guild]?.channelOverrides.first?.muteConfig)
        XCTAssertEqual(model.store.notificationLevel(target), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(target))
    }

    func testMalformedOptionalMuteMemberDoesNotDropDecodedOverride() throws {
        for overrides in [
            "{\"\(chat)\":{\"muted\":true,\"message_notifications\":2,\"mute_config\":{\"end_time\":\"2027-01-15T09:00:00Z\",\"selected_time_window\":\"bad\"}}}",
            "[{\"channel_id\":\"\(chat)\",\"muted\":true,\"message_notifications\":2,\"mute_config\":{\"end_time\":\"2027-01-15T09:00:00Z\",\"selected_time_window\":\"bad\"}}]"
        ] {
            let settings = try JSONDecoder().decode(UserGuildSettings.self, from: Data("{\"guild_id\":\"\(guild)\",\"channel_overrides\":\(overrides)}".utf8))
            let entry = try XCTUnwrap(settings.channelOverrides.first)
            XCTAssertTrue(entry.muted)
            XCTAssertEqual(entry.messageNotifications, 2)
            XCTAssertEqual(entry.muteConfig?.endTime, "2027-01-15T09:00:00Z")
            XCTAssertNil(entry.muteConfig?.selectedTimeWindow)
        }
    }

    func testNotificationRouteFollowsRegularWidthTableTopAndBack() {
        let (model, _) = fixture()
        model.fold.isCompact = false
        model.fold.windowSize = CGSize(width: 800, height: 1000)
        model.selectedChannel = chat
        model.drafts[chat] = Draft(text: "retained")
        let route = AppSheet.notifications(target)
        model.present(route)
        XCTAssertEqual(model.sidebarPanel, route)
        model.fold.foldFrame = CGRect(x: 0, y: 480, width: 800, height: 40)
        XCTAssertTrue(model.isTableTop)
        model.sizeClassChanged(compact: false) // callback for presentation-mode change
        XCTAssertEqual(model.sheet, route)
        XCTAssertNil(model.sidebarPanel)
        model.sizeClassChanged(compact: false)
        XCTAssertEqual(model.sheet, route, "Repeated layout callbacks keep one presentation")
        model.fold.foldFrame = nil
        model.sizeClassChanged(compact: false)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.sidebarPanel, route)
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertEqual(model.drafts[chat]?.text, "retained")
    }

    func testFailureIsVisibleAndDoesNotInventSuccessOrRetry() async {
        let (model, mock) = fixture()
        mock.failNextNotificationWrite = true
        await model.changeNotifications(target, patch: .mute(.hour, now: .now)).value
        XCTAssertFalse(model.store.isDirectlyMuted(target))
        XCTAssertNotNil(model.notificationErrors[guild])
        XCTAssertNotNil(model.toast)
        XCTAssertEqual(model.notificationSaves[guild], 0)
        XCTAssertEqual(mock.notificationOperations.count, 1)
        await model.changeNotifications(target, patch: .mute(.forever, now: .now)).value
        XCTAssertTrue(model.store.isDirectlyMuted(target))
        XCTAssertNil(model.notificationErrors[guild])
        XCTAssertEqual(mock.notificationOperations.count, 2)
    }

    func testQueuedChangesWaitAndNewerGatewayWinsOverOldHTTP() async throws {
        let (model, mock) = fixture()
        let gate = NotificationGate()
        mock.beforeNotificationResponse = { _ in await gate.pause() }
        let first = model.changeNotifications(target, patch: NotificationPatch(level: .all))
        await gate.waitUntilPaused()
        let second = model.changeNotifications(target, patch: NotificationPatch(level: .nothing))
        XCTAssertEqual(mock.notificationOperations.count, 1, "second choice waits for first HTTP completion")
        XCTAssertEqual(model.notificationSaves[guild], 2)
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":{\"\(chat)\":{\"message_notifications\":1}},\"suppress_everyone\":true}")
        let secondGate = NotificationGate()
        mock.beforeNotificationResponse = { _ in await secondGate.pause() }
        await gate.resume()
        await first.value
        await secondGate.waitUntilPaused()
        XCTAssertEqual(model.store.notificationLevel(target), .mentions, "old HTTP must not undo a newer gateway value")
        await secondGate.resume()
        await second.value
        XCTAssertEqual(model.store.notificationLevel(target), .nothing, "the queued newer choice is submitted after confirmation")
        XCTAssertTrue(model.store.guildSettings[guild]?.suppressEveryone == true)
        XCTAssertEqual(mock.notificationOperations.count, 2)
        XCTAssertEqual(model.notificationSaves[guild], 0)
    }

    func testGatewayEchoBeforeHTTPAndFailureAfterConfirmation() async {
        let (model, mock) = fixture()
        let events = NotificationEvents()
        mock.echo = { event in events.append(event) }
        mock.beforeNotificationResponse = { _ in
            if let event = events.last { await model.handle(event) }
            throw DiscordError.http(500, "Mock response lost after echo")
        }
        await model.changeNotifications(target, patch: .mute(.forever, now: .now)).value
        XCTAssertTrue(model.store.isDirectlyMuted(target), "retain the gateway confirmation even if HTTP fails")
        XCTAssertNotNil(model.notificationErrors[guild])
        XCTAssertEqual(events.last?.name, "USER_GUILD_SETTINGS_UPDATE")
        XCTAssertEqual(mock.notificationOperations.count, 1)
    }

    func testSharedDeadlinePublishesObservableRecoveryWithoutRelaunch() async throws {
        let (model, _) = fixture()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = formatter.string(from: .now.addingTimeInterval(1.2))
        await update(model, "{\"guild_id\":\"\(guild)\",\"channel_overrides\":{\"\(chat)\":{\"muted\":true,\"mute_config\":{\"end_time\":\"\(end)\",\"selected_time_window\":900}}}}")
        XCTAssertTrue(model.store.isDirectlyMuted(target))
        let changed = expectation(description: "shared expiry publishes")
        withObservationTracking {
            _ = model.store.isDirectlyMuted(target)
        } onChange: { changed.fulfill() }
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertFalse(model.store.isDirectlyMuted(target))
        XCTAssertTrue(model.store.shouldNotify(message(model, mention: true)))
    }

    func testNewReadySnapshotOutranksAnOlderHTTPResponse() async {
        let (model, mock) = fixture()
        let gate = NotificationGate()
        mock.beforeNotificationResponse = { _ in await gate.pause() }
        let request = model.changeNotifications(target, patch: NotificationPatch(level: .nothing))
        await gate.waitUntilPaused()
        model.store.apply(ready: mock.readyPayload())
        await gate.resume()
        await request.value
        XCTAssertEqual(model.store.notificationLevel(target), .inherit)
        XCTAssertNil(model.notificationErrors[guild])
    }

    func testQueuedRecoveryClearsEarlierFailureAndPreservesOtherTarget() async {
        let (model, mock) = fixture()
        mock.failNextNotificationWrite = true
        let failed = model.changeNotifications(target, patch: NotificationPatch(level: .nothing))
        let recovered = model.changeNotifications(target, patch: NotificationPatch(level: .all))
        let other = NotificationTarget.channel(guild: guild, channel: Snowflake(chat.raw + 1))
        let third = model.changeNotifications(other, patch: .mute(.forever, now: .now))
        await failed.value
        await recovered.value
        await third.value
        XCTAssertNil(model.notificationErrors[guild])
        XCTAssertEqual(model.store.notificationLevel(target), .all)
        XCTAssertTrue(model.store.isDirectlyMuted(other))
        XCTAssertEqual(mock.notificationOperations.count, 3)
        XCTAssertEqual(model.notificationSaves[guild], 0)
    }

    func testSettingsRoutingRetainsConversationDraftAnchorAndFocus() {
        let (model, _) = fixture()
        model.selectedGuild = guild
        model.selectedChannel = chat
        model.drafts[chat] = Draft(text: "untouched draft")
        let field = model.composerContinuity.attach(in: chat)
        model.composerContinuity.beganEditing(field, in: chat, selectedChannel: chat)
        model.composerContinuity.saveSelection(NSRange(location: 2, length: 3), text: "untouched draft", in: chat)
        model.anchors[chat] = ScrollAnchor(itemID: "message-123", offset: 12, pinnedToBottom: false)
        let before = model.anchors[chat]
        let panel = AppSheet.notifications(.guild(Snowflake(guild.raw + 1000)))
        model.fold.isCompact = false
        model.sizeClassChanged(compact: false)
        model.present(panel)
        XCTAssertEqual(model.sidebarPanel, panel)
        model.fold.isCompact = true
        model.sizeClassChanged(compact: true)
        XCTAssertEqual(model.sheet, panel)
        model.fold.isCompact = false
        model.sizeClassChanged(compact: false)
        XCTAssertEqual(model.sidebarPanel, panel)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.selectedChannel, chat)
        XCTAssertEqual(model.selectedGuild, guild)
        XCTAssertEqual(model.drafts[chat]?.text, "untouched draft")
        XCTAssertEqual(model.anchors[chat], before)
        XCTAssertTrue(model.composerContinuity.shouldFocus(field, in: chat, selectedChannel: chat))
        XCTAssertEqual(model.composerContinuity.selection(in: chat, text: "untouched draft"), NSRange(location: 2, length: 3))
    }
}

nonisolated private final class NotificationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GatewayDispatch] = []
    func append(_ event: GatewayDispatch) { lock.withLock { events.append(event) } }
    var last: GatewayDispatch? { lock.withLock { events.last } }
}

private actor NotificationGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var answer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            answer = continuation
            paused = true
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { answer?.resume(); answer = nil }
}

/// Intercepts every request, including failures. No connection can leave this
/// test's URLSession. Exercises the actual live PATCH encoder and GET-only retry.
nonisolated private final class NotificationWireNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [URLRequest] = []
    nonisolated(unsafe) private static var code = 200
    static func reset(status: Int) { lock.withLock { records = []; code = status } }
    static var requests: [URLRequest] { lock.withLock { records } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let code = Self.lock.withLock { Self.records.append(request); return Self.code }
        let body = code == 429 ? #"{"retry_after":0.01,"global":false}"# : #"{"guild_id":null,"channel_overrides":{"42":{"muted":true,"message_notifications":2,"mute_config":{"end_time":null,"selected_time_window":-1}}}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class NotificationWireTests: XCTestCase {
    private func rest() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "offline-test", superProperties: nil, userAgent: "offline-test"), protocolClasses: [NotificationWireNetwork.self])
    }
    func testLiveTypedPatchWireAndKeyedResponseThroughAppModel() async throws {
        NotificationWireNetwork.reset(status: 200)
        let model = AppModel(notificationAPI: rest())
        let target = NotificationTarget.channel(guild: nil, channel: 42)
        await model.changeNotifications(target, patch: .mute(.forever, now: .now)).value
        XCTAssertNil(model.notificationErrors[0])
        XCTAssertTrue(model.store.isDirectlyMuted(target))
        // Only requested fields from a full HTTP response are accepted.
        XCTAssertEqual(model.store.notificationLevel(target), .inherit)
        let request = try XCTUnwrap(NotificationWireNetwork.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/v9/users/@me/guilds/@me/settings")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let decoded = try JSONDecoder().decode(GuildSettingsUpdate.self, from: XCTUnwrap(body))
        XCTAssertEqual(decoded.fields, NotificationPatch.mute(.forever, now: .now).fields(for: target))
        XCTAssertEqual(NotificationWireNetwork.requests.count, 1)
    }
    func testLiveNotificationMutationIsNeverRetriedAfterRateLimit() async {
        NotificationWireNetwork.reset(status: 429)
        let model = AppModel(notificationAPI: rest())
        await model.changeNotifications(.guild(123), patch: NotificationPatch(level: .nothing)).value
        XCTAssertNotNil(model.notificationErrors[123])
        XCTAssertEqual(model.store.notificationLevel(.guild(123)), .inherit)
        XCTAssertEqual(NotificationWireNetwork.requests.count, 1)
        XCTAssertEqual(NotificationWireNetwork.requests.first?.httpMethod, "PATCH")
        XCTAssertEqual(NotificationWireNetwork.requests.first?.url?.path, "/api/v9/users/@me/guilds/123/settings")
    }
}
