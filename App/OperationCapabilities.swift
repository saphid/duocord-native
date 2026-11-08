import Foundation
import Observation

/// Confirmed sends only. The namespace fences old login/store completions and
/// exact-channel timing; neither latest-message IDs nor history absence qualify.
@Observable
final class OperationFacts {
    struct Scope: Equatable, Hashable {
        let account: Snowflake
        let login: UUID
        let epoch: UUID
    }
    private var scope: Scope?
    private var confirmedSends: [Snowflake: Date] = [:]

    func history(in channel: Snowflake, scope: Scope) -> SlowmodeHistory {
        guard self.scope == scope, let date = confirmedSends[channel] else { return .unknown }
        return .lastConfirmedSend(date)
    }
    func confirmed(in channel: Snowflake, at date: Date, scope: Scope) {
        if self.scope != scope { self.scope = scope; confirmedSends = [:] }
        confirmedSends[channel] = max(confirmedSends[channel] ?? .distantPast, date)
    }
}

struct ComposerCapability {
    let decision: CapabilityDecision
    let canSubmit: Bool
    let canAttachFiles: Bool
    let explanation: String?
    var canRefresh: Bool { decision.reasons.contains { if case .missing(let fact) = $0 { return ![CapabilityFact.slowmodeHistory, .accountKind, .ownership, .account].contains(fact) }; return false } }
}

extension AppModel {
    /// Capture before dispatch; pass back unchanged on HTTP/gateway confirmation.
    /// A late completion from another login or store epoch is discarded.
    var operationScope: OperationFacts.Scope? {
        store.me.map { OperationFacts.Scope(account: $0.id, login: accountGeneration, epoch: store.readEpoch) }
    }

    func noteConfirmedSend(in channel: Snowflake, author: Snowflake, at date: Date,
                           scope: OperationFacts.Scope) {
        guard operationScope == scope, scope.account == author else { return }
        operationFacts.confirmed(in: channel, at: date, scope: scope)
    }

    /// Fresh current store facts on every call. A decision is never a dispatch token.
    func operationDecision(_ operation: DiscordOperation, in channel: Snowflake,
                           messageAuthorID: Snowflake? = nil, now: Date = Date()) -> CapabilityDecision {
        guard let current = store.channel(channel) else { return .unknown(.channel) }
        let history = operationScope.map { operationFacts.history(in: channel, scope: $0) } ?? .unknown
        return store.capability(operation, in: current, now: now, slowmodeHistory: history, messageAuthorID: messageAuthorID)
    }

    func draftOperation(_ draft: Draft, in channel: Snowflake) -> DiscordOperation {
        if draft.editing != nil { return .editMessage }
        return .send(MessagePayloadFeatures(hasText: !outgoingText(draft, in: channel).isEmpty,
                                            isReply: draft.replyTo != nil, fileCount: draft.attachments.count))
    }

    /// Shared composer/explicit-send policy: unknown slowmode alone may be tried
    /// by the user, but never gets relabelled as known allowed. Other missing
    /// account/guild/member/parent facts fail closed. Account hypotheses preserve
    /// established non-send actions while remaining visible to attribution.
    func permitsExplicitAttempt(_ operation: DiscordOperation, decision: CapabilityDecision) -> Bool {
        if decision.isAllowed { return true }
        guard decision.state == .unknown, !decision.reasons.isEmpty else { return false }
        return decision.reasons.allSatisfy { reason in
            switch (operation, reason) {
            case (.send, .missing(.slowmodeConfiguration)), (.send, .missing(.slowmodeHistory)): true
            case (.send, _): false
            case (_, .accountValidationRequired): true
            default: false
            }
        }
    }

    func composerCapability(in channel: Snowflake, now: Date = Date()) -> ComposerCapability {
        let draft = drafts[channel] ?? Draft()
        let operation = draftOperation(draft, in: channel)
        let decision = operationDecision(operation, in: channel, messageAuthorID: draft.editing?.author.id, now: now)
        let hasContent = !outgoingText(draft, in: channel).isEmpty || (draft.editing == nil && !draft.attachments.isEmpty)
        let files = operationDecision(.send(MessagePayloadFeatures(fileCount: 1)), in: channel, now: now)
        let explanation = !hasContent && decision.reasons == [.invalidPayload] ? nil : decision.explanation(at: now)
        return ComposerCapability(decision: decision,
                                  canSubmit: hasContent && permitsExplicitAttempt(operation, decision: decision),
                                  canAttachFiles: draft.editing == nil && permitsExplicitAttempt(.send(MessagePayloadFeatures(fileCount: 1)), decision: files),
                                  explanation: explanation)
    }

    @discardableResult
    func preflight(_ operation: DiscordOperation, in channel: Snowflake, messageAuthorID: Snowflake? = nil,
                   now: Date = Date()) -> Bool {
        let decision = operationDecision(operation, in: channel, messageAuthorID: messageAuthorID, now: now)
        guard permitsExplicitAttempt(operation, decision: decision) else {
            showError(decision.explanation(at: now) ?? "This action is unavailable. Open the channel again and retry.")
            return false
        }
        return true
    }
}

/// Local refusal occurs before the API call and must never trigger uncertain-
/// outcome reconciliation, which is reserved for requests that reached transport.
nonisolated struct CapabilityPreflightRefusal: LocalizedError {
    var errorDescription: String? { "Channel eligibility changed before the action could be sent." }
}

extension CapabilityDecision {
    func explanation(at now: Date) -> String? {
        // Actionable known causes outrank unresolved metadata or derived masks.
        for reason in reasons {
            switch reason {
            case .timedOut(let until): return "You’re timed out. Try again in \(Self.wait(until, now: now))."
            case .cooldown(let until): return "Slowmode: wait \(Self.wait(until, now: now)) before sending again."
            default: break
            }
        }
        for reason in reasons {
            switch reason {
            case .missingPermissions(let mask):
                let names: [(UInt64, String)] = [(Permission.viewChannel, "View Channel"), (Permission.sendMessages, "Send Messages"),
                    (Permission.sendInThreads, "Send Messages in Threads"), (Permission.readHistory, "Read Message History"),
                    (Permission.attachFiles, "Attach Files"), (Permission.addReactions, "Add Reactions"),
                    (Permission.pinMessages, "Pin Messages"), (Permission.manageMessages, "Manage Messages"),
                    (Permission.connect, "Connect")]
                let missing = names.filter { mask & $0.0 != 0 }.map(\.1)
                return "Missing \(missing.isEmpty ? "channel permissions" : missing.joined(separator: ", ")). Ask a server moderator for access."
            case .missing(.slowmodeConfiguration), .missing(.slowmodeHistory):
                continue
            case .missing(let fact): return "\(fact.rawValue.capitalized) information is unavailable. Refresh eligibility and try again."
            case .threadArchived: return "This thread is closed. Open it before trying again."
            case .threadLocked: return "This thread is locked. Ask a thread manager for access."
            case .privateMembershipRequired: return "Join this private thread before trying again."
            case .threadActionUnavailable: return "This thread action is unavailable with its current state and your permissions."
            case .ownershipRequired: return "Only the message’s author can do this."
            case .unsupportedChannel: return "This action isn’t available in this kind of channel."
            case .invalidPayload: return "Add message text or a file before sending."
            case .contentRestricted: return "Age-restricted channels are unavailable in Duocord."
            case .accountValidationRequired(.voiceTextConnect): return "Check your voice or stage channel access with a moderator."
            case .accountValidationRequired: continue
            case .timedOut, .cooldown: break
            }
        }
        if reasons.contains(where: { if case .accountValidationRequired = $0 { true } else { false } }) {
            return "Check your channel access before trying this action."
        }
        if state == .unknown { return "Slowmode timing is unknown. You can try Send; Discord may ask you to wait." }
        return nil
    }

    private static func wait(_ until: Date, now: Date) -> String {
        let seconds = max(1, Int(ceil(until.timeIntervalSince(now))))
        return seconds < 60 ? "\(seconds)s" : "\(Int(ceil(Double(seconds) / 60))) min"
    }
}
