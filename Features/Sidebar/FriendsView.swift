import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    @State private var filter: FriendsFilter = .all
    @State private var username = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Friends filter", selection: $filter) {
                        ForEach(FriendsFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section("Add Friend") {
                    TextField("Unique username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Friend’s unique username")
                    Button("Send Friend Request", systemImage: "person.badge.plus") { model.addFriend(username: username) }
                        .disabled(!store.isReady || model.people.requestingUsername || FriendUsername(username) == nil)
                    if model.people.requestingUsername { ProgressView("Sending request…") }
                    if let feedback = model.people.usernameFeedback { Text(feedback).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                    Text("Use their unique username, without @. Legacy username#discriminator requests are not supported here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(filter.rawValue) {
                    if !store.isReady {
                        ProgressView("Waiting for the friends list…")
                        Text("Cached relationships are provisional until Discord reconnects.").font(.footnote)
                    } else if store.friends(filter).isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "person.2", description: Text(emptyDescription))
                    } else {
                        ForEach(store.friends(filter)) { relationship in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { model.sheet = .user(relationship.id) } label: {
                                    HStack {
                                        AvatarView(user: store.users[relationship.id], size: 36)
                                        VStack(alignment: .leading) {
                                            Text(store.users[relationship.id]?.displayName ?? "Unknown user")
                                            Text(status(relationship)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.buttonStyle(.plain)
                                PersonActionsView(userID: relationship.id, user: store.users[relationship.id])
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Close Friends", systemImage: "xmark") {
                    if let closePanel { closePanel() } else { dismiss() }
                }
            } }
        }
    }
    private var emptyTitle: String {
        switch filter { case .all: "No Friends Yet"; case .online: "No Friends Online"; case .pending: "No Pending Requests"; case .blocked: "No Blocked Users" }
    }
    private var emptyDescription: String {
        switch filter {
        case .all: "Send a request above or open a profile to add a friend."
        case .online: "Your friends will appear here when they are online."
        case .pending: "Incoming and outgoing friend requests will appear here."
        case .blocked: "People you block will appear here."
        }
    }
    private func status(_ relationship: Relationship) -> String {
        switch relationship.type {
        case 2: "Blocked"
        case 3: "Incoming request"
        case 4: "Outgoing request"
        default: (store.presences[relationship.id] ?? .offline).rawValue.capitalized
        }
    }
}

/// Shared profile and Friends controls. Confirmation captures the identity
/// and action at the tap, rather than consulting a later list selection.
struct PersonActionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let userID: Snowflake
    var user: User?
    @State private var confirmation: Confirmation?
    private struct Confirmation: Identifiable {
        let id = UUID()
        let userID: Snowflake
        let name: String
        let user: User?
        let action: RelationshipAction
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if model.people.saving[userID, default: 0] > 0 { ProgressView("Saving…") }
            if model.people.opening.contains(userID) { ProgressView("Opening conversation…") }
            if let error = model.people.errors[userID] { Text(error).font(.footnote).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            if let error = model.people.dmErrors[userID] { Text(error).font(.footnote).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
        }
        .confirmationDialog(confirmation.map { "\($0.action.title) \($0.name)?" } ?? "Confirm", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible, presenting: confirmation) { captured in
                Button(captured.action.title, role: .destructive) {
                    model.changeRelationship(captured.userID, action: captured.action, user: captured.user)
                    confirmation = nil
                }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { captured in
                Text(captured.action == .block ? "New local alerts from this person will be suppressed and their timeline messages collapsed. Platform permissions still apply." : "You can send another friend request later.")
            }
    }
    @ViewBuilder private var controls: some View {
        Button("Message", systemImage: "bubble.left") { model.messageUser(userID, user: user) }
            .disabled(!store.isReady || userID == store.me?.id || store.isBlocked(userID))
        Menu("Friend Actions", systemImage: "person.crop.circle.badge.checkmark") {
            ForEach(RelationshipAction.allCases.filter { model.canChangeRelationship(userID, action: $0) }, id: \.self) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    if action.isDestructive {
                        confirmation = Confirmation(userID: userID, name: user?.displayName ?? "Unknown user (\(userID))", user: user, action: action)
                    } else { model.changeRelationship(userID, action: action, user: user) }
                }
            }
        }
        .disabled(!store.isReady || userID == store.me?.id || model.people.saving[userID, default: 0] > 0)
        .accessibilityLabel("Friend actions for \(user?.displayName ?? "Unknown user")")
    }
}
