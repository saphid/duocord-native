import XCTest
@testable import DuocordNative

/// Offline transport for the thread-member settings endpoint; an exhausted
/// script fails closed.
nonisolated private final class ThreadSettingsWire: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var script: [(status: Int, body: String)] = []
    static var records: [(method: String, path: String, body: Data)] = []

    static func reset(_ responses: [(Int, String)]) {
        lock.withLock { script = responses.map { (status: $0.0, body: $0.1) }; records = [] }
    }
    static func captured() -> [(method: String, path: String, body: Data)] { lock.withLock { records } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let next: (status: Int, body: String) = Self.lock.withLock {
            Self.records.append((request.httpMethod ?? "", request.url?.path ?? "", data))
            return Self.script.isEmpty ? (599, "Unexpected offline request") : Self.script.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ThreadNotificationTests: XCTestCase {
    typealias F = MockDiscord.ThreadFixture
    private let images = MockDiscord.imageChannel

    private func fixture(store: DiscordStore? = nil) -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel(store: store, readAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        return (model, mock)
    }

    private func target(_ thread: Snowflake) -> NotificationTarget { .channel(guild: F.guild, channel: thread) }

    private func settingsOps(_ mock: MockDiscord) -> [MockDiscord.ThreadRecord] {
        mock.threadOperations.filter { $0.route.hasSuffix("/thread-members/@me/settings") }
    }

    private func mention(_ model: AppModel, in channel: Snowflake) -> Message {
        Message(id: 999, channelID: channel, guildID: F.guild,
                author: User(id: 6, username: "other", globalName: nil, discriminator: nil, avatar: nil, bot: nil),
                content: "ping", timestamp: "", mentions: [model.store.me!])
    }

    private func memberUpdate(_ model: AppModel, _ json: String) async {
        await model.handle(GatewayDispatch(name: "THREAD_MEMBER_UPDATE", data: Data(("{\"d\":" + json + "}").utf8)))
    }

    // MARK: Flags

    func testFlagMappingPreservesUnrelatedBits() {
        XCTAssertEqual(ThreadMemberFlags.level(nil), .inherit)
        XCTAssertEqual(ThreadMemberFlags.level(1), .inherit, "HAS_INTERACTED alone inherits")
        XCTAssertEqual(ThreadMemberFlags.level(1 | 2), .all)
        XCTAssertEqual(ThreadMemberFlags.level(4), .mentions)
        XCTAssertEqual(ThreadMemberFlags.level(8), .nothing)
        let current = ThreadMemberFlags.hasInteracted | ThreadMemberFlags.onlyMentions | (1 << 6)
        XCTAssertEqual(ThreadMemberFlags.flags(current, level: .all), 1 | 2 | (1 << 6))
        XCTAssertEqual(ThreadMemberFlags.flags(current, level: .nothing), 1 | 8 | (1 << 6))
        XCTAssertEqual(ThreadMemberFlags.flags(current, level: .inherit), 1 | (1 << 6))
        let mute = NotificationPatch.mute(.hour, now: Date(timeIntervalSince1970: 1_800_000_000)).threadFields(currentFlags: 5)
        XCTAssertEqual(Set(mute.keys), ["muted", "mute_config"], "muting never touches flags")
        XCTAssertEqual(NotificationPatch.mute(nil, now: .now).threadFields(currentFlags: 5), ["muted": .bool(false), "mute_config": .null])
        XCTAssertTrue(NotificationPatch(suppressEveryone: true).threadFields(currentFlags: 5).isEmpty, "server-only options do not apply")
    }

    // MARK: Existing preferences

    func testReadyPreferencesDriveLevelMuteAndInheritance() throws {
        let (model, _) = fixture()
        let store = model.store
        XCTAssertEqual(store.notificationLevel(target(F.hinge)), .mentions)
        XCTAssertEqual(store.effectiveNotificationLevel(target(F.hinge)).level, .mentions)
        XCTAssertEqual(store.effectiveNotificationLevel(target(F.hinge)).source, "Hinge animation timing")
        XCTAssertTrue(store.isDirectlyMuted(target(F.moderators)))
        XCTAssertTrue(store.isMuted(try XCTUnwrap(store.channel(F.moderators))))
        XCTAssertFalse(store.shouldNotify(mention(model, in: F.moderators)))
        // Inherit (HAS_INTERACTED only) follows the parent chain.
        XCTAssertEqual(store.notificationLevel(target(F.foldPhotos)), .inherit)
        XCTAssertEqual(store.effectiveNotificationLevel(target(F.foldPhotos)).level,
                       store.effectiveNotificationLevel(.channel(guild: F.guild, channel: MockDiscord.generalChannel)).level)
        XCTAssertFalse(store.needsThreadMembership(target(F.hinge)))
        XCTAssertTrue(store.needsThreadMembership(target(F.screenshots)))
        XCTAssertFalse(store.needsThreadMembership(.channel(guild: F.guild, channel: images)), "channels keep the guild path")
    }

    func testParentMuteAndLevelStillReachThreads() async throws {
        let (model, _) = fixture()
        await model.changeNotifications(.channel(guild: F.guild, channel: images), patch: .mute(.forever, now: .now)).value
        XCTAssertFalse(model.store.isDirectlyMuted(target(F.hinge)))
        XCTAssertTrue(model.store.isMuted(try XCTUnwrap(model.store.channel(F.hinge))), "a muted parent silences its threads")
    }

    // MARK: Writes

    func testLevelChangeUsesThreadMemberSettingsNotGuildOverrides() async throws {
        let (model, mock) = fixture()
        await model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .all)).value
        XCTAssertEqual(settingsOps(mock).last, .init(method: "PATCH", route: "channels/\(F.hinge)/thread-members/@me/settings",
                                                    fields: ["flags": .number(3)]), "HAS_INTERACTED kept, ALL_MESSAGES set")
        XCTAssertTrue(mock.notificationOperations.isEmpty, "no guild channel_overrides write")
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .all)
        XCTAssertEqual(model.store.channel(F.hinge)?.member?.flags, 3)
        XCTAssertEqual(model.notificationSaves[F.guild], 0)
        XCTAssertNil(model.notificationErrors[F.guild])

        await model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .inherit)).value
        XCTAssertEqual(settingsOps(mock).last?.fields, ["flags": .number(1)])
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .inherit)
    }

    func testMuteExpiresAndUnmuteClears() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DiscordStore(notificationClock: { now })
        let (model, mock) = fixture(store: store)
        await model.changeNotifications(target(F.hinge), patch: .mute(.hour, now: now)).value
        let fields = try XCTUnwrap(settingsOps(mock).last?.fields)
        XCTAssertEqual(fields["muted"], .bool(true))
        guard case .object(let config) = fields["mute_config"] else { return XCTFail("mute_config") }
        XCTAssertEqual(config["selected_time_window"], .number(3600))
        XCTAssertTrue(store.isDirectlyMuted(target(F.hinge)))
        XCTAssertFalse(store.shouldNotify(mention(model, in: F.hinge)))
        XCTAssertEqual(store.notificationLevel(target(F.hinge)), .mentions, "muting keeps the preference")
        now.addTimeInterval(3601)
        store.refreshMuteExpirations()
        XCTAssertFalse(store.isDirectlyMuted(target(F.hinge)), "the mute expires")
        XCTAssertTrue(store.shouldNotify(mention(model, in: F.hinge)))

        await model.changeNotifications(target(F.hinge), patch: .mute(.forever, now: now)).value
        XCTAssertTrue(store.isDirectlyMuted(target(F.hinge)))
        await model.changeNotifications(target(F.hinge), patch: .mute(nil, now: now)).value
        XCTAssertEqual(settingsOps(mock).last?.fields, ["muted": .bool(false), "mute_config": .null])
        XCTAssertFalse(store.isDirectlyMuted(target(F.hinge)))
        XCTAssertNil(store.channel(F.hinge)?.member?.muteConfig)
    }

    func testQueuedChangesComposeFromConfirmedFlags() async throws {
        let (model, mock) = fixture()
        let first = model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .all))
        let second = model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .nothing))
        let third = model.changeNotifications(target(F.hinge), patch: .mute(.forever, now: .now))
        await first.value; await second.value; await third.value
        XCTAssertEqual(settingsOps(mock).map { $0.fields?["flags"] }, [.number(3), .number(9), nil])
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(target(F.hinge)))
        XCTAssertEqual(model.notificationSaves[F.guild], 0)
    }

    func testUnchangedSettingIs204AndKeepsState() async throws {
        let (model, mock) = fixture()
        let before = model.store.channel(F.hinge)?.member
        await model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .mentions)).value
        XCTAssertEqual(settingsOps(mock).count, 1, "the request is sent")
        XCTAssertEqual(model.store.channel(F.hinge)?.member, before, "a 204 changes nothing")
        XCTAssertNil(model.notificationErrors[F.guild])
        XCTAssertNil(model.toast)
    }

    func testNotJoinedThreadNeverSavesOrJoinsSilently() async throws {
        let (model, mock) = fixture()
        await model.changeNotifications(target(F.screenshots), patch: .mute(.hour, now: .now)).value
        XCTAssertTrue(mock.threadOperations.isEmpty, "no settings write and no implicit join")
        XCTAssertTrue(mock.notificationOperations.isEmpty, "no guild override fallback")
        XCTAssertFalse(model.store.isJoined(thread: F.screenshots))
        XCTAssertEqual(model.notificationErrors[F.guild], "Join the thread to change its notification settings.")
        XCTAssertEqual(model.toast?.text, "Couldn’t save notification settings. Join the thread to change its notification settings.")
        XCTAssertEqual(model.notificationSaves[F.guild], 0)

        // An explicit Join Thread makes the preference editable.
        await model.perform(.join, on: F.screenshots).value
        XCTAssertFalse(model.store.needsThreadMembership(target(F.screenshots)))
        await model.changeNotifications(target(F.screenshots), patch: NotificationPatch(level: .nothing)).value
        XCTAssertEqual(settingsOps(mock).last?.fields, ["flags": .number(8)], "a fresh member has no flags to keep")
        XCTAssertEqual(model.store.notificationLevel(target(F.screenshots)), .nothing)
    }

    func testRefusalKeepsConfirmedState() async throws {
        let (model, mock) = fixture()
        mock.failNextThreadWrite = true
        await model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .nothing)).value
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .mentions)
        XCTAssertEqual(model.notificationErrors[F.guild], "Discord returned 403: Missing Permissions")
        XCTAssertEqual(model.notificationSaves[F.guild], 0)
    }

    func testSignOutDropsALateConfirmation() async throws {
        let (model, mock) = fixture()
        let task = model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .all))
        model.signOut()
        await task.value
        XCTAssertTrue(settingsOps(mock).count <= 1)
        XCTAssertNil(model.store.channel(F.hinge), "signed-out state stays empty")
    }

    // MARK: Gateway and freshness

    func testGatewayMemberUpdateMergesOnlyPresentFields() async throws {
        let (model, _) = fixture()
        await memberUpdate(model, #"{"id":"\#(F.hinge)","guild_id":"\#(F.guild)","muted":true,"mute_config":{"end_time":null,"selected_time_window":-1}}"#)
        XCTAssertTrue(model.store.isDirectlyMuted(target(F.hinge)))
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .mentions, "absent flags keep the preference")
        await memberUpdate(model, #"{"id":"\#(F.hinge)","flags":9,"muted":false,"mute_config":null}"#)
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .nothing)
        XCTAssertFalse(model.store.isDirectlyMuted(target(F.hinge)))
        XCTAssertNil(model.store.channel(F.hinge)?.member?.muteConfig, "explicit null clears")
        XCTAssertEqual(model.store.channel(F.hinge)?.member?.joinTimestamp, "2026-11-01T00:00:00Z", "membership kept")
    }

    func testStaleRESTResponseLosesToNewerGatewayField() async throws {
        let (model, _) = fixture()
        let store = model.store
        let versions = store.threadSettingsVersions(for: F.hinge)
        // Gateway: flags became NO_MESSAGES after the request began.
        await memberUpdate(model, #"{"id":"\#(F.hinge)","flags":9}"#)
        store.applyThreadSettings(ThreadMemberSettingsUpdate(flags: 3, muted: true, muteConfig: .some(MuteConfig(endTime: nil, selectedTimeWindow: -1))),
                                  thread: F.hinge, requested: ["flags", "muted", "mute_config"], versions: versions)
        XCTAssertEqual(store.notificationLevel(target(F.hinge)), .nothing, "the newer gateway flags win")
        XCTAssertTrue(store.isDirectlyMuted(target(F.hinge)), "unchallenged response fields still apply")
        // Fields the request did not ask for are ignored.
        store.applyThreadSettings(ThreadMemberSettingsUpdate(flags: 3, muted: false), thread: F.hinge, requested: ["muted"],
                                  versions: store.threadSettingsVersions(for: F.hinge))
        XCTAssertEqual(store.notificationLevel(target(F.hinge)), .nothing)
        XCTAssertFalse(store.isDirectlyMuted(target(F.hinge)))
    }

    func testLeavingDiscardsSettingsAndLateResponses() async throws {
        let (model, _) = fixture()
        let versions = model.store.threadSettingsVersions(for: F.hinge)
        await model.perform(.leave, on: F.hinge).value
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .inherit)
        XCTAssertTrue(model.store.needsThreadMembership(target(F.hinge)))
        model.store.applyThreadSettings(ThreadMemberSettingsUpdate(flags: 3), thread: F.hinge, requested: ["flags"], versions: versions)
        XCTAssertEqual(model.store.notificationLevel(target(F.hinge)), .inherit, "a response for a left thread is dropped")
    }

    func testThreadListSyncCarriesPreferences() async throws {
        let (model, _) = fixture()
        let json = #"{"d":{"guild_id":"\#(F.guild)","threads":[{"id":"\#(F.screenshots)","type":11,"parent_id":"\#(MockDiscord.generalChannel)","name":"Screenshot requests","thread_metadata":{"archived":false}}],"members":[{"id":"\#(F.screenshots)","user_id":"1","join_timestamp":"2026-11-02T00:00:00Z","flags":3,"muted":false}]}}"#
        await model.handle(GatewayDispatch(name: "THREAD_LIST_SYNC", data: Data(json.utf8)))
        XCTAssertTrue(model.store.isJoined(thread: F.screenshots))
        XCTAssertEqual(model.store.notificationLevel(target(F.screenshots)), .all)
    }

    func testMockReadyReflectsWrittenSettingsAndJoinResetsThem() async throws {
        let (model, mock) = fixture()
        await model.changeNotifications(target(F.hinge), patch: NotificationPatch(level: .nothing)).value
        XCTAssertEqual(mock.currentGuilds()[0].threads.first { $0.id == F.hinge }?.member?.flags, 9)
        await model.perform(.leave, on: F.hinge).value
        await model.perform(.join, on: F.hinge).value
        XCTAssertEqual(mock.currentGuilds()[0].threads.first { $0.id == F.hinge }?.member?.flags, 0, "rejoining starts fresh")
    }

    // MARK: REST list membership

    private func listPayload() -> Data {
        Data(#"{"threads":[{"id":"99001","type":11,"guild_id":"\#(F.guild)","parent_id":"\#(images)","name":"Archived member","thread_metadata":{"archived":true,"archive_timestamp":"2026-11-01T00:00:00Z"}}],"members":[{"id":"99001","join_timestamp":"2026-10-31T00:00:00Z","flags":9,"muted":true,"mute_config":{"end_time":null,"selected_time_window":-1}},{"id":"99002","flags":3}],"has_more":false}"#.utf8)
    }

    private func loadMemberPage(forum: Bool, model: AppModel,
                                beforeReturn: @escaping @MainActor () async -> Void = {}) async throws {
        let parent = try XCTUnwrap(model.store.channel(images))
        if forum {
            let result = try JSONDecoder().decode(ThreadSearchResult.self, from: listPayload())
            let owner = LookupPagingState<String, Channel>()
            await owner.start("forum", load: { _ in
                let revision = model.store.channelRevision
                await beforeReturn()
                return .forum(result, forum: parent, store: model.store, since: revision)
            }, isCurrent: { true }, publish: { model.store.remember(threads: $0.rows) }).value
        } else {
            let result = try JSONDecoder().decode(ArchivedThreadPage.self, from: listPayload())
            let owner = OtherListState<String, Channel, String>()
            await OtherListConsumers.archives(owner, input: "archives", api: model.api, parent: parent,
                                              store: model.store, isCurrent: { true }, fetch: { _ in
                await beforeReturn()
                return result
            }).value
        }
    }

    func testArchiveListHydratesJoinedMemberAndEditablePreferences() async throws {
        let (model, mock) = fixture()
        XCTAssertNil(model.store.channel(99001), "archived thread absent from READY")
        try await loadMemberPage(forum: false, model: model)
        XCTAssertTrue(model.store.isJoined(thread: 99001))
        XCTAssertEqual(model.store.threadMember(99001)?.joinTimestamp, "2026-10-31T00:00:00Z")
        XCTAssertEqual(model.store.notificationLevel(target(99001)), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(target(99001)))
        XCTAssertFalse(model.store.needsThreadMembership(target(99001)))
        XCTAssertFalse(model.store.isJoined(thread: 99002), "unreturned memberships cannot enter the store")
        // The same gate used by the settings view permits an archived member.
        // A mock refusal still proves the save was sent, rather than blocked as unjoined.
        await model.changeNotifications(target(99001), patch: NotificationPatch(level: .all)).value
        XCTAssertEqual(settingsOps(mock).last?.route, "channels/99001/thread-members/@me/settings")
    }

    func testForumListHydratesMemberNotificationFlagsAndMute() async throws {
        let (model, _) = fixture()
        try await loadMemberPage(forum: true, model: model)
        XCTAssertTrue(model.store.isJoined(thread: 99001))
        XCTAssertEqual(model.store.notificationLevel(target(99001)), .nothing)
        XCTAssertTrue(model.store.isDirectlyMuted(target(99001)))
        XCTAssertEqual(model.store.threadMember(99001)?.muteConfig?.selectedTimeWindow, -1)
        XCTAssertFalse(model.store.needsThreadMembership(target(99001)))
        XCTAssertFalse(model.store.isJoined(thread: 99002))
    }

    func testLateArchiveAndForumMembersCannotUndoNewSettingsOrLeave() async throws {
        for forum in [false, true] {
            for leave in [false, true] {
                let (model, _) = fixture()
                try await loadMemberPage(forum: forum, model: model)
                if !leave {
                    await memberUpdate(model, #"{"id":"99001","guild_id":"\#(F.guild)","flags":3,"muted":false,"mute_config":null}"#)
                }
                // Even an equal gateway echo is newer authority than the page.
                try await loadMemberPage(forum: forum, model: model, beforeReturn: {
                    if leave {
                        model.store.setThreadMembership(99001, joined: false)
                    } else {
                        await self.memberUpdate(model, #"{"id":"99001","guild_id":"\#(F.guild)","flags":3,"muted":false,"mute_config":null}"#)
                    }
                })
                XCTAssertEqual(model.store.isJoined(thread: 99001), !leave)
                XCTAssertEqual(model.store.notificationLevel(target(99001)), leave ? .inherit : .all)
                XCTAssertFalse(model.store.isDirectlyMuted(target(99001)))
            }
        }
    }

    // MARK: Live REST wire (offline URL protocol)

    private func client() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "ThreadNotificationTests"),
                    protocolClasses: [ThreadSettingsWire.self])
    }

    func testRESTWireMemberResponseAnd204() async throws {
        ThreadSettingsWire.reset([
            (200, #"{"id":"55","user_id":"5","join_timestamp":"2026-11-01T00:00:00Z","flags":9,"muted":true,"mute_config":{"end_time":null,"selected_time_window":-1}}"#),
            (204, ""),
        ])
        let api = client()
        let updated = try await api.modifyThreadSettings(55, fields: ["flags": .number(9)])
        XCTAssertEqual(updated?.flags, 9)
        XCTAssertEqual(updated?.muted, true)
        XCTAssertEqual(updated?.muteConfig, .some(MuteConfig(endTime: nil, selectedTimeWindow: -1)))
        let unchanged = try await api.modifyThreadSettings(55, fields: ["muted": .bool(false), "mute_config": .null])
        XCTAssertNil(unchanged, "204 means nothing changed")
        let records = ThreadSettingsWire.captured()
        XCTAssertEqual(records.map(\.method), ["PATCH", "PATCH"])
        XCTAssertEqual(records.map(\.path), ["/api/v9/channels/55/thread-members/@me/settings", "/api/v9/channels/55/thread-members/@me/settings"])
        let first = try JSONSerialization.jsonObject(with: records[0].body) as? [String: Any]
        XCTAssertEqual(first?.keys.sorted(), ["flags"])
        XCTAssertEqual(first?["flags"] as? Int, 9)
        let second = try JSONSerialization.jsonObject(with: records[1].body, options: [.fragmentsAllowed]) as? [String: Any]
        XCTAssertTrue(second?["mute_config"] is NSNull)
    }

    func testRESTRefusalSurfacesDiscordMessage() async {
        ThreadSettingsWire.reset([(404, #"{"message":"Unknown Member","code":10007}"#)])
        do {
            _ = try await client().modifyThreadSettings(55, fields: ["flags": .number(2)])
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Discord returned 404: Unknown Member")
        }
    }
}
