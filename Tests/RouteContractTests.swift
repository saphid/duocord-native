import XCTest
@testable import DuocordNative

nonisolated private final class RouteWire: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body = "{}"; var headers: [String: String] = [:]; var error: URLError.Code? = nil }
    static let lock = NSLock()
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; requests = [] } }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating:0,count:4096)
            while true {
                let count = stream.read(&bytes,maxLength:bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf:bytes.prefix(count))
            }
            captured.httpBody = data
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.requests.append(captured)
            return Self.replies.isEmpty ? Reply(status: 599, body: "unregistered offline request") : Self.replies.removeFirst()
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(error)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class RouteContractTests: XCTestCase {
    private let c = ChannelID(123), m = MessageID(456), g = GuildID(789), u = UserID(987)
    private func client() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "offline-route-secret", superProperties: nil, userAgent: "RouteTests"), protocolClasses: [RouteWire.self])
    }
    private struct WireCase {
        let methodKey: String
        let endpointKey: String
        let endpoint: DiscordEndpoint
        let method: String
        let path: String
        let run: (any DiscordAPI) async throws -> Void
    }
    /// Independent literal HTTP expectations exercise every protocol entry point,
    /// including overloads and compatibility helpers. Refusals avoid response
    /// fixture decoding hiding a wrong request. Other tests check success bodies.
    private var cases: [WireCase] {
        [
            .init(methodKey: "channel", endpointKey: "channel", endpoint: .channel(c), method: "GET", path: "channels/123", run: { _ = try await $0.channel(123) }),
            .init(methodKey: "guild", endpointKey: "guild", endpoint: .guild(g), method: "GET", path: "guilds/789", run: { _ = try await $0.guild(789) }),
            .init(methodKey: "guildRoles", endpointKey: "guildRoles", endpoint: .guildRoles(g), method: "GET", path: "guilds/789/roles", run: { _ = try await $0.guildRoles(789) }),
            .init(methodKey: "guildMember", endpointKey: "guildMember", endpoint: .guildMember(g,u), method: "GET", path: "guilds/789/members/987", run: { _ = try await $0.guildMember(987,in:789) }),
            .init(methodKey: "ownThreadMember", endpointKey: "ownThreadMember", endpoint: .ownThreadMember(c), method: "GET", path: "channels/123/thread-members/@me", run: { _ = try await $0.ownThreadMember(123,account:987) }),
            .init(methodKey: "messages", endpointKey: "messages", endpoint: .messages(c), method: "GET", path: "channels/123/messages", run: { _ = try await $0.messages(channel:123,before:456,after:nil,around:nil,limit:25) }),
            .init(methodKey: "pins", endpointKey: "pins", endpoint: .pins(c), method: "GET", path: "channels/123/messages/pins", run: { _ = try await $0.pins(channel:123) }),
            .init(methodKey: "pinPage", endpointKey: "pins", endpoint: .pins(c), method: "GET", path: "channels/123/messages/pins", run: { _ = try await $0.pinPage(channel:123,before:"opaque+cursor",limit:50) }),
            .init(methodKey: "search", endpointKey: "guildSearch", endpoint: .guildSearch(g), method: "GET", path: "guilds/789/messages/search", run: { _ = try await $0.search(guild:789,channel:123,query:"secret text",offset:25) }),
            .init(methodKey: "search", endpointKey: "channelSearch", endpoint: .channelSearch(c), method: "GET", path: "channels/123/messages/search", run: { _ = try await $0.search(guild:nil,channel:123,query:"secret text",offset:0) }),
            .init(methodKey: "mentions", endpointKey: "mentions", endpoint: .mentions, method: "GET", path: "users/@me/mentions", run: { _ = try await $0.mentions(limit:25,before:456) }),
            .init(methodKey: "forumThreads", endpointKey: "forumThreads", endpoint: .forumThreads(c), method: "GET", path: "channels/123/threads/search", run: { _ = try await $0.forumThreads(channel:123,offset:25) }),
            .init(methodKey: "archivedThreads", endpointKey: "publicArchives", endpoint: .publicArchives(c), method: "GET", path: "channels/123/threads/archived/public", run: { _ = try await $0.archivedThreads(channel:123) }),
            .init(methodKey: "publicArchivedThreads", endpointKey: "publicArchives", endpoint: .publicArchives(c), method: "GET", path: "channels/123/threads/archived/public", run: { _ = try await $0.publicArchivedThreads(channel:123,before:"opaque+cursor") }),
            .init(methodKey: "send#1", endpointKey: "send", endpoint: .send(c), method: "POST", path: "channels/123/messages", run: { _ = try await $0.send(channel:123,content:"private text",replyTo:456,pingReply:false,attachments:[],nonce:"nonce") }),
            .init(methodKey: "send#2", endpointKey: "send", endpoint: .send(c), method: "POST", path: "channels/123/messages", run: { _ = try await $0.send(channel:123,content:"private text",replyTo:nil,pingReply:false,attachments:[],nonce:"nonce",attempt:SendAttempt()) }),
            .init(methodKey: "edit", endpointKey: "edit", endpoint: .edit(c,m), method: "PATCH", path: "channels/123/messages/456", run: { _ = try await $0.edit(channel:123,message:456,content:"private edit") }),
            .init(methodKey: "delete", endpointKey: "delete", endpoint: .delete(c,m), method: "DELETE", path: "channels/123/messages/456", run: { try await $0.delete(channel:123,message:456) }),
            .init(methodKey: "setPinned", endpointKey: "pin", endpoint: .pin(c,m,pinned:true), method: "PUT", path: "channels/123/messages/pins/456", run: { try await $0.setPinned(channel:123,message:456,pinned:true) }),
            .init(methodKey: "setPinned", endpointKey: "pin", endpoint: .pin(c,m,pinned:false), method: "DELETE", path: "channels/123/messages/pins/456", run: { try await $0.setPinned(channel:123,message:456,pinned:false) }),
            .init(methodKey: "ack", endpointKey: "ack", endpoint: .ack(c,m), method: "POST", path: "channels/123/messages/456/ack", run: { try await $0.ack(channel:123,message:456) }),
            .init(methodKey: "acknowledge", endpointKey: "ack", endpoint: .ack(c,m), method: "POST", path: "channels/123/messages/456/ack", run: { try await $0.acknowledge(ReadAcknowledgement(channel:123,message:456,manual:true,mentionCount:0)) }),
            .init(methodKey: "acknowledgeBulk", endpointKey: "ackBulk", endpoint: .ackBulk, method: "POST", path: "read-states/ack-bulk", run: { try await $0.acknowledgeBulk([ReadAcknowledgement(channel:123,message:456)]) }),
            .init(methodKey: "acknowledgeGuild", endpointKey: "guildAck", endpoint: .guildAck(g), method: "POST", path: "guilds/789/ack", run: { try await $0.acknowledgeGuild(789) }),
            .init(methodKey: "typing", endpointKey: "typing", endpoint: .typing(c), method: "POST", path: "channels/123/typing", run: { try await $0.typing(channel:123) }),
            .init(methodKey: "react", endpointKey: "reaction", endpoint: .reaction(c,m,emoji:"a/b:987",add:true), method: "PUT", path: "channels/123/messages/456/reactions/a%2Fb%3A987/@me", run: { try await $0.react(channel:123,message:456,emoji:Emoji(id:987,name:"a/b"),add:true) }),
            .init(methodKey: "react", endpointKey: "reaction", endpoint: .reaction(c,m,emoji:"a/b:987",add:false), method: "DELETE", path: "channels/123/messages/456/reactions/a%2Fb%3A987/@me", run: { try await $0.react(channel:123,message:456,emoji:Emoji(id:987,name:"a/b"),add:false) }),
            .init(methodKey: "reactions", endpointKey: "reactions", endpoint: .reactions(c,m,emoji:"👍"), method: "GET", path: "channels/123/messages/456/reactions/%F0%9F%91%8D", run: { _ = try await $0.reactions(channel:123,message:456,emoji:Emoji(name:"👍"),limit:25) }),
            .init(methodKey: "patchNotificationSettings", endpointKey: "notificationSettings", endpoint: .notificationSettings(g), method: "PATCH", path: "users/@me/guilds/789/settings", run: { _ = try await $0.patchNotificationSettings(target:.channel(guild:789,channel:123),patch:NotificationPatch(level:.mentions)) }),
            .init(methodKey: "patchNotificationSettings", endpointKey: "notificationSettings", endpoint: .notificationSettings(nil), method: "PATCH", path: "users/@me/guilds/@me/settings", run: { _ = try await $0.patchNotificationSettings(target:.channel(guild:nil,channel:123),patch:NotificationPatch(muted:true)) }),
            .init(methodKey: "relationship", endpointKey: "relationship", endpoint: .relationship(u,removing:false), method: "PUT", path: "users/@me/relationships/987", run: { try await $0.relationship(user:987,action:.block) }),
            .init(methodKey: "requestFriend", endpointKey: "requestFriend", endpoint: .requestFriend, method: "POST", path: "users/@me/relationships", run: { try await $0.requestFriend(username:FriendUsername("offline.user")!) }),
            .init(methodKey: "createDM", endpointKey: "createDM", endpoint: .createDM, method: "POST", path: "users/@me/channels", run: { _ = try await $0.createDM(recipient:987) }),
            .init(methodKey: "leaveGuild", endpointKey: "leaveGuild", endpoint: .leaveGuild(g), method: "DELETE", path: "users/@me/guilds/789", run: { try await $0.leaveGuild(789, admission: { true }) }),
            .init(methodKey: "saveGuildFolders", endpointKey: "saveSettingsProto", endpoint: .saveSettingsProto, method: "PATCH", path: "users/@me/settings-proto/1", run: { api in
                let settings = try GuildFolderSettings(base64: MockDiscord.versionedServerSettings(guilds: MockDiscord().guilds.map(\.id)))
                let order = try GuildOrganization(folders: settings.folders, membershipOrder: settings.folders.flatMap(\.guildIDs))
                _ = try await api.saveGuildFolders(settings.patch(for: order), admission: { true })
            }),
            .init(methodKey: "settingsProto", endpointKey: "settingsProto", endpoint: .settingsProto, method: "GET", path: "users/@me/settings-proto/1", run: { _ = try await $0.settingsProto() }),
            .init(methodKey: "modifyThread", endpointKey: "modifyThread", endpoint: .modifyThread(c), method: "PATCH", path: "channels/123", run: { _ = try await $0.modifyThread(123,patch:ThreadPatch(archived:true)) }),
            .init(methodKey: "deleteThread", endpointKey: "deleteThread", endpoint: .deleteThread(c), method: "DELETE", path: "channels/123", run: { try await $0.deleteThread(123) }),
            .init(methodKey: "joinThread", endpointKey: "joinThread", endpoint: .joinThread(c), method: "PUT", path: "channels/123/thread-members/@me", run: { try await $0.joinThread(123) }),
            .init(methodKey: "leaveThread", endpointKey: "leaveThread", endpoint: .leaveThread(c), method: "DELETE", path: "channels/123/thread-members/@me", run: { try await $0.leaveThread(123) }),
            .init(methodKey: "modifyThreadSettings", endpointKey: "threadSettings", endpoint: .threadSettings(c), method: "PATCH", path: "channels/123/thread-members/@me/settings", run: { _ = try await $0.modifyThreadSettings(123,fields:["muted":.bool(true)]) }),
            .init(methodKey: "send#2", endpointKey: "attachments", endpoint: .attachments(c), method: "POST", path: "channels/123/attachments", run: { _ = try await $0.send(channel:123,content:"",replyTo:nil,pingReply:false,attachments:[OutgoingAttachment(filename:"private.bin",data:Data([1]),contentType:"application/octet-stream")],nonce:"n",attempt:SendAttempt()) })
        ]
    }
    func testEveryProtocolMethodUsesActualRegisteredWireRouteAndSafeDiagnostic() async throws {
        for item in cases {
            RouteWire.reset([.init(status:403,body:"{\"code\":50013,\"message\":\"secret server body\"}")])
            let rest = client()
            do { try await item.run(rest); XCTFail("Expected offline refusal: \(item.methodKey)") } catch {}
            let request = try XCTUnwrap(RouteWire.captured().first, item.methodKey)
            XCTAssertEqual(RouteWire.captured().count,1,item.methodKey)
            XCTAssertEqual(request.httpMethod,item.method,item.methodKey)
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.percentEncodedPath,"/api/v9/" + item.path,item.methodKey)
            let route = item.endpoint.descriptor
            XCTAssertEqual(route.path,item.path,item.methodKey)
            XCTAssertEqual(route.method,item.method,item.methodKey)
            let diagnostic = await rest.lastRequestDiagnostic
            XCTAssertEqual(diagnostic,DiscordRequestDiagnostic(endpoint:item.endpoint,status:403,code:50013,outcome:item.method == "GET" ? .readFailed : .refused),item.methodKey)
            let safe = String(describing:diagnostic)
            for forbidden in ["offline-route-secret","secret server body","private text","private.bin","123","456","789","987","a/b","👍","https:"] {
                XCTAssertFalse(safe.contains(forbidden),"\(item.methodKey): \(forbidden)")
            }
        }
    }

    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ path: String) throws -> String { try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8) }
    func testRegistryAndLedgerCannotSilentlyOmitProtocolMethodsOrEndpointCases() throws {
        let rest = try source("Discord/REST.swift")
        let protocolSource = try XCTUnwrap(rest.components(separatedBy:"protocol DiscordAPI: Sendable {").last?.components(separatedBy:"\n}\n").first)
        let names = protocolSource.split(separator:"\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in:.whitespaces)
            guard text.hasPrefix("func ") else { return nil }
            return String(text.dropFirst(5).prefix { $0 != "(" })
        }
        let totals = Dictionary(grouping:names,by:{ $0 }).mapValues(\.count)
        var seen: [String:Int] = [:]
        let keys = names.map { name in seen[name,default:0] += 1; return totals[name] == 1 ? name : "\(name)#\(seen[name]!)" }
        XCTAssertEqual(Set(keys),Set(cases.map(\.methodKey)))
        let routes = try source("Discord/Routes.swift").components(separatedBy:"    var descriptor:")[0]
        var endpoints: Set<String> = []
        for line in routes.split(separator:"\n") where line.trimmingCharacters(in:.whitespaces).hasPrefix("case ") {
            var depth = 0, word = ""
            for character in line.trimmingCharacters(in:.whitespaces).dropFirst(5) + "," {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if character == "," && depth == 0 {
                    endpoints.insert(String(word.trimmingCharacters(in:.whitespaces).prefix { $0 != "(" }))
                    word = ""
                } else { word.append(character) }
            }
        }
        // legacyPins is exercised by the explicit fallback test below.
        XCTAssertEqual(endpoints,Set(cases.map(\.endpointKey)).union(["legacyPins"]))
        let ledger = try JSONDecoder().decode(RouteLedger.self,from:Data(source("docs/discord-api-routes.json").utf8))
        XCTAssertEqual(Set(ledger.protocolMethods),Set(keys))
        XCTAssertEqual(Set(ledger.endpoints),endpoints)
        // Prevent a new handwritten network route bypassing this closed registry.
        XCTAssertFalse(rest.contains("raw(\"")); XCTAssertFalse(rest.contains("get(\"")); XCTAssertFalse(rest.contains("request(\""))
    }
    private struct RouteLedger: Decodable { let protocolMethods: [String]; let endpoints: [String] }

    func testMigratedOperationContractsMatchLiteralRoutesAndProductionRequests() async throws {
        var operations: [(DiscordOperation,String,String)] = [
            (.viewChannel,"GET","/channels/{channel}"), (.send(.init()),"POST","/channels/{channel}/messages"),
            (.editMessage,"PATCH","/channels/{channel}/messages/{message}"), (.deleteMessage,"DELETE","/channels/{channel}/messages/{message}"),
            (.addReaction,"PUT","/channels/{channel}/messages/{message}/reactions/{emoji}/@me"), (.addExistingReaction,"PUT","/channels/{channel}/messages/{message}/reactions/{emoji}/@me"),
            (.removeOwnReaction,"DELETE","/channels/{channel}/messages/{message}/reactions/{emoji}/@me"), (.listPins,"GET","/channels/{channel}/messages/pins"),
            (.pinMessage,"PUT","/channels/{channel}/messages/pins/{message}"), (.unpinMessage,"DELETE","/channels/{channel}/messages/pins/{message}")
        ]
        let threadActions: [ThreadAction] = [.join,.leave,.rename("secret name"),.close,.reopen,.lock,.unlock,.delete]
        for action in threadActions {
            let method: String
            switch action {
            case .join: method = "PUT"
            case .leave, .delete: method = "DELETE"
            default: method = "PATCH"
            }
            let template = action == .join || action == .leave ? "/channels/{channel}/thread-members/@me" : "/channels/{channel}"
            operations.append((.thread(action),method,template))
        }
        for (operation,method,template) in operations {
            let endpoint = operation.endpoint(channel:c,message:m,emoji:"a/b:987")
            XCTAssertEqual(operation.method,method); XCTAssertEqual(operation.routeTemplate,template)
            XCTAssertEqual(endpoint.descriptor.method,method); XCTAssertEqual(endpoint.descriptor.template,template)
            let fixture = try XCTUnwrap(cases.first { $0.endpoint.descriptor.path == endpoint.descriptor.path && $0.method == method })
            RouteWire.reset([.init(status:403)])
            do { try await fixture.run(client()) } catch {}
            XCTAssertEqual(RouteWire.captured().first?.httpMethod,method)
            XCTAssertEqual(URLComponents(url:RouteWire.captured().first!.url!,resolvingAgainstBaseURL:false)?.percentEncodedPath,"/api/v9/" + endpoint.descriptor.path)
        }
    }

    func testLegacyPinsFallbackHasOwnDescriptorAndOnlyUnknownRouteFallsBack() async throws {
        RouteWire.reset([.init(status:404,body:"{\"code\":0,\"message\":\"404: Not Found\"}"),.init(body:"[]")])
        let rest = client()
        let page = try await rest.pinPage(channel:123,before:nil,limit:50)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(RouteWire.captured().map { $0.url!.path },["/api/v9/channels/123/messages/pins","/api/v9/channels/123/pins"])
        let diagnostic = await rest.lastRequestDiagnostic
        XCTAssertEqual(diagnostic?.template,"/channels/{channel}/pins")
        XCTAssertEqual(DiscordEndpoint.legacyPins(c).descriptor.bucketIdentity,DiscordEndpoint.pins(c).descriptor.bucketIdentity)
        for (before,code) in [(Optional("cursor"),0),(nil,10003)] {
            RouteWire.reset([.init(status:404,body:"{\"code\":\(code),\"message\":\"404: Not Found\"}")])
            do { _ = try await client().pinPage(channel:123,before:before,limit:50); XCTFail("Must surface 404") } catch {}
            XCTAssertEqual(RouteWire.captured().count,1)
        }
    }
    func testOpaquePinCursorAndReactionEncodingRemainExact() async throws {
        let cursor = "2026-11-02T11:22:33.123456+00:00/&?%"
        RouteWire.reset([.init(body:"{\"items\":[],\"has_more\":false}")])
        _ = try await client().pinPage(channel:123,before:cursor,limit:50)
        let components = try XCTUnwrap(URLComponents(url:RouteWire.captured()[0].url!,resolvingAgainstBaseURL:false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "before" }?.value,cursor)
        XCTAssertTrue(components.percentEncodedQuery!.contains("%2B"))
        let key = "token/secret?x=123%2F#👍:987+ !~*'()"
        let descriptor = DiscordEndpoint.reaction(c,m,emoji:key,add:true).descriptor
        XCTAssertEqual(descriptor.path,"channels/123/messages/456/reactions/token%2Fsecret%3Fx%3D123%252F%23%F0%9F%91%8D%3A987%2B%20!~*'()/@me")
        XCTAssertEqual(descriptor.template,"/channels/{channel}/messages/{message}/reactions/{emoji}/@me")
        let safe = String(describing:DiscordRequestDiagnostic(endpoint:.reaction(c,m,emoji:key,add:true),outcome:.unknown))
        for secret in ["token","secret","123","456","987","👍","%2F"] { XCTAssertFalse(safe.contains(secret)) }
    }
    func testAllRelationshipActionsUseDeclaredDynamicMethodAndBody() async throws {
        for action in RelationshipAction.allCases {
            RouteWire.reset([.init(status:204,body:"")])
            try await client().relationship(user:987,action:action)
            let request = RouteWire.captured()[0]
            let removing = [RelationshipAction.decline,.cancel,.remove,.unblock].contains(action)
            XCTAssertEqual(request.httpMethod,removing ? "DELETE" : "PUT")
            XCTAssertEqual(request.url?.path,"/api/v9/users/@me/relationships/987")
            if removing { XCTAssertNil(request.httpBody) }
            else {
                let fields = try JSONDecoder().decode([String:JSONValue].self,from:XCTUnwrap(request.httpBody))
                XCTAssertEqual(fields,["type":.number(action == .block ? 2 : action == .accept ? 1 : -1)])
            }
        }
    }
    func testDecodeFailureAndUnknownCodePreserveErrorButOnlySafeMetadata() async throws {
        let rest = client()
        RouteWire.reset([.init(body:"{\"sensitive-key\":\"signed-url-and-token\"}")])
        do { _ = try await rest.reactions(channel:123,message:456,emoji:Emoji(name:"token/path"),limit:25); XCTFail("Expected decode error") }
        catch DiscordError.decoding(let detail) { XCTAssertEqual(detail,"/channels/{channel}/messages/{message}/reactions/{emoji}") }
        RouteWire.reset([.init(status:403,body:"{\"code\":987654,\"message\":\"private response text\"}")])
        do { try await rest.react(channel:123,message:456,emoji:Emoji(name:"token/path"),add:true); XCTFail("Expected refusal") }
        catch DiscordError.api(let status,let code,let message) { XCTAssertEqual(status,403); XCTAssertEqual(code,987654); XCTAssertEqual(message,"private response text") }
        let diagnostic = await rest.lastRequestDiagnostic
        XCTAssertEqual(diagnostic?.code,987654); XCTAssertEqual(diagnostic?.outcome,.refused)
        XCTAssertFalse(String(describing:diagnostic).contains("private response text"))
    }
    func testOperationDiagnosticRetainsAttributionWithoutOriginalPayloadOrErrorText() {
        let operation = DiscordOperation.addReaction
        let refusal = OperationRefusal(original:.api(status:403,code:50013,message:"private original"),
            context:OperationContext(operation:operation,channel:123,message:456,text:"private body",emoji:Emoji(name:"private token/👍")),
            freshness:.refreshed,decision:.denied(.missingPermissions(Permission.addReactions),.refreshedFacts))
        XCTAssertEqual(refusal.diagnostic.request.method,"PUT")
        XCTAssertEqual(refusal.diagnostic.request.code,50013)
        XCTAssertEqual(refusal.diagnostic.attribution,[.refreshedFacts])
        XCTAssertEqual(refusal.diagnostic.freshness,.refreshed)
        XCTAssertEqual(refusal.original.apiCode,50013)
        for secret in ["private","token","123","456","👍"] { XCTAssertFalse(String(describing:refusal.diagnostic).contains(secret)) }
        let unknown = OperationRefusal(original:.http(500,"private"),context:refusal.context,freshness:.unnecessary,decision:nil)
        XCTAssertEqual(unknown.diagnostic.request.outcome,.unknown)
    }
    func testSharedBucketStillQueuesDifferentEndpointsForSameMajorOnly() async throws {
        RouteWire.reset([
            .init(body:"[]",headers:["X-RateLimit-Bucket":"shared","X-RateLimit-Remaining":"1","X-RateLimit-Reset":"1"]),
            .init(body:"{}",headers:["X-RateLimit-Bucket":"shared","X-RateLimit-Remaining":"0","X-RateLimit-Reset":"1","X-RateLimit-Reset-After":"0.2"]),
            .init(body:"[]"),.init(body:"[]")
        ])
        let rest = client()
        _ = try await rest.messages(channel:123,before:nil,after:nil,around:nil,limit:25)
        try await rest.typing(channel:123)
        let clock = ContinuousClock(), start = clock.now
        _ = try await rest.messages(channel:124,before:nil,after:nil,around:nil,limit:25)
        XCTAssertLessThan(start.duration(to:clock.now),.milliseconds(180))
        _ = try await rest.messages(channel:123,before:nil,after:nil,around:nil,limit:25)
        XCTAssertGreaterThanOrEqual(start.duration(to:clock.now),.milliseconds(180))
        XCTAssertEqual(RouteWire.captured().count,4)
    }
    func testReservationSignedTransferAndFinalPostKeepSeparateContracts() async throws {
        let message = Message(id:456,channelID:123,guildID:nil,author:User(id:987,username:"offline"),content:"private",timestamp:"")
        let body = String(decoding:try JSONEncoder().encode(message),as:UTF8.self)
        RouteWire.reset([
            .init(body:"{\"attachments\":[{\"id\":\"0\",\"upload_url\":\"https://storage.example/signed/private?token=secret\",\"upload_filename\":\"opaque/private.bin\"}]}"),
            .init(status:200,body:""), .init(body:body)
        ])
        let rest = client()
        _ = try await rest.send(channel:123,content:"private",replyTo:nil,pingReply:false,
            attachments:[OutgoingAttachment(filename:"private.bin",data:Data([0,1,2]),contentType:"application/octet-stream")],nonce:"private-nonce")
        let requests = RouteWire.captured()
        XCTAssertEqual(requests.map(\.httpMethod),["POST","PUT","POST"])
        XCTAssertEqual(requests[0].url?.path,"/api/v9/channels/123/attachments")
        XCTAssertEqual(requests[1].url?.host,"storage.example")
        for header in ["Authorization","X-Super-Properties","X-Discord-Locale","Cookie"] { XCTAssertNil(requests[1].value(forHTTPHeaderField:header)) }
        XCTAssertEqual(requests[2].url?.path,"/api/v9/channels/123/messages")
        let fields = try JSONDecoder().decode([String:JSONValue].self,from:XCTUnwrap(requests[2].httpBody))
        XCTAssertEqual(fields["attachments"],.array([.object(["id":.string("0"),"filename":.string("private.bin"),"uploaded_filename":.string("opaque/private.bin")])]))
        let diagnostic = await rest.lastRequestDiagnostic
        XCTAssertEqual(diagnostic?.template,"/channels/{channel}/messages")
        for secret in ["storage.example","signed","secret","private","nonce","123","456"] { XCTAssertFalse(String(describing:diagnostic).contains(secret)) }
    }

    func testTransportDiagnosticSeparatesProvenNonDispatchFromUnknownAndReadFailure() async throws {
        let rest = client()
        for (error,expected) in [(URLError.Code.notConnectedToInternet,DiscordRequestDiagnostic.Outcome.notDispatched),(.timedOut,.unknown),(.networkConnectionLost,.unknown)] {
            RouteWire.reset([.init(error:error)])
            do { try await rest.delete(channel:123,message:456); XCTFail("Expected transport error") } catch {}
            let diagnostic = await rest.lastRequestDiagnostic
            XCTAssertEqual(diagnostic?.outcome,expected)
            XCTAssertEqual(diagnostic?.source,.transport)
            XCTAssertNil(diagnostic?.status); XCTAssertNil(diagnostic?.code)
            XCTAssertEqual(diagnostic?.template,"/channels/{channel}/messages/{message}")
            XCTAssertEqual(RouteWire.captured().count,1)
        }
        RouteWire.reset([.init(error:.timedOut)])
        do { _ = try await rest.channel(123); XCTFail("Expected read failure") } catch {}
        let diagnostic = await rest.lastRequestDiagnostic
        XCTAssertEqual(diagnostic?.outcome,.readFailed)
        XCTAssertEqual(diagnostic?.source,.transport)
    }

    func testHTTPAndTimelineLogSitesExcludeRawErrorsAndPaths() throws {
        let timeline = try source("Discord/MessageCenter.swift")
        let sites = timeline.split(separator:"\n").filter { $0.contains(".error(") }
        XCTAssertEqual(sites.count,7)
        XCTAssertTrue(sites.allSatisfy { !$0.contains("localizedDescription") && !$0.contains("String(describing:") && !$0.contains("privacy:") })
        let rest = try source("Discord/REST.swift")
        let logs = rest.split(separator:"\n").filter { $0.contains("log.error(") || $0.contains("log.notice(") }
        XCTAssertFalse(logs.isEmpty)
        for line in logs {
            for unsafe in ["localizedDescription","String(describing:","\\(path,","\\(route,","\\(request", "\\(error"] { XCTAssertFalse(line.contains(unsafe)) }
        }
    }

}
