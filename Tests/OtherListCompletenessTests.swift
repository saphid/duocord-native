import XCTest
@testable import DuocordNative

/// Production consumers with held responses; no mounted SwiftUI or live API.
@MainActor
final class OtherListCompletenessTests: XCTestCase {
    private final class Held<Value> {
        var response: CheckedContinuation<Value, Error>?
        var arrival: CheckedContinuation<Void, Never>?
        func load() async throws -> Value {
            try await withCheckedThrowingContinuation { response = $0; arrival?.resume(); arrival = nil }
        }
        func started() async { if response == nil { await withCheckedContinuation { arrival = $0 } } }
        func finish(_ result: Result<Value, Error>) { response!.resume(with: result); response = nil }
    }
    private func message(_ id: Int) -> Message {
        Message(id: Snowflake(UInt64(id)), channelID: 1, guildID: 10,
                author: User(id: Snowflake(UInt64(id + 10000)), username: "offline"),
                content: "visible ||private-cursor-secret||", timestamp: "")
    }
    private let parent = Channel(id: 1, type: .text, guildID: 10, name: "parent")
    private func thread(_ id: Int, parent: Snowflake = 1, timestamp: String? = nil) -> Channel {
        var row = Channel(id: Snowflake(UInt64(id)), type: .publicThread, guildID: 10, name: "archived", parentID: parent)
        row.threadMetadata = ThreadMetadata(archived: true, locked: false, archiveTimestamp: timestamp ?? stamp(id))
        return row
    }
    private func stamp(_ i: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000 - Double(i)))
    }
    private func archives(_ ids: [Int], more: Bool = true) -> ArchivedThreadPage {
        ArchivedThreadPage(threads: ids.map { thread($0) }, hasMore: more)
    }
    private func mentions(_ owner: OtherListState<String, Message, Snowflake>, store: DiscordStore,
                          current: @escaping () -> Bool = { true },
                          fetch: @escaping (Snowflake?) async throws -> [Message]) -> Task<Void, Never> {
        OtherListConsumers.mentions(owner, input: "inbox", api: OfflineAPI(), store: store, isCurrent: current, fetch: fetch)
    }
    private func archived(_ owner: OtherListState<String, Channel, String>, store: DiscordStore,
                          current: @escaping () -> Bool = { true },
                          fetch: @escaping (String?) async throws -> ArchivedThreadPage) -> Task<Void, Never> {
        OtherListConsumers.archives(owner, input: "threads", api: OfflineAPI(), parent: parent, store: store, isCurrent: current, fetch: fetch)
    }
    func testMentionsBeyond25PreserveServerOrderAndUseRawMinimumCursor() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore(); var cursors: [Snowflake?] = []
        await mentions(owner, store: store) { before in
            cursors.append(before)
            return (before == nil ? Array((76...100).reversed()) : Array((66...75).reversed())).map(self.message)
        }.value
        await owner.loadMore("inbox")?.value
        XCTAssertEqual(cursors, [nil,76]); XCTAssertEqual(owner.snapshot(for: "inbox").rows.map(\.id), (66...100).reversed().map { Snowflake(UInt64($0)) })
        XCTAssertEqual(owner.snapshot(for: "inbox").consumed,35); XCTAssertNotNil(store.users[10066]); XCTAssertNil(owner.loadMore("inbox"))
    }
    func testMentionsRawDuplicatesDoNotBecomeCursorPositionsOrOverwriteAuthors() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore(); var cursors: [Snowflake?] = []
        await mentions(owner, store: store) { before in
            cursors.append(before)
            if before == nil { return Array((77...100).reversed()).map(self.message) + [self.message(77)] }
            var duplicate = self.message(77); duplicate.author = User(id: 99999, username: "wrong")
            return [duplicate] + Array((54...76).reversed()).map(self.message) + [self.message(54)]
        }.value
        await owner.loadMore("inbox")?.value
        XCTAssertEqual(cursors,[nil,77]); XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,47)
        XCTAssertEqual(owner.snapshot(for: "inbox").consumed,50); XCTAssertEqual(owner.snapshot(for: "inbox").cursor,54)
        XCTAssertNil(store.users[99999]); XCTAssertEqual(Set(owner.snapshot(for: "inbox").rows.map(\.id)).count,47)
    }
    func testMentionsEmptyAndDuplicateOnlyAndNonprogressingPagesStop() async {
        for variant in 0..<3 {
            let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore()
            await mentions(owner, store: store) { before in
                if before == nil { return Array((76...100).reversed()).map(self.message) }
                if variant == 0 { return [] }
                if variant == 1 { return Array(repeating: self.message(76), count: 25) }
                return Array(repeating: self.message(200), count: 25)
            }.value
            await owner.loadMore("inbox")?.value
            XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,25)
            XCTAssertNil(store.users[10200]); XCTAssertNil(owner.loadMore("inbox"))
            guard case .finished(let reason) = owner.snapshot(for: "inbox").more else { XCTFail("Must stop"); continue }
            XCTAssertFalse(reason.isEmpty)
        }
    }
    func testMentionsZeroCursorIsMalformedAndCannotPublish() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore()
        await mentions(owner, store: store) { _ in [self.message(0)] }.value
        XCTAssertTrue(owner.snapshot(for: "inbox").rows.isEmpty); XCTAssertNil(store.users[10000])
        guard case .finished(let reason) = owner.snapshot(for: "inbox").more else { XCTFail(); return }
        XCTAssertTrue(reason.contains("cursor"))
    }
    func testMentionAppendFailureRetriesSameCursorAndCoalescesTaps() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore(), held = Held<[Message]>()
        var cursors: [Snowflake?] = [], attempts = 0
        await mentions(owner, store: store) { before in
            cursors.append(before)
            if before == nil { return Array((76...100).reversed()).map(self.message) }
            attempts += 1
            return attempts == 1 ? try await held.load() : [self.message(75)]
        }.value
        guard let task = owner.loadMore("inbox") else { XCTFail("Missing next page"); return }
        await held.started(); XCTAssertNil(owner.loadMore("inbox")); held.finish(.failure(URLError(.timedOut))); await task.value
        XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,25); XCTAssertEqual(owner.snapshot(for: "inbox").cursor,76)
        guard case .failed = owner.snapshot(for: "inbox").more else { XCTFail(); return }
        await owner.loadMore("inbox")?.value
        XCTAssertEqual(cursors,[nil,76,76]); XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,26)
    }
    func testMentionInitialFailureAndReloadRecoverWithoutChangingSelectionOrDraft() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore(), model = AppModel()
        model.selectedChannel = 1; model.drafts[1] = Draft(text: "retained")
        await mentions(owner, store: store) { _ in throw URLError(.timedOut) }.value
        guard case .failed = owner.snapshot(for: "inbox").status else { XCTFail(); return }
        await mentions(owner, store: store) { before in XCTAssertNil(before); return [self.message(100)] }.value
        XCTAssertEqual(owner.snapshot(for: "inbox").rows.map(\.id),[100]); XCTAssertEqual(model.selectedChannel,1)
        XCTAssertEqual(model.drafts[1]?.text,"retained")
    }
    func testMentionsExactAndStraddlingPositionCapsPrecedeAllPublication() async {
        for limit in [24,25,49,50] {
            let owner = OtherListState<String, Message, Snowflake>(positionLimit: limit), store = DiscordStore()
            await mentions(owner, store: store) { before in
                (before == nil ? Array((76...100).reversed()) : Array((51...75).reversed())).map(self.message)
            }.value
            await owner.loadMore("inbox")?.value
            let expected = limit < 25 ? 0 : (limit < 50 ? 25 : 50)
            XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,expected); XCTAssertEqual(owner.snapshot(for: "inbox").consumed,expected)
            XCTAssertEqual(store.users.count,expected); XCTAssertNil(owner.loadMore("inbox"))
            guard case .finished(let reason) = owner.snapshot(for: "inbox").more else { XCTFail(); continue }
            XCTAssertTrue(reason.contains(String(limit)))
        }
    }
    func testMentionsUnevenStraddlingPageCannotLeakRowsOrAuthors() async {
        let owner = OtherListState<String, Message, Snowflake>(positionLimit: 49), store = DiscordStore(); var count = 0
        await mentions(owner, store: store) { _ in
            count += 1
            return (count == 1 ? Array((77...100).reversed()) + [100] : Array((52...76).reversed())).map(self.message)
        }.value
        // 25 raw positions, 24 unique rows, next 25 crosses 49.
        await owner.loadMore("inbox")?.value
        XCTAssertEqual(owner.snapshot(for: "inbox").consumed,25); XCTAssertEqual(owner.snapshot(for: "inbox").rows.count,24)
        XCTAssertNil(store.users[10052]); XCTAssertEqual(store.users.count,24)
    }
    func testPublicArchivesBeyond25HonorShortHasMoreAndTimestampCursor() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore(); var cursors: [String?] = []
        await archived(owner, store: store) { before in
            cursors.append(before)
            if before == nil { return self.archives(Array(1...25)) }
            if before == self.stamp(25) { return self.archives([26]) }
            return self.archives(Array(27...32),more: false)
        }.value
        await owner.loadMore("threads")?.value; await owner.loadMore("threads")?.value
        XCTAssertEqual(cursors,[nil,stamp(25),stamp(26)]); XCTAssertEqual(owner.snapshot(for: "threads").rows.map(\.id),(1...32).map { Snowflake(UInt64($0)) })
        XCTAssertEqual(owner.snapshot(for: "threads").consumed,32); XCTAssertNotNil(store.channel(32)); XCTAssertNil(owner.loadMore("threads"))
    }
    func testArchiveDedupRetainsOriginalRecordAndRawTimestampTail() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore(); var cursors: [String?] = []
        await archived(owner, store: store) { before in
            cursors.append(before)
            if before == nil { return self.archives([1,2]) }
            var duplicate = self.thread(2,timestamp: self.stamp(3)); duplicate.name = "must not replace"
            return ArchivedThreadPage(threads: [duplicate,self.thread(3,timestamp: self.stamp(4))],hasMore: true)
        }.value
        await owner.loadMore("threads")?.value
        XCTAssertEqual(cursors,[nil,stamp(2)]); XCTAssertEqual(owner.snapshot(for: "threads").rows.map(\.id),[1,2,3])
        XCTAssertEqual(owner.snapshot(for: "threads").consumed,4); XCTAssertEqual(owner.snapshot(for: "threads").cursor,stamp(4))
        XCTAssertEqual(store.channel(2)?.name,"archived")
    }
    func testArchiveMissingMalformedEqualAndFutureCursorsStopRecoverably() async {
        for bad in [nil,"not-a-date",stamp(1),stamp(0)] as [String?] {
            let owner = OtherListState<String, Channel, String>(), store = DiscordStore()
            await archived(owner, store: store) { before in
                if before == nil { return self.archives([1]) }
                var row = self.thread(2); row.threadMetadata?.archiveTimestamp = bad
                return ArchivedThreadPage(threads: [row], hasMore: true)
            }.value
            await owner.loadMore("threads")?.value
            XCTAssertEqual(owner.snapshot(for: "threads").rows.map(\.id),[1]); XCTAssertNil(store.channel(2))
            guard case .finished(let reason) = owner.snapshot(for: "threads").more else { XCTFail(); continue }
            XCTAssertTrue(reason.contains("cursor")); XCTAssertNil(owner.loadMore("threads"))
            await archived(owner, store: store) { _ in self.archives([3],more: false) }.value
            XCTAssertEqual(owner.snapshot(for: "threads").rows.map(\.id),[3])
        }
    }
    func testArchiveEmptyHasMoreAndDuplicateOnlyStopWithoutLooping() async {
        for empty in [true,false] {
            let owner = OtherListState<String, Channel, String>(), store = DiscordStore()
            await archived(owner, store: store) { before in
                before == nil ? self.archives([1]) : ArchivedThreadPage(threads: empty ? [] : [self.thread(1,timestamp:self.stamp(2))],hasMore:true)
            }.value
            await owner.loadMore("threads")?.value
            XCTAssertEqual(owner.snapshot(for: "threads").rows.count,1); XCTAssertNil(owner.loadMore("threads"))
            guard case .finished(let reason) = owner.snapshot(for: "threads").more else { XCTFail(); continue }
            XCTAssertTrue(reason.contains("Reload")); XCTAssertEqual(store.channel(1)?.threadMetadata?.archiveTimestamp,stamp(1))
        }
    }
    func testArchiveEndFalsePublishesEvenWithoutCursorButDoesNotOfferMore() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore()
        var row = thread(1); row.threadMetadata?.archiveTimestamp = nil
        await archived(owner, store: store) { _ in ArchivedThreadPage(threads:[row],hasMore:false) }.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[1]); XCTAssertNotNil(store.channel(1)); XCTAssertNil(owner.loadMore("threads"))
    }
    func testArchiveParentGuildTypeAndArchivedValidationBeforeCacheWrites() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore()
        var guild = thread(3); guild.guildID = 20
        var type = thread(4); type.type = .text
        var active = thread(5); active.threadMetadata?.archived = false
        var privateThread = thread(6); privateThread.type = .privateThread
        await archived(owner, store: store) { _ in ArchivedThreadPage(threads:[self.thread(1),self.thread(2,parent:2),guild,type,active,privateThread],hasMore:false) }.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[1]); XCTAssertNotNil(store.channel(1))
        for id in 2...6 { XCTAssertNil(store.channel(Snowflake(UInt64(id)))) }
        XCTAssertEqual(owner.snapshot(for:"threads").consumed,6)
    }
    func testArchiveAppendFailureRetryAndDuplicateTapsKeepAcceptedRows() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore(), held = Held<ArchivedThreadPage>()
        var cursors: [String?] = [], attempt = 0
        await archived(owner, store:store) { before in
            cursors.append(before)
            if before == nil { return self.archives([1]) }
            attempt += 1; return attempt == 1 ? try await held.load() : self.archives([2],more:false)
        }.value
        guard let task = owner.loadMore("threads") else { XCTFail("Missing archive next page"); return }
        await held.started(); XCTAssertNil(owner.loadMore("threads")); held.finish(.failure(URLError(.timedOut))); await task.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[1]); XCTAssertEqual(owner.snapshot(for:"threads").cursor,stamp(1))
        guard case .failed = owner.snapshot(for:"threads").more else { XCTFail(); return }
        await owner.loadMore("threads")?.value
        XCTAssertEqual(cursors,[nil,stamp(1),stamp(1)]); XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[1,2])
    }
    func testArchiveInitialFailureReloadUsesNilAndCapturedParent() async {
        let owner = OtherListState<String, Channel, String>(), store = DiscordStore()
        await archived(owner, store:store) { _ in throw URLError(.timedOut) }.value
        guard case .failed = owner.snapshot(for:"threads").status else { XCTFail(); return }
        await archived(owner, store:store) { before in XCTAssertNil(before); return self.archives([2],more:false) }.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[2]); XCTAssertEqual(store.channel(2)?.parentID,1)
    }
    func testArchiveExactAndStraddlingCapsPrecedeCacheAndRows() async {
        for limit in [24,25,49,50] {
            let owner = OtherListState<String, Channel, String>(positionLimit:limit), store = DiscordStore()
            await archived(owner, store:store) { before in self.archives(before == nil ? Array(1...25) : Array(26...50)) }.value
            await owner.loadMore("threads")?.value
            let expected = limit < 25 ? 0 : (limit < 50 ? 25 : 50)
            XCTAssertEqual(owner.snapshot(for:"threads").rows.count,expected); XCTAssertEqual(owner.snapshot(for:"threads").consumed,expected)
            XCTAssertEqual(store.channels.count,expected); XCTAssertNil(owner.loadMore("threads"))
        }
    }
    func testMoreThan50UnreadChannelsAreDiscoverableAndMarkAllUsesFullSet() async {
        let mock = MockDiscord(), model = AppModel(readAPI:MockDiscord())
        var ready = mock.readyPayload()
        ready.privateChannels = (1...73).map { Channel(id:Snowflake(UInt64($0)),type:.dm,lastMessageID:300) }
        ready.readStates = ready.privateChannels.map { ReadState(id:$0.id,lastMessageID:10,mentionCount:1) }
        model.store.apply(ready:ready)
        let listed = InboxLists.unreadChannels(store:model.store)
        XCTAssertTrue(Set((1...73).map { Snowflake(UInt64($0)) }).isSubset(of:Set(listed.map(\.id))))
        await model.markAllAsRead().value
        for id in 1...73 { XCTAssertEqual(model.store.readStates[Snowflake(UInt64(id))]?.lastMessageID,300) }
    }
    func testMentionRowsRetainBlockedAndSpoilerPresentationWithoutRevealLeak() async {
        let owner = OtherListState<String, Message, Snowflake>(), store = DiscordStore()
        store.applyRelationship(Relationship(id:10100,type:2,user:message(100).author))
        await mentions(owner,store:store) { _ in [self.message(100),self.message(99)] }.value
        let rows = owner.snapshot(for:"inbox").rows
        XCTAssertEqual(rows.count,2)
        if rows.count == 2 {
            let blocked = MessageResultRow(message:rows[0]).presentation(store:store)
            XCTAssertTrue(blocked.concealed)
            XCTAssertFalse(MessageResultRow(message:rows[1]).presentation(store:store).text.contains("private-cursor-secret"))
            XCTAssertNotEqual(ExcerptRevealScope(message:rows[0],store:store),ExcerptRevealScope(message:rows[1],store:store))
        }
    }

    private func boundary(archive:Bool, initial:Bool, failure:Bool, change:String) async {
        let model = AppModel(), store = DiscordStore(), api = MockDiscord()
        model.selectedGuild = 10; model.selectedChannel = 1
        var target = parent, presentation = UUID(), sidebar = false, open = true, apiID = ObjectIdentifier(api)
        func identity() -> OtherListIdentity? {
            guard open else { return nil }
            return OtherListIdentity(context:LookupContext(model:model,store:store),route:archive ? .threads(target.id) : .inbox,
                                     parent:archive ? target : nil,api:apiID,presentation:presentation,sidebar:sidebar,navigation:model.navigationIntent)
        }
        let a = identity()!
        func changeIdentity() {
            switch change {
            case "parent": target = Channel(id:2,type:.text,guildID:20,name:"new parent")
            case "channel": model.selectedChannel = 2
            case "guild": model.selectedGuild = 20
            case "visit": model.selectedChannel = 2; model.selectedChannel = 1
            case "session": store.reset()
            case "account": var ready = MockDiscord().readyPayload(); ready.user = User(id:77,username:"other"); store.apply(ready:ready)
            case "close": open = false
            case "reopen": presentation = UUID()
            case "transfer": sidebar = true
            case "api": apiID = ObjectIdentifier(MockDiscord())
            default: model.sheet = .pins; model.sheet = nil
            }
        }
        if archive {
            let owner = OtherListState<OtherListIdentity,Channel,String>(), held = Held<ArchivedThreadPage>()
            let first = OtherListConsumers.archives(owner,input:a,api:api,parent:target,store:store,isCurrent:{ identity() == a },fetch:{ before in
                initial || before != nil ? try await held.load() : self.archives([1])
            })
            let task: Task<Void,Never>
            if initial { task = first } else { await first.value; guard let append = owner.loadMore(a) else { XCTFail("Append missing"); return }; task = append }
            await held.started(); changeIdentity()
            XCTAssertTrue(owner.snapshot(for:identity()).rows.isEmpty,change)
            held.finish(failure ? .failure(URLError(.timedOut)) : .success(archives([20])))
            await task.value; XCTAssertNil(store.channel(20),change); XCTAssertEqual(owner.snapshot(for:a).status,.idle,change)
        } else {
            let owner = OtherListState<OtherListIdentity,Message,Snowflake>(), held = Held<[Message]>()
            let first = OtherListConsumers.mentions(owner,input:a,api:api,store:store,isCurrent:{ identity() == a },fetch:{ before in
                initial || before != nil ? try await held.load() : Array((76...100).reversed()).map(self.message)
            })
            let task: Task<Void,Never>
            if initial { task = first } else { await first.value; guard let append = owner.loadMore(a) else { XCTFail("Append missing"); return }; task = append }
            await held.started(); changeIdentity()
            XCTAssertTrue(owner.snapshot(for:identity()).rows.isEmpty,change)
            held.finish(failure ? .failure(URLError(.timedOut)) : .success([message(20)]))
            await task.value; XCTAssertNil(store.users[10020],change); XCTAssertEqual(owner.snapshot(for:a).status,.idle,change)
        }
    }
    private func boundaries(archive:Bool,initial:Bool,failure:Bool) async {
        for c in ["channel","guild","visit","session","account","close","reopen","transfer","api","navigation"] + (archive ? ["parent"] : []) {
            await boundary(archive:archive,initial:initial,failure:failure,change:c)
        }
    }
    func testMentionInitialSuccessLiveIdentityFencesRowsAndCache() async { await boundaries(archive:false,initial:true,failure:false) }
    func testMentionInitialFailureLiveIdentityFence() async { await boundaries(archive:false,initial:true,failure:true) }
    func testMentionAppendSuccessLiveIdentityFencesRowsAndCache() async { await boundaries(archive:false,initial:false,failure:false) }
    func testMentionAppendFailureLiveIdentityFence() async { await boundaries(archive:false,initial:false,failure:true) }
    func testArchiveInitialSuccessLiveIdentityFencesRowsAndCache() async { await boundaries(archive:true,initial:true,failure:false) }
    func testArchiveInitialFailureLiveIdentityFence() async { await boundaries(archive:true,initial:true,failure:true) }
    func testArchiveAppendSuccessLiveIdentityFencesRowsAndCache() async { await boundaries(archive:true,initial:false,failure:false) }
    func testArchiveAppendFailureLiveIdentityFence() async { await boundaries(archive:true,initial:false,failure:true) }
    func testCancelledMentionLoadIgnoringCancellationCannotWrite() async {
        let owner = OtherListState<String,Message,Snowflake>(), store = DiscordStore(), held = Held<[Message]>()
        let task = mentions(owner,store:store) { _ in try await held.load() }
        await held.started(); task.cancel(); held.finish(.success([message(10)])); await task.value
        XCTAssertTrue(owner.snapshot(for:"inbox").rows.isEmpty); XCTAssertNil(store.users[10010])
    }
    func testCancelledArchiveLoadIgnoringCancellationCannotWrite() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), held = Held<ArchivedThreadPage>()
        let task = archived(owner,store:store) { _ in try await held.load() }
        await held.started(); task.cancel(); held.finish(.success(archives([10]))); await task.value
        XCTAssertTrue(owner.snapshot(for:"threads").rows.isEmpty); XCTAssertNil(store.channel(10))
    }
    func testClosedMentionGenerationCannotReplaceReopenedLoadingOrCurrentRows() async {
        let owner = OtherListState<String,Message,Snowflake>(), store = DiscordStore(), old = Held<[Message]>(), fresh = Held<[Message]>()
        let a = mentions(owner,store:store) { _ in try await old.load() }; await old.started(); owner.invalidate()
        let b = mentions(owner,store:store) { _ in try await fresh.load() }; await fresh.started()
        old.finish(.success([message(10)])); await a.value
        XCTAssertEqual(owner.snapshot(for:"inbox").status,.loading); XCTAssertNil(store.users[10010])
        fresh.finish(.success([message(20)])); await b.value; XCTAssertEqual(owner.snapshot(for:"inbox").rows.map(\.id),[20])
    }
    func testOldArchiveErrorCannotReplaceReloadedRows() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), old = Held<ArchivedThreadPage>()
        let a = archived(owner,store:store) { _ in try await old.load() }; await old.started()
        await archived(owner,store:store) { _ in self.archives([20],more:false) }.value
        old.finish(.failure(URLError(.timedOut))); await a.value
        XCTAssertEqual(owner.snapshot(for:"threads").status,.done); XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[20])
    }
    func testDefault1000MentionPositionLimitStopsBeforeFurtherFetchOrPublication() async {
        let owner = OtherListState<String,Message,Snowflake>(), store = DiscordStore(); var requests = 0
        await mentions(owner,store:store) { before in
            requests += 1
            let top = Int(before?.raw ?? 10001) - 1
            return Array(((top - 24)...top).reversed()).map(self.message)
        }.value
        for _ in 0..<45 { await owner.loadMore("inbox")?.value }
        XCTAssertEqual(requests,40); XCTAssertEqual(owner.snapshot(for:"inbox").consumed,1000)
        XCTAssertEqual(owner.snapshot(for:"inbox").rows.count,1000); XCTAssertEqual(store.users.count,1000)
        guard case .finished(let reason) = owner.snapshot(for:"inbox").more else { XCTFail(); return }
        XCTAssertTrue(reason.contains("1,000"))
    }
    func testDefault1000ArchivePositionLimitStopsBeforeFurtherFetchOrPublication() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore(); var requests = 0
        await archived(owner,store:store) { _ in
            let start = requests * 25 + 1; requests += 1
            return self.archives(Array(start..<(start + 25)))
        }.value
        for _ in 0..<45 { await owner.loadMore("threads")?.value }
        XCTAssertEqual(requests,40); XCTAssertEqual(owner.snapshot(for:"threads").consumed,1000)
        XCTAssertEqual(store.channels.count,1000); XCTAssertEqual(owner.snapshot(for:"threads").rows.count,1000)
    }
    func testArchiveUnevenStraddlingPageRejectsBeforeRowsAndCache() async {
        let owner = OtherListState<String,Channel,String>(positionLimit:49), store = DiscordStore()
        await archived(owner,store:store) { before in
            before == nil ? self.archives(Array(1...24)) : self.archives(Array(25...50))
        }.value
        await owner.loadMore("threads")?.value
        XCTAssertEqual(owner.snapshot(for:"threads").consumed,24); XCTAssertEqual(owner.snapshot(for:"threads").rows.count,24)
        XCTAssertEqual(store.channels.count,24); XCTAssertNil(store.channel(25))
    }
    func testArchiveSectionsUseCurrentActiveStoreWithoutDuplicateIDs() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
        store.remember(threads:[parent])
        await archived(owner,store:store) { _ in self.archives([1_001,1_002],more:false) }.value
        var active = thread(1_001); active.threadMetadata?.archived = false
        store.remember(threads:[active])
        // Store.threads(in:) requires guild indexing from READY, so pass the
        // store record itself as the current active projection in this seam.
        let visible = OtherListConsumers.archivedRows(owner.snapshot(for:"threads").rows,active:[store.channel(1_001)!])
        XCTAssertEqual(visible.map(\.id),[1_002]); XCTAssertEqual(store.channel(1_001)?.threadMetadata?.archived,false)
    }
    func testProductionIdentityCoversPresentationContextAndStableTransportReference() {
        let mock = MockDiscord(), model = AppModel(readAPI:mock), store = model.store, presentation = UUID()
        model.start() // Injected mock returns before any login/session credential path.
        store.apply(ready:mock.readyPayload()); model.selectedChannel = 1; model.selectedGuild = 10
        model.sheet = .inbox
        let a = OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:false)
        XCTAssertNotNil(a); XCTAssertEqual(a?.api,ObjectIdentifier(mock))
        XCTAssertEqual(a,OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:false))
        XCTAssertNil(OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:true))
        model.sheet = nil; XCTAssertNil(OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:false))
        model.sheet = .inbox
        XCTAssertNotEqual(a,OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:false))
        model.sidebarPanel = .inbox
        XCTAssertNotEqual(a,OtherListIdentity.current(model:model,store:store,route:.inbox,presentation:presentation,sidebar:true))
    }
    func testParentAssociationIdentityIgnoresTrafficButRejectsGuildAndTypeReplacement() {
        let model = AppModel(), store = DiscordStore(), api = MockDiscord(), presentation = UUID()
        func identity(_ channel:Channel) -> OtherListIdentity {
            OtherListIdentity(context:LookupContext(model:model,store:store),route:.threads(channel.id),parent:channel,
                              api:ObjectIdentifier(api),presentation:presentation,sidebar:false,navigation:model.navigationIntent)
        }
        var changed = parent; changed.lastMessageID = 99; changed.name = "renamed"
        XCTAssertEqual(identity(parent),identity(changed))
        changed.guildID = 20; XCTAssertNotEqual(identity(parent),identity(changed))
        changed = parent; changed.type = .forum; XCTAssertNotEqual(identity(parent),identity(changed))
    }
    func testMentionAcceptedRowsSuppressedSynchronouslyBeforeReplacementTask() async {
        let owner = OtherListState<String,Message,Snowflake>(), store = DiscordStore()
        await mentions(owner,store:store) { _ in [self.message(100)] }.value
        XCTAssertEqual(owner.snapshot(for:"inbox").rows.count,1)
        XCTAssertTrue(owner.snapshot(for:"other").rows.isEmpty); XCTAssertTrue(owner.snapshot(for:nil).rows.isEmpty)
        owner.invalidate(); XCTAssertEqual(owner.snapshot(for:"inbox").status,.idle)
    }
    func testArchiveAcceptedRowsSuppressedSynchronouslyBeforeReplacementTask() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
        await archived(owner,store:store) { _ in self.archives([10],more:false) }.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.count,1)
        XCTAssertTrue(owner.snapshot(for:"other").rows.isEmpty); XCTAssertTrue(owner.snapshot(for:nil).rows.isEmpty)
        owner.invalidate(); XCTAssertEqual(owner.snapshot(for:"threads").status,.idle)
    }
    func testArchiveUnorderedAndMissingInitialCursorDoNotPublishAnyThreads() async {
        for variant in 0..<2 {
            let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
            var invalid = thread(2); invalid.threadMetadata?.archiveTimestamp = nil
            await archived(owner,store:store) { _ in
                ArchivedThreadPage(threads:variant == 0 ? [self.thread(2),self.thread(1)] : [invalid],hasMore:true)
            }.value
            XCTAssertTrue(owner.snapshot(for:"threads").rows.isEmpty); XCTAssertTrue(store.channels.isEmpty)
            guard case .finished(let reason) = owner.snapshot(for:"threads").more else { XCTFail(); continue }
            XCTAssertTrue(reason.contains("cursor"))
        }
    }

    private func gatewayThread(_ row: Channel, store: DiscordStore) throws {
        struct Envelope: Encodable { var d: Channel }
        store.handle(GatewayDispatch(name: "THREAD_UPDATE", data: try JSONEncoder().encode(Envelope(d: row))))
    }

    func testHeldArchivePageRetainsNewerGatewayMetadataAndDeletion() async throws {
        for initial in [true, false] {
            for change in ["unarchive", "rename", "delete", "restore"] {
                let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), held = Held<ArchivedThreadPage>()
                store.upsert(channel: parent)
                var known = thread(102); known.name = "cache-start"
                store.upsert(channel: known)
                var response = known; response.name = "older-http"
                let first = archived(owner,store:store) { before in
                    if initial || before != nil { return try await held.load() }
                    return self.archives([101])
                }
                var pending = first
                if !initial { await first.value; pending = owner.loadMore("threads")! }
                await held.started()
                if change == "delete" {
                    store.handle(GatewayDispatch(name:"THREAD_DELETE",data:Data("{\"d\":{\"id\":\"102\"}}".utf8)))
                } else {
                    var fresh = known; fresh.name = "gateway-new"
                    if change == "unarchive" { fresh.threadMetadata?.archived = false }
                    try gatewayThread(fresh,store:store)
                    if change == "restore" { try gatewayThread(known,store:store) }
                }
                held.finish(.success(ArchivedThreadPage(threads:[response],hasMore:false))); await pending.value
                let snapshot = owner.snapshot(for:"threads")
                let shown = OtherListConsumers.archivedRows(snapshot.rows,active:store.threads(in:1))
                if change == "delete" {
                    XCTAssertNil(store.channel(102)); XCTAssertFalse(shown.contains { $0.id == 102 })
                } else {
                    XCTAssertEqual(store.channel(102)?.name,change == "restore" ? "cache-start" : "gateway-new")
                    if change == "unarchive" {
                        XCTAssertEqual(store.channel(102)?.threadMetadata?.archived,false)
                        XCTAssertFalse(shown.contains { $0.id == 102 })
                    } else {
                        XCTAssertEqual(shown.first { $0.id == 102 }?.name,change == "restore" ? "cache-start" : "gateway-new")
                    }
                }
            }
        }
    }

    func testArchiveContinuationPreservesSubmillisecondPrecisionAndTimezone() async {
        for firstStamp in ["2026-11-02T11:22:33.123456Z", "2026-11-02T13:52:33.123456+02:30"] {
            let owner = OtherListState<String,Channel,String>(), store = DiscordStore(); var cursors: [String?] = []
            await archived(owner,store:store) { before in
                cursors.append(before)
                let row = self.thread(before == nil ? 101 : 102,timestamp:before == nil ? firstStamp : "2026-11-02T11:22:33.123455999999Z")
                return ArchivedThreadPage(threads:[row],hasMore:true)
            }.value
            await owner.loadMore("threads")?.value
            XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[101,102])
            XCTAssertEqual(owner.snapshot(for:"threads").cursor,"2026-11-02T11:22:33.123455999999Z")
            XCTAssertEqual(cursors,[nil,firstStamp]); XCTAssertNotNil(store.channel(102))
        }
    }

    func testArchiveCursorRejectsCompleteSyntaxAndInvalidCalendarBeforePublishing() async {
        let bad = ["2026-11-02T11:22:33Zgarbage", "2026-02-30T11:22:33Z", "2025-02-29T11:22:33Z",
                   "2026-04-31T11:22:33Z", "2026-00-02T11:22:33Z", "2026-11-00T11:22:33Z",
                   "2026-11-02T24:00:00Z", "2026-11-02T11:22:33.Z", "2026-11-02T11:22:33",
                   "2026-11-02T11:22:33+24:00", "2026-11-02T11:22:33+00:60", "2026-11-02T11:22:33Z ",
                   " 2026-11-02T11:22:33Z", "0000-11-02T11:22:33Z"]
        for value in bad {
            for initial in [true,false] {
                let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
                await archived(owner,store:store) { before in
                    if !initial && before == nil { return ArchivedThreadPage(threads:[self.thread(101,timestamp:"2027-01-01T00:00:00Z")],hasMore:true) }
                    return ArchivedThreadPage(threads:[self.thread(102,timestamp:value)],hasMore:true)
                }.value
                if !initial { await owner.loadMore("threads")?.value }
                XCTAssertNil(store.channel(102),value)
                XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),initial ? [] : [101],value)
                XCTAssertNil(owner.loadMore("threads"),value)
            }
        }
    }

    func testArchiveSubmillisecondPageOrderingRejectsNewerTail() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
        await archived(owner,store:store) { _ in
            ArchivedThreadPage(threads:[self.thread(101,timestamp:"2026-11-02T11:22:33.123455Z"),
                                       self.thread(102,timestamp:"2026-11-02T11:22:33.123456Z")],hasMore:true)
        }.value
        XCTAssertTrue(owner.snapshot(for:"threads").rows.isEmpty)
        XCTAssertNil(store.channel(101)); XCTAssertNil(store.channel(102)); XCTAssertNil(owner.loadMore("threads"))
    }

    func testArchiveEqualFractionalInstantAcrossTimezonesDoesNotAdvance() async {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
        await archived(owner,store:store) { before in
            ArchivedThreadPage(threads:[self.thread(before == nil ? 101 : 102,timestamp:before == nil ?
                "2024-02-29T13:52:33.1234560+02:30" : "2024-02-29T11:22:33.123456Z")],hasMore:true)
        }.value
        await owner.loadMore("threads")?.value
        XCTAssertEqual(owner.snapshot(for:"threads").rows.map(\.id),[101])
        XCTAssertNil(store.channel(102)); XCTAssertNil(owner.loadMore("threads"))
    }

    func testArchiveProjectionReadsCurrentMetadataAfterPageCompletion() async throws {
        for change in ["rename", "move", "delete"] {
            let owner = OtherListState<String,Channel,String>(), store = DiscordStore()
            store.upsert(channel: parent)
            await archived(owner,store:store) { _ in self.archives([102],more:false) }.value
            if change == "delete" {
                store.handle(GatewayDispatch(name:"THREAD_DELETE",data:Data("{\"d\":{\"id\":\"102\"}}".utf8)))
            } else {
                var fresh = thread(102); fresh.name = "new-current-name"
                if change == "move" { fresh.parentID = 999 }
                try gatewayThread(fresh,store:store)
            }
            let shown = OtherListConsumers.archivedRows(owner.snapshot(for:"threads").rows,active:store.threads(in:1),store:store)
            if change == "rename" { XCTAssertEqual(shown.first?.name,"new-current-name") }
            else { XCTAssertTrue(shown.isEmpty) }
        }
    }

    func testArchiveFenceHandlesUnknownDeletionSyncAndUnrelatedChanges() async throws {
        for change in ["unknown-delete", "list-sync", "other-channel"] {
            let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), held = Held<ArchivedThreadPage>()
            store.upsert(channel: parent)
            if change != "unknown-delete" { store.upsert(channel: thread(102)) }
            let task = archived(owner,store:store) { _ in try await held.load() }; await held.started()
            if change == "unknown-delete" {
                store.handle(GatewayDispatch(name:"THREAD_DELETE",data:Data("{\"d\":{\"id\":\"102\"}}".utf8)))
            } else if change == "list-sync" {
                var current = thread(102); current.name = "sync-current"
                struct Sync: Encodable { var guild_id: String; var threads: [Channel] }
                struct Envelope: Encodable { var d: Sync }
                store.handle(GatewayDispatch(name:"THREAD_LIST_SYNC",data:try JSONEncoder().encode(Envelope(d:Sync(guild_id:"10",threads:[current])))))
            } else { try gatewayThread(thread(999),store:store) }
            var response = thread(102); response.name = "http-current"
            held.finish(.success(ArchivedThreadPage(threads:[response],hasMore:false))); await task.value
            if change == "unknown-delete" { XCTAssertNil(store.channel(102)); XCTAssertTrue(owner.snapshot(for:"threads").rows.isEmpty) }
            else { XCTAssertEqual(store.channel(102)?.name,change == "list-sync" ? "sync-current" : "http-current") }
        }
    }

    func testArchiveFenceRetainsMessageArrivalDuringSuspendedPage() async throws {
        let owner = OtherListState<String,Channel,String>(), store = DiscordStore(), held = Held<ArchivedThreadPage>()
        store.upsert(channel: parent)
        var stale = thread(102); stale.lastMessageID = 10; store.upsert(channel: stale)
        let task = archived(owner,store:store) { _ in try await held.load() }; await held.started()
        var arrival = message(999); arrival.channelID = 102
        struct Envelope: Encodable { var d: Message }
        store.handle(GatewayDispatch(name:"MESSAGE_CREATE",data:try JSONEncoder().encode(Envelope(d:arrival))))
        held.finish(.success(ArchivedThreadPage(threads:[stale],hasMore:false))); await task.value
        XCTAssertEqual(store.channel(102)?.lastMessageID,999)
        XCTAssertEqual(owner.snapshot(for:"threads").rows.first?.lastMessageID,999)
    }

    func testArchiveTimestampExactMicrosecondsAndWholeSecondEpochs() throws {
        let later = try XCTUnwrap(OtherListPages.archiveDate("2026-11-02T11:22:33.123456Z"))
        let earlier = try XCTUnwrap(OtherListPages.archiveDate("2026-11-02T11:22:33.123455Z"))
        XCTAssertLessThan(earlier,later)
        XCTAssertEqual(later,OtherListPages.archiveDate("2026-11-02T06:22:33.12345600-05:00"))
        XCTAssertLessThan(try XCTUnwrap(OtherListPages.archiveDate("2026-11-02T11:22:33.123455999999999999Z")),later)
        let formatter = ISO8601DateFormatter()
        for value in ["1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "2000-02-29T00:00:00Z", "1900-03-01T00:00:00Z", "2100-03-01T00:00:00Z", "2024-02-29T23:59:59+05:30", "9999-12-31T23:59:59Z"] {
            let parsed = try XCTUnwrap(OtherListPages.archiveDate(value))
            let expected = try XCTUnwrap(formatter.date(from:value))
            XCTAssertEqual(parsed.seconds,Int64(expected.timeIntervalSince1970),value)
        }
    }

}
