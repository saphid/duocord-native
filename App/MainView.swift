import SwiftUI

/// The signed-in app: a split view whose sidebar is the server rail plus the
/// channel (or DM) list and whose detail is the open conversation.
///
/// - Compact width (outer display, narrow multitasking): one stack.
/// - Regular width: sidebar + chat, members in an inspector.
/// - Book pose: the sidebar ends exactly at the fold; members take over the
///   sidebar page so the conversation keeps its own page.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(FoldState.self) private var fold
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if isTableTop {
                // Table-top: no split view, so no navigation control in the top
                // half; the deck's Servers button brings up the server list.
                NavigationStack { DetailColumn() }
                    .safeAreaInset(edge: .bottom) {
                        // Screens without the chat deck (no channel, forums) still
                        // reach the server list from the bottom half.
                        if !detailHasDeck {
                            DeckAction(title: "Servers", symbol: "sidebar.leading") { model.sheet = .servers }
                                .frame(maxWidth: 200)
                                .padding(.bottom, 12)
                        }
                    }
            } else {
                splitView
            }
        }
        .onChange(of: sizeClass, initial: true) { _, newValue in
            let compact = newValue != .regular
            if fold.isCompact != compact { fold.isCompact = compact }
            model.sizeClassChanged(compact: compact)
        }
        .onChange(of: isTableTop) { _, _ in
            model.sizeClassChanged(compact: fold.isCompact)
        }
        .sheet(item: model.sheetBinding, onDismiss: model.sheetDismissal) { sheet in
            SheetContent(sheet: sheet)
        }
        .overlay(alignment: .top) { ConnectionBanner() }
        .onAppear { Perf.shared.markOnce("mainViewAppear") }
    }

    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarColumn(showsNativeHeader: usesNativeSidebarHeader)
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
                // iPad's window controls reserve space in the native bar. Hiding
                // it lets the server rail's Home button occupy that same area.
                .navigationTitle(usesNativeSidebarHeader ? sidebarTitle : "")
                .navigationSubtitle(usesNativeSidebarHeader ? sidebarSubtitle : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(usesNativeSidebarHeader ? .visible : .hidden, for: .navigationBar)
        } detail: {
            DetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var usesNativeSidebarHeader: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var sidebarTitle: String {
        model.selectedGuild.flatMap { model.store.guilds[$0]?.name } ?? "Direct Messages"
    }

    private var sidebarSubtitle: String {
        guard let guild = model.selectedGuild.flatMap({ model.store.guilds[$0] }),
              let count = guild.memberCount else { return "" }
        return "\(count.formatted()) members"
    }

    private var detailHasDeck: Bool {
        guard let id = model.selectedChannel, let channel = model.store.channel(id) else { return false }
        return !channel.type.isForumLike
    }

    private var isTableTop: Bool {
        if case .tableTop = fold.posture, !fold.isCompact { return true }
        return false
    }

    /// In book pose the column spans the left page and the hinge (its content
    /// ends at the fold), so the conversation and its bar start on the right
    /// page. Otherwise a comfortable width.
    private var sidebarWidth: CGFloat {
        if case .book(let minX, let width) = fold.posture, model.settings.followFold { return minX + width }
        return min(340, max(300, fold.windowSize.width * 0.34))
    }
}

/// The conversation side of the split view.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(FoldState.self) private var fold

    var body: some View {
        @Bindable var model = model
        Group {
            if let channelID = model.selectedChannel, let channel = model.store.channel(channelID) {
                if channel.type.isForumLike {
                    ForumView(channel: channel)
                } else {
                    ChatView(channel: channel)
                        .id(channel.id)
                }
            } else {
                EmptyChatView()
            }
        }
        // With the sidebar hidden, the system's Show Sidebar control sits in
        // the title bar; minimised on scroll it would take the only way back
        // to the sidebar (and the title) with it.
        .toolbarMinimizationBehavior(revealsSidebarFromBar ? .never : .automatic, for: .navigationBar)
    }

    private var revealsSidebarFromBar: Bool {
        !fold.isCompact && !model.isTableTop && model.columnVisibility == .detailOnly
    }
}

struct EmptyChatView: View {
    @Environment(DiscordStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label(store.isReady ? "No Conversation Selected" : "Connecting…",
                  systemImage: store.isReady ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right")
        } description: {
            Text(store.isReady ? "Choose a channel or direct message." : "Loading your servers and messages.")
        }
        .background(Color.chatBackground.ignoresSafeArea())
    }
}

/// Shows reconnecting state without blocking the content underneath.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text {
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var text: String? {
        switch model.gatewayStatus {
        case .waiting(let seconds): "Reconnecting in \(seconds)s…"
        case .resuming: "Reconnecting…"
        case .failed(let reason): "Disconnected: \(reason)"
        case .connecting where model.store.isReady: "Reconnecting…"
        default: nil
        }
    }
}

struct SheetContent: View {
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .friends: FriendsView()
        case .search: SearchView()
        case .pins: PinsView()
        case .inbox: InboxView()
        case .settings: SettingsView()
        case .notifications(let target): NotificationSettingsView(target: target)
        case .threads(let channel): ThreadsView(parentID: channel)
        case .user(let user): UserProfileView(userID: user)
        case .media(let item): MediaViewer(item: item)
        case .servers:
            ServersSheet()
        case .reactions(let channel, let message, let emoji):
            ReactionsView(channel: channel, message: message, emoji: emoji)
                .id("\(message)-\(emoji)") // a panel reopened on another emoji starts on that tab
        case .emojiPicker(let channel, let message):
            EmojiPickerView(channelID: channel, messageID: message)
        case .members:
            NavigationStack { MemberListView(showsHeader: false).navigationTitle("Members").navigationBarTitleDisplayMode(.inline) }
                .presentationDetents([.medium, .large])
        }
    }
}

/// Table-top's server and channel list, opened from the deck.
struct ServersSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SidebarColumn()
                .navigationTitle("Servers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
