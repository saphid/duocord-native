import XCTest
@testable import DuocordNative

nonisolated private final class PagingWire: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var bodies: [Data] = []
    static var requests: [URLRequest] = []
    static func reset(_ values: [Data]) { lock.withLock { bodies = values; requests = [] } }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { () -> Data? in
            Self.requests.append(request)
            return Self.bodies.isEmpty ? nil : Self.bodies.removeFirst()
        }
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class LookupPagingWireTests: XCTestCase {
    private func client() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "synthetic-offline-only", superProperties: nil, userAgent: "PagingTests"), protocolClasses: [PagingWire.self])
    }
    private func message(_ id: Int) -> Message {
        Message(id: Snowflake(UInt64(id)), channelID: 1, guildID: 10, author: User(id: 900, username: "offline"), content: "fixture", timestamp: "")
    }
    private func query(_ request: URLRequest) -> [String:String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") }, uniquingKeysWith: { a,_ in a })
    }
    func testRESTSearchOwnerUsesRawHitPositionsIncludingEmptyGroups() async throws {
        let firstRows = try JSONSerialization.jsonObject(with: JSONEncoder().encode((1...24).map(message))) as! [[String:Any]]
        let secondRows = try JSONSerialization.jsonObject(with: JSONEncoder().encode((25...49).map(message))) as! [[String:Any]]
        let thirdRows = try JSONSerialization.jsonObject(with: JSONEncoder().encode((50...59).map(message))) as! [[String:Any]]
        let pages: [[String:Any]] = [
            ["total_results":60,"messages":firstRows.map { [$0] } + [[]]],
            ["total_results":60,"messages":secondRows.map { [$0] }],
            ["total_results":60,"messages":thirdRows.map { [$0] }]
        ]
        PagingWire.reset(try pages.map { try JSONSerialization.data(withJSONObject: $0) })
        let api = client(), owner = LookupPagingState<String, Message>()
        await owner.start("captured query", load: { offset in
            .search(try await api.search(guild: 10, channel: 1, query: "captured query", offset: offset))
        }, isCurrent: { true }).value
        await owner.loadMore("captured query")?.value; await owner.loadMore("captured query")?.value
        let requests = PagingWire.captured(); XCTAssertEqual(requests.count,3)
        XCTAssertEqual(requests.map { query($0)["offset"] ?? "0" }, ["0","25","50"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/v9/guilds/10/messages/search" && query($0)["channel_id"] == "1" && query($0)["content"] == "captured query" })
        XCTAssertEqual(owner.snapshot(for: "captured query").rows.count,59)
        XCTAssertEqual(owner.snapshot(for: "captured query").consumed,60); XCTAssertNil(owner.loadMore("captured query"))
    }
    func testRESTForumOwnerHonorsHasMoreAndActualOffsets() async throws {
        let forum = Channel(id: 1, type: .forum, guildID: 10, name: "offline")
        func data(_ range: ClosedRange<Int>, more: Bool) throws -> Data {
            let rows = range.map { Channel(id: Snowflake(UInt64($0)), type: .publicThread, guildID: 10, name: "post", parentID: 1) }
            let object: [String:Any] = ["threads":try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)), "first_messages":[], "has_more":more]
            return try JSONSerialization.data(withJSONObject: object)
        }
        PagingWire.reset([try data(10...34,more: true),try data(35...59,more: true),try data(60...65,more: false)])
        let api = client(), store = DiscordStore(), owner = LookupPagingState<String, Channel>()
        await owner.start("forum", load: { offset in .forum(try await api.forumThreads(channel: 1, offset: offset), forum: forum) },
                          isCurrent: { true }, publish: { store.remember(threads: $0.rows) }).value
        await owner.loadMore("forum")?.value; await owner.loadMore("forum")?.value
        let requests = PagingWire.captured()
        XCTAssertEqual(requests.map { query($0)["offset"] }, ["0","25","50"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/v9/channels/1/threads/search" && query($0)["limit"] == "25" })
        XCTAssertEqual(owner.snapshot(for: "forum").rows.count,56); XCTAssertNotNil(store.channel(65)); XCTAssertNil(owner.loadMore("forum"))
    }
    func testRESTDirectMessageSearchRetainsCapturedScopeAndOffset() async throws {
        PagingWire.reset([Data("{\"total_results\":0,\"messages\":[]}".utf8)])
        _ = try await client().search(guild: nil, channel: 123, query: "offline scope", offset: 50)
        let request = try XCTUnwrap(PagingWire.captured().first)
        XCTAssertEqual(request.url?.path,"/api/v9/channels/123/messages/search")
        XCTAssertEqual(query(request)["offset"],"50"); XCTAssertEqual(query(request)["content"],"offline scope"); XCTAssertNil(query(request)["channel_id"])
    }
}
