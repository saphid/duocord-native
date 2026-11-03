import Foundation
import Observation

@Observable
final class PeopleOperations {
    var saving: [Snowflake: Int] = [:]
    var errors: [Snowflake: String] = [:]
    var opening: Set<Snowflake> = []
    var dmErrors: [Snowflake: String] = [:]
    var requestingUsername = false
    var usernameFeedback: String?
    @ObservationIgnored var writes: [Snowflake: (RelationshipAction, Task<Void, Never>)] = [:]
    @ObservationIgnored var dms: [Snowflake: Task<Void, Never>] = [:]
    @ObservationIgnored var dmIntents: [Snowflake: UUID] = [:]
    @ObservationIgnored var usernameTask: Task<Void, Never>?

    func reset() {
        writes.values.forEach { $0.1.cancel() }; dms.values.forEach { $0.cancel() }; usernameTask?.cancel()
        writes = [:]; dms = [:]; dmIntents = [:]; saving = [:]; errors = [:]; opening = []; dmErrors = [:]
        requestingUsername = false; usernameFeedback = nil; usernameTask = nil
    }
}

extension AppModel {
    var allowsPeopleWrites: Bool {
        #if DEBUG
        isMock && api is MockDiscord
        #else
        !(api is OfflineAPI)
        #endif
    }

    func canChangeRelationship(_ id: Snowflake, action: RelationshipAction) -> Bool {
        store.isReady && id > 0 && id != store.me?.id && action.applies(to: store.relationships[id]?.type)
            && (!([RelationshipAction.request, .accept].contains(action)) || store.users[id]?.bot != true)
    }

    @discardableResult
    func changeRelationship(_ id: Snowflake, action: RelationshipAction, user: User? = nil) -> Task<Void, Never> {
        guard allowsPeopleWrites else {
            people.errors[id] = "People actions are disabled for real accounts in Debug."
            return Task {}
        }
        guard canChangeRelationship(id, action: action) else { return Task {} }
        if let user, user.id == id { store.remember(person: user) }
        if let existing = people.writes[id], existing.0 == action { return existing.1 }
        let previous = people.writes[id]?.1, epoch = store.peopleEpoch, api = api
        people.saving[id, default: 0] += 1
        people.errors[id] = nil
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.store.peopleEpoch == epoch, !Task.isCancelled else { return }
            self.people.errors[id] = nil
            // Conflicting choices are FIFO, and each checks current state.
            if self.canChangeRelationship(id, action: action) {
                let version = self.store.relationshipVersion(id)
                do {
                    try await api.relationship(user: id, action: action)
                    guard self.store.peopleEpoch == epoch else { return }
                    self.store.confirmRelationship(id, action: action, version: version)
                } catch {
                    guard self.store.peopleEpoch == epoch else { return }
                    if self.store.relationshipVersion(id) == version {
                        self.people.errors[id] = "\(action.title) failed. \(error.localizedDescription) Tap the action to retry."
                    }
                }
            }
            self.people.saving[id, default: 1] -= 1
            if self.people.saving[id] == 0 { self.people.writes[id] = nil }
        }
        people.writes[id] = (action, task)
        return task
    }

    @discardableResult
    func addFriend(username: String) -> Task<Void, Never> {
        guard !people.requestingUsername else { return people.usernameTask ?? Task {} }
        guard allowsPeopleWrites, store.isReady else {
            people.usernameFeedback = "Friend requests are unavailable for this session."
            return Task {}
        }
        guard let username = FriendUsername(username) else {
            people.usernameFeedback = "Enter a unique username: 2–32 lowercase letters, numbers, periods or underscores."
            return Task {}
        }
        if username.value == store.me?.username {
            people.usernameFeedback = "You can’t add yourself."
            return Task {}
        }
        let epoch = store.peopleEpoch, api = api, generation = store.relationshipGeneration
        people.requestingUsername = true; people.usernameFeedback = nil
        let task = Task { [weak self] in
            do {
                try await api.requestFriend(username: username)
                guard let self, self.store.peopleEpoch == epoch else { return }
                // The 204 does not identify a recipient. Only the gateway can
                // install this relationship; never resolve an unrelated ID.
                if self.store.usernameVersion(username.value) <= generation {
                    self.people.usernameFeedback = "Request sent. Waiting for the friends list to update."
                }
            } catch {
                guard let self, self.store.peopleEpoch == epoch else { return }
                if self.store.usernameVersion(username.value) <= generation {
                    self.people.usernameFeedback = "Couldn’t send request. \(error.localizedDescription) Try again."
                }
            }
            self?.people.requestingUsername = false
            self?.people.usernameTask = nil
        }
        people.usernameTask = task
        return task
    }

    @discardableResult
    func messageUser(_ id: Snowflake, user: User? = nil) -> Task<Void, Never> {
        guard store.isReady, id > 0, id != store.me?.id, !store.isBlocked(id) else { return Task {} }
        if let user, user.id == id { store.remember(person: user) }
        navigationIntent = UUID()
        people.dmIntents[id] = navigationIntent
        people.dmErrors[id] = nil
        if let existing = store.directMessage(to: id) {
            open(channel: existing.id, message: nil)
            return Task {}
        }
        if let task = people.dms[id] { return task }
        guard allowsPeopleWrites else {
            people.dmErrors[id] = "Creating DMs is disabled for real accounts in Debug."
            return Task {}
        }
        let epoch = store.peopleEpoch, api = api, version = store.dmVersion(id)
        people.opening.insert(id)
        let task = Task { [weak self] in
            do {
                let channel = try await api.createDM(recipient: id)
                guard let self, self.store.peopleEpoch == epoch else { return }
                let ids = channel.recipients.map { $0.map(\.id) } ?? channel.recipientIDs ?? []
                guard channel.type == .dm, channel.guildID == nil, ids == [id] else { throw DiscordError.decoding("one-to-one DM") }
                // A newer CHANNEL_CREATE/UPDATE/DELETE owns the recipient.
                if self.store.dmVersion(id) == version { self.store.upsert(channel: channel) }
                if self.navigationIntent == self.people.dmIntents[id], !self.store.isBlocked(id),
                   let current = self.store.directMessage(to: id) {
                    self.open(channel: current.id, message: nil)
                }
            } catch {
                guard let self, self.store.peopleEpoch == epoch else { return }
                if self.store.dmVersion(id) == version {
                    self.people.dmErrors[id] = "Couldn’t open Message. \(error.localizedDescription) Tap Message to retry."
                } else if self.navigationIntent == self.people.dmIntents[id], !self.store.isBlocked(id),
                          let current = self.store.directMessage(to: id) {
                    self.open(channel: current.id, message: nil)
                }
            }
            self?.people.opening.remove(id)
            self?.people.dms[id] = nil
            self?.people.dmIntents[id] = nil
        }
        people.dms[id] = task
        return task
    }
}
