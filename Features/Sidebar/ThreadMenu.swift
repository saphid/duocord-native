import SwiftUI

private struct ThreadMenuOriginKey: EnvironmentKey {
    static let defaultValue: ThreadMenuOrigin? = nil
}

extension EnvironmentValues {
    /// The surface hosting thread prompts for menus inside it.
    var threadMenuOrigin: ThreadMenuOrigin? {
        get { self[ThreadMenuOriginKey.self] }
        set { self[ThreadMenuOriginKey.self] = newValue }
    }
}

/// The thread menu Discord shows, used by the sidebar, the threads list,
/// forum posts and the chat header. Only actions the current user can
/// actually perform on this thread appear.
struct ThreadContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.threadMenuOrigin) private var origin
    let thread: Snowflake

    var body: some View {
        if let channel = store.channel(thread), channel.type.isThread {
            let can = model.threadCapabilities(thread)
            let saving = model.threads.isSaving(thread)
            ChannelReadButton(channel: thread)
            Section {
                NotificationContextMenu(target: .channel(guild: channel.guildID, channel: thread))
            }
            Section {
                if saving { Text("Updating Thread…") }
                if can.canRename, let origin {
                    Button("Edit Thread", systemImage: "pencil") { model.threads.prompt = .rename(thread, origin) }
                        .disabled(saving)
                }
                if can.canClose {
                    Button("Close Thread", systemImage: "archivebox") { model.perform(.close, on: thread) }
                        .disabled(saving)
                }
                if can.canReopen {
                    Button("Open Thread", systemImage: "arrow.uturn.backward") { model.perform(.reopen, on: thread) }
                        .disabled(saving)
                }
                if can.canLock {
                    Button("Lock Thread", systemImage: "lock") { model.perform(.lock, on: thread) }
                        .disabled(saving)
                }
                if can.canUnlock {
                    Button("Unlock Thread", systemImage: "lock.open") { model.perform(.unlock, on: thread) }
                        .disabled(saving)
                }
                if can.canJoin {
                    Button("Join Thread", systemImage: "plus.bubble") { model.perform(.join, on: thread) }
                        .disabled(saving)
                }
                if can.canLeave {
                    Button("Leave Thread", systemImage: "rectangle.portrait.and.arrow.right") { model.perform(.leave, on: thread) }
                        .disabled(saving)
                }
            }
            Section {
                Button("Copy Link", systemImage: "link") { model.copyLink(thread: thread) }
                Button("Copy Thread ID", systemImage: "number") { model.copyID(thread: thread) }
            }
            if can.canDelete, let origin {
                Section {
                    Button("Delete Thread", systemImage: "trash", role: .destructive) { model.threads.prompt = .delete(thread, origin) }
                        .disabled(saving)
                }
            }
        }
    }
}

/// The conversation's own actions: the thread menu for a thread, otherwise
/// mark read (the channel, and its threads), and notifications.
struct ChannelActionsMenu: View {
    let channel: Channel

    var body: some View {
        if channel.type.isThread {
            ThreadContextMenu(thread: channel.id)
        } else {
            ChannelReadButton(channel: channel.id)
            ThreadsReadButton(parent: channel)
            NotificationContextMenu(target: .channel(guild: channel.guildID, channel: channel.id))
        }
    }
}

extension View {
    /// Hosts rename and delete prompts for thread menus opened inside this view.
    func threadPromptHost(_ origin: ThreadMenuOrigin) -> some View {
        modifier(ThreadPromptHost(origin: origin))
    }
}

private struct ThreadPromptHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let origin: ThreadMenuOrigin
    @State private var name = ""

    private var prompt: ThreadPrompt? {
        guard let prompt = model.threads.prompt, prompt.origin == origin else { return nil }
        return prompt
    }

    private func binding(rename: Bool) -> Binding<Bool> {
        Binding(get: {
            guard let prompt else { return false }
            if case .rename = prompt { return rename }
            return !rename
        }, set: { shown in
            if !shown, prompt != nil { model.threads.prompt = nil }
        })
    }

    private var threadName: String {
        prompt.flatMap { store.channel($0.thread)?.name } ?? "this thread"
    }

    func body(content: Content) -> some View {
        content
            .environment(\.threadMenuOrigin, origin)
            .onChange(of: prompt) { _, new in
                if case .rename(let id, _)? = new { name = store.channel(id)?.name ?? "" }
            }
            .alert("Edit Thread", isPresented: binding(rename: true)) {
                TextField("Thread name", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) { model.threads.prompt = nil }
                Button("Save") {
                    if let id = prompt?.thread { model.perform(.rename(name), on: id) }
                    model.threads.prompt = nil
                }
                .disabled(ThreadPatch.validName(name) == nil)
            } message: {
                Text("Thread names can be up to 100 characters.")
            }
            .alert("Delete Thread", isPresented: binding(rename: false)) {
                Button("Cancel", role: .cancel) { model.threads.prompt = nil }
                Button("Delete Thread", role: .destructive) {
                    if let id = prompt?.thread { model.perform(.delete, on: id) }
                    model.threads.prompt = nil
                }
            } message: {
                Text("Are you sure you want to delete “\(threadName)”? Its messages are deleted for everyone. This can’t be undone.")
            }
    }
}
