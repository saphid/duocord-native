import SwiftUI

/// Server rail + channel list (or DMs). In book pose with members open, the
/// member list takes this page.
struct SidebarColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(FoldState.self) private var fold

    var body: some View {
        HStack(spacing: 0) {
            ServerRail()
                .frame(width: 72)
            Group {
                if let panel = model.sidebarPanel, !fold.isCompact {
                    VStack(spacing: 0) {
                        PanelHeader(title: Self.title(for: panel)) {
                            withAnimation(.snappy(duration: 0.25)) { model.sidebarPanel = nil }
                        }
                        SheetContent(sheet: panel)
                            .environment(\.closePanel) { withAnimation(.snappy(duration: 0.25)) { model.sidebarPanel = nil } }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else if showsMembersHere {
                    MemberListView(showsHeader: true)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else if model.isHome {
                    DirectMessageList()
                } else if let guild = model.selectedGuild {
                    ChannelList(guildID: guild)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.sidebarBackground)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UserPanel() }
        .padding(.trailing, hingeWidth)
        .background(Color.railBackground.ignoresSafeArea())
        .animation(.snappy(duration: 0.25), value: showsMembersHere)
        .animation(.snappy(duration: 0.25), value: model.sidebarPanel)
    }

    static func title(for panel: AppSheet) -> String {
        switch panel {
        case .friends: "Friends"
        case .search: "Search"
        case .pins: "Pinned Messages"
        case .inbox: "Inbox"
        case .threads: "Threads"
        case .settings: "Settings"
        case .notifications: "Notification Settings"
        case .reactions: "Reactions"
        case .emojiPicker: "Add Reaction"
        default: ""
        }
    }

    /// Book pose: nothing is drawn on the hinge itself.
    private var hingeWidth: CGFloat {
        if case .book(_, let width) = fold.posture, model.settings.followFold, !fold.isCompact { return width }
        return 0
    }

    /// On regular width the members take this page (in book pose and flat
    /// alike), so the conversation keeps its full width.
    private var showsMembersHere: Bool {
        model.membersVisible && !fold.isCompact
    }
}

/// Title and close for a page shown in the sidebar (members, lookups).
struct PanelHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.textMuted) }
                }
                Spacer()
                Button("Close \(title)", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            Divider().overlay(Color.separatorLine)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Server rail

struct ServerRail: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 8) {
                HomeButton()
                ForEach(store.unreadDMs.prefix(5)) { dm in
                    DMRailButton(channel: dm)
                }
                Capsule()
                    .fill(Color.separatorLine)
                    .frame(width: 32, height: 2)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)
                ForEach(store.sidebarItems) { item in
                    switch item {
                    case .guild(let id):
                        GuildButton(guildID: id)
                    case .folder(let folder):
                        FolderButton(folder: folder)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(Color.railBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Servers")
    }
}

/// The left pill Discord uses: a dot for unread, tall for selected.
struct RailPill: View {
    var selected: Bool
    var unread: Bool

    var body: some View {
        Capsule()
            .fill(Color.textPrimary)
            .frame(width: 4, height: selected ? 36 : (unread ? 8 : 0))
            .opacity(selected || unread ? 1 : 0)
            .animation(.snappy(duration: 0.2), value: selected)
    }
}

struct RailIcon<Content: View>: View {
    var selected: Bool
    var unread: Bool
    var mentions: Int
    var label: String
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: selected ? 16 : 24, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        MentionBadge(count: mentions)
                            .offset(x: 4, y: 4)
                    }
                }
                .animation(.snappy(duration: 0.2), value: selected)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) { RailPill(selected: selected, unread: unread) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(mentions > 0 ? "\(mentions) mentions" : (unread ? "Unread" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MentionBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.unreadRed, in: Capsule())
            .overlay(Capsule().stroke(Color.railBackground, lineWidth: 3))
            .accessibilityHidden(true)
    }
}

struct HomeButton: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store

    var body: some View {
        RailIcon(selected: model.isHome, unread: false, mentions: 0, label: "Direct Messages") {
            model.select(guild: nil)
        } content: {
            ZStack {
                (model.isHome ? Color.accentBlurple : Color.elevated)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.isHome ? .white : Color.textSecondary)
            }
        }
        .accessibilityIdentifier("homeButton")
    }
}

struct DMRailButton: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel

    var body: some View {
        RailIcon(selected: false, unread: true, mentions: store.mentionCount(channel.id), label: store.dmName(channel)) {
            model.select(channel: channel.id)
        } content: {
            ChannelAvatar(channel: channel, size: 48)
        }
    }
}

struct GuildButton: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let guildID: Snowflake

    var body: some View {
        if let guild = store.guilds[guildID] {
            let badge = store.badge(for: guildID)
            RailIcon(selected: model.selectedGuild == guildID, unread: badge.unread, mentions: badge.mentions, label: guild.name) {
                model.select(guild: guildID)
            } content: {
                GuildIcon(guild: guild, size: 48, selected: model.selectedGuild == guildID)
            }
            .opacity(store.isMuted(guild: guildID) ? 0.6 : 1)
            .contextMenu {
                Button("Mark as Read", systemImage: "checkmark.message") { model.markServerAsRead(guildID) }
                NotificationContextMenu(target: .guild(guildID))
            }
            .accessibilityIdentifier("guild-\(guildID)")
        }
    }
}

struct GuildIcon: View {
    let guild: Guild
    var size: CGFloat
    var selected = false

    var body: some View {
        if let url = guild.iconURL(size: 128) {
            RemoteImage(url: url, size: CGSize(width: size, height: size))
        } else {
            ZStack {
                (selected ? Color.accentBlurple : Color.elevated)
                Text(guild.initials)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(selected ? .white : Color.textPrimary)
                    .minimumScaleFactor(0.5)
                    .padding(4)
            }
        }
    }
}

struct FolderButton: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let folder: GuildFolder

    private var key: Int64 { folder.id ?? Int64(folder.guildIDs.first?.raw ?? 0 & 0x7FFF_FFFF) }
    private var expanded: Bool { model.expandedFolders.contains(key) }
    private var color: Color { folder.color.map { Color.role(Int($0)) } ?? .accentBlurple }

    var body: some View {
        VStack(spacing: 8) {
            let badges = folder.guildIDs.map { store.badge(for: $0) }
            let containsSelected = folder.guildIDs.contains { $0 == model.selectedGuild }
            RailIcon(selected: false, unread: !expanded && badges.contains { $0.unread }, mentions: expanded ? 0 : badges.reduce(0) { $0 + $1.mentions },
                     label: "\(folder.name ?? "Folder"), \(folder.guildIDs.count) servers") {
                withAnimation(.snappy(duration: 0.25)) {
                    if expanded { model.expandedFolders.remove(key) } else { model.expandedFolders.insert(key) }
                }
            } content: {
                ZStack {
                    color.opacity(0.28)
                    if expanded {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(color)
                    } else {
                        LazyVGrid(columns: [GridItem(.fixed(18), spacing: 4), GridItem(.fixed(18), spacing: 4)], spacing: 4) {
                            ForEach(folder.guildIDs.prefix(4), id: \.self) { id in
                                if let guild = store.guilds[id] {
                                    GuildIcon(guild: guild, size: 18).clipShape(Circle())
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .leading) {
                if containsSelected && !expanded { RailPill(selected: true, unread: false) }
            }
            .accessibilityHint(expanded ? "Collapses the folder" : "Expands the folder")
            if expanded {
                ForEach(folder.guildIDs, id: \.self) { id in
                    GuildButton(guildID: id)
                }
            }
        }
        .padding(.vertical, expanded ? 6 : 0)
        .background {
            if expanded {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(color.opacity(0.14))
                    .padding(.horizontal, 10)
            }
        }
    }
}

// MARK: - Channel list

struct ChannelList: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let guildID: Snowflake
    @State private var collapsed: Set<Snowflake> = []

    var body: some View {
        @Bindable var model = model
        let guild = store.guilds[guildID]
        List(selection: channelSelection) {
            Section {
                ForEach(store.sections(for: guildID)) { section in
                    if let category = section.category {
                        CategoryHeader(name: category.name ?? "", collapsed: collapsed.contains(category.id)) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if collapsed.contains(category.id) { collapsed.remove(category.id) } else { collapsed.insert(category.id) }
                            }
                        }
                        .contextMenu { NotificationContextMenu(target: .channel(guild: guildID, channel: category.id)) }
                        .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 2, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                    }
                    let isCollapsed = section.category.map { collapsed.contains($0.id) } ?? false
                    ForEach(section.channels) { channel in
                        // A collapsed category still shows unread or selected channels, like Discord.
                        if !isCollapsed || store.isUnread(channel) || model.selectedChannel == channel.id {
                            ChannelRow(channel: channel)
                                .tag(channel.id)
                            if !isCollapsed, !channel.type.isForumLike {
                                ForEach(store.threads(in: channel.id).prefix(5)) { thread in
                                    ChannelRow(channel: thread, isThread: true)
                                        .tag(thread.id)
                                }
                                if channel.type.isVoice {
                                    VoiceParticipants(channel: channel)
                                }
                            }
                        }
                    }
                }
            } header: {
                GuildHeader(guild: guild)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 34)
        .focusEffectDisabled()
        .focusable(false)
        .accessibilityIdentifier("channelList")
    }

    private var channelSelection: Binding<Snowflake?> {
        Binding(get: { model.selectedChannel }, set: { model.select(channel: $0) })
    }
}

struct GuildHeader: View {
    let guild: Guild?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(guild?.name ?? "")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            if let count = guild?.memberCount {
                Text("\(count.formatted()) members")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.leading, 12)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }
}

struct CategoryHeader: View {
    let name: String
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(name.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.3)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Color.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    var isThread = false

    var body: some View {
        let unread = store.isUnread(channel) && !store.isMuted(channel)
        let mentions = store.mentionCount(channel.id)
        let selected = model.selectedChannel == channel.id
        HStack(spacing: 8) {
            if isThread {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 20)
            } else {
                Image(systemName: Self.symbol(for: channel))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(unread || selected ? Color.textPrimary : Color.textMuted)
                    .frame(width: 20)
            }
            Text(channel.name ?? "")
                .font(.system(.body, weight: unread || selected ? .semibold : .regular))
                .foregroundStyle(unread || selected ? Color.textPrimary : (store.isMuted(channel) ? Color.textMuted.opacity(0.6) : Color.textSecondary))
                .lineLimit(1)
            Spacer(minLength: 4)
            if mentions > 0 {
                Text("\(mentions)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(Color.unreadRed, in: Capsule())
            }
        }
        .padding(.leading, isThread ? 12 : 0)
        .overlay(alignment: .leading) {
            if unread && !selected {
                Capsule().fill(Color.textPrimary).frame(width: 4, height: 8).offset(x: -12)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.selectedRow : .clear)
                .padding(.horizontal, 6)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isThread ? "Thread" : Self.kind(for: channel)) \(channel.name ?? "")")
        .accessibilityValue([unread ? "unread" : nil, mentions > 0 ? "\(mentions) mentions" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .contextMenu {
            ChannelReadButton(channel: channel.id)
            NotificationContextMenu(target: .channel(guild: channel.guildID, channel: channel.id))
        }
        .accessibilityIdentifier("channel-\(channel.id)")
        .focusEffectDisabled()
    }

    static func symbol(for channel: Channel) -> String {
        switch channel.type {
        case .voice: "speaker.wave.2.fill"
        case .stage: "dot.radiowaves.left.and.right"
        case .announcement: "megaphone.fill"
        case .forum, .media: "bubble.left.and.text.bubble.right.fill"
        case .publicThread, .privateThread, .announcementThread: "bubble.left.fill"
        default: channel.nsfw == true ? "exclamationmark.triangle" : "number"
        }
    }

    static func kind(for channel: Channel) -> String {
        switch channel.type {
        case .voice: "Voice channel"
        case .stage: "Stage"
        case .announcement: "Announcement channel"
        case .forum, .media: "Forum"
        default: "Channel"
        }
    }
}

struct VoiceParticipants: View {
    @Environment(DiscordStore.self) private var store
    let channel: Channel

    var body: some View {
        let states = channel.guildID.map { store.voiceStates(in: channel.id, guild: $0) } ?? []
        ForEach(states, id: \.userID) { state in
            let user = store.users[state.userID] ?? state.member?.user
            HStack(spacing: 8) {
                AvatarView(user: user, size: 22)
                Text(user.map { store.displayName(for: $0, in: channel.guildID) } ?? "Someone")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Spacer()
                if state.selfMute || state.mute {
                    Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(Color.textMuted)
                }
                if state.selfDeaf || state.deaf {
                    Image(systemName: "headphones.slash").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
            .padding(.leading, 40)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Direct messages

struct DirectMessageList: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store

    var body: some View {
        List(selection: Binding(get: { model.selectedChannel }, set: { model.select(channel: $0) })) {
            Button("Friends", systemImage: "person.2") { model.present(.friends) }
                .accessibilityIdentifier("friendsRoute")
            Section {
                if store.isReady && store.privateChannels.isEmpty {
                    Text("No direct messages yet. Open Friends or a profile to start a conversation.").foregroundStyle(.secondary)
                }
                ForEach(store.privateChannels) { channel in
                    DMRow(channel: channel)
                        .tag(channel.id)
                }
            } header: {
                Text("Direct Messages")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .textCase(nil)
                    .padding(.vertical, 10)
                    .padding(.leading, 12)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled()
        .accessibilityIdentifier("dmList")
    }
}

struct DMRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel

    var body: some View {
        let selected = model.selectedChannel == channel.id
        let mentions = store.mentionCount(channel.id)
        let unread = store.isUnread(channel) && !store.isMuted(channel)
        HStack(spacing: 10) {
            ChannelAvatar(channel: channel, size: 34)
                .overlay(alignment: .bottomTrailing) {
                    if channel.type == .dm, let user = store.recipients(of: channel).first {
                        PresenceDot(status: store.presences[user.id] ?? .offline)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.dmName(channel))
                    .font(.system(.body, weight: unread || selected ? .semibold : .regular))
                    .foregroundStyle(unread || selected ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(1)
                if channel.type == .groupDM {
                    Text("\(store.recipients(of: channel).count + 1) members")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 4)
            if mentions > 0 { MentionBadge(count: mentions) }
        }
        .opacity(store.isMuted(channel) ? 0.6 : 1)
        .contextMenu {
            ChannelReadButton(channel: channel.id)
            NotificationContextMenu(target: .channel(guild: nil, channel: channel.id))
        }
        .padding(.vertical, 3)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.selectedRow : .clear)
                .padding(.horizontal, 6)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.dmName(channel))
        .accessibilityValue(mentions > 0 ? "\(mentions) unread" : "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - User panel

struct UserPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let call = model.voice.call {
                CallPanel(call: call)
                Divider().overlay(Color.separatorLine)
            }
            HStack(spacing: 10) {
                AvatarView(user: store.me, size: 34)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(status: .online) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.me?.displayName ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(store.me.map { "@\($0.username)" } ?? "")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button("Settings", systemImage: "gearshape.fill") { model.present(.settings) }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("settingsButton")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
        }
        .background(Color.railBackground)
    }
}

/// Connected call: channel, server, mute / deafen / leave.
struct CallPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let call: VoiceController.Call

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Label("Voice Connected", systemImage: "waveform")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: Theme.online))
                Text("\(store.channel(call.channelID)?.name ?? "Voice") · \(store.guilds[call.guildID]?.name ?? "")")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            CallButtons(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct CallButtons: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    var compact = false

    var body: some View {
        let muted = store.myVoiceState?.selfMute ?? false
        let deafened = store.myVoiceState?.selfDeaf ?? false
        HStack(spacing: compact ? 4 : 10) {
            CallButton(title: muted ? "Unmute" : "Mute", symbol: muted ? "mic.slash.fill" : "mic.fill", active: muted, compact: compact) {
                model.voice.toggleMute()
            }
            .accessibilityValue(muted ? "Muted" : "On")
            CallButton(title: deafened ? "Undeafen" : "Deafen", symbol: deafened ? "headphones.slash" : "headphones", active: deafened, compact: compact) {
                model.voice.toggleDeafen()
            }
            .accessibilityValue(deafened ? "Deafened" : "Off")
            CallButton(title: "Leave Call", symbol: "phone.down.fill", active: false, destructive: true, compact: compact) {
                model.voice.leave()
            }
        }
    }
}

/// A round call control: engaged toggles fill white with the slashed symbol,
/// only Leave is red (the convention the system call controls use).
struct CallButton: View {
    let title: String
    let symbol: String
    let active: Bool
    var destructive = false
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(destructive ? .white : (active ? Color.black : Color.textPrimary))
                .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                .background(destructive ? Color.unreadRed : (active ? Color.white : Color.selectedRow), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
