import SwiftUI

extension EnvironmentValues {
    /// Set when a lookup is shown as a sidebar panel instead of a sheet.
    @Entry var closePanel: (() -> Void)? = nil
}

/// A message in search results, pins and the inbox: tap to jump to it.
struct MessageResultRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let message: Message
    var showChannel = true
    @State private var reveal: ExcerptRevealScope?

    func presentation(store: DiscordStore, reveal: ExcerptRevealScope? = nil) -> MessageExcerptPresentation {
        SnippetView(message: message).presentation(store: store, reveal: reveal)
    }

    var body: some View {
        let guild = message.guildID ?? store.channel(message.channelID)?.guildID
        let content = presentation(store: store, reveal: reveal)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.open(channel: message.channelID, message: message.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if let user = content.avatarUser { AvatarView(user: user, size: 36) }
                    VStack(alignment: .leading, spacing: 3) {
                        if content.concealed {
                            Text(content.restricted ? "Content unavailable" : "Blocked user").font(.subheadline.weight(.semibold)).foregroundStyle(Color.textMuted)
                        } else {
                            HStack(spacing: 6) {
                                Text(store.displayName(for: message.author, in: guild))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(store.roleColor(for: message.author.id, in: guild).map(Color.role) ?? Color.textPrimary)
                                    .lineLimit(1)
                                Text(MessageBuilder.stamp(message.date))
                                    .font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                            }
                        }
                        if showChannel, !content.restricted, let channel = store.channel(message.channelID) {
                            Text(channelLabel(channel)).font(.caption.weight(.medium))
                                .foregroundStyle(Color.textSecondary).lineLimit(1)
                        }
                        SnippetView(message: message, reveal: reveal).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the message in its channel")
            if content.concealed, !content.restricted {
                Button("Reveal message") { reveal = content.scope }
                    .font(.subheadline).buttonStyle(.borderless)
                    .accessibilityHint("Reveals this excerpt only")
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func channelLabel(_ channel: Channel) -> String {
        if channel.type.isPrivate { return store.dmName(channel) }
        let guildName = channel.guildID.flatMap { store.guilds[$0]?.name } ?? ""
        return "#\(channel.name ?? "") · \(guildName)"
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() {
        lookup.invalidate()
        if let closePanel { closePanel() } else { dismiss() }
    }
    @State private var query = ""
    @State private var thisChannelOnly = false
    @State private var lookup = LookupPagingState<SearchPageIdentity, Message>()
    @State private var presentationID = UUID()
    /// The last request run, so a jump from the results can run it again.
    @State private var lastRun: SearchPageIdentity?

    private var pagingIdentity: SearchPageIdentity? {
        submission.map { SearchPageIdentity(submission: $0, presentation: presentationID, sidebar: closePanel != nil, navigation: model.navigationIntent) }
    }

    private var channel: Channel? { model.selectedChannel.flatMap { store.channel($0) } }

    private var submission: SearchSubmission? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.phase == .signedIn,
              closePanel == nil ? model.sheet == .search : model.sidebarPanel == .search,
              !text.isEmpty, let channel else { return nil }
        return SearchSubmission(context: LookupContext(model: model, store: store), query: text,
                                guild: channel.guildID,
                                channel: (thisChannelOnly || channel.guildID == nil) ? channel.id : nil,
                                scopeName: selectedScopeName)
    }

    // Both the sheet field and sidebar field invalidate synchronously on edits.
    // Draft/scope/navigation changes require an explicit new submission.
    private var searchQuery: Binding<String> {
        Binding(get: { query }, set: { value in
            guard query != value else { return }
            lookup.invalidate()
            query = value
        })
    }

    private var searchScope: Binding<Bool> {
        Binding(get: { thisChannelOnly }, set: { value in
            guard thisChannelOnly != value else { return }
            lookup.invalidate()
            thisChannelOnly = value
        })
    }

    private var selectedScopeName: String {
        if thisChannelOnly, channel?.guildID != nil { return "#\(channel?.name ?? "")" }
        return scopeName
    }

    var body: some View {
        NavigationStack {
            List {
                if closePanel != nil {
                    // Panel mode has no navigation bar: an inline field instead.
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.textMuted)
                        TextField("Search \(selectedScopeName)", text: searchQuery)
                            .submitLabel(.search)
                            .onSubmit { run() }
                            .accessibilityIdentifier("searchField")
                        if !query.isEmpty {
                            Button("Clear Search", systemImage: "xmark.circle.fill") { searchQuery.wrappedValue = "" }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(Color.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if channel?.guildID != nil {
                    Picker("Scope", selection: searchScope) {
                        Text(scopeName).tag(false)
                        Text("#\(channel?.name ?? "")").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                let snapshot = lookup.snapshot(for: pagingIdentity)
                let results = snapshot.rows
                switch snapshot.status {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                case .failed(let message):
                    ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(message))
                case .done where results.isEmpty:
                    ContentUnavailableView.search(text: snapshot.input?.submission.query ?? "")
                case .done:
                    Section {
                        ForEach(results) { MessageResultRow(message: $0) }
                    } header: {
                        Text("\((snapshot.total ?? 0).formatted()) results in \(snapshot.input?.submission.scopeName ?? "")")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.textMuted)
                            .textCase(nil)
                            .padding(.leading, 12)
                    }
                }
                if snapshot.status == .done, let identity = snapshot.input {
                    LookupPagingControls(progress: snapshot.more,
                                         loadMore: { lookup.loadMore(identity) }, reload: { run() })
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .modifier(SheetSearchField(enabled: closePanel == nil, query: searchQuery, prompt: "Search \(selectedScopeName)"))
            .onSubmit(of: .search) { run() }
            .onChange(of: pagingIdentity) {
                lookup.invalidate(unless: pagingIdentity)
                if pagingIdentity?.repeatsRequest(of: lastRun) == true { run() }
            }
            .task {
                #if DEBUG
                if let preset = UserDefaults.standard.string(forKey: "DuocordSearchQuery"), query.isEmpty {
                    query = preset
                    run()
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } }
            }
        }
        .onDisappear { lookup.invalidate() }
    }

    private var scopeName: String {
        if let guild = channel?.guildID, let name = store.guilds[guild]?.name { return name }
        return channel.map { store.dmName($0) } ?? "Discord"
    }

    private func run() {
        guard let identity = pagingIdentity else { lookup.invalidate(); return }
        lastRun = identity
        let submission = identity.submission
        let api = model.api
        let targetStore = store
        lookup.start(identity, load: { offset in
            .search(try await api.search(guild: submission.guild, channel: submission.channel, query: submission.query, offset: offset))
        }, isCurrent: { self.pagingIdentity == identity }, publish: { page in
            targetStore.remember(messageAuthors: page.rows)
        })
    }
}

struct PinsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() {
        lookup.invalidate()
        if let closePanel { closePanel() } else { dismiss() }
    }
    @State private var lookup = OtherListState<PinsListIdentity, Message, String>()
    @State private var presentationID = UUID()

    private var submission: PinsListIdentity? {
        PinsListIdentity.current(model: model, store: store, presentation: presentationID, sidebar: closePanel != nil)
    }

    private func load(_ submission: PinsListIdentity?) async {
        guard !Task.isCancelled else { return }
        guard let submission else { lookup.invalidate(); return }
        let api = model.api, targetStore = store
        let request = OtherListConsumers.pins(lookup, input: submission, api: api, channel: submission.pins.channel,
                                              store: targetStore, isCurrent: { self.submission == submission })
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    var body: some View {
        NavigationStack {
            List {
                let snapshot = lookup.snapshot(for: submission)
                if case .failed(let error) = snapshot.status {
                    ContentUnavailableView("Couldn't Load Pins", systemImage: "pin.slash", description: Text(error))
                    Button("Retry Pins") { Task { await load(submission) } }
                } else if snapshot.status == .done {
                    let pins = snapshot.rows
                    if pins.isEmpty {
                        ContentUnavailableView("No Pinned Messages", systemImage: "pin", description: Text("Pinned messages in this channel appear here."))
                    }
                    ForEach(pins) { MessageResultRow(message: $0, showChannel: false) }
                    if let accepted = snapshot.input {
                        LookupPagingControls(progress: snapshot.more,
                                             loadMore: { lookup.loadMore(accepted) },
                                             reload: { Task { await load(submission) } })
                    }
                } else if submission != nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("Select a Channel", systemImage: "pin")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Pinned Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } } }
            .task(id: submission) { await load(submission) }
            .refreshable { await load(submission) }
        }
        .onDisappear { lookup.invalidate(); presentationID = UUID() }
        .presentationDetents([.medium, .large])
    }
}

/// Recent mentions and unread direct messages.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() {
        lookup.invalidate()
        if let closePanel { closePanel() } else { dismiss() }
    }
    @State private var lookup = OtherListState<OtherListIdentity, Message, Snowflake>()
    @State private var presentationID = UUID()
    private var submission: OtherListIdentity? {
        OtherListIdentity.current(model: model, store: store, route: .inbox, presentation: presentationID, sidebar: closePanel != nil)
    }
    @State private var tab = 0
    @State private var previews = InboxPreviews()
    @AppStorage(InboxUnreadPreferenceKey.grouping) private var grouping = InboxUnreadOrganization.standard.grouping
    @AppStorage(InboxUnreadPreferenceKey.filter) private var filter = InboxUnreadOrganization.standard.filter
    @AppStorage(InboxUnreadPreferenceKey.sort) private var sort = InboxUnreadOrganization.standard.sort
    @State private var unreadQuery = ""

    var body: some View {
        NavigationStack {
            List {
                Picker("Inbox", selection: $tab) {
                    Text("Mentions").tag(0)
                    Text("Unreads").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
                if tab == 0 {
                    let snapshot = lookup.snapshot(for: submission)
                    if case .failed(let error) = snapshot.status {
                        ContentUnavailableView("Couldn't Load Mentions", systemImage: "at", description: Text(error))
                        Button("Retry Mentions") { Task { await load(submission) } }
                    } else if snapshot.status == .done {
                        let mentions = snapshot.rows
                        if mentions.isEmpty { ContentUnavailableView("No Recent Mentions", systemImage: "at") }
                        ForEach(mentions) { MessageResultRow(message: $0) }
                        if let accepted = snapshot.input {
                            LookupPagingControls(progress: snapshot.more,
                                                 loadMore: { lookup.loadMore(accepted) },
                                                 reload: { Task { await load(submission) } })
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                } else {
                    let unread = InboxLists.organizedUnreads(store: store, organization: organization.wrappedValue)
                    if unread.isCaughtUp {
                        ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle")
                    } else {
                        InboxUnreadControls(organization: organization, reset: resetOrganization)
                        if unread.isHiddenByOrganization {
                            ContentUnavailableView {
                                Label("No Matching Unreads", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("Unread conversations are hidden by the current filter or search.")
                            } actions: {
                                Button("Show All Unreads") { filter = .all; unreadQuery = "" }
                            }
                        }
                    }
                    // Previews load per visible row, never for the whole list at once.
                    ForEach(unread.sections) { section in
                        if let title = section.title {
                            Section {
                                unreadRows(section.rows)
                            } header: {
                                HStack {
                                    Text(title).lineLimit(1)
                                    Spacer()
                                    Text("\(section.rows.count)").monospacedDigit()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        } else {
                            unreadRows(section.rows)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
             .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } }
                if tab == 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark All Read", systemImage: "checkmark.message") { model.markAllAsRead() }
                    }
                }
            }
            .task(id: submission) { await load(submission) }
            .refreshable { await load(submission) }
        }
        .onDisappear { lookup.invalidate(); previews.invalidate(); presentationID = UUID() }
    }

    private func load(_ submission: OtherListIdentity?) async {
        guard !Task.isCancelled else { return }
        guard let submission else { lookup.invalidate(); return }
        let api = model.api, targetStore = store
        let request = OtherListConsumers.mentions(lookup, input: submission, api: api, store: targetStore,
                                                 isCurrent: { self.submission == submission })
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    private var organization: Binding<InboxUnreadOrganization> {
        Binding {
            InboxUnreadOrganization(grouping: grouping, filter: filter, sort: sort, query: unreadQuery)
        } set: { value in
            if grouping != value.grouping { grouping = value.grouping }
            if filter != value.filter { filter = value.filter }
            if sort != value.sort { sort = value.sort }
            if unreadQuery != value.query { unreadQuery = value.query }
        }
    }

    private func resetOrganization() {
        let standard = InboxUnreadOrganization.standard
        grouping = standard.grouping; filter = standard.filter; sort = standard.sort; unreadQuery = ""
    }

    private func unreadRows(_ rows: [Channel]) -> some View {
        ForEach(rows) { channel in
            InboxUnreadRow(channel: channel, previews: previews)
        }
    }
}

/// Active threads for a channel, plus archived ones on demand.
struct ThreadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() {
        lookup.invalidate()
        if let closePanel { closePanel() } else { dismiss() }
    }
    let parentID: Snowflake
    @State private var lookup = OtherListState<OtherListIdentity, Channel, String>()
    @State private var presentationID = UUID()
    private var submission: OtherListIdentity? {
        guard let parent = store.channel(parentID) else { return nil }
        return OtherListIdentity.current(model: model, store: store, route: .threads(parentID), parent: parent,
                                         presentation: presentationID, sidebar: closePanel != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                let active = submission == nil ? [] : store.threads(in: parentID)
                Section("Active") {
                    if active.isEmpty { Text("No active threads").foregroundStyle(Color.textMuted) }
                    ForEach(active) { thread in threadRow(thread) }
                }
                let snapshot = lookup.snapshot(for: submission)
                let archived = OtherListConsumers.archivedRows(snapshot.rows, active: active, store: store, parent: parentID)
                Section("Archived") {
                    ForEach(archived) { thread in threadRow(thread) }
                    if case .failed(let error) = snapshot.status {
                        ContentUnavailableView("Couldn't Load Archived Threads", systemImage: "exclamationmark.triangle", description: Text(error))
                        Button("Retry Archived Threads") { Task { await load(submission) } }
                    } else if snapshot.status == .done {
                        if archived.isEmpty { Text("No archived threads loaded").foregroundStyle(Color.textMuted) }
                        if let accepted = snapshot.input {
                            LookupPagingControls(progress: snapshot.more,
                                                 loadMore: { lookup.loadMore(accepted) },
                                                 reload: { Task { await load(submission) } })
                        }
                    } else if submission != nil {
                        ProgressView("Loading archived threads")
                    } else {
                        Text("Select a channel to load archived threads").foregroundStyle(Color.textMuted)
                    }
                }
            }
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } } }
            .task(id: submission) { await load(submission) }
            .refreshable { await load(submission) }
        }
        .threadPromptHost(.threadList)
        .onDisappear { lookup.invalidate(); presentationID = UUID() }
        .presentationDetents([.medium, .large])
    }

    private func load(_ submission: OtherListIdentity?) async {
        guard !Task.isCancelled else { return }
        guard let submission, let parent = submission.parent else { lookup.invalidate(); return }
        let api = model.api, targetStore = store
        let request = OtherListConsumers.archives(lookup, input: submission, api: api, parent: parent, store: targetStore,
                                                 isCurrent: { self.submission == submission })
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    private func threadRow(_ thread: Channel) -> some View {
        Button {
            model.open(channel: thread.id, message: nil)
        } label: {
            HStack {
                Image(systemName: thread.threadMetadata?.locked == true ? "lock.fill" : "bubble.left.fill").foregroundStyle(Color.textMuted)
                Text(thread.name ?? "").font(.body.weight(store.isUnread(thread) ? .semibold : .regular))
                Spacer()
                if let count = thread.messageCount { Text("\(count)").font(.caption).foregroundStyle(Color.textMuted) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(thread.threadMetadata?.locked == true ? "Locked" : "")
        .contextMenu { ThreadContextMenu(thread: thread.id) }
    }
}

/// A forum or media channel: its posts, newest activity first.
struct ForumView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    @State private var reveals: [Snowflake: ExcerptRevealScope] = [:]
    @State private var lookup = LookupPagingState<ForumSubmission, Channel>()
    @State private var presentationID = UUID()
    @State private var revealIdentity: ForumSubmission?

    private var submission: ForumSubmission? {
        guard model.phase == .signedIn, model.selectedChannel == channel.id else { return nil }
        return ForumSubmission(context: LookupContext(model: model, store: store),
                               forum: channel.id, presentation: presentationID, navigation: model.navigationIntent)
    }

    private func load(_ submission: ForumSubmission?) async {
        guard !Task.isCancelled else { return }
        reveals.removeAll(); revealIdentity = submission
        guard let submission else { lookup.invalidate(); return }
        let api = model.api, targetStore = store, forum = channel
        let request = lookup.start(submission, load: { offset in
            let revision = targetStore.channelRevision
            return .forum(try await api.forumThreads(channel: submission.forum, offset: offset),
                          forum: forum, store: targetStore, since: revision)
        }, isCurrent: { self.submission == submission }, publish: { page in
            targetStore.remember(threads: page.rows)
        })
        await withTaskCancellationHandler {
            await request.value
        } onCancel: { request.cancel() }
    }

    func excerptPresentation(_ message: Message, store: DiscordStore, reveal: ExcerptRevealScope? = nil) -> MessageExcerptPresentation {
        SnippetView(message: message).presentation(store: store, reveal: reveal)
    }

    func postPresentation(_ post: Channel, firstMessage: Message?, store: DiscordStore,
                          reveal: ExcerptRevealScope? = nil) -> ForumPostPresentation {
        guard store.contentAccess(to: post).permitsContent else {
            return ForumPostPresentation(title: "Content unavailable", excerpt: nil, revealScope: nil)
        }
        if let firstMessage {
            let content = excerptPresentation(firstMessage, store: store, reveal: reveal)
            guard !content.restricted else {
                return ForumPostPresentation(title: "Content unavailable", excerpt: nil, revealScope: nil)
            }
            return ForumPostPresentation(title: content.concealed ? "Blocked post" : (post.name ?? ""),
                                         excerpt: content, revealScope: content.concealed ? content.scope : nil)
        }
        // A missing first message does not make a known blocked owner's title public.
        if let owner = post.ownerID, store.isBlocked(owner) {
            let scope = ExcerptRevealScope(forumPost: post, forum: channel.id, owner: owner, store: store)
            if reveal != scope {
                return ForumPostPresentation(title: "Blocked post", excerpt: nil, revealScope: scope)
            }
        }
        return ForumPostPresentation(title: post.name ?? "", excerpt: nil, revealScope: nil)
    }

    var body: some View {
        List {
            let snapshot = lookup.snapshot(for: submission)
            // Posts follow the store, so a renamed, closed or deleted post updates in place.
            let posts = snapshot.rows.compactMap { store.channel($0.id) ?? (store.isReady ? nil : $0) }
            if case .failed(let error) = snapshot.status {
                ContentUnavailableView("Couldn't Load Posts", systemImage: "exclamationmark.triangle", description: Text(error))
                Button("Reload Posts") { Task { await load(submission) } }
            } else if snapshot.status == .done {
                if posts.isEmpty { ContentUnavailableView("No Posts Yet", systemImage: "bubble.left.and.text.bubble.right") }
                ForEach(posts) { post in
                    let content = postPresentation(post, firstMessage: snapshot.firstMessages[post.id], store: store, reveal: revealIdentity == submission ? reveals[post.id] : nil)
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            model.open(channel: post.id, message: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(content.title).font(.headline).foregroundStyle(Color.textPrimary)
                                if let excerpt = content.excerpt {
                                    Text(excerpt.text)
                                        .font(.subheadline).foregroundStyle(Color.textSecondary).lineLimit(3)
                                }
                                HStack(spacing: 12) {
                                    Label("\(post.messageCount ?? 0)", systemImage: "bubble.left")
                                    if let last = post.lastMessageID {
                                        Text(last.date.formatted(.relative(presentation: .named)))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Color.textMuted)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the forum post")
                        .contextMenu { ThreadContextMenu(thread: post.id) }
                        if let scope = content.revealScope {
                            Button("Reveal message") {
                                if revealIdentity != submission { reveals.removeAll(); revealIdentity = submission }
                                reveals[post.id] = scope
                            }
                                .font(.subheadline).buttonStyle(.borderless)
                                .accessibilityHint("Reveals this excerpt only")
                        }
                    }
                    .listRowBackground(Color.elevated)
                }
                if let accepted = snapshot.input {
                    LookupPagingControls(progress: snapshot.more,
                                         loadMore: { lookup.loadMore(accepted) },
                                         reload: { Task { await load(submission) } })
                }
            } else if submission != nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.chatBackground)
        .navigationTitle(channel.name ?? "Forum")
        .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            if !model.fold.isCompact, !model.isTableTop, model.columnVisibility != .detailOnly {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hide Sidebar", systemImage: "sidebar.leading") {
                        withAnimation(.snappy(duration: 0.3)) { model.columnVisibility = .detailOnly }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { model.present(.search) }
            }
        }
        .task(id: submission) { await load(submission) }
        .refreshable { await load(submission) }
        .threadPromptHost(.forum)
        .onDisappear { lookup.invalidate(); reveals.removeAll(); revealIdentity = nil }
    }
}

struct UserProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    let userID: Snowflake
    /// REST reactor users need not already be in the member/author cache.
    var fallbackUser: User? = nil
    var channelID: Snowflake? = nil
    var embedded = false
    var closeProfile: (() -> Void)? = nil

    private func close() {
        if let closeProfile { closeProfile() }
        else if let closePanel { closePanel() }
        else { dismiss() }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
                .presentationDetents([.medium, .large])
        }
    }

    private var content: some View {
        let user = Self.resolveUser(userID, cached: store.users[userID], fallback: fallbackUser)
        let guild = profileGuild
        return VStack(spacing: 14) {
            AvatarView(user: user, size: 88)
                .padding(.top, 24)
            VStack(spacing: 2) {
                Text(user.map { store.displayName(for: $0, in: guild) } ?? "Unknown")
                    .font(.title2.bold())
                if let user { Text("@\(user.username)").foregroundStyle(Color.textSecondary) }
            }
            if let guild, let roles = store.member(userID, in: guild)?.roles, !roles.isEmpty {
                FlowRoles(roles: roles.compactMap { store.role($0, in: guild) })
            }
            PersonActionsView(userID: userID, user: user)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } } }
    }

    private var profileGuild: Snowflake? {
        if let channelID { return store.channel(channelID)?.guildID }
        return model.selectedGuild
    }

    nonisolated static func resolveUser(_ id: Snowflake, cached: User?, fallback: User?) -> User? {
        if let cached, cached.id == id { return cached }
        if let fallback, fallback.id == id { return fallback }
        return nil
    }
}

struct FlowRoles: View {
    let roles: [Role]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(roles.sorted { $0.position > $1.position }.prefix(6)) { role in
                HStack(spacing: 4) {
                    Circle().fill(role.color == 0 ? Color.textMuted : Color.role(role.color)).frame(width: 8, height: 8)
                    Text(role.name).font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.elevated, in: Capsule())
            }
        }
    }
}

/// Full-screen picture viewer with zoom; videos and files open externally.
struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() { if let closePanel { closePanel() } else { dismiss() } }
    let item: MediaItem
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = MessageLayoutEngine.fit(item, maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                RemoteImage(url: item.url, size: size, contentMode: .fit)
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation { scale = 1 } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(item.alt ?? "Image")
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: item.openURL) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                if item.isVideo {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Play Video", systemImage: "play.fill") { UIApplication.shared.open(item.openURL) }
                    }
                }
            }
        }
    }
}

/// The system search field, only when search is a sheet (panels draw their own).
struct SheetSearchField: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        } else {
            content
        }
    }
}

extension SnippetView {
    /// Inline code in a narrow excerpt: monospaced but without the chip
    /// background, so a wrapped span never leaves an empty chip behind.
    static func snippetStyle(_ text: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.dcInlineCode, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            output.removeAttribute(.backgroundColor, range: range)
            output.addAttribute(.foregroundColor, value: Theme.mentionText, range: range)
            let trimmed = output.attributedSubstring(from: range).string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2009}"))
            output.replaceCharacters(in: range, with: NSAttributedString(string: trimmed, attributes: output.attributes(at: range.location, effectiveRange: nil)))
        }
        return output
    }
}

/// A message excerpt in the chat's markdown: text runs up to three lines;
/// code stays one monospaced line, truncated, never broken mid-token.
struct SnippetView: View {
    @Environment(DiscordStore.self) private var store
    let message: Message
    var reveal: ExcerptRevealScope? = nil

    func presentation(store: DiscordStore, reveal: ExcerptRevealScope? = nil) -> MessageExcerptPresentation {
        MessageExcerptPresentation(message: message, store: store, reveal: reveal)
    }

    var body: some View {
        let content = presentation(store: store, reveal: reveal)
        let segments = content.segments
        VStack(alignment: .leading, spacing: 4) {
            if segments.isEmpty {
                Text(content.fallback)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
            ForEach(Array(segments.prefix(3).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    let safe = Self.snippetStyle(MarkdownRenderer.redactingSpoilers(text))
                    Text((try? AttributedString(safe, including: \.uiKit)) ?? AttributedString(safe.string))
                        .lineLimit(3)
                case .code(let code):
                    Text(code.string.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
