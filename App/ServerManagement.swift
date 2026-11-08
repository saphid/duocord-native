import Foundation
import Observation

struct ServerLeaveConfirmation: Identifiable {
    let id = UUID()
    let guild: Snowflake
    let name: String
    let account: Snowflake
    let generation: UUID
    let epoch: UUID
    let membership: UUID
}

@Observable
final class ServerManagement {
    var confirmation: ServerLeaveConfirmation?
    var busy = false
    var feedback: String?
    var error: String?
    @ObservationIgnored var operation = UUID()
    @ObservationIgnored var dismissed: UUID?
    @ObservationIgnored var drag: (receipt: String, guild: Snowflake, generation: UUID, epoch: UUID, membership: UUID)?

    func reset() {
        operation = UUID(); busy = false; feedback = nil; error = nil; confirmation = nil; dismissed = nil; drag = nil
    }
}

extension AppModel {
    var allowsServerWrites: Bool {
        #if DEBUG
        isMock && api is MockDiscord
        #else
        !(api is OfflineAPI)
        #endif
    }

    func serverDrag(_ guild: Snowflake) -> String {
        let receipt = UUID().uuidString
        guard store.isReady, !servers.busy, store.guilds[guild] != nil else { return "" }
        servers.drag = (receipt, guild, accountGeneration, store.readEpoch, store.serverMembershipRevision)
        return receipt
    }

    func receiveServerDrag(_ receipt: String, before target: Snowflake?) {
        guard let drag = servers.drag, drag.receipt == receipt,
              drag.generation == accountGeneration, drag.epoch == store.readEpoch,
              drag.membership == store.serverMembershipRevision else { return }
        servers.drag = nil
        moveServer(drag.guild, before: target)
    }

    @discardableResult
    func moveServer(_ guild: Snowflake, before target: Snowflake?, withinFolder: Bool = true) -> Task<Void, Never> {
        guard store.isReady, !servers.busy, allowsServerWrites, let account = store.me?.id else { return Task {} }
        let generation = accountGeneration, epoch = store.readEpoch, membership = store.serverMembershipRevision
        let folders = store.folders, members = store.guildOrder, api = api
        let departed = store.confirmedDepartedServers
        let token = UUID(); servers.operation = token; servers.busy = true; servers.feedback = nil
        let current: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return false }
            return await MainActor.run {
                return self.accountGeneration == generation && self.store.me?.id == account && self.store.readEpoch == epoch
                    && self.store.serverMembershipRevision == membership && self.store.folders == folders
                    && self.servers.operation == token && self.allowsServerWrites
            }
        }
        return Task {
            defer { if servers.operation == token { servers.busy = false } }
            do {
                guard let base64 = try await api.settingsProto(), await current() else { throw GuildOrganizationError.stale }
                let settings = try GuildFolderSettings(base64: base64)
                let old = try GuildOrganization(folders: settings.folders, membershipOrder: members, departed: departed)
                let displayed = try GuildOrganization(folders: folders, membershipOrder: members, departed: departed)
                guard old == displayed else {
                    store.applyServerFolders(settings)
                    throw GuildOrganizationError.stale
                }
                let next = try old.moving(guild, before: target, withinFolder: withinFolder)
                let response = try await api.saveGuildFolders(settings.patch(for: next), admission: current)
                guard await current() else { return }
                let saved = try GuildFolderSettings(base64: response.settings)
                // A stale-version response is a refresh, never a successful move.
                store.applyServerFolders(saved)
                guard response.outOfDate != true,
                      try GuildOrganization(folders: saved.folders, membershipOrder: members, departed: departed) == next else {
                    throw GuildOrganizationError.stale
                }
                servers.feedback = "Server order saved."
                saveCache()
            } catch GuildOrganizationError.noChange { }
            catch {
                guard servers.operation == token, accountGeneration == generation else { return }
                serverManagementFailed("Couldn’t save server order. \(error.localizedDescription)")
            }
        }
    }

    /// Reads unknown ownership before offering a confirmation; no write occurs here.
    @discardableResult
    func requestLeaveServer(_ guild: Snowflake) -> Task<Void, Never> {
        guard store.isReady, !servers.busy, let account = store.me?.id, let listed = store.guilds[guild], !listed.unavailable else { return Task {} }
        let capture = ServerLeaveConfirmation(guild: guild, name: listed.name, account: account, generation: accountGeneration,
                                              epoch: store.readEpoch, membership: store.serverMembershipRevision)
        let token = UUID(); servers.operation = token; servers.busy = true; servers.feedback = nil
        let api = api
        return Task {
            defer { if servers.operation == token { servers.busy = false } }
            do {
                let owner: Snowflake?
                if let known = listed.ownerID { owner = known }
                else { owner = try await api.guild(guild).ownerID }
                guard leaveCaptureIsCurrent(capture), servers.operation == token else { return }
                guard let owner else { throw DiscordError.decoding("Server ownership is unavailable. Try again.") }
                guard owner != account else { serverManagementFailed("Transfer ownership of \(listed.name) before leaving."); return }
                servers.dismissed = nil
                servers.confirmation = capture
            } catch {
                guard servers.operation == token, accountGeneration == capture.generation else { return }
                serverManagementFailed("Couldn’t check \(listed.name). \(error.localizedDescription)")
            }
        }
    }

    func dismissServerLeave() {
        servers.dismissed = servers.confirmation?.id
        servers.confirmation = nil
    }

    func cancelServerLeave() { servers.confirmation = nil; servers.dismissed = nil }

    func leaveCaptureIsCurrent(_ capture: ServerLeaveConfirmation) -> Bool {
        accountGeneration == capture.generation && store.me?.id == capture.account && store.readEpoch == capture.epoch
            && store.serverMembershipRevision == capture.membership && store.guilds[capture.guild] != nil
            && store.guilds[capture.guild]?.unavailable == false
    }

    @discardableResult
    func confirmServerLeave(_ capture: ServerLeaveConfirmation) -> Task<Void, Never> {
        guard servers.confirmation?.id == capture.id || servers.dismissed == capture.id else { return Task {} }
        cancelServerLeave()
        guard !servers.busy, leaveCaptureIsCurrent(capture), store.guilds[capture.guild]?.ownerID != capture.account, allowsServerWrites else { return Task {} }
        let token = UUID(); servers.operation = token; servers.busy = true; servers.feedback = nil
        let api = api
        let current: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return false }
            return await MainActor.run {
                return self.servers.operation == token && self.leaveCaptureIsCurrent(capture) && self.store.guilds[capture.guild]?.ownerID != capture.account && self.allowsServerWrites
            }
        }
        return Task {
            defer { if servers.operation == token { servers.busy = false } }
            do {
                try await api.leaveGuild(capture.guild, admission: current)
                guard await current() else { return }
                removeServerLocally(capture.guild)
                servers.feedback = "Left \(capture.name)."
            } catch {
                guard await current() else { return }
                serverManagementFailed("Couldn’t confirm leaving \(capture.name). \(error.localizedDescription) The server list will update when Discord confirms your membership.")
            }
        }
    }

    private func serverManagementFailed(_ message: String) {
        servers.error = message
        servers.feedback = message
        showError(message)
    }
}
