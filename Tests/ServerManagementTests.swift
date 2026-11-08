import XCTest
@testable import DuocordNative

@MainActor
final class ServerManagementTests: XCTestCase {
    private func fixture() -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        // Use the same concrete transport whose writes are inspected.
        let subject = AppModel(readAPI: mock)
        subject.store.apply(ready: mock.readyPayload())
        return (subject, mock)
    }

    func testReorderPersistsAndKeepsFolderMetadataAndMemberships() async throws {
        let (model, mock) = fixture()
        let original = model.store.folders
        let source = mock.guilds[7].id, target = mock.guilds[0].id
        await model.moveServer(source, before: target).value
        XCTAssertEqual(mock.serverWrites, ["order"])
        XCTAssertEqual(model.store.folders.first?.guildIDs, [source])
        XCTAssertEqual(Set(model.store.folders.flatMap(\.guildIDs)), Set(mock.guilds.map(\.id)))
        XCTAssertEqual(model.store.folders.first { $0.id == 42 }, original.first { $0.id == 42 })
        let saved = try await mock.settingsProto()
        let persisted = try GuildFolderSettings(base64: XCTUnwrap(saved))
        XCTAssertEqual(persisted.folders, model.store.folders)
        XCTAssertEqual(persisted.dataVersion, 2)
    }

    func testMoveIntoFolderAndToEndPreservesOtherMembers() async throws {
        let (model, mock) = fixture()
        let source = mock.guilds[0].id, target = mock.guilds[3].id
        await model.moveServer(source, before: target).value
        XCTAssertEqual(model.store.folders.first { $0.id == 42 }?.guildIDs,
                       [mock.guilds[2].id, source, target, mock.guilds[4].id])
        await model.moveServer(source, before: nil).value
        XCTAssertEqual(model.store.folders.last?.guildIDs, [source])
        XCTAssertEqual(Set(model.store.folders.flatMap(\.guildIDs)), Set(mock.guilds.map(\.id)))
    }

    func testRefusedOrderDoesNotApplyAndFeedbackSurvives() async {
        let (model, mock) = fixture(), before = model.store.folders
        mock.serverWriteHook = { _ in throw DiscordError.http(403, "Refused") }
        await model.moveServer(mock.guilds[7].id, before: mock.guilds[0].id).value
        XCTAssertEqual(model.store.folders, before)
        XCTAssertTrue(mock.serverWrites.isEmpty)
        XCTAssertNotNil(model.servers.error)
        XCTAssertFalse(model.servers.busy)
    }

    func testForeignOrExpiredDragCannotReorder() async {
        let (model, mock) = fixture()
        model.receiveServerDrag("external", before: mock.guilds[0].id)
        let receipt = model.serverDrag(mock.guilds[7].id)
        model.store.apply(ready: mock.readyPayload())
        model.receiveServerDrag(receipt, before: mock.guilds[0].id)
        XCTAssertTrue(mock.serverWrites.isEmpty)
        XCTAssertFalse(model.servers.busy)
    }

    func testLeaveCancelSendsNothingAndRetainsDraft() async throws {
        let (model, mock) = fixture(), guild = mock.guilds[0]
        model.drafts[MockDiscord.generalChannel] = Draft(text: "Keep this")
        await model.requestLeaveServer(guild.id).value
        let capture = try XCTUnwrap(model.servers.confirmation)
        XCTAssertEqual(capture.name, guild.name)
        model.cancelServerLeave()
        await model.confirmServerLeave(capture).value
        XCTAssertTrue(mock.serverWrites.isEmpty)
        XCTAssertNotNil(model.store.guilds[guild.id])
        XCTAssertEqual(model.drafts[MockDiscord.generalChannel]?.text, "Keep this")
    }

    func testConfirmedLeaveRemovesOnlyTargetAndReturnsHome() async throws {
        let (model, mock) = fixture(), guild = mock.guilds[0]
        model.select(guild: guild.id); model.select(channel: MockDiscord.generalChannel)
        let other = mock.guilds[1].channels.first!.id
        model.drafts[MockDiscord.generalChannel] = Draft(text: "Discard")
        model.drafts[other] = Draft(text: "Keep")
        await model.requestLeaveServer(guild.id).value
        let capture = try XCTUnwrap(model.servers.confirmation)
        // SwiftUI dismisses the alert before running its button on some OS versions.
        model.dismissServerLeave()
        await model.confirmServerLeave(capture).value
        XCTAssertEqual(mock.serverWrites, ["leave"])
        XCTAssertNil(model.store.guilds[guild.id]); XCTAssertNil(model.selectedGuild); XCTAssertNil(model.selectedChannel)
        XCTAssertNil(model.drafts[MockDiscord.generalChannel]); XCTAssertEqual(model.drafts[other]?.text, "Keep")
        XCTAssertEqual(model.store.guilds.count, mock.guilds.count - 1)
        XCTAssertFalse(model.store.channels.values.contains { $0.guildID == guild.id })
        await model.confirmServerLeave(capture).value
        XCTAssertEqual(mock.serverWrites, ["leave"], "Confirmation is single use")
    }

    func testRefusedLeaveRetainsServerSelectionAndDraft() async throws {
        let (model, mock) = fixture(), guild = mock.guilds[0]
        model.select(guild: guild.id); model.select(channel: MockDiscord.generalChannel)
        model.drafts[MockDiscord.generalChannel] = Draft(text: "Keep")
        mock.serverWriteHook = { _ in throw DiscordError.http(403, "Refused") }
        await model.requestLeaveServer(guild.id).value
        await model.confirmServerLeave(try XCTUnwrap(model.servers.confirmation)).value
        XCTAssertNotNil(model.store.guilds[guild.id]); XCTAssertEqual(model.selectedGuild, guild.id)
        XCTAssertEqual(model.drafts[MockDiscord.generalChannel]?.text, "Keep")
        XCTAssertNotNil(model.servers.error); XCTAssertTrue(mock.serverWrites.isEmpty)
    }

    func testOwnerAndOldMembershipCannotBeLeft() async throws {
        let (model, mock) = fixture(), guild = mock.guilds[0]
        await model.requestLeaveServer(guild.id).value
        let capture = try XCTUnwrap(model.servers.confirmation)
        model.store.apply(ready: mock.readyPayload())
        await model.confirmServerLeave(capture).value
        XCTAssertTrue(mock.serverWrites.isEmpty)
        var ready = mock.readyPayload(); ready.guilds[0].ownerID = mock.me.id
        model.store.apply(ready: ready)
        await model.requestLeaveServer(guild.id).value
        XCTAssertNil(model.servers.confirmation)
        XCTAssertTrue(mock.serverWrites.isEmpty)
        XCTAssertTrue(model.servers.error?.contains("Transfer ownership") == true)
    }

    func testOrderPatchPreservesUnknownFieldsAndSendsOnlyFolderSection() throws {
        let base = MockDiscord.versionedServerSettings(guilds: MockDiscord().guilds.map(\.id))
        let data = try XCTUnwrap(Data(base64Encoded: base)) + FolderProtoField.message(99, Data("untouched".utf8))
        let settings = try GuildFolderSettings(base64: data.base64EncodedString())
        let order = try GuildOrganization(folders: settings.folders, membershipOrder: settings.folders.flatMap(\.guildIDs))
        let patch = try settings.patch(for: order.moving(order.positions.last!, before: order.positions.first!))
        let fields = try FolderProtoField.parse(XCTUnwrap(Data(base64Encoded: patch.settings)))
        XCTAssertEqual(fields.map(\.number), [14])
        let updated = try settings.replacingFolders(with: order, version: 2)
        XCTAssertTrue(try FolderProtoField.parse(XCTUnwrap(Data(base64Encoded: updated.base64))).contains { $0.number == 99 })
    }

    func testLeaveRouteIsMembershipDeleteNeverServerDelete() {
        let route = DiscordEndpoint.leaveGuild(GuildID(123)).descriptor
        XCTAssertEqual(route.method, "DELETE")
        XCTAssertEqual(route.path, "users/@me/guilds/123")
        XCTAssertEqual(DiscordEndpoint.saveSettingsProto.descriptor.method, "PATCH")
    }

    func testMembershipReplacementBeforeAdmissionRefusesBothWrites() async throws {
        for leaving in [false, true] {
            let (model, mock) = fixture()
            mock.serverWriteHook = { @MainActor _ in model.store.apply(ready: mock.readyPayload()) }
            if leaving {
                await model.requestLeaveServer(mock.guilds[0].id).value
                await model.confirmServerLeave(try XCTUnwrap(model.servers.confirmation)).value
            } else {
                await model.moveServer(mock.guilds[7].id, before: mock.guilds[0].id).value
            }
            XCTAssertTrue(mock.serverWrites.isEmpty)
            XCTAssertEqual(model.store.guilds.count, 8)
        }
    }

    func testMoveToTopDoesNotAccidentallyJoinFirstFolder() throws {
        let order = try GuildOrganization(folders: [GuildFolder(id: 42, name: "Keep", color: 123, guildIDs: [1, 2]),
                                                    GuildFolder(guildIDs: [3])], membershipOrder: [1, 2, 3])
        let next = try order.moving(3, before: 1, withinFolder: false)
        XCTAssertEqual(next.rows.first?.guildIDs, [3])
        XCTAssertEqual(next.rows.last, order.rows.first)
        let extracted = try order.moving(1, before: 1, withinFolder: false)
        XCTAssertEqual(extracted.rows.first?.guildIDs, [1])
        XCTAssertNil(extracted.rows.first?.id)
        XCTAssertEqual(extracted.rows[1].id, 42)
        XCTAssertEqual(extracted.rows[1].guildIDs, [2])
    }

    func testLeaveThenReorderReconcilesOnlyConfirmedDepartedReferences() async throws {
        let (model, mock) = fixture(), guild = mock.guilds[2]
        await model.requestLeaveServer(guild.id).value
        await model.confirmServerLeave(try XCTUnwrap(model.servers.confirmation)).value
        XCTAssertFalse(model.store.folders.flatMap(\.guildIDs).contains(guild.id))
        // REST still has the old reference until the next order write.
        let staleBase64 = try await mock.settingsProto()
        let stale = try GuildFolderSettings(base64: XCTUnwrap(staleBase64))
        XCTAssertTrue(stale.folders.flatMap(\.guildIDs).contains(guild.id))
        await model.moveServer(mock.guilds[7].id, before: mock.guilds[0].id).value
        XCTAssertEqual(mock.serverWrites, ["leave", "order"])
        XCTAssertEqual(Set(model.store.folders.flatMap(\.guildIDs)), Set(mock.guilds.map(\.id)).subtracting([guild.id]))
        XCTAssertEqual(model.store.folders.first { $0.id == 42 }?.guildIDs, [mock.guilds[3].id, mock.guilds[4].id])
        XCTAssertThrowsError(try GuildOrganization(folders: stale.folders, membershipOrder: model.store.guildOrder),
                             "Unknown missing memberships must still fail closed")
    }

    func testRESTLeaveAndOrderContractsAndAdmission() async throws {
        let credentials = SessionCredentials(token: "offline", superProperties: nil, userAgent: "Offline tests")
        let rest = DiscordREST(credentials: credentials, protocolClasses: [ServerManagementWire.self])
        ServerManagementWire.reset(status: 204, body: "")
        try await rest.leaveGuild(123, admission: { true })
        XCTAssertEqual(ServerManagementWire.records.first?.httpMethod, "DELETE")
        XCTAssertEqual(ServerManagementWire.records.first?.url?.path, "/api/v9/users/@me/guilds/123")
        XCTAssertNil(ServerManagementWire.records.first?.httpBody)

        ServerManagementWire.reset(status: 403, body: "{\"message\":\"Refused\",\"code\":50013}")
        do { try await rest.leaveGuild(124, admission: { true }); XCTFail("Refused leave must throw") } catch { }
        XCTAssertEqual(ServerManagementWire.records.count, 1, "Never replay a leave")
        ServerManagementWire.reset(status: 204, body: "")
        do { try await rest.leaveGuild(125, admission: { false }); XCTFail("Expired admission must throw") } catch { }
        XCTAssertTrue(ServerManagementWire.records.isEmpty)

        let base = MockDiscord.versionedServerSettings(guilds: MockDiscord().guilds.map(\.id))
        let settings = try GuildFolderSettings(base64: base)
        let order = try GuildOrganization(folders: settings.folders, membershipOrder: settings.folders.flatMap(\.guildIDs))
        let patch = try settings.patch(for: order)
        let response = String(decoding: try JSONEncoder().encode(GuildFolderSaveResponse(settings: base, outOfDate: false)), as: UTF8.self)
        ServerManagementWire.reset(status: 200, body: response)
        _ = try await rest.saveGuildFolders(patch, admission: { true })
        XCTAssertEqual(ServerManagementWire.records.first?.httpMethod, "PATCH")
        XCTAssertEqual(ServerManagementWire.records.first?.url?.path, "/api/v9/users/@me/settings-proto/1")
    }
}

/// Every URL is intercepted; an unexpected request fails closed.
nonisolated private final class ServerManagementWire: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var status = 599
    private static var body = ""
    private static var captured: [URLRequest] = []
    static var records: [URLRequest] { lock.withLock { captured } }
    static func reset(status: Int, body: String) { lock.withLock { self.status = status; self.body = body; captured = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.captured.append(request)
            return (Self.status, Self.body)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
