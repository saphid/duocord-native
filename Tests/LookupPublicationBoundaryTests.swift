import XCTest
@testable import DuocordNative

/// Additional publication-boundary checks. No change callback or cancellation
/// runs before the held completion: the live context check must do the work.
@MainActor
final class LookupPublicationBoundaryTests: XCTestCase {
    private final class Held<Value> {
        var response: CheckedContinuation<Value, Error>?
        var arrival: CheckedContinuation<Void, Never>?
        func load() async throws -> Value {
            try await withCheckedThrowingContinuation {
                response = $0; arrival?.resume(); arrival = nil
            }
        }
        func started() async {
            if response != nil { return }
            await withCheckedContinuation { arrival = $0 }
        }
        func finish(_ result: Result<Value, Error>) { response!.resume(with: result); response = nil }
    }
    private func message(_ id: UInt64) -> Message {
        Message(id: Snowflake(id), channelID: 1, guildID: nil,
                author: User(id: Snowflake(id + 100), username: "offline"), content: "fixture", timestamp: "")
    }
    private func boundary(pins: Bool, failure: Bool, change: String) async {
        let model = AppModel(), store = DiscordStore()
        model.selectedChannel = 1; model.selectedGuild = 10
        let context = LookupContext(model: model, store: store)
        // Both surfaces use this same owner. A context-only input makes the
        // pre-callback authority check explicit without any draft mutations.
        let owner = LookupRequestState<LookupContext, [Message]>()
        let held = Held<[Message]>()
        var presented = true
        let task = owner.start(context, load: { try await held.load() }, isCurrent: {
            presented && LookupContext(model: model, store: store) == context
        }, publish: { store.remember(messageAuthors: $0) })
        await held.started()
        switch change {
        case "session": store.reset()
        case "close": presented = false
        default: model.selectedChannel = 2; model.selectedGuild = 20
        }
        // Deliberately no owner.invalidate() and no replacement start().
        held.finish(failure ? .failure(URLError(.timedOut)) : .success([message(1)]))
        await task.value
        XCTAssertEqual(owner.snapshot(for: context).status, .idle, pins ? "Pins" : "Search")
        XCTAssertNil(owner.snapshot(for: context).value)
        XCTAssertNil(store.users[101], "The old session must not repopulate the store before onChange/onDisappear")
    }
    func testSearchLiveSessionCheckBeforeInvalidationRejectsSuccess() async { await boundary(pins: false, failure: false, change: "session") }
    func testSearchLiveSessionCheckBeforeInvalidationRejectsFailure() async { await boundary(pins: false, failure: true, change: "session") }
    func testSearchLiveCloseCheckBeforeDisappearanceRejectsSuccess() async { await boundary(pins: false, failure: false, change: "close") }
    func testPinsLiveNavigationCheckBeforeTaskRestartRejectsSuccess() async { await boundary(pins: true, failure: false, change: "navigation") }
    func testPinsLiveNavigationCheckBeforeTaskRestartRejectsFailure() async { await boundary(pins: true, failure: true, change: "navigation") }
    func testPinsLiveSessionCheckBeforeTaskRestartRejectsSuccess() async { await boundary(pins: true, failure: false, change: "session") }

    private func oldWhileLoading(failure: Bool, pins: Bool) async {
        let owner = LookupRequestState<String, [Message]>()
        let old = Held<[Message]>(), fresh = Held<[Message]>()
        var live = "A", published: [Snowflake] = []
        let a = owner.start("A", load: { try await old.load() }, isCurrent: { live == "A" },
                            publish: { published += $0.map(\.id) })
        await old.started()
        live = "B"
        let b = owner.start("B", load: { try await fresh.load() }, isCurrent: { live == "B" },
                            publish: { published += $0.map(\.id) })
        await fresh.started()
        old.finish(failure ? .failure(URLError(.timedOut)) : .success([message(1)])); await a.value
        XCTAssertEqual(owner.snapshot(for: "B").status, .loading, pins ? "Pins" : "Search")
        XCTAssertNil(owner.snapshot(for: "B").value)
        XCTAssertTrue(published.isEmpty)
        fresh.finish(.success([message(2)])); await b.value
        XCTAssertEqual(owner.snapshot(for: "B").status, .done)
        XCTAssertEqual(published, [2])
    }
    func testSearchOldSuccessCannotEndCurrentLoading() async { await oldWhileLoading(failure: false, pins: false) }
    func testSearchOldFailureCannotEndCurrentLoading() async { await oldWhileLoading(failure: true, pins: false) }
    func testPinsOldSuccessCannotEndCurrentLoading() async { await oldWhileLoading(failure: false, pins: true) }
    func testPinsOldFailureCannotEndCurrentLoading() async { await oldWhileLoading(failure: true, pins: true) }
}
