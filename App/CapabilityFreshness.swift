import Foundation
import Observation

/// Kept in memory for this action; never logged. Features alone are insufficient
/// diagnostic context for a refusal of a retained retry or queued edit.
struct OperationContext {
    var operation: DiscordOperation
    var channel: Snowflake
    var message: Snowflake? = nil
    var author: Snowflake? = nil
    var text: String? = nil
    var reply: Snowflake? = nil
    var ping: Bool? = nil
    var files: [OutgoingAttachment] = []
    var emoji: Emoji? = nil
    var nonce: String? = nil
}

struct OperationRefusal {
    enum Freshness: String { case refreshed, incomplete, expired, obsolete, unnecessary }
    let original: DiscordError
    let context: OperationContext
    let freshness: Freshness
    let decision: CapabilityDecision?
    /// Full reevaluation retains unknown facts and account hypotheses for diagnostics.
    var evaluation: CapabilityDecision? = nil
    var scope: OperationFacts.Scope? = nil
    var facts: DiscordStore.FactSnapshot? = nil
    /// Safe projection for inspection. The original error and retained payload
    /// remain available in this in-memory refusal, never in this metadata.
    var diagnostic: OperationDiagnostic {
        OperationDiagnostic(request: DiscordRequestDiagnostic(
            endpoint: context.operation.endpoint(channel: ChannelID(context.channel.raw),
                message: MessageID(context.message?.raw ?? 0), emoji: context.emoji?.reactionKey ?? ""),
            status: original.httpStatus, code: original.apiCode,
            outcome: original.httpStatus.map { (400..<500).contains($0) } == true ? .refused : .unknown, source: .operationError),
            freshness: freshness, attribution: decision?.provenance ?? [])
    }
    var explanation: String {
        if let decision, decision.state == .denied, let text = decision.explanation(at: Date()) { return text }
        if original.isPermissionRefusal(for: context.operation) {
            return "Discord refused this action. Refresh eligibility, check your access, then try again."
        }
        return original.localizedDescription
    }
}

struct OperationDiagnostic {
    let request: DiscordRequestDiagnostic
    let freshness: OperationRefusal.Freshness
    let attribution: [CapabilityProvenance]
}

extension DiscordError {
    var apiCode: Int? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }

    func isPermissionRefusal(for operation: DiscordOperation) -> Bool {
        guard case .api(let status, let code, _) = self, (400..<500).contains(status) else { return false }
        if code == 50001 || code == 50013 { return true }
        if case .send(let payload) = operation, payload.isReply, code == 160002 { return true }
        switch operation {
        case .send, .editMessage, .deleteMessage, .addReaction, .addExistingReaction, .removeOwnReaction,
             .pinMessage, .unpinMessage, .thread:
            return code == 50083 || code == 160005
        default: return false
        }
    }
}

/// One coordinator over the existing store, with exact account/login/epoch and
/// entity keys. No write is reachable from this read-only path.
@Observable
final class CapabilityFreshness {
    struct Key: Hashable { let scope: OperationFacts.Scope; let entity: String; let id: Snowflake }
    private var refreshes: [Key: Task<OperationRefusal.Freshness, Never>] = [:]
    @ObservationIgnored private var reads: [Key: Task<Bool, Never>] = [:]
    private(set) var lastRefusal: OperationRefusal?
    @ObservationIgnored private var feedbackToken = UUID()

    func begin(_ key: String) -> UUID { feedbackToken = UUID(); return feedbackToken }
    func isLatest(_ key: String, _ token: UUID) -> Bool { feedbackToken == token }
    func reset() {
        for task in refreshes.values { task.cancel() }
        for task in reads.values { task.cancel() }
        refreshes = [:]; reads = [:]; lastRefusal = nil; feedbackToken = UUID()
    }
    func record(_ refusal: OperationRefusal) { lastRefusal = refusal }
    func isRefreshing(channel: Snowflake, scope: OperationFacts.Scope?) -> Bool {
        guard let scope else { return false }
        return refreshes[Key(scope: scope, entity: "refresh", id: channel)] != nil
    }

    func refresh(channel: Snowflake, model: AppModel, until outerDeadline: ContinuousClock.Instant? = nil) async -> OperationRefusal.Freshness {
        guard let scope = model.operationScope else { return .obsolete }
        let key = Key(scope: scope, entity: "refresh", id: channel)
        let deadline = min(outerDeadline ?? .now + model.capabilityRefreshTimeout, .now + model.capabilityRefreshTimeout)
        if let pending = refreshes[key] { return await FreshnessWait.value(pending, until: deadline) ?? .expired }
        // Captured before root discovery: a parent event while that GET is held
        // must also fence the subsequently discovered parent's REST result.
        let snapshot = model.store.factSnapshot()
        let task = Task { [weak model] () -> OperationRefusal.Freshness in
            defer { self.refreshes[key] = nil }
            guard let model else { return .obsolete }
            let attempt = SendAttempt(timeout: ContinuousClock.now.duration(to: deadline)) { @MainActor [weak model] in model?.operationScope == scope }
            do {
                let complete = try await attempt.run { @MainActor in
                    var complete = await self.read(.init(scope: scope, entity: "channel", id: channel), deadline: deadline, model: model, snapshot: snapshot)
                    guard model.operationScope == scope, let current = model.store.channel(channel) else { return false }
                    if current.type.isPrivate { return complete }
                    if current.type.isThread, let parent = current.parentID {
                        complete = await self.read(.init(scope: scope, entity: "channel", id: parent), deadline: deadline, model: model, snapshot: snapshot) && complete
                    }
                    guard let guild = model.store.channel(channel)?.guildID else { return false }
                    // All three are relevant to operation permissions and timeout.
                    // Serial admission bounds work; shared entity tasks coalesce
                    // sibling-channel refreshes without a guild-wide channel scan.
                    for entity in ["guild", "roles", "member"] {
                        complete = await self.read(.init(scope: scope, entity: entity, id: guild), deadline: deadline, model: model) && complete
                    }
                    if current.type == .privateThread {
                        complete = await self.read(.init(scope: scope, entity: "membership", id: channel), deadline: deadline, model: model) && complete
                    }
                    return complete
                }
                guard model.operationScope == scope else { return .obsolete }
                guard ContinuousClock.now < deadline else { return .expired }
                return complete ? .refreshed : .incomplete
            } catch {
                if model.operationScope != scope { return .obsolete }
                return ContinuousClock.now >= deadline ? .expired : .incomplete
            }
        }
        refreshes[key] = task
        return await FreshnessWait.value(task, until: deadline) ?? .expired
    }

    private func read(_ key: Key, deadline: ContinuousClock.Instant, model: AppModel,
                      snapshot earlier: DiscordStore.FactSnapshot? = nil) async -> Bool {
        guard model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
        if let pending = reads[key] { return await FreshnessWait.value(pending, until: deadline) ?? false }
        let snapshot = earlier ?? model.store.factSnapshot()
        let api = model.api, store = model.store
        let task = Task { () -> Bool in
            defer { self.reads[key] = nil }
            let attempt = SendAttempt(timeout: ContinuousClock.now.duration(to: deadline)) { @MainActor in model.operationScope == key.scope }
            do {
                return try await attempt.run { @MainActor in
                    switch key.entity {
                    case "channel":
                        let value = try await api.channel(key.id)
                        guard value.id == key.id, model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                        store.commitFactChannel(value, snapshot: snapshot)
                    case "guild":
                        let value = try await api.guild(key.id)
                        guard value.id == key.id, model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                        store.commitFactGuild(value, snapshot: snapshot)
                    case "roles":
                        let value = try await api.guildRoles(key.id)
                        guard model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                        store.commitFactRoles(value, guild: key.id, snapshot: snapshot)
                    case "member":
                        let value = try await api.guildMember(key.scope.account, in: key.id)
                        guard value.userID == key.scope.account, model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                        store.commitFactMember(value, guild: key.id, snapshot: snapshot)
                    case "membership":
                        do {
                            let value = try await api.ownThreadMember(key.id, account: key.scope.account)
                            guard model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                            store.commitFactMembership(value, thread: key.id, snapshot: snapshot)
                        } catch DiscordError.api(404, 10007, _) {
                            guard model.operationScope == key.scope, ContinuousClock.now < deadline else { return false }
                            store.commitFactAbsentMembership(thread: key.id, snapshot: snapshot)
                        }
                    default: return false
                    }
                    return true
                }
            } catch { return false }
        }
        reads[key] = task
        return await FreshnessWait.value(task, until: deadline) ?? false
    }
}

/// Per UI intent. The state machine awaits attribution while still retaining
/// gateway confirmation state, then decides whether this failure is publishable.
final class OperationFeedback {
    let context: OperationContext
    let scope: OperationFacts.Scope?
    let navigation: UUID
    let key: String
    let token: UUID
    let toast: UUID?
    var refusal: OperationRefusal?
    init(_ context: OperationContext, model: AppModel) {
        self.context = context; scope = model.operationScope; navigation = model.navigationIntent
        key = "\(context.channel):\(context.message ?? 0):\(context.operation.routeTemplate)"
        token = model.capabilityFreshness.begin(key); toast = model.toast?.token
    }
    func capture(_ error: Error, model: AppModel, operation: DiscordOperation? = nil) async {
        guard !(error is CapabilityPreflightRefusal), model.operationScope == scope else { return }
        var context = context
        if let operation { context.operation = operation }
        refusal = await model.attributeRefusal(error, context: context)
    }
    func publish(_ fallback: String, model: AppModel) {
        guard !Task.isCancelled, model.operationScope == scope, model.navigationIntent == navigation,
              model.capabilityFreshness.isLatest(key, token), model.toast?.token == toast else { return }
        if let refusal { model.capabilityFreshness.record(refusal) }
        model.showError(refusal?.explanation ?? fallback)
    }
}

extension AppModel {
    func attributeRefusal(_ error: Error, context: OperationContext, until deadline: ContinuousClock.Instant? = nil) async -> OperationRefusal? {
        guard let original = error as? DiscordError else { return nil }
        let scope = operationScope
        guard original.isPermissionRefusal(for: context.operation) else {
            return OperationRefusal(original: original, context: context, freshness: .unnecessary, decision: nil, scope: scope)
        }
        let freshness = await capabilityFreshness.refresh(channel: context.channel, model: self, until: deadline)
        guard operationScope == scope else { return nil }
        var decision: CapabilityDecision?
        var evaluation: CapabilityDecision?
        if freshness == .refreshed {
            let current = operationDecision(context.operation, in: context.channel, messageAuthorID: context.author)
            evaluation = current
            // Missing facts/hypotheses and unrelated cached denials cannot explain
            // the server's response. Raw code alone never supplies a missing bit.
            let provenReasons = current.reasons.filter {
                switch $0 {
                case .missing, .accountValidationRequired: return false
                default: return true
                }
            }
            if current.state == .denied, !provenReasons.isEmpty {
                decision = CapabilityDecision(state: .denied, reasons: provenReasons,
                    provenance: current.provenance.filter { $0 != .cachedFacts && $0 != .accountHypothesis } + [.refreshedFacts])
            }
        }
        return OperationRefusal(original: original, context: context, freshness: freshness, decision: decision, evaluation: evaluation, scope: scope, facts: evaluation == nil ? nil : store.factSnapshot())
    }

    @discardableResult
    func refreshEligibility(in channel: Snowflake) -> Task<Void, Never> {
        let context = OperationContext(operation: draftOperation(drafts[channel] ?? Draft(), in: channel), channel: channel)
        let feedback = OperationFeedback(context, model: self)
        return Task {
            let result = await capabilityFreshness.refresh(channel: channel, model: self)
            guard result != .obsolete, !Task.isCancelled else { return }
            if result != .refreshed { feedback.publish("Couldn’t refresh eligibility. Check your connection and try again.", model: self) }
            // A successful recheck only updates facts. Sending is a separate tap.
        }
    }
}

/// Joining a shared read never extends this caller's total budget. Cancellation
/// ends only the waiter; other callers still own the coalesced read. Entity
/// commits also check their own deadline so cancelled/late work cannot publish.
@MainActor
private final class FreshnessWait<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    private var finished = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private func finish(_ value: T?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: value); continuation = nil
        worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
    }
    static func value(_ task: Task<T, Never>, until deadline: ContinuousClock.Instant) async -> T? {
        let waiter = FreshnessWait<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !waiter.finished else { continuation.resume(returning: nil); return }
                waiter.continuation = continuation
                guard !Task.isCancelled, ContinuousClock.now < deadline else { waiter.finish(nil); return }
                waiter.worker = Task { waiter.finish(await task.value) }
                waiter.timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous); waiter.finish(nil) } catch { }
                }
            }
        } onCancel: { Task { @MainActor in waiter.finish(nil) } }
    }
}
