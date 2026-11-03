import XCTest
@testable import DuocordNative

@MainActor
final class LookupPagingBoundaryTests: XCTestCase {
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
    private func message(_ id: Int, channel: Snowflake = 1, author: Snowflake = 900) -> Message {
        Message(id: Snowflake(UInt64(id)), channelID: channel, guildID: 10,
                author: User(id: author, username: "offline"), content: "offline", timestamp: "")
    }
    private let forum = Channel(id: 1, type: .forum, guildID: 10, name: "offline")
    private func thread(_ id: Int, parent: Snowflake = 1) -> Channel {
        Channel(id: Snowflake(UInt64(id)), type: .publicThread, guildID: 10, name: "post", parentID: parent)
    }
    private func threads(_ ids: [Int], more: Bool = true) -> LookupPage<Channel> {
        .forum(ThreadSearchResult(threads: ids.map { thread($0) }, firstMessages: ids.map { message($0, channel: Snowflake(UInt64($0))) }, hasMore: more), forum: forum)
    }
    private func searchIdentity(_ model: AppModel, _ store: DiscordStore, query: String = "q", scoped: Bool = false,
                                presentation: UUID, sidebar: Bool = false) -> SearchPageIdentity {
        SearchPageIdentity(submission: SearchSubmission(context: LookupContext(model: model, store: store), query: query,
                            guild: 10, channel: scoped ? model.selectedChannel : nil, scopeName: scoped ? "#offline" : "offline"),
                           presentation: presentation, sidebar: sidebar, navigation: model.navigationIntent)
    }
    private func searchBoundary(_ change: String, failure: Bool) async {
        let model = AppModel(), store = DiscordStore(); model.selectedGuild = 10; model.selectedChannel = 1
        let owner = LookupPagingState<SearchPageIdentity, Message>(), held = Held<LookupPage<Message>>()
        var presentation = UUID(), query = "q", scoped = false, sidebar = false, open = true
        func identity() -> SearchPageIdentity? {
            open ? searchIdentity(model, store, query: query, scoped: scoped, presentation: presentation, sidebar: sidebar) : nil
        }
        let a = identity()!
        await owner.start(a, load: { offset in
            offset == 0 ? LookupPage(rows: [self.message(1)], consumed: 25, total: 60, hasMore: true) : try await held.load()
        }, isCurrent: { identity() == a }, publish: { store.remember(messageAuthors: $0.rows) }).value
        let request = owner.loadMore(a)!
        await held.started()
        switch change {
        case "query": query = "other"
        case "scope": scoped = true
        case "channel": model.selectedChannel = 2
        case "guild": model.selectedGuild = 20
        case "session": store.reset()
        case "account":
            var ready = MockDiscord().readyPayload(); ready.user = User(id: 77, username: "other"); store.apply(ready: ready)
        case "presentation": sidebar = true
        case "close": open = false
        case "reopen": presentation = UUID()
        default: model.sheet = .search; model.sheet = nil; model.sheet = .search
        }
        // No cancellation/invalidation/change callback; projection must already hide A.
        XCTAssertTrue(owner.snapshot(for: identity()).rows.isEmpty, change)
        held.finish(failure ? .failure(URLError(.timedOut)) : .success(LookupPage(rows: [message(2, author: 901)], consumed: 25, total: 60, hasMore: true)))
        await request.value
        XCTAssertEqual(owner.snapshot(for: a).status, .idle, change); XCTAssertNil(store.users[901], change)
    }
    func testSearchTypedLiveAppendSuccessBoundaries() async {
        for c in ["query","scope","channel","guild","session","account","presentation","close","reopen","route"] { await searchBoundary(c, failure: false) }
    }
    func testSearchTypedLiveAppendErrorBoundaries() async {
        for c in ["query","scope","channel","guild","session","account","presentation","close","reopen","route"] { await searchBoundary(c, failure: true) }
    }
    private func forumBoundary(_ change: String, initial: Bool, failure: Bool) async {
        let model = AppModel(), store = DiscordStore(); model.selectedGuild = 10; model.selectedChannel = 1
        let owner = LookupPagingState<ForumSubmission, Channel>(), held = Held<LookupPage<Channel>>()
        var target: Snowflake = 1, presentation = UUID(), open = true
        func identity() -> ForumSubmission? {
            open ? ForumSubmission(context: LookupContext(model: model, store: store), forum: target,
                                   presentation: presentation, navigation: model.navigationIntent) : nil
        }
        let a = identity()!
        let first = owner.start(a, load: { offset in
            initial || offset > 0 ? try await held.load() : self.threads([10])
        }, isCurrent: { identity() == a }, publish: { store.remember(threads: $0.rows) })
        let request: Task<Void, Never>
        if initial { request = first }
        else { await first.value; request = owner.loadMore(a)! }
        await held.started()
        switch change {
        case "forum": target = 2
        case "channel": model.selectedChannel = 2
        case "session": store.reset()
        case "account":
            var ready = MockDiscord().readyPayload(); ready.user = User(id: 77, username: "other"); store.apply(ready: ready)
        case "visit": model.selectedChannel = 2; model.selectedChannel = 1
        case "close": open = false
        default: presentation = UUID()
        }
        XCTAssertTrue(owner.snapshot(for: identity()).rows.isEmpty, change)
        held.finish(failure ? .failure(URLError(.timedOut)) : .success(threads([20])))
        await request.value
        XCTAssertNil(store.channel(20), change); XCTAssertEqual(owner.snapshot(for: a).status, .idle, change)
    }
    func testForumInitialSuccessCannotWriteCacheAfterIdentityReplacement() async {
        for c in ["forum","channel","session","account","visit","close","reopen"] { await forumBoundary(c, initial: true, failure: false) }
    }
    func testForumInitialErrorCannotPublishAfterIdentityReplacement() async {
        for c in ["forum","channel","session","account","visit","close","reopen"] { await forumBoundary(c, initial: true, failure: true) }
    }
    func testForumAppendSuccessCannotWriteCacheAfterIdentityReplacement() async {
        for c in ["forum","channel","session","account","visit","close","reopen"] { await forumBoundary(c, initial: false, failure: false) }
    }
    func testForumAppendErrorCannotPublishAfterIdentityReplacement() async {
        for c in ["forum","channel","session","account","visit","close","reopen"] { await forumBoundary(c, initial: false, failure: true) }
    }
    func testForumHasMoreOffsetsAndFirstMessagesAcrossMoreThan50Posts() async {
        let owner = LookupPagingState<String, Channel>(), store = DiscordStore(); var offsets: [Int] = []
        await owner.start("forum", load: { offset in
            offsets.append(offset); return self.threads(Array((offset + 1)...min(offset + 25, 63)), more: offset < 50)
        }, isCurrent: { true }, publish: { store.remember(threads: $0.rows) }).value
        await owner.loadMore("forum")?.value; await owner.loadMore("forum")?.value
        let snapshot = owner.snapshot(for: "forum")
        XCTAssertEqual(offsets, [0,25,50]); XCTAssertEqual(snapshot.rows.map(\.id), (1...63).map { Snowflake(UInt64($0)) })
        XCTAssertEqual(snapshot.firstMessages.count, 63); XCTAssertEqual(snapshot.consumed, 63)
        XCTAssertNotNil(store.channel(63)); XCTAssertNil(owner.loadMore("forum"))
    }
    func testForumAssociationValidationRetainsKnownConcealmentAndOwnerFallback() async {
        let owner = LookupPagingState<String, Channel>(), store = DiscordStore()
        var blocked = thread(10); blocked.ownerID = 900
        store.applyRelationship(Relationship(id: 900, type: 2, user: User(id: 900, username: "blocked")))
        let first = message(10, channel: 10)
        let foreign = message(999, channel: 10, author: 901)
        let wrongAuthor = message(10, channel: 10, author: 901)
        let invalid = LookupPage<Channel>.forum(ThreadSearchResult(threads: [blocked, thread(30,parent: 2)],
                                        firstMessages: [foreign,wrongAuthor,message(30,channel: 30)], hasMore: false), forum: forum)
        XCTAssertEqual(invalid.rows.map(\.id), [10]); XCTAssertTrue(invalid.firstMessages.isEmpty)
        let fallback = ForumView(channel: forum).postPresentation(blocked, firstMessage: invalid.firstMessages[10], store: store)
        XCTAssertEqual(fallback.title, "Blocked post"); XCTAssertNotNil(fallback.revealScope)
        await owner.start("forum", load: { offset in
            .forum(ThreadSearchResult(threads: [blocked], firstMessages: offset == 0 ? [first] : [foreign,wrongAuthor], hasMore: offset == 0), forum: self.forum)
        }, isCurrent: { true }).value
        await owner.loadMore("forum")?.value
        XCTAssertEqual(owner.snapshot(for: "forum").firstMessages[10]?.author.id, 900)
        XCTAssertEqual(owner.snapshot(for: "forum").firstMessages[10]?.id, 10)
        let content = ForumView(channel: forum).postPresentation(blocked, firstMessage: owner.snapshot(for: "forum").firstMessages[10], store: store)
        XCTAssertEqual(content.title, "Blocked post")
        let oldScope = ExcerptRevealScope(message: first, store: store)
        store.reset()
        XCTAssertNotEqual(oldScope, ExcerptRevealScope(message: first, store: store))
    }
    func testForumOverlapAndDuplicateTapsFailureRetryPreserveRowsAndAssociations() async {
        let owner = LookupPagingState<String, Channel>(), held = Held<LookupPage<Channel>>()
        var offsets: [Int] = [], attempt = 0, publications: [[Snowflake]] = []
        await owner.start("f", load: { offset in
            offsets.append(offset)
            if offset == 0 { return self.threads(Array(1...25)) }
            attempt += 1
            if attempt == 1 { return try await held.load() }
            return self.threads(Array(20...44), more: false)
        }, isCurrent: { true }, publish: { publications.append($0.rows.map(\.id)) }).value
        let request = owner.loadMore("f")!; await held.started(); XCTAssertNil(owner.loadMore("f"))
        held.finish(.failure(URLError(.timedOut))); await request.value
        XCTAssertEqual(owner.snapshot(for: "f").rows.count, 25); XCTAssertEqual(owner.snapshot(for: "f").firstMessages.count, 25)
        guard case .failed = owner.snapshot(for: "f").more else { XCTFail("Append failure is separate"); return }
        await owner.loadMore("f")?.value
        XCTAssertEqual(offsets,[0,25,25]); XCTAssertEqual(owner.snapshot(for: "f").consumed, 50)
        XCTAssertEqual(owner.snapshot(for: "f").rows.count, 44); XCTAssertEqual(owner.snapshot(for: "f").firstMessages.count, 44)
        XCTAssertEqual(publications.map(\.count), [25,19])
    }
    func testForumEmptyAndDuplicateOnlyPagesWithHasMoreStop() async {
        for empty in [false,true] {
            let owner = LookupPagingState<String, Channel>(); var offsets: [Int] = []
            await owner.start("f", load: { offset in
                offsets.append(offset); return self.threads(offset == 0 ? [1,2] : empty ? [] : [1,2])
            }, isCurrent: { true }).value
            await owner.loadMore("f")?.value
            XCTAssertEqual(offsets,[0,2]); XCTAssertNil(owner.loadMore("f")); XCTAssertEqual(owner.snapshot(for: "f").rows.count, 2)
            guard case .finished(let reason) = owner.snapshot(for: "f").more else { XCTFail("Must stop"); continue }
            XCTAssertFalse(reason.isEmpty)
        }
    }
    func testIgnoredCancellationSuccessAndErrorCannotMutateNewGeneration() async {
        for failure in [false,true] {
            let owner = LookupPagingState<String, Channel>(), held = Held<LookupPage<Channel>>(), store = DiscordStore()
            await owner.start("same", load: { offset in offset == 0 ? self.threads([1]) : try await held.load() },
                              isCurrent: { true }, publish: { store.remember(threads: $0.rows) }).value
            let old = owner.loadMore("same")!; await held.started(); owner.invalidate()
            let fresh = owner.start("same", load: { _ in self.threads([30], more: false) }, isCurrent: { true },
                                    publish: { store.remember(threads: $0.rows) })
            await fresh.value
            held.finish(failure ? .failure(URLError(.timedOut)) : .success(threads([20]))); await old.value
            XCTAssertEqual(owner.snapshot(for: "same").rows.map(\.id), [30]); XCTAssertNil(store.channel(20)); XCTAssertNotNil(store.channel(30))
        }
    }
    func testCancelledTransportCompletionWithoutReplacementRejectsBothOutcomes() async {
        for failure in [false,true] {
            let owner = LookupPagingState<String, Channel>(), held = Held<LookupPage<Channel>>(); var published = false
            let request = owner.start("f", load: { _ in try await held.load() }, isCurrent: { true }, publish: { _ in published = true })
            await held.started(); request.cancel()
            held.finish(failure ? .failure(URLError(.timedOut)) : .success(threads([20])))
            await request.value
            XCTAssertFalse(published); XCTAssertEqual(owner.snapshot(for: "f").status, .idle)
        }
    }
    func testExplicitResubmissionAfterAppendFailureAndInitialFailureRecovers() async {
        let owner = LookupPagingState<String, Channel>()
        await owner.start("f", load: { offset in
            if offset == 0 { return self.threads([1]) }; throw URLError(.timedOut)
        }, isCurrent: { true }).value
        await owner.loadMore("f")?.value
        await owner.start("f", load: { _ in throw URLError(.cannotConnectToHost) }, isCurrent: { true }).value
        guard case .failed = owner.snapshot(for: "f").status else { XCTFail("Initial error"); return }
        await owner.start("f", load: { _ in self.threads([2], more: false) }, isCurrent: { true }).value
        XCTAssertEqual(owner.snapshot(for: "f").rows.map(\.id), [2]); XCTAssertEqual(owner.snapshot(for: "f").status,.done)
    }
    func testTotalChangesAndClientCapStopHonestly() async {
        for capped in [false,true] {
            let owner = LookupPagingState<String, Message>(positionLimit: capped ? 50 : 1000)
            var offsets: [Int] = []
            await owner.start("q", load: { offset in
                offsets.append(offset)
                return LookupPage(rows: ((offset+1)...(offset+25)).map { self.message($0) }, consumed: 25,
                                  total: capped || offset == 0 ? 100 : 90, hasMore: true)
            }, isCurrent: { true }).value
            await owner.loadMore("q")?.value
            XCTAssertNil(owner.loadMore("q")); XCTAssertEqual(offsets,[0,25])
            guard case .finished(let reason) = owner.snapshot(for: "q").more else { XCTFail("Bounded stop"); continue }
            XCTAssertTrue(reason.contains(capped ? "limited" : "inconsistent"))
        }
    }
    func testForumDuplicateCannotReplaceMissingBlockedOwnerFallbackWithOtherAuthor() async {
        let owner = LookupPagingState<String, Channel>(), store = DiscordStore()
        var known = thread(10); known.ownerID = 900
        var duplicate = known; duplicate.ownerID = 901
        store.applyRelationship(Relationship(id: 900, type: 2))
        let injected = message(10, channel: 10, author: 901)
        await owner.start("f", load: { offset in
            .forum(ThreadSearchResult(threads: [offset == 0 ? known : duplicate], firstMessages: offset == 0 ? [] : [injected], hasMore: offset == 0), forum: self.forum)
        }, isCurrent: { true }, publish: { store.remember(threads: $0.rows) }).value
        await owner.loadMore("f")?.value
        let snapshot = owner.snapshot(for: "f")
        XCTAssertNil(snapshot.firstMessages[10]); XCTAssertEqual(snapshot.rows.first?.ownerID, 900)
        XCTAssertEqual(store.channel(10)?.ownerID,900)
        XCTAssertEqual(ForumView(channel: forum).postPresentation(snapshot.rows[0], firstMessage: snapshot.firstMessages[10], store: store).title,"Blocked post")
    }
    func testSearchOldAppendCannotAffectNewQueryLoadingOrCompletion() async {
        for failure in [false,true] {
            let owner = LookupPagingState<String, Message>(), old = Held<LookupPage<Message>>(), fresh = Held<LookupPage<Message>>()
            let store = DiscordStore(); var live = "A"
            await owner.start("A", load: { offset in
                offset == 0 ? LookupPage(rows: [self.message(1)], consumed: 25, total: 60, hasMore: true) : try await old.load()
            }, isCurrent: { live == "A" }, publish: { store.remember(messageAuthors: $0.rows) }).value
            let a = owner.loadMore("A")!; await old.started(); live = "B"
            let b = owner.start("B", load: { _ in try await fresh.load() }, isCurrent: { live == "B" }, publish: { store.remember(messageAuthors: $0.rows) })
            await fresh.started()
            old.finish(failure ? .failure(URLError(.timedOut)) : .success(LookupPage(rows: [message(2,author: 901)], consumed: 25, total: 60, hasMore: true)))
            await a.value
            XCTAssertEqual(owner.snapshot(for: "B").status,.loading); XCTAssertTrue(owner.snapshot(for: "B").rows.isEmpty); XCTAssertNil(store.users[901])
            fresh.finish(.success(LookupPage(rows: [message(3,author: 902)], consumed: 1, total: 1, hasMore: false))); await b.value
            XCTAssertEqual(owner.snapshot(for: "B").rows.map(\.id),[3]); XCTAssertNotNil(store.users[902])
        }
    }
    func testFirstPageDedupAndServerFalseHasMoreTerminateWithoutExtraRequest() async {
        let owner = LookupPagingState<String, Channel>(); var offsets: [Int] = []
        await owner.start("f", load: { offset in offsets.append(offset); return self.threads([1,1,2],more: false) }, isCurrent: { true }).value
        XCTAssertEqual(owner.snapshot(for: "f").rows.map(\.id),[1,2]); XCTAssertEqual(owner.snapshot(for: "f").consumed,3)
        XCTAssertNil(owner.loadMore("f")); XCTAssertEqual(offsets,[0])
    }
    func testUnevenSearchPagesCannotPublishPastThousandPositionBound() async {
        let owner = LookupPagingState<String, Message>(), store = DiscordStore()
        var offsets: [Int] = [], publishedPositions = 0
        await owner.start("q", load: { offset in
            offsets.append(offset)
            let count = offset == 0 ? 24 : 25
            return LookupPage(rows: ((offset + 1)...(offset + count)).map {
                self.message($0, author: Snowflake(UInt64($0 + 10000)))
            }, consumed: count, total: 2000, hasMore: true)
        }, isCurrent: { true }, publish: { page in
            publishedPositions += page.consumed
            store.remember(messageAuthors: page.rows)
        }).value
        for _ in 0..<39 { await owner.loadMore("q")?.value }
        XCTAssertEqual(owner.snapshot(for: "q").consumed, 999)
        await owner.loadMore("q")?.value
        let snapshot = owner.snapshot(for: "q")
        XCTAssertEqual(offsets.last, 999)
        XCTAssertEqual(snapshot.consumed, 999)
        XCTAssertEqual(snapshot.rows.count, 999)
        XCTAssertEqual(publishedPositions, 999)
        XCTAssertNil(store.users[11000], "An over-budget page must not reach the author cache")
        guard case .finished(let reason) = snapshot.more else { XCTFail("Bound must stop paging"); return }
        XCTAssertTrue(reason.contains("1,000"))
        XCTAssertNil(owner.loadMore("q"))
    }

    func testUnevenForumPageCannotPublishRowsFirstMessagesOrThreadsPastBound() async {
        let owner = LookupPagingState<String, Channel>(positionLimit: 50), store = DiscordStore()
        var publications = 0
        await owner.start("f", load: { offset in
            let count = offset == 0 ? 24 : 25
            return self.threads(Array((offset + 1)...(offset + count)))
        }, isCurrent: { true }, publish: { page in
            publications += 1
            store.remember(threads: page.rows)
        }).value
        await owner.loadMore("f")?.value
        XCTAssertEqual(owner.snapshot(for: "f").consumed, 49)
        await owner.loadMore("f")?.value
        let snapshot = owner.snapshot(for: "f")
        XCTAssertEqual(snapshot.consumed, 49)
        XCTAssertEqual(snapshot.rows.count, 49)
        XCTAssertEqual(snapshot.firstMessages.count, 49)
        XCTAssertEqual(publications, 2)
        XCTAssertNil(store.channel(50), "Rejected page must not reach the thread cache")
        XCTAssertNil(owner.loadMore("f"))
    }

    func testOversizedInitialPageStopsBeforePublicationAndExactFitReloadWorks() async {
        let owner = LookupPagingState<String, Channel>(positionLimit: 24)
        var publications = 0
        await owner.start("f", load: { _ in self.threads(Array(1...25)) },
                          isCurrent: { true }, publish: { _ in publications += 1 }).value
        let snapshot = owner.snapshot(for: "f")
        XCTAssertEqual(snapshot.consumed, 0)
        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertTrue(snapshot.firstMessages.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(snapshot.status, .done)
        XCTAssertNil(owner.loadMore("f"))

        await owner.start("f", load: { _ in self.threads(Array(1...24)) },
                          isCurrent: { true }, publish: { _ in publications += 1 }).value
        XCTAssertEqual(owner.snapshot(for: "f").rows.count, 24)
        XCTAssertEqual(owner.snapshot(for: "f").consumed, 24)
        XCTAssertEqual(publications, 1)
        XCTAssertNil(owner.loadMore("f"))
    }

    func testCurrentAcceptedRowsAndCachePublishTogetherOnMainActor() async {
        let owner = LookupPagingState<String, Channel>(), store = DiscordStore(); var cachePublicationTurns = 0
        await owner.start("f", load: { offset in self.threads(offset == 0 ? [1] : [2],more: offset == 0) }, isCurrent: { true }, publish: { page in
            MainActor.assertIsolated()
            store.remember(threads: page.rows); cachePublicationTurns += 1
        }).value
        await owner.loadMore("f")?.value
        XCTAssertEqual(cachePublicationTurns,2)
        XCTAssertTrue(owner.snapshot(for: "f").rows.allSatisfy { store.channel($0.id) != nil })
        XCTAssertEqual(owner.snapshot(for: "f").firstMessages.count,2)
    }

}
