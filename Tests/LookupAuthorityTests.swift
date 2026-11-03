import XCTest
@testable import DuocordNative

/// Exercises the same state owner the real SearchView/PinsView use. These are
/// offline production-state tests, not mounted SwiftUI or device interaction.
@MainActor
final class LookupAuthorityTests: XCTestCase {
    private final class Live<Input> {
        var input: Input?
        init(_ input: Input?) { self.input = input }
    }
    /// Intentionally ignores Task cancellation. Starting and completing each
    /// request are explicit continuation handshakes; no timing sleeps or URLs.
    private final class Held<Value> {
        var response: CheckedContinuation<Value, Error>?
        var arrival: CheckedContinuation<Void, Never>?
        func load() async throws -> Value {
            try await withCheckedThrowingContinuation {
                response = $0
                arrival?.resume(); arrival = nil
            }
        }
        func started() async {
            if response != nil { return }
            await withCheckedContinuation { arrival = $0 }
        }
        func finish(_ result: Result<Value, Error>) {
            response!.resume(with: result); response = nil
        }
    }
    private func message(_ id: UInt64, channel: Snowflake = 1) -> Message {
        Message(id: Snowflake(id), channelID: channel, guildID: nil,
                author: User(id: Snowflake(id + 100), username: "author\(id)"),
                content: "offline \(id)", timestamp: "")
    }
    private func search(_ model: AppModel, _ store: DiscordStore, query: String = "A", channel: Snowflake? = nil,
                        scope: String = "Server A") -> SearchSubmission {
        SearchSubmission(context: LookupContext(model: model, store: store), query: query,
                         guild: model.selectedGuild, channel: channel, scopeName: scope)
    }
    private func pins(_ model: AppModel, _ store: DiscordStore, channel: Snowflake = 1) -> PinsSubmission {
        PinsSubmission(context: LookupContext(model: model, store: store), channel: channel)
    }
    private func begin<I: Equatable, V>(_ owner: LookupRequestState<I, V>, _ input: I, _ live: Live<I>,
                                        _ held: Held<V>, publish: @escaping (V) -> Void = { _ in }) -> Task<Void, Never> {
        owner.start(input, load: { try await held.load() }, isCurrent: { live.input == input }, publish: publish)
    }

    private func searchRace(oldFails: Bool, newFails: Bool) async {
        let store = DiscordStore(), model = AppModel()
        let owner = LookupRequestState<SearchSubmission, SearchResult>()
        let a = search(model, store), b = search(model, store, query: "B", channel: 2, scope: "#B")
        let live = Live(a), old = Held<SearchResult>(), fresh = Held<SearchResult>()
        let oldTask = begin(owner, a, live, old) { store.remember(messageAuthors: $0.messages) }
        await old.started()
        live.input = b
        let newTask = begin(owner, b, live, fresh) { store.remember(messageAuthors: $0.messages) }
        await fresh.started()
        XCTAssertEqual(owner.snapshot(for: b).status, .loading)
        XCTAssertNil(owner.snapshot(for: b).value)
        fresh.finish(newFails ? .failure(URLError(.cannotConnectToHost)) : .success(SearchResult(totalResults: 42, messages: [message(2)])))
        await newTask.value
        let acceptedStatus = owner.snapshot(for: b).status
        old.finish(oldFails ? .failure(URLError(.timedOut)) : .success(SearchResult(totalResults: 999, messages: [message(1)])))
        await oldTask.value
        let snapshot = owner.snapshot(for: b)
        XCTAssertEqual(snapshot.input, b, "The accepted query and captured scope own the result")
        XCTAssertEqual(snapshot.status, acceptedStatus, "Old success/failure must not replace current status")
        XCTAssertEqual(snapshot.value?.messages.map(\.id), newFails ? nil : [2])
        XCTAssertEqual(snapshot.value?.totalResults, newFails ? nil : 42)
        XCTAssertNil(store.users[101], "Obsolete authors must never reach the cache")
        XCTAssertEqual(store.users[102]?.id, newFails ? nil : 102)
    }
    func testSearchOldSuccessAfterCurrentSuccess() async { await searchRace(oldFails: false, newFails: false) }
    func testSearchOldFailureAfterCurrentSuccess() async { await searchRace(oldFails: true, newFails: false) }
    func testSearchOldSuccessAfterCurrentFailure() async { await searchRace(oldFails: false, newFails: true) }
    func testSearchOldFailureAfterCurrentFailure() async { await searchRace(oldFails: true, newFails: true) }

    private func invalidatedSearch(_ change: String, fails: Bool = false) async {
        let store = DiscordStore(), model = AppModel()
        model.selectedGuild = 10; model.selectedChannel = 1
        let owner = LookupRequestState<SearchSubmission, SearchResult>()
        let a = search(model, store), live = Live(a), held = Held<SearchResult>()
        let task = begin(owner, a, live, held) { store.remember(messageAuthors: $0.messages) }
        await held.started()
        switch change {
        case "scope": live.input = search(model, store, channel: 1, scope: "#A")
        case "server": model.selectedGuild = 20; live.input = search(model, store, scope: "Server B")
        case "channel": model.selectedChannel = 2; live.input = search(model, store)
        case "session": store.reset(); live.input = search(model, store)
        case "draft": live.input = search(model, store, query: "unfinished edit")
        default: live.input = nil
        }
        // Real views also use this projection before an asynchronous SwiftUI
        // change callback runs. A mismatch may never expose the former rows.
        XCTAssertEqual(owner.snapshot(for: live.input).status, .idle)
        owner.invalidate(unless: live.input)
        held.finish(fails ? .failure(URLError(.timedOut)) : .success(SearchResult(totalResults: 1, messages: [message(1)])))
        await task.value
        XCTAssertNil(owner.snapshot(for: live.input).value)
        XCTAssertEqual(owner.snapshot(for: live.input).status, .idle)
        XCTAssertNil(store.users[101])
    }
    func testSearchClearedQueryRejectsHeldSuccess() async { await invalidatedSearch("clear") }
    func testSearchClearedQueryRejectsHeldFailure() async { await invalidatedSearch("clear", fails: true) }
    func testSearchDraftEditSuppressesPreviousSubmission() async { await invalidatedSearch("draft") }
    func testSearchScopeChangeSuppressesPreviousSubmission() async { await invalidatedSearch("scope") }
    func testSearchServerChangeRejectsHeldSuccess() async { await invalidatedSearch("server") }
    func testSearchChannelChangeRejectsHeldFailure() async { await invalidatedSearch("channel", fails: true) }
    func testSearchCloseRejectsHeldSuccess() async { await invalidatedSearch("close") }
    func testSearchSessionReplacementRejectsHeldSuccessAndCache() async { await invalidatedSearch("session") }
    func testSearchSessionReplacementRejectsHeldFailure() async { await invalidatedSearch("session", fails: true) }

    private func pinsRace(oldFails: Bool, newFails: Bool, sameChannel: Bool = false) async {
        let store = DiscordStore(), model = AppModel()
        model.selectedChannel = 1
        let owner = LookupRequestState<PinsSubmission, [Message]>()
        let a = pins(model, store), live = Live(a), old = Held<[Message]>(), fresh = Held<[Message]>()
        let oldTask = begin(owner, a, live, old) { store.remember(messageAuthors: $0) }
        await old.started()
        if !sameChannel { model.selectedChannel = 2; model.selectedGuild = 20 }
        let b = pins(model, store, channel: sameChannel ? 1 : 2)
        live.input = b
        let newTask = begin(owner, b, live, fresh) { store.remember(messageAuthors: $0) }
        await fresh.started()
        fresh.finish(newFails ? .failure(URLError(.cannotConnectToHost)) : .success([message(2, channel: b.channel)]))
        await newTask.value
        let status = owner.snapshot(for: b).status
        old.finish(oldFails ? .failure(URLError(.timedOut)) : .success([message(1)]))
        await oldTask.value
        XCTAssertEqual(owner.snapshot(for: b).input, b)
        XCTAssertEqual(owner.snapshot(for: b).value?.map(\.id), newFails ? nil : [2])
        XCTAssertEqual(owner.snapshot(for: b).status, status)
        XCTAssertNil(store.users[101])
    }
    func testPinsChannelAOldSuccessAfterBSuccess() async { await pinsRace(oldFails: false, newFails: false) }
    func testPinsChannelAOldFailureAfterBSuccess() async { await pinsRace(oldFails: true, newFails: false) }
    func testPinsChannelAOldSuccessAfterBFailure() async { await pinsRace(oldFails: false, newFails: true) }
    func testPinsChannelAOldFailureAfterBFailure() async { await pinsRace(oldFails: true, newFails: true) }
    func testPinsSameChannelReloadRejectsOldSuccess() async { await pinsRace(oldFails: false, newFails: false, sameChannel: true) }
    func testPinsSameChannelReloadRejectsOldFailure() async { await pinsRace(oldFails: true, newFails: false, sameChannel: true) }

    func testPinsSelectionProjectionSuppressesLoadedAImmediately() async {
        let model = AppModel(), store = DiscordStore()
        model.selectedChannel = 1
        let owner = LookupRequestState<PinsSubmission, [Message]>()
        let a = pins(model, store), live = Live(a), held = Held<[Message]>()
        let task = begin(owner, a, live, held)
        await held.started(); held.finish(.success([message(1)])); await task.value
        model.selectedChannel = 2; model.selectedGuild = 20
        let b = pins(model, store, channel: 2)
        // No invalidation/change callback has run yet.
        XCTAssertNil(owner.snapshot(for: b).value)
        XCTAssertEqual(owner.snapshot(for: b).status, .idle)
        XCTAssertNil(owner.snapshot(for: nil).value)
    }

    private func closedPins(fails: Bool, replaceSession: Bool = false, reopen: Bool = false) async {
        let model = AppModel(), store = DiscordStore()
        let owner = LookupRequestState<PinsSubmission, [Message]>()
        let a = pins(model, store), live = Live(a), held = Held<[Message]>()
        let task = begin(owner, a, live, held) { store.remember(messageAuthors: $0) }
        await held.started()
        if replaceSession { store.reset(); live.input = pins(model, store) } else { live.input = nil }
        owner.invalidate()
        if reopen {
            live.input = a
            let fresh = Held<[Message]>()
            let freshTask = begin(owner, a, live, fresh) { store.remember(messageAuthors: $0) }
            await fresh.started(); fresh.finish(.success([message(2)])); await freshTask.value
        }
        held.finish(fails ? .failure(URLError(.timedOut)) : .success([message(1)])); await task.value
        XCTAssertEqual(owner.snapshot(for: live.input).value?.map(\.id), reopen ? [2] : nil)
        if !reopen { XCTAssertEqual(owner.snapshot(for: live.input).status, .idle) }
        XCTAssertNil(store.users[101])
    }
    func testPinsCloseRejectsHeldSuccess() async { await closedPins(fails: false) }
    func testPinsEmptySelectionRejectsHeldFailure() async { await closedPins(fails: true) }
    func testPinsSessionReplacementRejectsHeldSuccessAndCache() async { await closedPins(fails: false, replaceSession: true) }
    func testPinsSessionReplacementRejectsHeldFailure() async { await closedPins(fails: true, replaceSession: true) }
    func testPinsReopenSameChannelRejectsPreviousOpening() async { await closedPins(fails: false, reopen: true) }

    func testExplicitCancellationIgnoringLoadCannotPublish() async {
        let model = AppModel(), store = DiscordStore()
        let owner = LookupRequestState<PinsSubmission, [Message]>()
        let input = pins(model, store), live = Live(input), held = Held<[Message]>()
        var publications = 0
        let task = begin(owner, input, live, held) { _ in publications += 1 }
        await held.started(); task.cancel()
        held.finish(.success([message(1)])); await task.value
        XCTAssertEqual(publications, 0)
        XCTAssertNil(owner.snapshot(for: input).value)
        XCTAssertEqual(owner.snapshot(for: input).status, .idle)
    }

    func testCurrentSearchFailureThenSuccessClearsErrorAndPublishesCache() async {
        let model = AppModel(), store = DiscordStore()
        let owner = LookupRequestState<SearchSubmission, SearchResult>()
        let input = search(model, store), live = Live(input)
        let fail = Held<SearchResult>(), success = Held<SearchResult>()
        let first = begin(owner, input, live, fail)
        await fail.started(); fail.finish(.failure(URLError(.timedOut))); await first.value
        guard case .failed = owner.snapshot(for: input).status else { return XCTFail("Current failure must be visible") }
        let second = begin(owner, input, live, success) { store.remember(messageAuthors: $0.messages) }
        await success.started()
        XCTAssertEqual(owner.snapshot(for: input).status, .loading)
        success.finish(.success(SearchResult(totalResults: 7, messages: [message(2)]))); await second.value
        XCTAssertEqual(owner.snapshot(for: input).status, .done)
        XCTAssertEqual(owner.snapshot(for: input).value?.totalResults, 7)
        XCTAssertEqual(store.users[102]?.id, 102)
        owner.invalidate(unless: input)
        XCTAssertEqual(owner.snapshot(for: input).status, .done, "A delayed callback for the accepted input must not clear it")
    }
    func testCurrentPinsFailureThenEmptySuccessRecovers() async {
        let model = AppModel(), store = DiscordStore()
        let owner = LookupRequestState<PinsSubmission, [Message]>()
        let input = pins(model, store), live = Live(input)
        let fail = Held<[Message]>(), success = Held<[Message]>()
        let first = begin(owner, input, live, fail)
        await fail.started(); fail.finish(.failure(URLError(.timedOut))); await first.value
        guard case .failed = owner.snapshot(for: input).status else { return XCTFail("Current failure must be visible") }
        let second = begin(owner, input, live, success)
        await success.started(); success.finish(.success([])); await second.value
        XCTAssertEqual(owner.snapshot(for: input).status, .done)
        XCTAssertEqual(owner.snapshot(for: input).value?.count, 0)
    }
    func testContextChangesOnRealStoreResetAndChannelVisit() {
        let model = AppModel(), store = DiscordStore()
        model.selectedChannel = 1
        let before = LookupContext(model: model, store: store)
        model.selectedChannel = 2; model.selectedChannel = 1
        XCTAssertNotEqual(LookupContext(model: model, store: store), before)
        let visit = LookupContext(model: model, store: store)
        store.reset()
        XCTAssertNotEqual(LookupContext(model: model, store: store), visit)
    }
}
