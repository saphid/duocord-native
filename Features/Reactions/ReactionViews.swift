import SwiftUI

/// A Unicode emoji or a server's custom emoji at a given size.
struct EmojiGlyph: View {
    let emoji: Emoji
    var size: CGFloat

    var body: some View {
        if let url = emoji.url(size: Int(size * 3)) {
            RemoteImage(url: url, size: CGSize(width: size, height: size), contentMode: .fit, placeholder: .clear, mediaKind: .emoji)
        } else {
            Text(emoji.name ?? "")
                .font(.system(size: size * 0.9))
                .frame(width: size, height: size)
        }
    }
}

/// Who reacted to a message, one tab per emoji. A sidebar panel at regular
/// width, a sheet in compact width.
struct ReactionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() { if let closePanel { closePanel() } else { dismiss() } }
    let channelID: Snowflake
    let messageID: Snowflake
    @State private var selected: String
    @State private var reactors: [String: [User]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var profile: User?

    init(channel: Snowflake, message: Snowflake, emoji: String) {
        channelID = channel
        messageID = message
        _selected = State(initialValue: emoji)
    }

    var body: some View {
        let reactions = currentReactions
        let current = reactions.first { $0.emoji.reactionKey == selected } ?? reactions.first
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(reactions, id: \.emoji.reactionKey) { reaction in
                            tab(reaction, isSelected: reaction.emoji.reactionKey == current?.emoji.reactionKey)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                Divider().overlay(Color.separatorLine)
                List {
                    if let current {
                        let key = current.emoji.reactionKey
                        if let error = errors[key] {
                            ContentUnavailableView("Couldn't Load Reactions", systemImage: "face.dashed", description: Text(error))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        } else if let fetched = reactors[key] {
                            let users = shown(fetched, me: current.me)
                            ForEach(users) { row($0) }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                            if current.count > users.count {
                                Text("and \(current.count - users.count) more")
                                    .font(.footnote)
                                    .foregroundStyle(Color.textMuted)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                    .listRowBackground(Color.clear)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                        }
                    } else {
                        ContentUnavailableView("No Reactions", systemImage: "face.smiling")
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .navigationDestination(item: $profile) { user in
                // Push within this sheet/sidebar stack. Replacing model.sheet
                // would lose the reaction tab/list and compete with its sheet.
                UserProfileView(userID: user.id, fallbackUser: user, channelID: channelID,
                                embedded: true, closeProfile: { profile = nil })
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } } }
            // Reloads when someone reacts meanwhile, and when Discord confirms
            // your own change (a fetch made while it was in flight may predate it).
            .task(id: current.map { "\($0.emoji.reactionKey)#\($0.count)#\(confirmation)" }) {
                guard let current else { return }
                await load(current.emoji)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentReactions: [Reaction] {
        let timeline = model.timeline(for: channelID)
        _ = timeline.revision
        return timeline.index(of: messageID).map { timeline.messages[$0].reactions } ?? []
    }

    private func tab(_ reaction: Reaction, isSelected: Bool) -> some View {
        Button {
            selected = reaction.emoji.reactionKey
        } label: {
            HStack(spacing: 6) {
                EmojiGlyph(emoji: reaction.emoji, size: 20)
                Text(reaction.count, format: .number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            // Unselected tabs use a translucent fill: the theme's pill colour
            // matches the light sidebar page and would vanish there.
            .background(isSelected ? Color.reactionMine : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentBlurple : .clear, lineWidth: 1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reaction.emoji.name ?? "emoji"), \(reaction.count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func row(_ user: User) -> some View {
        let guild = store.channel(channelID)?.guildID
        return Button {
            profile = user
        } label: {
            HStack(spacing: 12) {
                AvatarView(user: user, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName(for: user, in: guild)).font(.body.weight(.medium))
                    Text("@\(user.username)").font(.caption).foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: 0)
                if user.id == store.me?.id {
                    Text("You").font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.textMuted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("View profile")
        .accessibilityIdentifier("reactor-\(user.id)")
    }

    /// Discord's confirmations of your reaction changes to this message.
    private var confirmation: Int { model.timeline(for: channelID).reactionConfirmations[messageID] ?? 0 }

    /// Your own pending change shows at once: you're listed (first) exactly
    /// when the pill says you reacted.
    private func shown(_ users: [User], me mine: Bool) -> [User] {
        guard let me = store.me else { return users }
        let others = users.filter { $0.id != me.id }
        return mine ? [me] + others : others
    }

    private func load(_ emoji: Emoji) async {
        let key = emoji.reactionKey
        let started = confirmation
        do {
            let users = try await model.api.reactions(channel: channelID, message: messageID, emoji: emoji, limit: 100)
            // Discord confirmed a change after this request went out: the
            // reload that confirmation started has the newer list.
            guard confirmation == started else { return }
            reactors[key] = users
            errors[key] = nil
        } catch is CancellationError {
        } catch {
            if reactors[key] == nil { errors[key] = error.localizedDescription }
        }
    }
}

/// Recents, the current server's emoji and every standard emoji by
/// category, with search. Choosing one reacts (or removes your reaction).
struct EmojiPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(DiscordStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() { if let closePanel { closePanel() } else { dismiss() } }
    let channelID: Snowflake
    let messageID: Snowflake
    @State private var query = ""

    static let popular = ["👍", "❤️", "😂", "🎉", "👀", "🔥", "✅", "😮", "🙏", "💯"].map { Emoji(id: nil, name: $0, animated: false) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    searchField
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 2)], spacing: 2) {
                            if query.isEmpty {
                                section(settings.recentEmoji.isEmpty ? "Popular" : "Recently Used", id: "recent",
                                        emoji: settings.recentEmoji.isEmpty ? Self.popular : settings.recentEmoji)
                                if !serverEmoji.isEmpty {
                                    section(serverName, id: "server", emoji: serverEmoji)
                                }
                                ForEach(EmojiCatalog.groups) { group in
                                    section(group.title, id: group.id, emoji: group.entries.map(\.emoji), names: group.entries.map(\.name))
                                }
                            } else {
                                section("Results", id: "results", emoji: customResults + standardResults.map(\.emoji),
                                        names: customResults.map { $0.name ?? "" } + standardResults.map(\.name))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        if !query.isEmpty, customResults.isEmpty, standardResults.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    if query.isEmpty { categoryBar(proxy) }
                }
            }
            .navigationTitle("Add Reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var customResults: [Emoji] { serverEmoji.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) } }
    private var standardResults: [EmojiEntry] { EmojiCatalog.search(query) }
    private var guildID: Snowflake? { store.channel(channelID)?.guildID }
    private var serverEmoji: [Emoji] { guildID.flatMap { store.guilds[$0]?.emojis } ?? [] }
    private var serverName: String { guildID.flatMap { store.guilds[$0]?.name } ?? "Server" }

    private var mine: Set<String> {
        let timeline = model.timeline(for: channelID)
        _ = timeline.revision
        let reactions = timeline.index(of: messageID).map { timeline.messages[$0].reactions } ?? []
        return Set(reactions.filter(\.me).map(\.emoji.reactionKey))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.textMuted)
            TextField("Search Emoji", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("emojiSearch")
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        // A translucent fill reads on the sheet's glass and the sidebar page alike.
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func section(_ title: String, id: String, emoji: [Emoji], names: [String]? = nil) -> some View {
        let reacted = mine
        return Section {
            ForEach(Self.cells(section: id, emoji: emoji, names: names)) { cell in
                Button {
                    pick(cell.emoji)
                } label: {
                    EmojiGlyph(emoji: cell.emoji, size: 32)
                        .frame(width: 44, height: 44)
                        .background(reacted.contains(cell.emoji.reactionKey) ? Color.reactionMine : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cell.name)
                .accessibilityAddTraits(reacted.contains(cell.emoji.reactionKey) ? .isSelected : [])
            }
        } header: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .id(id)
                .accessibilityAddTraits(.isHeader)
        }
    }

    nonisolated struct Cell: Identifiable, Sendable {
        let id: String
        let emoji: Emoji
        let name: String
    }

    /// Cells keyed by section and position: every section shares one grid,
    /// so bare positions would collide and SwiftUI would drop the repeats.
    nonisolated static func cells(section: String, emoji: [Emoji], names: [String]?) -> [Cell] {
        emoji.enumerated().map { index, item in
            let name = names.flatMap { index < $0.count ? $0[index] : nil } ?? item.name ?? "emoji"
            return Cell(id: "\(section)/\(index)", emoji: item, name: name.isEmpty ? (item.name ?? "emoji") : name)
        }
    }

    /// Jumps between categories, like the emoji keyboard. The buttons share
    /// the width when full-size ones fit, and scroll sideways when they don't
    /// (the outer display and the narrow sidebar page).
    private func categoryBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.separatorLine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { categoryButtons(proxy) }
                    .padding(.horizontal, 4)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) { categoryButtons(proxy) }
                        .padding(.horizontal, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func categoryButtons(_ proxy: ScrollViewProxy) -> some View {
        categoryButton("Recent", symbol: "clock", id: "recent", proxy: proxy)
        if !serverEmoji.isEmpty { categoryButton(serverName, symbol: "star", id: "server", proxy: proxy) }
        ForEach(EmojiCatalog.groups) { group in
            categoryButton(group.title, symbol: group.symbol, id: group.id, proxy: proxy)
        }
    }

    private func categoryButton(_ title: String, symbol: String, id: String, proxy: ScrollViewProxy) -> some View {
        Button(title, systemImage: symbol) {
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17))
        .foregroundStyle(Color.textSecondary)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func pick(_ emoji: Emoji) {
        model.toggleReaction(emoji, message: messageID, channel: channelID)
        close()
    }
}

nonisolated struct EmojiEntry: Hashable, Sendable {
    let emoji: Emoji
    let name: String
}

/// The standard emoji set (Unicode 16.0), by category.
nonisolated enum EmojiCatalog {
    struct Group: Identifiable, Sendable {
        let title: String
        let symbol: String
        let entries: [EmojiEntry]
        var id: String { title }
    }

    static let groups: [Group] = EmojiCatalogData.groups.map { title, symbol, lines in
        Group(title: title, symbol: symbol, entries: lines.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return EmojiEntry(emoji: Emoji(id: nil, name: String(parts[0]), animated: false), name: parts.count > 1 ? String(parts[1]) : "")
        })
    }

    /// Emoji whose name contains every word of the query: an exact name
    /// first ("fire" before "firefighter"), then prefix matches, then the rest.
    static func search(_ query: String) -> [EmojiEntry] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == ":" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        let matches = groups.flatMap(\.entries).filter { entry in words.allSatisfy { entry.name.contains($0) } }
        func rank(_ entry: EmojiEntry) -> Int { entry.name == phrase ? 0 : entry.name.hasPrefix(words[0]) ? 1 : 2 }
        return (0...2).flatMap { tier in matches.filter { rank($0) == tier } }
    }
}
