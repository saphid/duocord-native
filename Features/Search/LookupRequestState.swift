import Foundation
import Observation

/// Captures navigation and the store's existing reset epoch without changing
/// session, navigation, or transport authority elsewhere in the app.
struct LookupContext: Equatable {
    let session: UUID
    let account: Snowflake?
    let selectedGuild: Snowflake?
    let selectedChannel: Snowflake?
    let visit: UUID

    init(model: AppModel, store: DiscordStore) {
        session = store.readEpoch
        account = store.me?.id
        selectedGuild = model.selectedGuild
        selectedChannel = model.selectedChannel
        visit = model.conversationVisit
    }
}

struct SearchSubmission: Equatable {
    let context: LookupContext
    let query: String
    let guild: Snowflake?
    let channel: Snowflake?
    let scopeName: String
}

struct PinsSubmission: Equatable {
    let context: LookupContext
    let channel: Snowflake
    /// The channel's CHANNEL_PINS_UPDATE revision: a pin change anywhere is a new submission.
    var revision = 0

    static func current(model: AppModel, store: DiscordStore, channel: Snowflake) -> PinsSubmission {
        PinsSubmission(context: LookupContext(model: model, store: store), channel: channel, revision: store.pinsRevision(for: channel))
    }
}

/// The production owner used by both lookup surfaces. Async closures provide
/// the existing API seam; tests can hold responses without opening a session.
@MainActor @Observable
final class LookupRequestState<Input: Equatable, Value> {
    enum Status: Equatable { case idle, loading, done, failed(String) }
    struct Snapshot {
        var input: Input?
        var value: Value?
        var status: Status = .idle
    }
    private var current = Snapshot()
    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private var generation = UUID()

    /// Suppress an obsolete snapshot synchronously, before a SwiftUI change
    /// callback or replacement task has had a chance to run.
    func snapshot(for input: Input?) -> Snapshot {
        guard let input, input == current.input else { return Snapshot() }
        return current
    }

    func invalidate(unless input: Input? = nil) {
        if let input, current.input == input { return }
        generation = UUID()
        task?.cancel()
        task = nil
        current = Snapshot()
    }

    @discardableResult
    func start(_ input: Input, load: @escaping @MainActor () async throws -> Value,
               isCurrent: @escaping @MainActor () -> Bool,
               publish: @escaping @MainActor (Value) -> Void = { _ in }) -> Task<Void, Never> {
        // Even an identical resubmission/reload owns a new generation.
        invalidate()
        let accepted = generation
        current = Snapshot(input: input, status: .loading)
        let task = Task { @MainActor in
            guard accepts(accepted, isCurrent: isCurrent) else { return }
            do {
                let value = try await load()
                guard accepts(accepted, isCurrent: isCurrent) else { return }
                // Validation and all publication share one MainActor turn.
                // Cancellation is an optimization; identity is the authority.
                publish(value)
                current = Snapshot(input: input, value: value, status: .done)
                self.task = nil
            } catch {
                guard accepts(accepted, isCurrent: isCurrent) else { return }
                current = Snapshot(input: input, status: .failed(error.localizedDescription))
                self.task = nil
            }
        }
        self.task = task
        return task
    }

    private func accepts(_ accepted: UUID, isCurrent: () -> Bool) -> Bool {
        guard generation == accepted else { return false }
        guard !Task.isCancelled, isCurrent() else {
            invalidate()
            return false
        }
        return true
    }
}
