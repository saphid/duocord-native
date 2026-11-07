import Foundation

/// Certainty belongs to this attempt, not to an error category or a nonce.
/// A nonce is retained for correlation; server-side deduplication is not assumed.
nonisolated enum SendFailureOutcome: Sendable {
    case notDispatched, refused, unknown
}

nonisolated final class SendAttempt: @unchecked Sendable {
    let deadline: ContinuousClock.Instant
    private let authority: @Sendable () async -> Bool
    private let lock = NSLock()
    private var dispatched = false

    init(timeout: Duration = .seconds(45), authority: @escaping @Sendable () async -> Bool = { true }) {
        deadline = .now + timeout
        self.authority = authority
    }

    func check() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        guard await authority() else { throw CancellationError() }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
    }

    /// Called immediately before handing the final message POST to URLSession.
    /// After that boundary even cancellation/decoding failure is uncertain.
    func markDispatched() { lock.withLock { dispatched = true } }

    func outcome(for error: Error) -> SendFailureOutcome {
        guard lock.withLock({ dispatched }) else { return .notDispatched }
        if let error = error as? DiscordError, let status = error.httpStatus, (400..<500).contains(status) {
            return .refused
        }
        // URL Loading System can establish that no connection was made even
        // after handoff. Lost responses, timeouts and cancellation cannot.
        if let error = error as? URLError, !DiscordError.mayHaveApplied(error) {
            return .notDispatched
        }
        return .unknown
    }

    /// One clock covers queue admission, reservations, uploads and HTTP. The
    /// losing child is cancelled and joined; URLSession/sleeps honor cancellation.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await self.check(); return try await operation() }
            group.addTask {
                try await Task.sleep(until: self.deadline, clock: .continuous)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
