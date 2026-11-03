import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(FoldState.self) private var fold
    /// nil when the bar is horizontal (inner portrait); then secondary items
    /// fold into a menu so the channel title keeps its place.
    @Environment(\.toolbarVerticalEdge) private var verticalBar
    let channel: Channel

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Group {
                if let split = tableTopSplit(frame: frame) {
                    // Table-top: reading above the fold, controls below it.
                    // Typing, the keyboard fills the bottom half: the deck is
                    // just the composer riding on the keyboard, and the list
                    // ends where the controls (which keep clear of the fold) begin.
                    // The same views either way, so the composer keeps focus.
                    let typing = model.keyboardVisible
                    VStack(spacing: 0) {
                        MessageListView(channel: channel)
                            .frame(height: typing ? nil : split.top)
                        if !typing {
                            Color.chatBackground.frame(height: split.gap)
                        }
                        TableTopDeck(channel: channel, typing: typing)
                            .frame(maxHeight: typing ? nil : .infinity, alignment: .top)
                    }
                } else {
                    // Runs under the title bar so the system's soft scroll-edge
                    // effect fades content instead of a hard cut.
                    MessageListView(channel: channel)
                        .ignoresSafeArea(.container, edges: .top)
                        .safeAreaInset(edge: .top, spacing: 0) { UnreadNavigationBar(channel: channel.id) }
                        .safeAreaInset(edge: .bottom, spacing: 0) { ChatControls(channel: channel).homeIndicatorClearance() }
                }
            }
        }
        .background(Color.chatBackground.ignoresSafeArea())
        // Above the title bar (where the status bar used to be) nothing scrolls through.
        .overlay(alignment: .top) {
            Color.chatBackground.frame(height: 0).ignoresSafeArea(.container, edges: .top).allowsHitTesting(false)
        }
        .navigationTitle(title)
        .navigationSubtitle(channel.topic.map { String($0.prefix(120)) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(Color.chatBackground, for: .navigationBar)
        .onAppear { Perf.shared.markOnce("chatViewAppear"); Perf.shared.end("channelSwitch", extra: ["channel": channel.id.description, "cached": model.messages.existingTimeline(for: channel.id)?.messages.isEmpty == false]) }
    }

    private var title: String {
        if channel.type.isPrivate { return store.dmName(channel) }
        return channel.name ?? ""
    }

    private func tableTopSplit(frame: CGRect) -> (top: CGFloat, gap: CGFloat)? {
        // A tall keyboard doesn't end table-top (that would rebuild the composer and drop focus).
        guard case .tableTop(let minY, let height) = fold.posture, frame.minY < minY,
              model.keyboardVisible || frame.maxY > minY + height else { return nil }
        return (minY - frame.minY, height)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Symbol-only, titled items: the system moves them into the
        // vertical side bar on iPhone Duo; text-only items stay horizontal.
        if !fold.isCompact, !model.isTableTop, !model.keyboardVisible, model.columnVisibility != .detailOnly {
            // The system shows its own reveal control while the sidebar is hidden.
            ToolbarItem(placement: .topBarLeading) {
                Button("Hide Sidebar", systemImage: "sidebar.leading") {
                    withAnimation(.snappy(duration: 0.3)) { model.columnVisibility = .detailOnly }
                }
            }
        }
        if !model.isTableTop {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // A horizontal bar (inner portrait), or a side bar shortened by
                // the keyboard: secondary items fold into More so Search,
                // Members and Inbox (with its badge) always stay visible.
                if fold.isCompact && model.keyboardVisible {
                    // The outer display's side bar is shortest with the keyboard
                    // up: Back, More and Inbox only.
                    Menu("More", systemImage: "ellipsis") {
                        ChannelReadButton(channel: channel.id)
                        NotificationContextMenu(target: .channel(guild: channel.guildID, channel: channel.id))
                        Button("Search", systemImage: "magnifyingglass") { model.present(.search) }
                        if channel.guildID != nil {
                            Button("Members", systemImage: "person.2") { model.toggleMembers() }
                        }
                        if !channel.type.isPrivate {
                            Button("Threads", systemImage: "bubble.left.and.text.bubble.right") { model.present(.threads(threadParent)) }
                        }
                        Button("Pinned Messages", systemImage: "pin") { model.present(.pins) }
                    }
                } else if (verticalBar == nil && !fold.isCompact) || model.keyboardVisible {
                    Menu("More", systemImage: "ellipsis") {
                        ChannelReadButton(channel: channel.id)
                        NotificationContextMenu(target: .channel(guild: channel.guildID, channel: channel.id))
                        if !channel.type.isPrivate {
                            Button("Threads", systemImage: "bubble.left.and.text.bubble.right") { model.present(.threads(threadParent)) }
                        }
                        Button("Pinned Messages", systemImage: "pin") { model.present(.pins) }
                    }
                } else {
                    Menu("More", systemImage: "ellipsis") {
                        ChannelReadButton(channel: channel.id)
                        NotificationContextMenu(target: .channel(guild: channel.guildID, channel: channel.id))
                    }
                    if !channel.type.isPrivate {
                        Button("Threads", systemImage: threadsOpen ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right") {
                            model.present(.threads(threadParent))
                        }
                    }
                    Button("Pinned Messages", systemImage: panelOpen(.pins) ? "pin.fill" : "pin") { model.present(.pins) }
                }
                // Open pages use their filled glyph (search has none; its panel shows it).
                if !(fold.isCompact && model.keyboardVisible) {
                Button("Search", systemImage: panelOpen(.search) ? "magnifyingglass" : "magnifyingglass") { model.present(.search) }
                    .keyboardShortcut("f")
                }
                if channel.guildID != nil, !(fold.isCompact && model.keyboardVisible) {
                    Button(model.membersVisible ? "Hide Members" : "Show Members",
                           systemImage: model.membersVisible ? "person.2.fill" : "person.2") {
                        withAnimation(.snappy(duration: 0.25)) { model.toggleMembers() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Inbox", systemImage: panelOpen(.inbox) ? "tray.fill" : "tray") { model.present(.inbox) }
                    .badge(store.totalBadge)
            }
        }
    }

    private var threadParent: Snowflake { channel.type.isThread ? channel.parentID ?? channel.id : channel.id }
    private var threadsOpen: Bool { if case .threads? = model.sidebarPanel { true } else { false } }

    private func panelOpen(_ panel: AppSheet) -> Bool { model.sidebarPanel == panel }
}

/// Table-top's lower half: the composer right under the fold (the keyboard
/// rises beneath it), call controls, and one-tap switching between unread
/// and recent conversations, since the sidebar steps aside in this pose.
/// While typing (`typing`), only the composer: the keyboard covers the rest.
struct TableTopDeck: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    var typing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UnreadNavigationBar(channel: channel.id)
            ChannelReadButton(channel: channel.id)
            ChatControls(channel: channel)
            if !typing {
                extras
            }
        }
        .padding(.top, typing ? 0 : 6)
        .background(Color.chatBackground)
    }

    @ViewBuilder
    private var extras: some View {
        if model.voice.call != nil, !channel.type.isVoice {
            HStack {
                Label("In a call", systemImage: "waveform").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: Theme.online))
                Spacer()
                CallButtons()
            }
            .padding(.horizontal, 16)
        }
        // The bar's actions live here in table-top, within reach.
        HStack(spacing: 8) {
            DeckAction(title: "Search", symbol: "magnifyingglass") { model.present(.search) }
            DeckAction(title: "Inbox", symbol: "tray", badge: store.totalBadge) { model.present(.inbox) }
            DeckAction(title: "Pins", symbol: "pin") { model.present(.pins) }
            if !channel.type.isPrivate {
                DeckAction(title: "Threads", symbol: "bubble.left.and.text.bubble.right") {
                    model.present(.threads(channel.type.isThread ? channel.parentID ?? channel.id : channel.id))
                }
                DeckAction(title: "Members", symbol: "person.2") { model.toggleMembers() }
            }
            DeckAction(title: "Notifications", symbol: "bell") {
                model.present(.notifications(.channel(guild: channel.guildID, channel: channel.id)))
            }
            DeckAction(title: "Servers", symbol: "sidebar.leading") { model.sheet = .servers }
        }
        .padding(.horizontal, 16)
        Text("Jump to")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 4)
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(destinations) { destination in
                    Button {
                        model.select(channel: destination.id)
                    } label: {
                        HStack(spacing: 6) {
                            if destination.type.isPrivate {
                                ChannelAvatar(channel: destination, size: 22)
                            } else {
                                Image(systemName: ChannelRow.symbol(for: destination)).font(.footnote.weight(.semibold))
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(store.channelName(destination)).font(.subheadline.weight(.medium)).lineLimit(1)
                                // Which server, so repeated channel names stay unambiguous.
                                if let guild = destination.guildID.flatMap({ store.guilds[$0] }) {
                                    Text(guild.name).font(.caption2).foregroundStyle(Color.textMuted).lineLimit(1)
                                }
                            }
                            if store.mentionCount(destination.id) > 0 {
                                MentionBadge(count: store.mentionCount(destination.id))
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(destination.id == channel.id ? Color.selectedRow : Color.elevated,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// Unread first, then this server's channels and recent DMs.
    private var destinations: [Channel] {
        var seen = Set<Snowflake>()
        var result: [Channel] = []
        func add(_ channel: Channel) { if seen.insert(channel.id).inserted { result.append(channel) } }
        let unread = store.channels.values.filter { store.mentionCount($0.id) > 0 && ($0.guildID == nil || store.canView($0)) }
            .sorted { ($0.lastMessageID ?? 0) > ($1.lastMessageID ?? 0) }
        unread.prefix(8).forEach(add)  // up to 30 destinations fill the deck
        if let guild = channel.guildID {
            store.sections(for: guild).flatMap(\.channels).filter { $0.type.isTextLike && !$0.type.isVoice }.prefix(14).forEach(add)
        }
        store.privateChannels.prefix(8).forEach(add)
        return result
    }
}

/// Shown above the composer while reading older messages: says so, and
/// jumps back. It takes its own row, so it never covers a message.
struct HistoryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            if let channel = model.selectedChannel { model.jumpRequest = (channel, UUID()) }
        } label: {
            HStack(spacing: 8) {
                Text("Viewing older messages")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Label("Jump to Present", systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentBlurple)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .accessibilityLabel("Viewing older messages. Jump to Present")
        .accessibilityIdentifier("jumpToPresent")
    }
}

/// A labelled action button in the table-top deck.
struct DeckAction: View {
    let title: String
    let symbol: String
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge > 0 { MentionBadge(count: badge).offset(x: -6, y: 4) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textPrimary)
    }
}

/// Typing line, call bar and composer: everything under the messages.
struct ChatControls: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel

    var body: some View {
        VStack(spacing: 0) {
            if channel.type.isVoice {
                VoiceChannelBar(channel: channel)
            }
            if model.viewingHistory {
                HistoryStrip()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let toast = model.toast {
                ToastBanner(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            TypingBar(channelID: channel.id, guildID: channel.guildID)
            Composer(channel: channel)
        }
        .background(Color.chatBackground)
        // A short fade so a message partly behind the controls reads as scrolled, not cut.
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.chatBackground.opacity(0), Color.chatBackground], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
                .offset(y: -14)
                .allowsHitTesting(false)
        }
    }
}

/// A failed action, said in its own row above the composer (never over a
/// message); tap to dismiss, or it goes by itself.
struct ToastBanner: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        Button { model.dismissToast() } label: {
            Label(toast.text, systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Color.unreadRed, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityHint("Dismisses")
        .accessibilityIdentifier("errorToast")
    }
}

struct TypingBar: View {
    @Environment(DiscordStore.self) private var store
    let channelID: Snowflake
    let guildID: Snowflake?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let names = store.typingUsers(in: channelID).compactMap { store.users[$0] }.map { store.displayName(for: $0, in: guildID) }
            HStack(spacing: 6) {
                if !names.isEmpty {
                    Image(systemName: "ellipsis")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.caption.weight(.bold))
                    Text(text(names))
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: names.isEmpty ? 0 : 20)
            .clipped()
            .animation(.snappy(duration: 0.2), value: names)
            .accessibilityElement(children: .combine)
        }
    }

    private func text(_ names: [String]) -> AttributedString {
        var result: AttributedString
        switch names.count {
        case 1: result = AttributedString("\(names[0]) is typing…")
        case 2: result = AttributedString("\(names[0]) and \(names[1]) are typing…")
        case 3: result = AttributedString("\(names[0]), \(names[1]) and \(names[2]) are typing…")
        default: result = AttributedString("Several people are typing…")
        }
        for name in names.prefix(3) {
            if let range = result.range(of: name) { result[range].font = .caption.bold() }
        }
        return result
    }
}

struct VoiceChannelBar: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel

    var body: some View {
        let inThisCall = model.voice.call?.channelID == channel.id
        let states = channel.guildID.map { store.voiceStates(in: channel.id, guild: $0) } ?? []
        let count = states.count
        HStack(spacing: 10) {
            Image(systemName: inThisCall ? "waveform" : "speaker.wave.2.fill")
                .foregroundStyle(inThisCall ? Color(uiColor: Theme.online) : Color.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(inThisCall ? "Connected" : (count == 0 ? "No one is here yet" : "\(count) in voice"))
                    .font(.subheadline.weight(.semibold))
                if let error = model.voice.error {
                    Text(error).font(.caption).foregroundStyle(Color.unreadRed)
                } else if model.voice.joining == channel.id {
                    Text("Joining…").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
            HStack(spacing: -8) {
                ForEach(states.prefix(4), id: \.userID) { state in
                    AvatarView(user: store.users[state.userID] ?? state.member?.user, size: 26)
                        .overlay(Circle().stroke(Color.elevated, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if inThisCall {
                CallButtons()
            } else {
                Button("Join Voice") { model.voice.join(channel) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: Theme.online))
                    .disabled(!model.voice.canJoin(channel) || model.voice.joining != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Composer

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    /// The suggestion a hardware keyboard's Return or Tab would pick.
    @State private var highlighted = 0
    /// Escape hides suggestions until the query changes.
    @State private var dismissedQuery: Autocomplete.Query?

    private var draft: Binding<Draft> {
        Binding(get: { model.drafts[channel.id] ?? Draft() }, set: { model.drafts[channel.id] = $0 })
    }

    var body: some View {
        if !store.canSend(in: channel) {
            Label("You don't have permission to send messages here.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.elevated)
        } else {
            let query = activeQuery
            let suggestions = query.map { model.suggestions(for: $0, in: channel) } ?? []
            let fold = foldLayout(hasStrip: usesStrip && !suggestions.isEmpty)
            VStack(spacing: 6) {
                if let query, !suggestions.isEmpty, !usesStrip {
                    // Right above the field, inside the controls: it rises with
                    // the keyboard, stays in the conversation's column (never
                    // across the hinge) and below the fold in table-top.
                    SuggestionList(query: query, suggestions: suggestions, highlighted: min(highlighted, suggestions.count - 1),
                                   maxRows: maxSuggestionRows, guildID: channel.guildID) { accept($0, for: query) }
                        .padding(.leading, hingeInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let query, !suggestions.isEmpty, fold?.stripBelow != true {
                    // No room for the list: one row of chips (in table-top,
                    // just above the fold when it can't sit on the keyboard).
                    strip(query, suggestions)
                }
                if draft.wrappedValue.editing != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").font(.caption.weight(.semibold))
                        Text("Editing message").font(.caption.weight(.semibold))
                        Spacer()
                        Button("Cancel Edit", systemImage: "xmark.circle.fill") { model.cancelEdit(in: channel.id) }
                            .labelStyle(.iconOnly)
                            .frame(width: 32, height: 32)
                            .accessibilityIdentifier("cancelEdit")
                    }
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 14)
                } else if let reply = draft.wrappedValue.replyTo {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.caption)
                        Text("Replying to **\(store.displayName(for: reply.author, in: channel.guildID))**").font(.caption)
                            .lineLimit(1)
                        Spacer()
                        // Replying to yourself never pings, so there's nothing to toggle.
                        if reply.author.id != store.me?.id {
                            ReplyPingToggle()
                        }
                        Button("Cancel Reply", systemImage: "xmark.circle.fill") { draft.wrappedValue.replyTo = nil }
                            .labelStyle(.iconOnly)
                            .frame(width: 32, height: 32)
                    }
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 14)
                }
                if model.keyboardVisible, model.fold.isCompact, draftWraps {
                    // The title bar can minimise while composing on the outer
                    // display: keep the destination in view next to the text.
                    Label(channel.type.isPrivate ? "To \(store.dmName(channel))" : "To #\(channel.name ?? "")",
                          systemImage: channel.type.isPrivate ? "person.fill" : "number")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 60)
                        .accessibilityLabel("Sending to \(channel.type.isPrivate ? store.dmName(channel) : "#" + (channel.name ?? ""))")
                }
                if !draft.wrappedValue.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(draft.wrappedValue.attachments) { file in
                                AttachmentChip(file: file) {
                                    draft.wrappedValue.attachments.removeAll { $0.id == file.id }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .scrollIndicators(.hidden)
                }
                if let fold {
                    // Table-top while typing: the fold, kept clear. Everything
                    // above sits in the top half; the field rides on the keyboard.
                    Color.clear.frame(height: fold.spacer)
                        .accessibilityHidden(true)
                    if let query, !suggestions.isEmpty, fold.stripBelow {
                        strip(query, suggestions)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
                        Button("Files", systemImage: "doc") { showFiles = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.elevated, in: Circle())
                    }
                    .accessibilityLabel("Add Attachment")
                    .frame(width: 44, height: 44)
                    // An edit changes text only.
                    .disabled(isEditing)
                    .opacity(isEditing ? 0.4 : 1)
                    ComposerTextInput(draft: draft, model: model, channelID: channel.id,
                                      wantsFocus: model.composerContinuity.focusedChannel == channel.id,
                                      maximumLines: tableTopTyping ? 1 : 6, placeholder: placeholder,
                                      hasSuggestions: query != nil && !suggestions.isEmpty, handleKey: handleKey)
                        .overlay(alignment: .topLeading) {
                            if draft.wrappedValue.text.isEmpty {
                                Text(placeholder).foregroundStyle(Color.textMuted).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onChange(of: draft.wrappedValue.text) { old, new in
                            if new.count > old.count, !isEditing { model.userTyped(in: channel.id) }
                            if new.isEmpty, !draft.wrappedValue.tokens.isEmpty { draft.wrappedValue.tokens = [] }
                        }
                    // Save replaces Send while editing.
                    Button(isEditing ? "Save" : "Send", systemImage: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill") { model.send(in: channel.id) }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentBlurple : Color.textMuted)
                        .disabled(!canSend)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier(isEditing ? "save" : "send")
                }
                .padding(.horizontal, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            }
            .padding(.vertical, 6)
            .animation(.snappy(duration: 0.2), value: suggestions.isEmpty)
            .onChange(of: query) { _, newQuery in
                highlighted = 0
                if let newQuery, newQuery.trigger == .mention, let guild = channel.guildID {
                    model.searchMembers(newQuery.text, guild: guild)
                }
            }
            .onChange(of: SuggestionSummary(query: query, count: suggestions.count)) { old, new in
                announce(new, previous: old, first: suggestions.first)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(urls) }
            }
            .onChange(of: photoItems) { _, items in addPhotos(items) }
        }
    }


    @State private var frame: CGRect = .zero

    /// The word at the cursor, when it asks for suggestions.
    private var activeQuery: Autocomplete.Query? {
        let text = draft.wrappedValue.text
        guard !text.isEmpty, let query = Autocomplete.query(in: text, cursor: cursor(in: text)), query != dismissedQuery else { return nil }
        return query
    }

    /// The cursor as a Character offset (the end when unknown or a range is selected's end).
    private func cursor(in text: String) -> Int {
        let selected = model.composerContinuity.selection(in: channel.id, text: text)
        guard let range = Range(selected, in: text) else { return text.count }
        return text.distance(from: text.startIndex, to: range.upperBound)
    }

    /// Fewer rows where space is short: table-top's lower half, and the outer
    /// display with the keyboard up.
    /// Never more than fit above the field.
    private var maxSuggestionRows: Int {
        if model.isTableTop { return 3 }
        let preferred = model.fold.isCompact && model.keyboardVisible ? 4 : 5
        return max(1, min(preferred, fittingRows ?? preferred))
    }

    /// List rows (plus the half row that says there are more) that fit
    /// above the field while the title bar and some of the conversation
    /// stay in view. Worked out from the controls' bottom edge, which the
    /// list doesn't move. Nil in table-top, where the deck grows downwards.
    private var fittingRows: Int? {
        guard !model.isTableTop, frame.maxY > 0, rowHeight > 0 else { return nil }
        // Padding, the typing line or a banner, the list's heading, the conversation.
        let space = frame.maxY - 12 - rowHeight - 24 - 30 - 120
        return Int((space / SuggestionList.rowHeight - 0.5).rounded(.down))
    }

    /// The field row's height (without the controls' vertical padding).
    @State private var rowHeight: CGFloat = 0

    private var tableTopTyping: Bool { model.isTableTop && model.keyboardVisible }

    /// Suggestions as one row of chips: table-top with the keyboard up (the
    /// keyboard fills the bottom half), or wherever fewer than two list rows fit.
    private var usesStrip: Bool {
        tableTopTyping || (fittingRows ?? 2) < 2
    }

    /// Table-top while typing: the gap to leave so the field sits under the
    /// fold (on the keyboard) and everything above it stays above the fold,
    /// and whether the strip fits under the fold too. Nil otherwise.
    private func foldLayout(hasStrip: Bool) -> (spacer: CGFloat, stripBelow: Bool)? {
        guard tableTopTyping, case .tableTop(let foldMinY, let foldHeight) = model.fold.posture,
              rowHeight > 0, frame.maxY > foldMinY + foldHeight else { return nil }
        // From the bottom: 6 pt padding, the field row, then 6 pt between rows.
        let rowTop = frame.maxY - 6 - rowHeight
        let stripTop = rowTop - 6 - SuggestionStrip.height
        let stripBelow = hasStrip && stripTop >= foldMinY + foldHeight
        // The row above the gap ends at the fold's top edge.
        let spacer = (stripBelow ? stripTop : rowTop) - 6 - (foldMinY + 6)
        return (max(0, spacer), stripBelow)
    }

    private func strip(_ query: Autocomplete.Query, _ suggestions: [Autocomplete.Suggestion]) -> some View {
        SuggestionStrip(query: query, suggestions: suggestions, highlighted: min(highlighted, suggestions.count - 1)) { accept($0, for: query) }
            .padding(.leading, hingeInset)
            .transition(.opacity)
    }

    /// Book pose with the conversation spanning both pages (sidebar hidden):
    /// the list starts on the right page, never on the hinge.
    private var hingeInset: CGFloat {
        guard case .book(let minX, let width) = model.fold.posture, frame.minX < minX, frame.maxX > minX + width else { return 0 }
        return minX + width - frame.minX
    }

    private func accept(_ suggestion: Autocomplete.Suggestion, for query: Autocomplete.Query) {
        let cursor = model.apply(suggestion, for: query, in: channel.id)
        let text = draft.wrappedValue.text
        let index = text.index(text.startIndex, offsetBy: min(cursor, text.count))
        model.composerContinuity.saveSelection(NSRange(index..<index, in: text), text: text, in: channel.id)
        highlighted = 0
        model.composerContinuity.requestFocus(in: channel.id)
        UIAccessibility.post(notification: .announcement, argument: "Inserted \(suggestion.spokenName)")
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        guard let query = activeQuery else { return .ignored }
        let suggestions = model.suggestions(for: query, in: channel)
        guard !suggestions.isEmpty else { return .ignored }
        switch key {
        case .downArrow: highlighted = (min(highlighted, suggestions.count - 1) + 1) % suggestions.count
        case .upArrow: highlighted = (min(highlighted, suggestions.count - 1) + suggestions.count - 1) % suggestions.count
        case .return, .tab: accept(suggestions[min(highlighted, suggestions.count - 1)], for: query)
        case .escape: dismissedQuery = query
        default: return .ignored
        }
        if key == .downArrow || key == .upArrow {
            UIAccessibility.post(notification: .announcement, argument: suggestions[highlighted].spokenName)
        }
        return .handled
    }

    /// VoiceOver hears when suggestions appear (and how many), not every keystroke.
    private func announce(_ summary: SuggestionSummary, previous: SuggestionSummary, first: Autocomplete.Suggestion?) {
        guard summary.count > 0, summary.trigger != previous.trigger || summary.count != previous.count else { return }
        let kind = switch summary.trigger {
        case .mention?: "mention"
        case .emoji?: "emoji"
        case .channel?: "channel"
        case nil: ""
        }
        let first = first.map { ", \($0.spokenName)" } ?? ""
        UIAccessibility.post(notification: .announcement, argument: "\(summary.count) \(kind) suggestion\(summary.count == 1 ? "" : "s")\(first)")
    }

    /// While composing on the outer display the system may minimise the
    /// title bar, so the destination always shows next to a non-empty draft.
    private var draftWraps: Bool { !draft.wrappedValue.text.isEmpty }

    private var placeholder: String {
        channel.type.isPrivate ? "Message @\(store.dmName(channel))" : "Message #\(channel.name ?? "")"
    }

    private var isEditing: Bool { draft.wrappedValue.editing != nil }

    private var canSend: Bool {
        let hasText = !draft.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isEditing ? hasText : hasText || !draft.wrappedValue.attachments.isEmpty
    }

    private func addPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                let ext = type.preferredFilenameExtension ?? "jpg"
                let file = DraftAttachment(filename: "image-\(Int(Date.now.timeIntervalSince1970)).\(ext)", data: data,
                                           contentType: type.preferredMIMEType ?? "image/jpeg",
                                           thumbnail: ImagePipeline.downsample(data, maxPixel: 160, scale: 2))
                draft.wrappedValue.attachments.append(file)
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 25_000_000 else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            draft.wrappedValue.attachments.append(DraftAttachment(filename: url.lastPathComponent, data: data,
                                                                  contentType: type.preferredMIMEType ?? "application/octet-stream",
                                                                  thumbnail: type.conforms(to: .image) ? ImagePipeline.downsample(data, maxPixel: 160, scale: 2) : nil))
        }
    }
}

/// What VoiceOver is told about: which kind of suggestions, and how many.
struct SuggestionSummary: Equatable {
    var trigger: Autocomplete.Trigger?
    var count: Int
    init(query: Autocomplete.Query?, count: Int) { trigger = query?.trigger; self.count = count }
}

extension Autocomplete.Suggestion {
    /// How a row reads to VoiceOver and in announcements.
    var spokenName: String {
        switch self {
        case .member(let user, let name): name == user.username ? name : "\(name), \(user.username)"
        case .role(let role): "\(role.name) role"
        case .mass(let word): "at \(word)"
        case .emoji(let emoji, let name): emoji.id == nil ? (emoji.name ?? name) + " " + name.replacingOccurrences(of: "_", with: " ") : "\(name) emoji"
        case .channel(let channel): "\(channel.name ?? "") channel"
        }
    }
}

/// Autocomplete for the composer: members, roles, emoji or channels
/// matching the word being typed, in 44 pt rows.
struct SuggestionList: View {
    @Environment(DiscordStore.self) private var store
    let query: Autocomplete.Query
    let suggestions: [Autocomplete.Suggestion]
    let highlighted: Int
    let maxRows: Int
    let guildID: Snowflake?
    let choose: (Autocomplete.Suggestion) -> Void

    static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(suggestion, isHighlighted: index == highlighted)
                                .id(suggestion.id)
                        }
                    }
                }
                .scrollIndicators(suggestions.count > maxRows ? .visible : .hidden)
                // A part row peeks when there are more, so the list reads as scrollable.
                .frame(height: Self.rowHeight * (suggestions.count > maxRows ? CGFloat(maxRows) + 0.5 : CGFloat(suggestions.count)))
                .onChange(of: highlighted) { _, index in
                    guard suggestions.indices.contains(index) else { return }
                    withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(suggestions[index].id) }
                }
            }
        }
        .padding(.bottom, 4)
        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("suggestions")
    }

    private var title: String { Self.title(for: query) }

    /// What the suggestions are, as a heading and for VoiceOver.
    static func title(for query: Autocomplete.Query) -> String {
        switch query.trigger {
        case .mention: query.text.isEmpty ? "Members" : "Members matching @\(query.text)"
        case .emoji: "Emoji matching :\(query.text)"
        case .channel: query.text.isEmpty ? "Channels" : "Channels matching #\(query.text)"
        }
    }

    private func row(_ suggestion: Autocomplete.Suggestion, isHighlighted: Bool) -> some View {
        Button { choose(suggestion) } label: {
            HStack(spacing: 10) {
                Self.icon(suggestion)
                    .frame(width: 28, height: 28)
                Text(Self.primary(suggestion))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Self.primaryColor(suggestion))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let secondary = secondary(suggestion) {
                    Text(secondary)
                        .font(.footnote)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(isHighlighted ? Color.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(suggestion.spokenName)
        .accessibilityHint("Inserts it in your message")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("suggestion-\(suggestion.id)")
    }

    @ViewBuilder
    static func icon(_ suggestion: Autocomplete.Suggestion) -> some View {
        switch suggestion {
        case .member(let user, _):
            AvatarView(user: user, size: 28)
        case .role(let role):
            Image(systemName: "at").font(.body.weight(.bold))
                .foregroundStyle(role.color != 0 ? Color(uiColor: .role(role.color)) : Color.textSecondary)
        case .mass:
            Image(systemName: "at").font(.body.weight(.bold)).foregroundStyle(Color.textSecondary)
        case .emoji(let emoji, _):
            EmojiGlyph(emoji: emoji, size: 24)
        case .channel(let channel):
            Image(systemName: ChannelRow.symbol(for: channel)).font(.callout.weight(.semibold)).foregroundStyle(Color.textSecondary)
        }
    }

    static func primary(_ suggestion: Autocomplete.Suggestion) -> String {
        switch suggestion {
        case .member(_, let name): name
        case .role(let role): "@\(role.name)"
        case .mass(let word): "@\(word)"
        case .emoji(_, let name): ":\(name):"
        case .channel(let channel): channel.name ?? ""
        }
    }

    static func primaryColor(_ suggestion: Autocomplete.Suggestion) -> Color {
        if case .role(let role) = suggestion, role.color != 0 { return Color(uiColor: .role(role.color)) }
        return Color.textPrimary
    }

    private func secondary(_ suggestion: Autocomplete.Suggestion) -> String? {
        switch suggestion {
        case .member(let user, let name): name == user.username ? nil : user.username
        case .role: "Role"
        case .mass(let word): word == "here" ? "Notify everyone online here" : "Notify everyone in this channel"
        case .emoji(let emoji, _): emoji.id != nil ? guildID.flatMap { store.guilds[$0]?.name } : nil
        case .channel(let channel):
            // Threads say which channel they're in; channels their category.
            channel.parentID.flatMap { store.channel($0)?.name }
        }
    }
}

/// Autocomplete as one row of 44 pt chips, where the list has no room:
/// table-top with the keyboard up, or a short window.
struct SuggestionStrip: View {
    let query: Autocomplete.Query
    let suggestions: [Autocomplete.Suggestion]
    let highlighted: Int
    let choose: (Autocomplete.Suggestion) -> Void

    /// The chips and their padding.
    static let height: CGFloat = SuggestionList.rowHeight + 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        chip(suggestion, isHighlighted: index == highlighted)
                            .id(suggestion.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: highlighted) { _, index in
                guard suggestions.indices.contains(index) else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(suggestions[index].id) }
            }
        }
        .frame(height: SuggestionList.rowHeight)
        .padding(.vertical, 4)
        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SuggestionList.title(for: query))
        .accessibilityIdentifier("suggestions")
    }

    private func chip(_ suggestion: Autocomplete.Suggestion, isHighlighted: Bool) -> some View {
        Button { choose(suggestion) } label: {
            HStack(spacing: 6) {
                SuggestionList.icon(suggestion)
                    .frame(width: 24, height: 24)
                Text(SuggestionList.primary(suggestion))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SuggestionList.primaryColor(suggestion))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: SuggestionList.rowHeight, minHeight: SuggestionList.rowHeight)
            .background(isHighlighted ? Color.selectedRow : Color.chatBackground.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(suggestion.spokenName)
        .accessibilityHint("Inserts it in your message")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("suggestion-\(suggestion.id)")
    }
}

/// Discord's "@ On / @ Off" in the reply banner: whether the reply pings
/// the person you're replying to.
struct ReplyPingToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.pingReplies.toggle()
        } label: {
            Text(model.pingReplies ? "@ On" : "@ Off")
                .font(.caption.weight(.bold))
                .foregroundStyle(model.pingReplies ? Color.accentBlurple : Color.textMuted)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mention author")
        .accessibilityValue(model.pingReplies ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("replyPing")
    }
}

struct AttachmentChip: View {
    let file: DraftAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = file.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.title2)
                        Text(file.filename).font(.caption2).lineLimit(1)
                    }
                    .padding(6)
                }
            }
            .frame(width: 72, height: 72)
            .background(Color.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button("Remove \(file.filename)", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .font(.system(size: 20))
                .frame(width: 32, height: 32)
                .offset(x: 8, y: -8)
        }
    }
}

// MARK: - Bridge to the UIKit list

struct MessageListView: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    let channel: Channel

    func makeCoordinator() -> ListCoordinator { ListCoordinator() }

    func makeUIViewController(context: Context) -> MessageListController {
        let timeline = model.timeline(for: channel.id)
        let store = model.store
        let title: String
        let subtitle: String
        let icon: String
        if channel.type.isPrivate {
            title = store.dmName(channel)
            subtitle = "This is the beginning of your direct message history with \(title)."
            icon = channel.type == .groupDM ? "person.2.fill" : "person.fill"
        } else {
            title = "Welcome to #\(channel.name ?? "")!"
            subtitle = channel.topic ?? "This is the start of the #\(channel.name ?? "") channel."
            icon = channel.type.isThread ? "bubble.left.fill" : (channel.type.isVoice ? "speaker.wave.2.fill" : "number")
        }
        let controller = MessageListController(timeline: timeline, store: store, api: model.api, guildID: channel.guildID,
                                               title: title, subtitle: subtitle, icon: icon,
                                               anchor: model.anchors[channel.id], unreadAfter: model.unreadBoundary(for: channel.id))
        context.coordinator.model = model
        context.coordinator.channel = channel
        context.coordinator.controller = controller
        controller.host = context.coordinator
        Task { await timeline.loadLatest(api: model.api, store: store) }
        return controller
    }

    func updateUIViewController(_ controller: MessageListController, context: Context) {
        let boundary = model.unreadBoundary(for: channel.id), target = model.explicitUnreadTarget(for: channel.id)
        DispatchQueue.main.async {
            guard model.selectedChannel == channel.id, model.unreadBoundary(for: channel.id) == boundary,
                  model.explicitUnreadTarget(for: channel.id) == target else { return }
            controller.setUnreadBoundary(boundary, target: target)
        }
        if let request = model.jumpRequest, request.channel == channel.id, request.token != context.coordinator.lastJump {
            context.coordinator.lastJump = request.token
            DispatchQueue.main.async {
                // Consume only this request; a newer one stays pending.
                guard model.jumpRequest?.token == request.token else { return }
                model.jumpRequest = nil
                controller.jumpToPresent()
            }
        }
        if let request = model.revealRequest, request.channel == channel.id, request.token != context.coordinator.lastReveal {
            context.coordinator.lastReveal = request.token
            DispatchQueue.main.async {
                guard model.selectedChannel == channel.id, model.revealRequest?.token == request.token else { return }
                controller.reveal(request.message)
            }
        }
    }
}

final class ListCoordinator: MessageListHost {
    weak var model: AppModel?
    var channel: Channel?
    weak var controller: MessageListController?
    var lastReveal: UUID?
    var lastJump: UUID?

    func list(openMedia item: MediaItem, from view: UIView) { model?.sheet = .media(item) }

    func list(openURL url: URL) {
        // Discord message links open in the app.
        if url.host?.hasSuffix("discord.com") == true, url.pathComponents.count >= 4, url.pathComponents[1] == "channels",
           let channel = Snowflake(url.pathComponents[3]) {
            model?.open(channel: channel, message: url.pathComponents.count > 4 ? Snowflake(url.pathComponents[4]) : nil)
            return
        }
        guard url.scheme == "https" || url.scheme == "http" else { return }
        UIApplication.shared.open(url)
    }

    func list(openUser user: Snowflake) { model?.sheet = .user(user) }
    func list(openChannel channel: Snowflake) { model?.select(channel: channel) }

    func list(toggleReaction emoji: Emoji, on message: Snowflake) {
        guard let channel else { return }
        model?.toggleReaction(emoji, message: message, channel: channel.id)
    }

    func list(showReactions emoji: Emoji, on message: Snowflake) {
        guard let channel else { return }
        model?.present(.reactions(channel: channel.id, message: message, emoji: emoji.reactionKey))
    }

    func list(addReactionTo message: Snowflake) {
        guard let channel else { return }
        model?.present(.emojiPicker(channel: channel.id, message: message))
    }

    func list(reply message: Message) { model?.reply(to: message) }
    func list(retry message: Message) { model?.retry(message) }
    func list(discard message: Message) { model?.discard(message) }
    func list(markUnread message: Message) { model?.markUnread(message) }
    func listReaderMoved() {
        guard let channel, model?.selectedChannel == channel.id else { return }
        model?.automaticReadCeilings[channel.id] = nil
    }
    func list(firstVisible message: Snowflake?) {
        guard let channel, model?.selectedChannel == channel.id else { return }
        if model?.firstVisibleMessages[channel.id] != message { model?.firstVisibleMessages[channel.id] = message }
    }

    func list(edit message: Message) { model?.beginEdit(message) }
    func list(delete message: Message) { model?.delete(message) }

    func listQuickReactions() -> [String] {
        // Unicode recents first (menu images are drawn from text), then the defaults.
        let recent = model?.settings.recentEmoji.filter { $0.id == nil }.compactMap(\.name) ?? []
        var seen = Set<String>()
        return (recent + MessageListController.defaultQuickReactions).filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    func list(didReadUpTo message: Snowflake) {
        guard let channel else { return }
        model?.didRead(channel: channel.id, upTo: message)
    }

    func list(saveAnchor anchor: ScrollAnchor) {
        guard let channel else { return }
        model?.anchors[channel.id] = anchor
    }

    func listNearBottomChanged(_ nearBottom: Bool) {
        model?.store.visibleIsLive = nearBottom && (model?.isActive ?? false)
        if model?.viewingHistory != !nearBottom {
            withAnimation(.snappy(duration: 0.2)) { model?.viewingHistory = !nearBottom }
        }
    }
}

/// UITextView supplies the actual edited range, which a plain String
/// binding cannot recover when two mentions have identical display names.
struct ComposerTextInput: UIViewRepresentable {
    @Binding var draft: Draft
    let model: AppModel
    let channelID: Snowflake
    var wantsFocus: Bool
    var maximumLines: Int
    var placeholder = "Message"
    var hasSuggestions: Bool
    var handleKey: (KeyEquivalent) -> KeyPress.Result

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Input {
        let view = Input()
        view.delegate = context.coordinator
        view.attachmentChanged = { [weak coordinator = context.coordinator] view in
            coordinator?.windowChanged(view)
        }
        view.pastedImages = { [weak coordinator = context.coordinator] files in
            coordinator?.attach(files)
        }
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "composer"
        view.isAccessibilityElement = true
        return view
    }

    func updateUIView(_ view: Input, context: Context) {
        context.coordinator.owner = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = Theme.textPrimary
        view.accessibilityLabel = placeholder
        view.commandHandler = handleKey
        view.commandsEnabled = hasSuggestions
        // An edit changes text only (the attachment button is disabled too).
        view.acceptsImages = draft.editing == nil
        if view.text?.utf16.elementsEqual(draft.text.utf16) != true {
            view.text = draft.text
            context.coordinator.pending = nil
        }
        let selected = model.composerContinuity.selection(in: channelID, text: draft.text)
        if view.markedTextRange == nil, view.selectedRange != selected { view.selectedRange = selected }
        if wantsFocus { context.coordinator.restoreFocus(view) }
        if model.composerContinuity.focusedChannel != channelID || model.selectedChannel != channelID {
            if view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ view: Input, coordinator: Coordinator) {
        coordinator.saveSelection(view)
        coordinator.dismantled = true
        coordinator.owner.model.composerContinuity.detach(coordinator.lease, in: coordinator.owner.channelID)
        view.delegate = nil
        view.attachmentChanged = nil
        view.pastedImages = nil
        view.commandHandler = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Input, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(max(line, fit.height), line * CGFloat(maximumLines)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var owner: ComposerTextInput
        var updating = false
        var pending: (text: String, tokens: [ComposerToken])?
        let lease: UUID
        var dismantled = false
        var endingEditing = false
        private var detachRevision = 0
        init(_ owner: ComposerTextInput) {
            self.owner = owner
            lease = owner.model.composerContinuity.attach(in: owner.channelID)
        }

        private var ownsField: Bool {
            !dismantled && owner.model.composerContinuity.owns(lease, in: owner.channelID)
        }

        func saveSelection(_ view: UITextView) {
            guard ownsField, let text = view.text, text.utf16.elementsEqual(owner.draft.text.utf16) else { return }
            owner.model.composerContinuity.saveSelection(view.selectedRange, text: text, in: owner.channelID, owner: lease)
        }

        func windowChanged(_ view: Input) {
            if view.window == nil {
                detachRevision += 1
                saveSelection(view)
            } else { restoreFocus(view) }
        }

        func restoreFocus(_ view: Input) {
            // UIKit can reject focus before insertion into a window. Retry at
            // attachment, not with a timer; never resurrect a dismissed field.
            guard ownsField, !endingEditing, view.window != nil, !view.isFirstResponder,
                  owner.model.composerContinuity.shouldFocus(lease, in: owner.channelID,
                                                            selectedChannel: owner.model.selectedChannel) else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.ownsField, !self.endingEditing, view.window != nil,
                      self.owner.model.composerContinuity.shouldFocus(self.lease, in: self.owner.channelID,
                                                                     selectedChannel: self.owner.model.selectedChannel) else { return }
                view.becomeFirstResponder()
            }
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard ownsField, owner.model.selectedChannel == owner.channelID else { return false }
            let old = view.text ?? ""
            guard let edit = Range(range, in: old), old.utf16.elementsEqual(owner.draft.text.utf16) else {
                pending = nil
                return true
            }
            pending = (old.replacingCharacters(in: edit, with: replacement),
                       Autocomplete.rebase(owner.draft.tokens, in: old, replacing: range, with: replacement))
            return true
        }

        func textViewDidChange(_ view: UITextView) {
            guard !updating, ownsField, owner.model.selectedChannel == owner.channelID else { return }
            var draft = owner.draft
            draft.text = view.text ?? ""
            if let pending, pending.text == draft.text { draft.tokens = pending.tokens }
            pending = nil
            owner.draft = draft
            textViewDidChangeSelection(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            saveSelection(view)
        }

        func attach(_ files: [DraftAttachment]) {
            guard ownsField, owner.model.selectedChannel == owner.channelID, owner.draft.editing == nil else { return }
            owner.draft.attachments.append(contentsOf: files)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard ownsField else { return }
            endingEditing = false
            owner.model.composerContinuity.beganEditing(lease, in: owner.channelID, selectedChannel: owner.model.selectedChannel)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            saveSelection(textView)
            endingEditing = true
            let wasAttached = textView.window != nil
            let revision = detachRevision
            let focusRevision = owner.model.composerContinuity.focusRevision
            // End-editing also arrives while a navigation container is being
            // replaced. Let dismantle/window removal/new ownership settle first.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.ownsField, let textView, !textView.isFirstResponder else { return }
                self.owner.model.composerContinuity.endedEditing(self.lease, in: self.owner.channelID,
                                                                isAttached: wasAttached && textView.window != nil && revision == self.detachRevision,
                                                                revision: focusRevision)
                self.endingEditing = false
                if let input = textView as? Input { self.restoreFocus(input) }
            }
        }
    }

    final class Input: UITextView {
        var commandsEnabled = false
        var attachmentChanged: ((Input) -> Void)?
        /// A plain-text view refuses pasted images; they become attachments.
        var pastedImages: (([DraftAttachment]) -> Void)?
        var acceptsImages = true
        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachmentChanged?(self)
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), acceptsImages, pastedImages != nil, UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard acceptsImages, let pastedImages, UIPasteboard.general.hasImages else { return super.paste(sender) }
            let files = Self.images(in: UIPasteboard.general)
            if files.isEmpty { super.paste(sender) } else { pastedImages(files) }
        }

        /// Each pasted image in its original encoding (so a GIF stays animated).
        /// Raw bytes per item: `items` hands images back as re-encodable UIImages.
        static func images(in pasteboard: UIPasteboard) -> [DraftAttachment] {
            let stamp = Int(Date.now.timeIntervalSince1970)
            return (0..<pasteboard.numberOfItems).compactMap { index in
                let set = IndexSet(integer: index)
                let types = (pasteboard.types(forItemSet: set)?.first ?? []).compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
                guard let type = types.first(where: { $0 == .gif }) ?? types.first(where: { $0 == .png }) ?? types.first,
                      let data = pasteboard.data(forPasteboardType: type.identifier, inItemSet: set)?.first,
                      data.count < 25_000_000 else { return nil }
                return DraftAttachment(filename: "image-\(stamp).\(type.preferredFilenameExtension ?? "png")", data: data,
                                       contentType: type.preferredMIMEType ?? "image/png",
                                       thumbnail: ImagePipeline.downsample(data, maxPixel: 160, scale: 2))
            }
        }
        var commandHandler: ((KeyEquivalent) -> KeyPress.Result)?
        override var keyCommands: [UIKeyCommand]? {
            guard commandsEnabled else { return super.keyCommands }
            return [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\t", UIKeyCommand.inputEscape].map {
                let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(chooseSuggestion))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        @objc private func chooseSuggestion(_ command: UIKeyCommand) {
            let key: KeyEquivalent
            switch command.input {
            case UIKeyCommand.inputUpArrow: key = .upArrow
            case UIKeyCommand.inputDownArrow: key = .downArrow
            case "\r": key = .return
            case "\t": key = .tab
            default: key = .escape
            }
            _ = commandHandler?(key)
        }
    }
}
