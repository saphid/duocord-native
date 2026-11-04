import SwiftUI

/// Reused by row context menus and the conversation's More menu. The target
/// is captured explicitly; opening settings never selects another conversation.
struct NotificationContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let target: NotificationTarget

    var body: some View {
        if model.notificationSaves[target.resource, default: 0] > 0 {
            Text("Saving notification settings…")
        }
        // A thread's preference needs membership: its settings page explains
        // and offers Join Thread rather than saving anything here.
        if store.needsThreadMembership(target) {
            Button("Notification Settings", systemImage: "bell.badge") { model.present(.notifications(target)) }
        } else {
            muteAndSettings
        }
    }

    @ViewBuilder private var muteAndSettings: some View {
        if store.isDirectlyMuted(target) {
            Button("Unmute", systemImage: "bell") { model.muteNotifications(target, for: nil) }
        }
        Menu(store.isDirectlyMuted(target) ? "Mute for…" : "Mute", systemImage: "bell.slash") {
            ForEach(MuteDuration.allCases, id: \.self) { duration in
                Button(duration.title) { model.muteNotifications(target, for: duration) }
            }
        }
        Button("Notification Settings", systemImage: "bell.badge") { model.present(.notifications(target)) }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    let target: NotificationTarget

    private var name: String {
        if let id = target.channelID, let channel = store.channel(id) {
            return channel.type.isPrivate ? store.dmName(channel) : channel.name ?? "Channel"
        }
        return store.guilds[target.resource]?.name ?? "Server"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(name).font(.headline)
                    let effective = store.effectiveNotificationLevel(target)
                    LabeledContent("Effective", value: effective.level.title)
                    LabeledContent("From", value: effective.source)
                    if store.isDirectlyMuted(target) {
                        Label("Muted", systemImage: "bell.slash")
                        if let end = muteConfig?.endTime.flatMap(DiscordDate.parse) {
                            LabeledContent("Until") { Text(end, format: .dateTime.month().day().hour().minute()) }
                        } else { Text("Until turned back on").foregroundStyle(.secondary) }
                        Button("Unmute") { model.muteNotifications(target, for: nil) }
                    } else if inheritedMute {
                        Label("Muted by server or parent", systemImage: "bell.slash")
                    }
                    if !needsMembership {
                        Menu("Mute for…", systemImage: "bell.slash") {
                            ForEach(MuteDuration.allCases, id: \.self) { duration in
                                Button(duration.title) { model.muteNotifications(target, for: duration) }
                            }
                        }
                    }
                }
                if needsMembership, let id = target.channelID {
                    Section {
                        Text("Join this thread to choose its own notifications. Until then it follows the parent channel.")
                            .foregroundStyle(.secondary)
                        if model.threadCapabilities(id).canJoin {
                            Button(model.threads.isSaving(id) ? "Joining…" : "Join Thread", systemImage: "plus.bubble") {
                                model.perform(.join, on: id)
                            }
                            .disabled(model.threads.isSaving(id))
                        }
                    }
                    .accessibilityIdentifier("threadNotificationsJoin")
                } else {
                    Section {
                        Picker("Notify me about", selection: Binding(
                            get: { store.notificationLevel(target) },
                            set: { model.changeNotifications(target, patch: NotificationPatch(level: $0)) }
                        )) {
                            ForEach(levels, id: \.self) { level in Text(level.title).tag(level) }
                        }
                        .pickerStyle(.inline)
                    } header: { Text("Messages") } footer: {
                        Text(target.resource == 0
                             ? "Inherit follows the private message default. Muting silences notifications without changing this preference."
                             : "Inherit follows the parent channel, then server settings and the server default. Muting silences notifications without changing this preference.")
                    }
                }
                if target.channelID == nil, target.resource != 0 {
                    Section("Mentions") {
                        Toggle("Suppress @everyone and @here", isOn: Binding(
                            get: { store.guildSettings[target.resource]?.suppressEveryone ?? false },
                            set: { model.changeNotifications(target, patch: NotificationPatch(suppressEveryone: $0)) }
                        ))
                        Toggle("Suppress Role Mentions", isOn: Binding(
                            get: { store.guildSettings[target.resource]?.suppressRoles ?? false },
                            set: { model.changeNotifications(target, patch: NotificationPatch(suppressRoles: $0)) }
                        ))
                    }
                }
                if model.notificationSaves[target.resource, default: 0] > 0 {
                    Section { ProgressView("Saving notification settings…") }
                }
                if let error = model.notificationErrors[target.resource] {
                    Section {
                        Label("Couldn't save notification settings", systemImage: "exclamationmark.triangle")
                        Text(error).foregroundStyle(.secondary)
                        Text("The displayed values reflect the last confirmation. Choose the setting again to retry.")
                    }
                    .accessibilityIdentifier("notificationSaveError")
                }
            }
            .navigationTitle("Notification Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { if let closePanel { closePanel() } else { dismiss() } }
                }
            }
        }
    }

    private var levels: [NotificationLevel] {
        if let id = target.channelID, store.channel(id)?.type == .dm {
            return [.all, .nothing, .inherit]
        }
        return NotificationLevel.allCases
    }

    private var needsMembership: Bool { store.needsThreadMembership(target) }

    private var muteConfig: MuteConfig? {
        if let id = target.channelID, store.channel(id)?.type.isThread == true { return store.threadMember(id)?.muteConfig }
        let settings = store.guildSettings[target.resource]
        if let id = target.channelID { return settings?.channelOverrides.first { $0.channelID == id }?.muteConfig }
        return settings?.muteConfig
    }

    private var inheritedMute: Bool {
        guard let id = target.channelID, let channel = store.channel(id) else { return false }
        return store.isMuted(channel) || store.isMuted(guild: target.resource)
    }
}
