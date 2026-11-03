import SwiftUI

struct ChannelReadButton: View {
    @Environment(AppModel.self) private var model
    let channel: Snowflake
    var body: some View {
        Button(model.readSaves[channel, default: 0] > 0 ? "Updating Read State…" : "Mark as Read", systemImage: "checkmark.message") {
            model.markAsRead(channel: channel)
        }
        .disabled(model.readSaves[channel, default: 0] > 0)
    }
}

/// Lives in the conversation page. No count or timestamp is inferred from a
/// partial history window. Both controls keep their titles at large text sizes.
struct UnreadNavigationBar: View {
    @Environment(AppModel.self) private var model
    let channel: Snowflake
    var body: some View {
        if model.unreadIsAboveViewport(channel) {
            ViewThatFits(in: .horizontal) {
                HStack { jump; Spacer(minLength: 8); markRead }
                VStack(alignment: .leading, spacing: 4) { jump; markRead }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.elevated)
        }
    }
    private var jump: some View {
        Button("Jump to First Unread", systemImage: "arrow.up.to.line") { model.jumpToUnread(channel) }
            .frame(minHeight: 44)
    }
    private var markRead: some View {
        Button("Mark as Read", systemImage: "checkmark") { model.markAsRead(channel: channel) }
            .frame(minHeight: 44)
    }
}
