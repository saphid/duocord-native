import XCTest
@testable import DuocordNative

@MainActor
final class CapabilityTests: XCTestCase {
    private func fixture(_ edit: (inout ReadyPayload) -> Void = { _ in }) -> (DiscordStore, Channel) {
        let mock = MockDiscord()
        var ready = mock.readyPayload()
        edit(&ready)
        let store = DiscordStore()
        store.apply(ready: ready)
        return (store, store.channel(MockDiscord.generalChannel)!)
    }

    func testMissingGuildAndAccountAreNotDirectMessages() {
        let store = DiscordStore()
        XCTAssertFalse(store.canSend(in: Channel(id: 1, type: .text)))
        XCTAssertFalse(store.canView(Channel(id: 1, type: .text, guildID: 2)))
        XCTAssertFalse(store.canPin(in: Channel(id: 1, type: .text, guildID: 2)))
        XCTAssertFalse(store.canSend(in: Channel(id: 1, type: .dm)), "even a DM requires an account")
        let (known, _) = fixture()
        XCTAssertTrue(known.canSend(in: Channel(id: 1, type: .dm)))
        XCTAssertTrue(known.canSend(in: Channel(id: 1, type: .groupDM)))
    }

    func testMissingMemberDoesNotFallBackToEveryone() {
        let (store, channel) = fixture { $0.mergedMembers = [] }
        XCTAssertFalse(store.canSend(in: channel))
        XCTAssertFalse(store.canView(channel))
    }

    func testThreadMustResolveItsParentBeforeGrantingPermissions() {
        let (store, channel) = fixture()
        var thread = Channel(id: 1, type: .publicThread, guildID: channel.guildID, parentID: 2)
        thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        XCTAssertFalse(store.canSend(in: thread))
        XCTAssertEqual(store.permissions(in: thread), 0)
    }

    func testTimeoutPreventsSendAndPinsButPreservesView() throws {
        let mock = MockDiscord()
        let data = Data("{\"user\":{\"id\":\"\(mock.me.id)\",\"username\":\"me\"},\"roles\":[],\"communication_disabled_until\":\"2099-01-01T00:00:00Z\"}".utf8)
        let member = try JSONDecoder().decode(Member.self, from: data)
        let (store, channel) = fixture { $0.mergedMembers[0] = [member] }
        XCTAssertTrue(store.canView(channel))
        XCTAssertFalse(store.canSend(in: channel))
        XCTAssertFalse(store.canPin(in: channel))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(member)) as! [String: Any]
        XCTAssertEqual(json["communication_disabled_until"] as? String, "2099-01-01T00:00:00Z")
    }

    func testNoSendImplicitlyRemovesAttachmentAndEmbedPermissions() {
        let (store, channel) = fixture { ready in
            let guild = ready.guilds[0].id
            let index = ready.guilds[0].channels.firstIndex { $0.id == MockDiscord.generalChannel }!
            ready.guilds[0].channels[index].permissionOverwrites = [
                PermissionOverwrite(id: guild, type: 0, allow: String((1 << 14) | (1 << 15)), deny: String(Permission.sendMessages))
            ]
        }
        XCTAssertEqual(store.permissions(in: channel) & ((1 << 14) | (1 << 15)), 0)
    }

    func testPartialMemberUpdateKeepsKnownRolesAndAvatar() throws {
        let mock = MockDiscord()
        let (store, channel) = fixture()
        let before = try XCTUnwrap(store.member(mock.me.id, in: channel.guildID))
        let payload = "{\"d\":{\"guild_id\":\"\(channel.guildID!)\",\"user\":{\"id\":\"\(mock.me.id)\",\"username\":\"me\"},\"nick\":\"updated\"}}"
        store.handle(GatewayDispatch(name: "GUILD_MEMBER_UPDATE", data: Data(payload.utf8)))
        let after = try XCTUnwrap(store.member(mock.me.id, in: channel.guildID))
        XCTAssertEqual(after.nick, "updated")
        XCTAssertEqual(after.roles, before.roles)
        XCTAssertEqual(after.avatar, before.avatar)
    }
    private func context(bits: UInt64 = Permission.viewChannel | Permission.sendMessages | Permission.sendInThreads | Permission.readHistory) -> CapabilityContext {
        let account = User(id: 5, username: "offline")
        var channel = Channel(id: 2, type: .text, guildID: 1)
        channel.rateLimitPerUser = 0
        let guild = Guild(id: 1, name: "offline", roles: [Role(id: 1, name: "everyone", color: 0, position: 0, permissions: String(bits))])
        return CapabilityContext(channel: channel, account: account, guild: guild,
                                 member: Member(user: account, nick: nil, roles: []), now: Date(timeIntervalSince1970: 1000))
    }

    private func send(_ context: CapabilityContext, _ features: MessagePayloadFeatures = MessagePayloadFeatures()) -> CapabilityDecision {
        DiscordOperation.send(features).evaluate(context)
    }

    func testUnknownFactsStayDistinctFromDenial() {
        var c = context()
        c.account = nil
        XCTAssertEqual(send(c).state, .unknown)
        XCTAssertTrue(send(c).reasons.contains(.missing(.account)))
        c = context(); c.guild = nil
        XCTAssertEqual(send(c).state, .unknown)
        XCTAssertTrue(send(c).reasons.contains(.missing(.guild)))
        c = context(); c.member = nil
        XCTAssertEqual(send(c).state, .unknown)
        XCTAssertTrue(send(c).reasons.contains(.missing(.member)))
        c = context(bits: Permission.viewChannel)
        XCTAssertEqual(send(c).state, .denied)
        XCTAssertTrue(send(c).reasons.contains(.missingPermissions(Permission.sendMessages)))
    }

    func testDirectMessageKindsHaveExplicitProvenance() {
        for type: ChannelType in [.dm, .groupDM] {
            var c = context(); c.channel.type = type; c.channel.guildID = nil; c.guild = nil; c.member = nil
            XCTAssertTrue(send(c).isAllowed)
            XCTAssertTrue(send(c).provenance.contains(.directMessage))
            c.channel.type = .text
            XCTAssertEqual(send(c).state, .unknown)
        }
    }

    func testEveryoneThenAggregatedRolesThenMemberOverwriteAndFlips() {
        var c = context()
        c.guild!.roles += [Role(id: 7, name: "deny", color: 0, position: 1), Role(id: 8, name: "allow", color: 0, position: 2)]
        c.member!.roles = [1, 7, 8] // everyone must not be reapplied as an ordinary role
        c.channel.permissionOverwrites = [
            PermissionOverwrite(id: 1, type: 0, allow: "0", deny: String(Permission.sendMessages)),
            PermissionOverwrite(id: 7, type: 0, allow: "0", deny: String(Permission.sendMessages)),
            PermissionOverwrite(id: 8, type: 0, allow: String(Permission.sendMessages), deny: "0")
        ]
        XCTAssertTrue(send(c).isAllowed, "role allows aggregate after all role denies")
        c.channel.permissionOverwrites!.append(PermissionOverwrite(id: 5, type: 1, allow: "0", deny: String(Permission.sendMessages)))
        XCTAssertEqual(send(c).state, .denied, "member overwrite is last")
        c.channel.permissionOverwrites![3] = PermissionOverwrite(id: 5, type: 1, allow: String(Permission.sendMessages), deny: "0")
        XCTAssertTrue(send(c).isAllowed)
        c.channel.permissionOverwrites![3] = PermissionOverwrite(id: 5, type: 1, allow: "0", deny: String(Permission.viewChannel))
        let p = CapabilityResolver.permissions(c)
        XCTAssertEqual(p.permissions! & Permission.channelScoped, 0)
        XCTAssertEqual(send(c).state, .denied)
    }

    func testPayloadRequirementsDoNotDisablePlainText() {
        var c = context(bits: Permission.viewChannel | Permission.sendMessages)
        XCTAssertTrue(send(c).isAllowed)
        XCTAssertEqual(send(c, MessagePayloadFeatures(isReply: true)).state, .denied)
        XCTAssertEqual(send(c, MessagePayloadFeatures(fileCount: 1)).state, .denied)
        c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.sendMessages | Permission.readHistory)
        XCTAssertTrue(send(c, MessagePayloadFeatures(isReply: true)).isAllowed)
        XCTAssertEqual(send(c, MessagePayloadFeatures(fileCount: 1)).state, .denied)
        c.guild!.roles[0].permissions = String(UInt64(c.guild!.roles[0].permissions)! | Permission.attachFiles)
        XCTAssertTrue(send(c, MessagePayloadFeatures(hasText: false, isReply: true, fileCount: 2)).isAllowed)
        XCTAssertEqual(send(c, MessagePayloadFeatures(hasText: false)).state, .denied)
        XCTAssertEqual(send(c, MessagePayloadFeatures(fileCount: -1)).state, .denied)
        XCTAssertEqual(send(c, MessagePayloadFeatures(hasEmbeds: true)).state, .denied)
        XCTAssertEqual(send(c, MessagePayloadFeatures(hasPoll: true)).state, .denied)
    }

    func testThreadsUseParentOverwritesButTheirOwnSendBitAndSlowmode() {
        var c = context(bits: Permission.viewChannel | Permission.sendInThreads | Permission.attachFiles)
        c.parent = c.channel
        c.channel.id = 3; c.channel.type = .publicThread; c.channel.parentID = 2
        c.channel.threadMetadata = ThreadMetadata(archived: false, locked: false)
        c.channel.permissionOverwrites = [PermissionOverwrite(id: 1, type: 0, allow: "0", deny: String(Permission.sendInThreads))]
        XCTAssertTrue(send(c, MessagePayloadFeatures(fileCount: 1)).isAllowed, "thread overwrites are inherited, not independently applied")
        c.parent!.permissionOverwrites = c.channel.permissionOverwrites
        XCTAssertEqual(send(c).state, .denied)
        c.parent = nil
        XCTAssertEqual(send(c).state, .unknown)
        XCTAssertTrue(send(c).reasons.contains(.missing(.parent)))
    }

    func testPrivateThreadMembershipUnknownJoinedAndConfirmedAbsent() {
        var c = context()
        c.parent = c.channel
        c.channel.id = 3; c.channel.type = .privateThread; c.channel.parentID = 2
        c.channel.threadMetadata = ThreadMetadata(archived: false, locked: false)
        c.channel.ownerID = 99
        XCTAssertEqual(send(c).state, .unknown)
        XCTAssertTrue(send(c).reasons.contains(.missing(.membership)))
        c.membership = .notJoined
        XCTAssertEqual(send(c).state, .denied)
        c.membership = .joined
        XCTAssertTrue(send(c).isAllowed)
        c.membership = .notJoined; c.channel.ownerID = 5
        XCTAssertTrue(send(c).isAllowed)
        c.channel.ownerID = 99; c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.sendInThreads | Permission.manageThreads)
        XCTAssertTrue(send(c).isAllowed, "thread managers bypass private membership")
    }

    func testTimeoutExpiryAndDocumentedOwnerAdminExemptions() {
        for bypass in [0, 1, 2] {
            var c = context()
            if bypass == 1 { c.guild!.ownerID = c.account!.id }
            if bypass == 2 { c.guild!.roles[0].permissions = String(Permission.administrator) }
            c.member!.communicationDisabledUntil = "1970-01-01T00:20:00.000Z"
            XCTAssertEqual(send(c).state, bypass == 0 ? .denied : .allowed)
            XCTAssertEqual(send(c).reasons.contains(.timedOut(until: Date(timeIntervalSince1970: 1200))), bypass == 0)
            XCTAssertTrue(DiscordOperation.viewChannel.evaluate(c).isAllowed)
            XCTAssertTrue(DiscordOperation.listPins.evaluate(c).isAllowed)
            c.now = Date(timeIntervalSince1970: 1200)
            XCTAssertTrue(send(c).isAllowed, "expiry is evaluated at the boundary without a gateway event")
        }
        var c = context(); c.member!.communicationDisabledUntil = "malformed"
        XCTAssertEqual(send(c).state, .unknown)
    }

    func testPartialTimeoutUpdatePreservesThenExplicitNullClears() throws {
        let mock = MockDiscord()
        let (store, channel) = fixture()
        let guild = channel.guildID!
        func update(_ fields: String) {
            let json = "{\"d\":{\"guild_id\":\"\(guild)\",\"user\":{\"id\":\"\(mock.me.id)\",\"username\":\"me\"},\(fields)}}"
            store.handle(GatewayDispatch(name: "GUILD_MEMBER_UPDATE", data: Data(json.utf8)))
        }
        update("\"communication_disabled_until\":\"2099-01-01T00:00:00Z\",\"avatar\":\"guild-avatar\"")
        let roles = try XCTUnwrap(store.member(mock.me.id, in: guild)).roles
        XCTAssertFalse(store.canSend(in: channel))
        update("\"nick\":\"new nick\"")
        let kept = try XCTUnwrap(store.member(mock.me.id, in: guild))
        XCTAssertEqual(kept.communicationDisabledUntil, "2099-01-01T00:00:00Z")
        XCTAssertEqual(kept.roles, roles); XCTAssertEqual(kept.avatar, "guild-avatar")
        update("\"communication_disabled_until\":null,\"avatar\":null,\"roles\":[]")
        let cleared = try XCTUnwrap(store.member(mock.me.id, in: guild))
        XCTAssertNil(cleared.communicationDisabledUntil); XCTAssertNil(cleared.avatar); XCTAssertEqual(cleared.roles, [])
        XCTAssertTrue(store.canSend(in: channel))
    }

    func testHumanSlowmodeKnownUnknownExpiryAndExemptions() {
        var c = context(); c.channel.rateLimitPerUser = 10
        var permissions = CapabilityResolver.permissions(c)
        XCTAssertEqual(CapabilityResolver.slowmode(c, permissions: permissions), .unknown(.slowmodeHistory))
        XCTAssertEqual(send(c).state, .unknown)
        c.slowmodeHistory = .lastConfirmedSend(Date(timeIntervalSince1970: 995))
        XCTAssertEqual(CapabilityResolver.slowmode(c, permissions: permissions), .cooldown(until: Date(timeIntervalSince1970: 1005)))
        XCTAssertEqual(send(c).state, .denied)
        c.now = Date(timeIntervalSince1970: 1005)
        XCTAssertTrue(send(c).isAllowed)
        c.slowmodeHistory = .eligible
        XCTAssertTrue(send(c).isAllowed)
        c.slowmodeHistory = .unknown
        for exemption in [Permission.manageMessages, Permission.manageChannels, Permission.administrator] {
            c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.sendMessages | exemption)
            permissions = CapabilityResolver.permissions(c)
            XCTAssertEqual(CapabilityResolver.slowmode(c, permissions: permissions), .exempt)
            XCTAssertTrue(send(c).isAllowed)
        }
        c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.sendMessages | Permission.manageThreads)
        c.accountKind = .bot
        XCTAssertEqual(send(c).state, .unknown, "do not import bot exemption observations into human-account policy")
        c.accountKind = .human
        XCTAssertEqual(send(c).state, .unknown, "Manage Threads alone is not a slowmode exemption")
        c.channel.rateLimitPerUser = nil
        XCTAssertTrue(send(c).reasons.contains(.missing(.slowmodeConfiguration)))
    }

    func testPinHistoryKindsAndMessageOwnershipHaveContext() {
        var c = context(bits: Permission.viewChannel | Permission.pinMessages)
        XCTAssertEqual(DiscordOperation.pinMessage.evaluate(c).state, .unknown)
        XCTAssertTrue(DiscordOperation.pinMessage.evaluate(c).reasons.contains(.accountValidationRequired(.pinHistory)))
        c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.pinMessages | Permission.readHistory)
        XCTAssertTrue(DiscordOperation.pinMessage.evaluate(c).isAllowed)
        c.channel.type = .voice
        XCTAssertEqual(DiscordOperation.pinMessage.evaluate(c).state, .unknown)
        XCTAssertTrue(DiscordOperation.pinMessage.evaluate(c).reasons.contains(.accountValidationRequired(.pinChannelKind)))
        c.channel.type = .forum
        XCTAssertEqual(DiscordOperation.pinMessage.evaluate(c).state, .denied)
        c.channel.type = .text
        XCTAssertEqual(DiscordOperation.editMessage.evaluate(c).state, .unknown)
        c.messageAuthorID = 5
        XCTAssertTrue(DiscordOperation.editMessage.evaluate(c).isAllowed)
        c.messageAuthorID = 7
        XCTAssertEqual(DiscordOperation.editMessage.evaluate(c).state, .denied)
        XCTAssertEqual(DiscordOperation.deleteMessage.evaluate(c).state, .denied)
        c.guild!.roles[0].permissions = String(Permission.viewChannel | Permission.manageMessages)
        XCTAssertTrue(DiscordOperation.deleteMessage.evaluate(c).isAllowed)
        c.channel.type = .dm; c.channel.guildID = nil
        XCTAssertEqual(DiscordOperation.deleteMessage.evaluate(c).state, .denied)
    }

    func testThreadPolicyKeepsArchivedSendAndCreatorDeleteConservative() {
        var c = context(); c.parent = c.channel
        c.channel.id = 3; c.channel.type = .publicThread; c.channel.parentID = 2
        c.channel.ownerID = 5; c.membership = .joined
        c.channel.threadMetadata = ThreadMetadata(archived: false, locked: false)
        XCTAssertTrue(ThreadCapabilities.evaluate(context: c).canClose)
        XCTAssertFalse(ThreadCapabilities.evaluate(context: c).canDelete)
        c.channel.threadMetadata!.archived = true
        XCTAssertEqual(send(c).state, .denied, "do not auto-unarchive based on bot-only evidence")
        XCTAssertTrue(ThreadCapabilities.evaluate(context: c).canReopen)
        c.channel.threadMetadata = nil
        XCTAssertEqual(DiscordOperation.thread(.close).evaluate(c).state, .unknown)
    }

    func testMalformedRoleAndOverwriteFactsStayUnknown() throws {
        var c = context()
        c.guild!.roles[0].permissions = "broken"
        XCTAssertEqual(send(c).state, .unknown)
        c = context(); c.member!.roles = [999]
        XCTAssertEqual(send(c).state, .unknown)
        c = context(); c.channel.permissionOverwrites = [PermissionOverwrite(id: 1, type: 0, allow: "broken", deny: "0")]
        XCTAssertEqual(send(c).state, .unknown)
        c = context()
        c.member = try JSONDecoder().decode(Member.self, from: Data("{\"user_id\":\"5\"}".utf8))
        XCTAssertEqual(send(c).state, .unknown)
        c.member = try JSONDecoder().decode(Member.self, from: JSONEncoder().encode(c.member!))
        XCTAssertEqual(send(c).state, .unknown, "snapshot encoding must not turn unknown roles into known empty roles")
    }

    func testPartialChannelUpdatePreservesPermissionAndThreadFacts() throws {
        let (store, original) = fixture()
        var parent = original
        parent.rateLimitPerUser = 30
        parent.permissionOverwrites = [PermissionOverwrite(id: parent.guildID!, type: 0, allow: "0", deny: String(Permission.sendMessages))]
        store.upsert(channel: parent)
        store.upsert(channel: Channel(id: parent.id, type: parent.type, name: "renamed"))
        let kept = try XCTUnwrap(store.channel(parent.id))
        XCTAssertEqual(kept.rateLimitPerUser, 30)
        XCTAssertEqual(kept.permissionOverwrites, parent.permissionOverwrites)
        XCTAssertFalse(store.canSend(in: kept))
        var thread = Channel(id: 3, type: .privateThread, guildID: parent.guildID, parentID: parent.id)
        thread.ownerID = 5; thread.threadMetadata = ThreadMetadata(archived: false, locked: true)
        store.upsert(channel: thread)
        var patch = Channel(id: 3, type: .privateThread)
        patch.threadMetadata = ThreadMetadata(archived: true)
        store.upsert(channel: patch)
        let merged = try XCTUnwrap(store.channel(3))
        XCTAssertEqual(merged.parentID, thread.parentID); XCTAssertEqual(merged.ownerID, 5)
        XCTAssertEqual(merged.threadMetadata?.locked, true); XCTAssertEqual(merged.threadMetadata?.archived, true)
    }

    func testStoreAdaptersAndPayloadDecisionsUseTheSamePermissions() throws {
        let (store, original) = fixture { ready in
            for index in ready.guilds[0].roles.indices {
                ready.guilds[0].roles[index].permissions = String(Permission.viewChannel | Permission.sendMessages)
            }
        }
        var channel = original; channel.rateLimitPerUser = 0
        store.upsert(channel: channel)
        XCTAssertTrue(store.canSend(in: channel))
        XCTAssertTrue(store.capability(.send(MessagePayloadFeatures()), in: channel).isAllowed)
        XCTAssertEqual(store.capability(.send(MessagePayloadFeatures(fileCount: 1)), in: channel).state, .denied)
        XCTAssertEqual(store.capability(.send(MessagePayloadFeatures(isReply: true)), in: channel).state, .denied)
        channel.rateLimitPerUser = 10
        store.upsert(channel: channel)
        XCTAssertTrue(store.canSend(in: channel), "unknown timing alone keeps drafting available")
        XCTAssertEqual(store.capability(.send(MessagePayloadFeatures()), in: channel).state, .unknown)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(store.capability(.send(MessagePayloadFeatures()), in: channel, now: now,
                                        slowmodeHistory: .lastConfirmedSend(now)).state, .denied)
    }

    func testStorePreservesUnknownVersusConfirmedPrivateMembership() {
        let (store, parent) = fixture()
        var thread = Channel(id: 3, type: .privateThread, guildID: parent.guildID, parentID: parent.id)
        thread.ownerID = 99; thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
        store.upsert(channel: thread)
        XCTAssertEqual(store.capability(.viewChannel, in: thread).state, .unknown)
        store.setThreadMembership(thread.id, joined: true)
        XCTAssertTrue(store.capability(.viewChannel, in: thread).isAllowed)
        store.setThreadMembership(thread.id, joined: false)
        XCTAssertEqual(store.capability(.viewChannel, in: thread).state, .denied)
        XCTAssertTrue(store.capability(.viewChannel, in: thread).reasons.contains(.privateMembershipRequired))
    }

    func testVoiceConnectImplicitMaskAndThreadSendPayloadMask() {
        var c = context(bits: Permission.viewChannel | Permission.sendMessages | (1 << 21) | (1 << 9))
        c.channel.type = .voice
        XCTAssertEqual(CapabilityResolver.permissions(c).permissions! & Permission.voiceScoped, 0)
        c.guild!.roles[0].permissions = String(UInt64(c.guild!.roles[0].permissions)! | Permission.connect)
        XCTAssertNotEqual(CapabilityResolver.permissions(c).permissions! & (1 << 21), 0)
        c = context(bits: Permission.viewChannel | Permission.sendMessages | Permission.attachFiles | Permission.embedLinks)
        c.parent = c.channel; c.channel.id = 3; c.channel.type = .publicThread; c.channel.parentID = 2
        XCTAssertEqual(CapabilityResolver.permissions(c).permissions! & Permission.sendPayload, 0,
                       "parent Send Messages does not replace Send Messages In Threads")
    }

}
