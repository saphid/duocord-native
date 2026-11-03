import SwiftUI

/// The guild's lazily loaded member list, grouped by hoisted role and
/// online status (GUILD_MEMBER_LIST_UPDATE). DMs list recipients.
struct MemberListView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    var showsHeader: Bool

    var body: some View {
        let channel = model.selectedChannel.flatMap { store.channel($0) }
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Members").font(.headline)
                        if let name = channel?.name {
                            Text("#\(name)").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    Spacer()
                    Button("Close Members", systemImage: "xmark") {
                        withAnimation(.snappy(duration: 0.25)) { model.membersVisible = false }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("closeMembers")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                Divider().overlay(Color.separatorLine)
            }
            List {
                if let guild = channel?.guildID {
                    let rows = store.memberLists[guild]?.rows ?? []
                    if rows.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .group(_, let title, let count):
                            Text("\(title.uppercased()) — \(count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.textMuted)
                                .padding(.top, 10)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .accessibilityAddTraits(.isHeader)
                        case .member(let member, let status):
                            MemberRow(user: member.user, name: member.nick ?? member.user?.displayName ?? "",
                                      color: store.roleColor(for: member, in: guild), status: status)
                        }
                    }
                } else if let channel {
                    ForEach(store.recipients(of: channel) + (store.me.map { [$0] } ?? [])) { user in
                        MemberRow(user: user, name: user.displayName, color: nil, status: store.presences[user.id] ?? .offline)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
        }
        .background(Color.sidebarBackground)
        .accessibilityIdentifier("memberList")
    }
}

struct MemberRow: View {
    @Environment(AppModel.self) private var model
    let user: User?
    let name: String
    let color: Int?
    let status: PresenceStatus

    var body: some View {
        Button {
            if let id = user?.id { model.sheet = .user(id) }
        } label: {
            HStack(spacing: 10) {
                AvatarView(user: user, size: 32)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(status: status) }
                    .opacity(status == .offline ? 0.5 : 1)
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color.map(Color.role) ?? Color.textPrimary)
                    .opacity(status == .offline ? 0.6 : 1)
                    .lineLimit(1)
                if user?.bot == true {
                    Text("APP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentBlurple, in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityLabel("\(name), \(status.rawValue)")
    }
}
