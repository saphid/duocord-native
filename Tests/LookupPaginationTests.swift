import XCTest
@testable import DuocordNative

@MainActor
final class LookupPaginationTests: XCTestCase {
    private func message(_ id: Int) -> Message {
        Message(id: Snowflake(UInt64(id)), channelID: 1, guildID: nil,
                author: User(id: Snowflake(UInt64(id + 10000)), username: "offline"), content: "fixture", timestamp: "")
    }
    private func page(_ ids: [Int], total: Int = 60, more: Bool = true) -> LookupPage<Message> {
        LookupPage(rows: ids.map(message), consumed: ids.count, total: total, hasMore: more)
    }
    private final class Held<Value> {
        var response: CheckedContinuation<Value, Error>?
        var arrival: CheckedContinuation<Void, Never>?
        func load() async throws -> Value {
            try await withCheckedThrowingContinuation { response = $0; arrival?.resume(); arrival = nil }
        }
        func started() async {
            if response != nil { return }; await withCheckedContinuation { arrival = $0 }
        }
        func finish(_ result: Result<Value, Error>) { response!.resume(with: result); response = nil }
    }
    func testSearchReachesBeyond50InServerOrderAndTerminatesAtTotal() async {
        let owner = LookupPagingState<String, Message>(); var offsets: [Int] = []
        await owner.start("q", load: { offset in
            offsets.append(offset)
            return self.page(Array((offset + 1)...min(offset + 25, 60)), total: 60)
        }, isCurrent: { true }).value
        await owner.loadMore("q")?.value; await owner.loadMore("q")?.value
        XCTAssertEqual(offsets, [0, 25, 50]); XCTAssertEqual(owner.snapshot(for: "q").rows.map(\.id), (1...60).map { Snowflake(UInt64($0)) })
        XCTAssertEqual(owner.snapshot(for: "q").consumed, 60)
        XCTAssertNil(owner.loadMore("q"))
    }
    func testOverlapConsumesServerPositionsRatherThanUniqueRows() async {
        let owner = LookupPagingState<String, Message>(); var offsets: [Int] = []
        await owner.start("q", load: { offset in
            offsets.append(offset)
            if offset == 0 { return self.page(Array(1...25)) }
            if offset == 25 { return self.page(Array(20...44)) }
            return self.page(Array(45...54), more: false)
        }, isCurrent: { true }).value
        await owner.loadMore("q")?.value; await owner.loadMore("q")?.value
        XCTAssertEqual(offsets, [0, 25, 50]); XCTAssertEqual(owner.snapshot(for: "q").rows.count, 54)
        XCTAssertEqual(Set(owner.snapshot(for: "q").rows.map(\.id)).count, 54)
        XCTAssertEqual(owner.snapshot(for: "q").consumed, 60)
    }
    func testDuplicateTapsCoalesceAndFailedPageRetriesSameOffset() async {
        let owner = LookupPagingState<String, Message>(); let held = Held<LookupPage<Message>>()
        var offsets: [Int] = [], attempt = 0, published: [Int] = []
        await owner.start("q", load: { offset in
            offsets.append(offset); if offset == 0 { return self.page(Array(1...25)) }
            attempt += 1
            if attempt == 1 { return try await held.load() }
            return self.page(Array(26...50), more: false)
        }, isCurrent: { true }, publish: { published.append($0.consumed) }).value
        guard let append = owner.loadMore("q") else { XCTFail("Load More unavailable after first 25"); return }
        await held.started(); XCTAssertNil(owner.loadMore("q")); held.finish(.failure(URLError(.timedOut))); await append.value
        XCTAssertEqual(owner.snapshot(for: "q").rows.count, 25); XCTAssertEqual(owner.snapshot(for: "q").consumed, 25)
        guard case .failed = owner.snapshot(for: "q").more else { XCTFail("Separate append error required"); return }
        await owner.loadMore("q")?.value
        XCTAssertEqual(offsets, [0,25,25]); XCTAssertEqual(published, [25,25]); XCTAssertEqual(owner.snapshot(for: "q").rows.count, 50)
    }
    func testDuplicateOnlyAndEmptyPagesStopWithRecoverableExplanation() async {
        for empty in [false, true] {
            let owner = LookupPagingState<String, Message>(); var offsets: [Int] = []
            await owner.start("q", load: { offset in
                offsets.append(offset); return self.page(offset == 0 ? [1,2] : (empty ? [] : [1,2]))
            }, isCurrent: { true }).value
            await owner.loadMore("q")?.value
            XCTAssertEqual(offsets, [0,2]); XCTAssertEqual(owner.snapshot(for: "q").rows.count, 2)
            guard case .finished(let reason) = owner.snapshot(for: "q").more else { XCTFail("Stop without progress"); continue }
            XCTAssertFalse(reason.isEmpty); XCTAssertNil(owner.loadMore("q"))
            await owner.start("q", load: { _ in self.page([3], total: 1, more: false) }, isCurrent: { true }).value
            XCTAssertEqual(owner.snapshot(for: "q").rows.map(\.id), [3])
        }
    }
    func testHeldAppendCannotPublishAfterLiveIdentityChangesIgnoringCancellation() async {
        for failure in [false,true] {
            let owner = LookupPagingState<String, Message>(); let held = Held<LookupPage<Message>>()
            var live = "q"; let store = DiscordStore()
            await owner.start("q", load: { offset in
                offset == 0 ? self.page([1]) : try await held.load()
            }, isCurrent: { live == "q" }, publish: { store.remember(messageAuthors: $0.rows) }).value
            guard let append = owner.loadMore("q") else { XCTFail("Append required to test live fence"); continue }
            await held.started(); live = "new"
            XCTAssertTrue(owner.snapshot(for: live).rows.isEmpty)
            held.finish(failure ? .failure(URLError(.timedOut)) : .success(page([2]))); await append.value
            XCTAssertNil(store.users[10002]); XCTAssertEqual(owner.snapshot(for: "q").status, .idle)
        }
    }
}
