import XCTest
@testable import DuocordNative

nonisolated private final class OtherListWire: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var bodies: [Data] = []
    static var requests: [URLRequest] = []
    static func reset(_ values:[Data]) { lock.withLock { bodies = values; requests = [] } }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { () -> Data? in Self.requests.append(request); return Self.bodies.isEmpty ? nil : Self.bodies.removeFirst() }
        guard let data else { client?.urlProtocol(self,didFailWithError:URLError(.resourceUnavailable)); return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class OtherListWireTests: XCTestCase {
    private func client() -> DiscordREST {
        DiscordREST(credentials:SessionCredentials(token:"synthetic-offline-only",superProperties:nil,userAgent:"OtherListTests"),protocolClasses:[OtherListWire.self])
    }
    private func query(_ request:URLRequest) -> [String:String] {
        Dictionary((URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ a,_ in a })
    }
    func testMentionProductionConsumerSerializesBeforeAndRetainsMentionFlags() async throws {
        func message(_ id:Int) -> Message { Message(id:Snowflake(UInt64(id)),channelID:1,guildID:nil,author:User(id:900,username:"offline"),content:"",timestamp:"") }
        OtherListWire.reset([try JSONEncoder().encode((76...100).reversed().map(message)),try JSONEncoder().encode([message(75)])])
        let api = client(), store = DiscordStore(), owner = OtherListState<String,Message,Snowflake>()
        await OtherListConsumers.mentions(owner,input:"inbox",api:api,store:store,isCurrent:{ true }).value
        await owner.loadMore("inbox")?.value
        let requests = OtherListWire.captured(); XCTAssertEqual(requests.count,2)
        XCTAssertEqual(requests.map { query($0)["before"] },[nil,"76"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/v9/users/@me/mentions" && query($0)["limit"] == "25" && query($0)["roles"] == "true" && query($0)["everyone"] == "true" })
        XCTAssertEqual(owner.snapshot(for:"inbox").rows.count,26)
    }
    func testArchiveTransportRetainsHasMoreAndExactTimestampQueryNotMessageID() async throws {
        let cursor = "2026-11-02T11:22:33.123456+00:00"
        OtherListWire.reset([Data("{\"threads\":[],\"has_more\":true}".utf8)])
        let page = try await client().publicArchivedThreads(channel:123,before:cursor)
        XCTAssertTrue(page.hasMore)
        let request = try XCTUnwrap(OtherListWire.captured().first)
        XCTAssertEqual(request.url?.path,"/api/v9/channels/123/threads/archived/public")
        XCTAssertEqual(query(request)["before"],cursor); XCTAssertEqual(query(request)["limit"],"25")
        XCTAssertEqual(request.httpMethod,"GET")
    }
    func testArchiveConsumerUsesRawTimestampWithFractionsAcrossURLProtocolPages() async throws {
        let cursor = "2026-11-02T11:22:33.123456+00:00", older = "2026-11-02T11:22:32.100000+00:00"
        func data(id:Snowflake,stamp:String,more:Bool) throws -> Data {
            var row = Channel(id:id,type:.publicThread,guildID:10,name:"offline",parentID:1)
            row.threadMetadata = ThreadMetadata(archived:true,archiveTimestamp:stamp)
            return try JSONSerialization.data(withJSONObject:["threads":JSONSerialization.jsonObject(with:JSONEncoder().encode([row])),"has_more":more])
        }
        OtherListWire.reset([try data(id:98765,stamp:cursor,more:true),try data(id:23456,stamp:older,more:false)])
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), api = client()
        await OtherListConsumers.archives(owner,input:"threads",api:api,parent:Channel(id:1,type:.text,guildID:10),store:store,isCurrent:{ true }).value
        await owner.loadMore("threads")?.value
        XCTAssertEqual(OtherListWire.captured().map { query($0)["before"] },[nil,cursor])
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[98765,23456]); XCTAssertNotNil(store.channel(23456))
    }
    func testArchiveMissingHasMoreIsRecoverableDecodeFailureRatherThanFalseCompletion() async {
        OtherListWire.reset([Data("{\"threads\":[]}".utf8)])
        do { _ = try await client().publicArchivedThreads(channel:1,before:nil); XCTFail("Missing continuation authority must fail") } catch {}
    }
    func testMockMentionsHonorsBeforeAndNeverRepeatsFirstPage() async throws {
        let api = MockDiscord(), first = try await api.mentions(limit:25,before:nil)
        XCTAssertEqual(first.count,25)
        let cursor = try XCTUnwrap(first.map(\.id).min()), second = try await api.mentions(limit:25,before:cursor)
        XCTAssertFalse(second.isEmpty); XCTAssertTrue(second.allSatisfy { $0.id < cursor })
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with:Set(second.map(\.id))))
    }
    func testMockPublicArchivesHaveMoreThan25AndStableTimestampContinuation() async throws {
        let api = MockDiscord(), channel = MockDiscord.generalChannel
        let first = try await api.publicArchivedThreads(channel:channel,before:nil)
        XCTAssertEqual(first.threads.count,25); XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.threads.last?.threadMetadata?.archiveTimestamp)
        let second = try await api.publicArchivedThreads(channel:channel,before:cursor)
        XCTAssertFalse(second.threads.isEmpty); XCTAssertTrue(second.threads.allSatisfy { $0.parentID == channel && $0.threadMetadata?.archived == true })
        XCTAssertTrue(Set(first.threads.map(\.id)).isDisjoint(with:Set(second.threads.map(\.id))))
    }
}
