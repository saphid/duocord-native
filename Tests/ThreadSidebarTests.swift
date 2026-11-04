import XCTest
@testable import DuocordNative

/// Offline URL transport for the thread endpoints: records every request and
/// answers from a script; an exhausted script fails closed.
nonisolated private final class ThreadWire: URLProtocol, @unchecked Sendable {
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
final class ThreadSidebarTests: XCTestCase {
    typealias F = MockDiscord.ThreadFixture
    private let general = MockDiscord.generalChannel
    private let images = MockDiscord.imageChannel

    private func fixture() -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel(readAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        return (model, mock)
    }

    private func project(_ model: AppModel, categoryCollapsed: Bool = false) -> [DiscordStore.ChannelListEntry] {
        let category: Snowflake = 910_000_000_000_000_001
        let sections = model.store.channelList(for: F.guild, collapsed: categoryCollapsed ? [category] : [],
                                               threadsCollapsed: model.collapsedThreadParents, selected: model.selectedChannel)
        return sections.first { $0.category?.id == category }?.entries ?? []
    }

    // MARK: Collapse (built on the store's sidebar channel list)

    func testFixtureThreadsNestUnderTheirChannels() {
        let (model, _) = fixture()
        let rows = project(model)
        let generalRow = rows.first { $0.id == general }!
        XCTAssertEqual(Set(generalRow.threads.map(\.id)), [F.bookPose, F.screenshots, F.foldPhotos])
        XCTAssertEqual(generalRow.threads.first?.id, F.screenshots, "most recent activity first")
        XCTAssertTrue(generalRow.showsThreadDisclosure)
        XCTAssertFalse(generalRow.threadsCollapsed)
        XCTAssertEqual(generalRow.hiddenThreads, 0)
        let imageRow = rows.first { $0.id == images }!
        XCTAssertEqual(Set(imageRow.threads.map(\.id)), [F.hinge, F.release, F.moderators])
        XCTAssertEqual(imageRow.threads.first?.id, F.hinge)
        XCTAssertFalse(rows.first { $0.id == 910_000_000_000_000_101 }!.showsThreadDisclosure, "#welcome has no threads")
        XCTAssertTrue(model.store.isUnread(model.store.channel(F.hinge)!))
        XCTAssertEqual(model.store.mentionCount(F.hinge), 2)
    }

    func testFoldingOneChannelHidesOnlyItsQuietThreads() {
        let (model, _) = fixture()
        model.select(channel: general)
        model.toggleThreads(under: images)
        XCTAssertTrue(model.threadsCollapsed(under: images))
        let rows = project(model)
        let imageRow = rows.first { $0.id == images }!
        XCTAssertTrue(imageRow.threads.isEmpty, "Hide Threads hides unread and mentioned threads too")
        XCTAssertTrue(imageRow.threadsCollapsed)
        XCTAssertTrue(imageRow.showsThreadDisclosure, "the chevron stays to expand again")
        XCTAssertEqual(imageRow.threadCount, 3)
        XCTAssertEqual(imageRow.hiddenThreads, 3)
        XCTAssertEqual(rows.first { $0.id == general }!.threads.count, 3, "other channels are independent")
        XCTAssertEqual(model.selectedChannel, general, "folding never changes the selection")
        // No parent badge rollup: the channel row's own state is unchanged.
        XCTAssertEqual(ChannelRow.Badge(channel: imageRow.channel, store: model.store),
                       ChannelRow.Badge(channel: model.store.channel(images)!, store: model.store))
        XCTAssertEqual(model.store.mentionCount(images), 0)
        XCTAssertEqual(ThreadDisclosureButton.hint(imageRow), "3 threads hidden, 1 unread, 2 mentions")
        model.toggleThreads(under: images)
        XCTAssertEqual(Set(project(model).first { $0.id == images }!.threads.map(\.id)), [F.hinge, F.release, F.moderators])
        XCTAssertEqual(ThreadDisclosureButton.title(collapsed: true), "Show Threads")
    }

    func testFoldingHidesTheOpenUnreadThreadButKeepsTheConversation() {
        let (model, _) = fixture()
        model.select(channel: F.hinge)
        model.toggleThreads(under: images)
        let row = project(model).first { $0.id == images }!
        XCTAssertTrue(row.threads.isEmpty, "the open, unread, mentioned thread folds away too")
        XCTAssertEqual(row.hiddenThreads, 3)
        XCTAssertEqual(model.selectedChannel, F.hinge, "the conversation stays open")
        model.toggleThreads(under: images)
        XCTAssertTrue(project(model).first { $0.id == images }!.threads.contains { $0.id == F.hinge }, "expanding restores it")
    }

    func testBusyChannelWhoseThreadsAreAllUnreadStillFolds() {
        let (model, _) = fixture()
        var ready = MockDiscord().readyPayload()
        let ids = (0..<8).map { Snowflake(960_000_000_000_000_000 + UInt64($0)) }
        for (index, id) in ids.enumerated() {
            var thread = Channel(id: id, type: .publicThread, guildID: F.guild, name: "PR \(index)", parentID: general,
                                 lastMessageID: Snowflake(2_000 + UInt64(index)))
            thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
            ready.guilds[0].threads.append(thread)
            ready.readStates.append(ReadState(id: id, lastMessageID: 1, mentionCount: index % 2))
        }
        model.store.apply(ready: ready)
        XCTAssertTrue(Set(ids).isSubset(of: Set(project(model).first { $0.id == general }!.threads.map(\.id))),
                      "unread threads beyond the recent few stay listed while expanded")
        model.toggleThreads(under: general)
        let row = project(model).first { $0.id == general }!
        XCTAssertTrue(row.threads.isEmpty)
        XCTAssertEqual(row.hiddenThreads, row.threadCount)
        XCTAssertGreaterThanOrEqual(row.rollup.unreadThreads, 8)
    }

    func testCollapsedCategoryOwnsVisibilityAndOffersNoThreadDisclosure() {
        let (model, _) = fixture()
        model.select(channel: F.bookPose)
        model.toggleThreads(under: general)
        let rows = project(model, categoryCollapsed: true)
        let generalRow = rows.first { $0.id == general }!
        XCTAssertEqual(Set(generalRow.threads.map(\.id)), [F.bookPose, F.screenshots])
        XCTAssertFalse(generalRow.showsThreadDisclosure, "the category chevron owns this state")
        XCTAssertEqual(rows.first { $0.id == images }?.threads.map(\.id), [F.hinge], "an unread thread keeps its channel visible")
    }

    func testArchivedOpenThreadStaysUnderItsChannel() {
        let (model, _) = fixture()
        var archived = Channel(id: 777, type: .publicThread, guildID: F.guild, name: "Old", parentID: general)
        archived.threadMetadata = ThreadMetadata(archived: true, locked: false)
        model.store.remember(threads: [archived])
        model.select(channel: 777)
        XCTAssertTrue(project(model).first { $0.id == general }!.threads.contains { $0.id == 777 })
        model.toggleThreads(under: general)
        XCTAssertTrue(project(model).first { $0.id == general }!.threads.isEmpty)
        XCTAssertEqual(model.selectedChannel, 777)
    }

    // MARK: Eligibility

    func testOwnerMemberAndModeratorEligibility() {
        let (model, _) = fixture()
        // #image-dump: your role has Manage Threads.
        let hinge = model.threadCapabilities(F.hinge)
        XCTAssertTrue(hinge.canRename && hinge.canClose && hinge.canLock && hinge.canDelete && hinge.canLeave)
        XCTAssertFalse(hinge.canJoin || hinge.canReopen || hinge.canUnlock)
        let release = model.threadCapabilities(F.release)
        XCTAssertTrue(release.canUnlock && release.canJoin && release.canRename && release.canDelete)
        XCTAssertFalse(release.canLock || release.canLeave)
        XCTAssertTrue(model.threadCapabilities(F.moderators).canLeave)
        // #general: no Manage Threads.
        let screenshots = model.threadCapabilities(F.screenshots)
        XCTAssertEqual(screenshots, ThreadCapabilities(canJoin: true))
        let mine = model.threadCapabilities(F.foldPhotos)
        XCTAssertEqual(mine, ThreadCapabilities(canLeave: true, canRename: true, canClose: true))
        XCTAssertEqual(model.threadCapabilities(general), .none, "channels get no thread actions")
    }

    func testDiscordRulesForArchivedLockedAndPrivateThreads() {
        let me: Snowflake = 1, other: Snowflake = 2
        func thread(owner: Snowflake, archived: Bool = false, locked: Bool = false, type: ChannelType = .publicThread) -> Channel {
            var value = Channel(id: 10, type: type, guildID: 3, name: "t", parentID: 4)
            value.ownerID = owner
            value.threadMetadata = ThreadMetadata(archived: archived, locked: locked)
            return value
        }
        let member = Permission.viewChannel | Permission.sendInThreads
        let moderator = member | Permission.manageThreads
        // Anyone who can send in threads reopens an unlocked archive; a locked one needs a moderator.
        XCTAssertTrue(ThreadCapabilities.evaluate(thread: thread(owner: other, archived: true), me: me, permissions: member, canView: true, joined: false).canReopen)
        XCTAssertFalse(ThreadCapabilities.evaluate(thread: thread(owner: me, archived: true, locked: true), me: me, permissions: member, canView: true, joined: false).canReopen)
        XCTAssertTrue(ThreadCapabilities.evaluate(thread: thread(owner: other, archived: true, locked: true), me: me, permissions: moderator, canView: true, joined: false).canReopen)
        // An archived thread is reopened before anything else changes.
        let archived = ThreadCapabilities.evaluate(thread: thread(owner: me, archived: true), me: me, permissions: moderator, canView: true, joined: true)
        XCTAssertFalse(archived.canRename || archived.canLock || archived.canJoin || archived.canLeave || archived.canClose)
        XCTAssertTrue(archived.canDelete)
        // A locked thread's owner can no longer rename or close it.
        let locked = ThreadCapabilities.evaluate(thread: thread(owner: me, locked: true), me: me, permissions: member, canView: true, joined: true)
        XCTAssertFalse(locked.canRename || locked.canClose || locked.canUnlock)
        // Private threads are joined by invitation unless you manage threads.
        XCTAssertFalse(ThreadCapabilities.evaluate(thread: thread(owner: other, type: .privateThread), me: me, permissions: member, canView: true, joined: false).canJoin)
        XCTAssertTrue(ThreadCapabilities.evaluate(thread: thread(owner: other, type: .privateThread), me: me, permissions: moderator, canView: true, joined: false).canJoin)
        // Manage Channels alone grants no thread management.
        let channels = member | (1 << 4)
        XCTAssertEqual(ThreadCapabilities.evaluate(thread: thread(owner: other), me: me, permissions: channels, canView: true, joined: true),
                       ThreadCapabilities(canLeave: true))
        XCTAssertEqual(ThreadCapabilities.evaluate(thread: thread(owner: other), me: me, permissions: moderator, canView: false, joined: true), .none)
    }

    func testRenameValidation() {
        XCTAssertEqual(ThreadPatch.validName("  Hinge timing \n"), "Hinge timing")
        XCTAssertNil(ThreadPatch.validName("   "))
        XCTAssertNil(ThreadPatch.validName(String(repeating: "a", count: 101)))
        XCTAssertNotNil(ThreadPatch.validName(String(repeating: "a", count: 100)))
        XCTAssertEqual(ThreadPatch(archived: true).fields, ["archived": .bool(true)], "only changed fields are sent")
    }

    // MARK: Writes through the mock

    func testRenameCloseAndReopenUpdateStoreAfterConfirmation() async throws {
        let (model, mock) = fixture()
        model.select(channel: F.hinge)
        await model.perform(.rename("  Hinge easing curves "), on: F.hinge).value
        XCTAssertEqual(mock.threadOperations.last, .init(method: "PATCH", route: "channels/\(F.hinge)", fields: ["name": .string("Hinge easing curves")]))
        XCTAssertEqual(model.store.channel(F.hinge)?.name, "Hinge easing curves")
        await model.perform(.rename("Hinge easing curves"), on: F.hinge).value
        XCTAssertEqual(mock.threadOperations.count, 1, "an unchanged name sends nothing")

        await model.perform(.close, on: F.hinge).value
        XCTAssertEqual(mock.threadOperations.last?.fields, ["archived": .bool(true)])
        XCTAssertEqual(model.store.channel(F.hinge)?.threadMetadata?.archived, true)
        XCTAssertFalse(model.store.threads(in: images).contains { $0.id == F.hinge })
        XCTAssertEqual(model.selectedChannel, F.hinge, "closing keeps the conversation open")
        XCTAssertTrue(project(model).first { $0.id == images }!.threads.contains { $0.id == F.hinge }, "and its sidebar row")
        XCTAssertTrue(model.threadCapabilities(F.hinge).canReopen)

        await model.perform(.reopen, on: F.hinge).value
        XCTAssertEqual(model.store.channel(F.hinge)?.threadMetadata?.archived, false)
        XCTAssertFalse(mock.readyPayload().guilds[0].threads.isEmpty)
        XCTAssertEqual(mock.currentGuilds()[0].threads.first { $0.id == F.hinge }?.name, "Hinge easing curves", "READY reflects the change")
    }

    func testClosingMovesActiveThreadIntoArchiveWithoutReload() async {
        let (model, _) = fixture()
        let store = model.store
        func archived(_ loaded: [Channel] = []) -> [Channel] {
            OtherListConsumers.archivedRows(loaded, active: store.threads(in: images), store: store, parent: images)
        }
        XCTAssertFalse(archived().contains { $0.id == F.hinge })
        await model.perform(.close, on: F.hinge).value
        XCTAssertEqual(archived().filter { $0.id == F.hinge }.count, 1)
        let closed = store.channel(F.hinge)!
        XCTAssertEqual(archived([closed, closed]).filter { $0.id == F.hinge }.count, 1)
        XCTAssertTrue(model.threadCapabilities(F.hinge).canReopen)
        await model.perform(.reopen, on: F.hinge).value
        XCTAssertFalse(archived([closed]).contains { $0.id == F.hinge })
        XCTAssertTrue(store.threads(in: images).contains { $0.id == F.hinge })
    }

    func testLockUnlockJoinAndLeave() async throws {
        let (model, mock) = fixture()
        await model.perform(.unlock, on: F.release).value
        XCTAssertEqual(model.store.channel(F.release)?.threadMetadata?.locked, false)
        await model.perform(.lock, on: F.release).value
        XCTAssertEqual(model.store.channel(F.release)?.threadMetadata?.locked, true)

        await model.perform(.join, on: F.screenshots).value
        XCTAssertEqual(mock.threadOperations.last, .init(method: "PUT", route: "channels/\(F.screenshots)/thread-members/@me", fields: nil))
        XCTAssertTrue(model.store.isJoined(thread: F.screenshots))
        XCTAssertTrue(model.threadCapabilities(F.screenshots).canLeave)

        await model.perform(.leave, on: F.foldPhotos).value
        XCTAssertEqual(mock.threadOperations.last?.method, "DELETE")
        XCTAssertFalse(model.store.isJoined(thread: F.foldPhotos))
        XCTAssertNil(model.store.channel(F.foldPhotos)?.member, "stale READY membership is cleared")
        XCTAssertTrue(model.threadCapabilities(F.foldPhotos).canJoin)
    }

    func testIneligibleActionsSendNothing() async {
        let (model, mock) = fixture()
        await model.perform(.delete, on: F.screenshots).value
        await model.perform(.lock, on: F.foldPhotos).value
        await model.perform(.leave, on: F.screenshots).value
        await model.perform(.rename("   "), on: F.foldPhotos).value
        XCTAssertTrue(mock.threadOperations.isEmpty)
        XCTAssertNotNil(model.threadCapabilities(F.screenshots))
    }

    func testDeleteRemovesThreadAndSelectsItsParent() async throws {
        let (model, mock) = fixture()
        model.select(channel: F.release)
        model.threads.prompt = .delete(F.release, .sidebar)
        await model.perform(.delete, on: F.release).value
        XCTAssertEqual(mock.threadOperations.last, .init(method: "DELETE", route: "channels/\(F.release)", fields: nil))
        XCTAssertNil(model.store.channel(F.release))
        XCTAssertEqual(model.selectedChannel, images)
        XCTAssertNil(model.threads.prompt)
        XCTAssertFalse(mock.currentGuilds()[0].threads.contains { $0.id == F.release })
    }

    func testRefusedWriteChangesNothingAndReportsIt() async throws {
        let (model, mock) = fixture()
        mock.failNextThreadWrite = true
        await model.perform(.close, on: F.hinge).value
        XCTAssertEqual(model.store.channel(F.hinge)?.threadMetadata?.archived, false)
        XCTAssertTrue(model.toast?.text.hasPrefix("Couldn’t close the thread.") == true)
        XCTAssertFalse(model.threads.isSaving(F.hinge))
        mock.failNextThreadWrite = true
        await model.perform(.delete, on: F.hinge).value
        XCTAssertNotNil(model.store.channel(F.hinge))
    }

    func testRealAccountWritesAreBlockedInDebug() async {
        let mock = MockDiscord()
        let model = AppModel(notificationAPI: mock)
        model.store.apply(ready: mock.readyPayload())
        await model.perform(.close, on: F.hinge).value
        XCTAssertTrue(mock.threadOperations.isEmpty)
        XCTAssertEqual(model.toast?.text, "Thread actions are disabled for real accounts in Debug.")
    }

    func testGatewayDeleteOfOpenThreadFallsBackToParent() async {
        let (model, _) = fixture()
        model.select(channel: F.screenshots)
        await model.handle(GatewayDispatch(name: "THREAD_DELETE", data: Data(#"{"d":{"id":"\#(F.screenshots)","parent_id":"\#(general)"}}"#.utf8)))
        XCTAssertNil(model.store.channel(F.screenshots))
        XCTAssertEqual(model.selectedChannel, general)
    }

    func testGatewayLeaveClearsMembership() async {
        let (model, mock) = fixture()
        let me = mock.me.id
        await model.handle(GatewayDispatch(name: "THREAD_MEMBERS_UPDATE",
            data: Data(#"{"d":{"id":"\#(F.hinge)","guild_id":"\#(F.guild)","removed_member_ids":["\#(me)"]}}"#.utf8)))
        XCTAssertFalse(model.store.isJoined(thread: F.hinge))
        XCTAssertTrue(model.threadCapabilities(F.hinge).canJoin)
    }

    // MARK: Live REST wire (offline URL protocol)

    func testRESTThreadEndpointsWire() async throws {
        ThreadWire.reset([(200, #"{"id":"55","type":11,"guild_id":"7","name":"Renamed","parent_id":"6","thread_metadata":{"archived":false,"locked":true}}"#),
                          (204, ""), (204, ""), (204, "")])
        let api = DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "ThreadTests"),
                              protocolClasses: [ThreadWire.self])
        let updated = try await api.modifyThread(55, patch: ThreadPatch(name: "Renamed", locked: true))
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.threadMetadata?.locked, true)
        try await api.joinThread(55)
        try await api.leaveThread(55)
        try await api.deleteThread(55)
        let records = ThreadWire.captured()
        XCTAssertEqual(records.map(\.method), ["PATCH", "PUT", "DELETE", "DELETE"])
        XCTAssertEqual(records.map(\.path), ["/api/v9/channels/55", "/api/v9/channels/55/thread-members/@me",
                                             "/api/v9/channels/55/thread-members/@me", "/api/v9/channels/55"])
        let body = try JSONSerialization.jsonObject(with: records[0].body) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "Renamed")
        XCTAssertEqual(body?["locked"] as? Bool, true)
        XCTAssertNil(body?["archived"])
        XCTAssertTrue(records[1].body.isEmpty)
    }

    func testRESTRefusalSurfacesDiscordMessage() async {
        ThreadWire.reset([(403, #"{"message":"Missing Permissions","code":50013}"#)])
        let api = DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-token", superProperties: nil, userAgent: "ThreadTests"),
                              protocolClasses: [ThreadWire.self])
        do {
            try await api.deleteThread(55)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Discord returned 403: Missing Permissions")
        }
    }

    func testLinkFormat() {
        XCTAssertEqual(DiscordStore.link(guild: F.guild, channel: F.hinge), "https://discord.com/channels/\(F.guild)/\(F.hinge)")
    }
}
