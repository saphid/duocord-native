import Foundation
import Observation
import UIKit

/// Where a thread menu was opened. Each surface presents its own rename and
/// delete prompts, so a prompt opened in a sheet is never hidden behind it.
enum ThreadMenuOrigin: Hashable {
    case sidebar, threadList, forum, chat
}

/// A thread action that asks first: a new name, or confirming a delete.
enum ThreadPrompt: Equatable, Identifiable {
    case rename(Snowflake, ThreadMenuOrigin)
    case delete(Snowflake, ThreadMenuOrigin)

    var thread: Snowflake {
        switch self { case .rename(let id, _), .delete(let id, _): id }
    }
    var origin: ThreadMenuOrigin {
        switch self { case .rename(_, let origin), .delete(_, let origin): origin }
    }
    var id: String {
        switch self {
        case .rename(let id, _): "rename-\(id)"
        case .delete(let id, _): "delete-\(id)"
        }
    }
}

/// Thread writes in flight, per thread, and the open prompt.
@Observable
final class ThreadOperations {
    var saving: [Snowflake: Int] = [:]
    var prompt: ThreadPrompt?
    @ObservationIgnored var writes: [Snowflake: Task<Void, Never>] = [:]
    @ObservationIgnored var session = UUID()

    func isSaving(_ id: Snowflake) -> Bool { saving[id, default: 0] > 0 }

    func reset() {
        session = UUID()
        writes.values.forEach { $0.cancel() }
        writes = [:]; saving = [:]; prompt = nil
    }
}

extension AppModel {
    /// Debug builds write only to the in-process mock, never a real account.
    var allowsThreadWrites: Bool {
        #if DEBUG
        isMock && api is MockDiscord
        #else
        !(api is OfflineAPI)
        #endif
    }

    func threadCapabilities(_ id: Snowflake) -> ThreadCapabilities {
        guard store.isReady, let thread = store.channel(id) else { return .none }
        return store.threadCapabilities(thread)
    }

    // MARK: Sidebar collapse

    func threadsCollapsed(under parent: Snowflake) -> Bool { collapsedThreadParents.contains(parent) }

    /// Hides or shows a channel's threads in the sidebar. Independent of the
    /// category's own collapse; the selection is untouched.
    func toggleThreads(under parent: Snowflake) {
        if collapsedThreadParents.contains(parent) { collapsedThreadParents.remove(parent) }
        else { collapsedThreadParents.insert(parent) }
    }

    // MARK: Copy

    func copyLink(thread id: Snowflake) {
        guard let thread = store.channel(id) else { return }
        UIPasteboard.general.string = DiscordStore.link(guild: thread.guildID, channel: thread.id)
    }

    func copyID(thread id: Snowflake) {
        UIPasteboard.general.string = id.description
    }

    // MARK: Writes

    /// Confirmed changes only: the store updates after Discord accepts, and a
    /// refusal shows an error with nothing changed. Writes to one thread are
    /// FIFO, and each re-checks eligibility against the state it then finds.
    @discardableResult
    func perform(_ action: ThreadAction, on id: Snowflake) -> Task<Void, Never> {
        guard allowsThreadWrites else {
            showError("Thread actions are disabled for real accounts in Debug.")
            return Task {}
        }
        if case .rename(let raw) = action {
            guard let name = ThreadPatch.validName(raw) else {
                showError("Thread names need 1–100 characters.")
                return Task {}
            }
            if name == store.channel(id)?.name { return Task {} }
            return enqueue(.rename(name), on: id)
        }
        return enqueue(action, on: id)
    }

    private func enqueue(_ action: ThreadAction, on id: Snowflake) -> Task<Void, Never> {
        guard threadCapabilities(id).allows(action) else { return Task {} }
        let previous = threads.writes[id], session = threads.session, api = api
        threads.saving[id, default: 0] += 1
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.threads.session == session, !Task.isCancelled else { return }
            defer {
                self.threads.saving[id, default: 1] -= 1
                if self.threads.saving[id] == 0 { self.threads.saving[id] = nil; self.threads.writes[id] = nil }
            }
            guard self.threadCapabilities(id).allows(action), let thread = self.store.channel(id) else { return }
            do {
                switch action {
                case .join:
                    try await api.joinThread(id)
                    guard self.threads.session == session else { return }
                    self.store.setThreadMembership(id, joined: true)
                case .leave:
                    try await api.leaveThread(id)
                    guard self.threads.session == session else { return }
                    self.store.setThreadMembership(id, joined: false)
                case .delete:
                    try await api.deleteThread(id)
                    guard self.threads.session == session else { return }
                    self.store.removeChannel(id)
                    self.threadRemoved(id, parent: thread.parentID)
                case .rename, .close, .reopen, .lock, .unlock:
                    guard let patch = action.patch else { return }
                    var updated = try await api.modifyThread(id, patch: patch)
                    guard self.threads.session == session else { return }
                    // A deleted thread stays deleted, even if this answer arrives late.
                    guard self.store.channel(id) != nil else { return }
                    if updated.guildID == nil { updated.guildID = thread.guildID }
                    self.store.upsert(channel: updated)
                }
            } catch {
                guard self.threads.session == session else { return }
                self.showError("Couldn’t \(action.failure). " + error.localizedDescription)
            }
        }
        threads.writes[id] = task
        return task
    }

    /// The open thread went away: show its parent channel instead.
    func threadRemoved(_ id: Snowflake, parent: Snowflake?) {
        if threads.prompt?.thread == id { threads.prompt = nil }
        guard selectedChannel == id else { return }
        if let parent, store.channel(parent) != nil { select(channel: parent) } else { select(channel: nil) }
    }
}

// MARK: Thread notification settings

enum ThreadNotificationError: LocalizedError {
    case notJoined
    var errorDescription: String? { "Join the thread to change its notification settings." }
}

extension AppModel {
    /// Saves a thread's own notification preference on the current user's
    /// thread member. Runs inside `changeNotifications`' FIFO, so flags are
    /// computed from the state the previous write confirmed. Never joins.
    func saveThreadNotifications(_ id: Snowflake, patch: NotificationPatch, api: DiscordAPI, session: UUID) async throws {
        guard let member = store.threadMember(id) else { throw ThreadNotificationError.notJoined }
        let fields = patch.threadFields(currentFlags: member.flags ?? 0)
        guard !fields.isEmpty else { return }
        let requested = ThreadMemberSettingsUpdate(fields: fields).fieldNames
        let versions = store.threadSettingsVersions(for: id)
        let result = try await api.modifyThreadSettings(id, fields: fields)
        // 204: Discord changed nothing, so nothing is applied.
        guard notificationSessionID == session, let result else { return }
        store.applyThreadSettings(result, thread: id, requested: requested, versions: versions)
    }
}
