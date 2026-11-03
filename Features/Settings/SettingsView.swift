import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    private func close() { if let closePanel { closePanel() } else { dismiss() } }
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(user: model.store.me, size: 48)
                        VStack(alignment: .leading) {
                            Text(model.store.me?.displayName ?? "").font(.headline)
                            Text(model.store.me.map { "@\($0.username)" } ?? "").font(.subheadline).foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                Section {
                    // Segments where all four titles fit; a menu on the narrow sidebar page.
                    ViewThatFits(in: .horizontal) {
                        themePicker.pickerStyle(.segmented).fixedSize()
                        themePicker.pickerStyle(.menu)
                    }
                    .accessibilityIdentifier("themePicker")
                    AccentPicker(selection: $settings.accent)
                    Toggle("Autoplay GIFs", isOn: $settings.autoplayGIFs)
                    Toggle("Animate Emoji", isOn: $settings.animateEmoji)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Onyx uses pure black backgrounds. Animations pause with Reduce Motion. Tap paused media to play it; media is always silent.")
                }
                Section {
                    Toggle("Notifications", isOn: $settings.notificationsEnabled)
                    Toggle("App Icon Badge", isOn: $settings.badgeEnabled)
                        .onChange(of: settings.badgeEnabled) { model.updateBadge() }
                    Toggle("Stay Connected in Background", isOn: $settings.keepAlive)
                        .onChange(of: settings.keepAlive) { model.reconcileKeepAlive() }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Duocord follows each server's notification settings. Staying connected plays silent audio so messages keep arriving while Duocord is in the background; it uses more battery.")
                }
                Section {
                    Toggle("Voice Live Activity", isOn: $settings.liveActivity)
                        .onChange(of: settings.liveActivity) { model.voice.updateActivity() }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Voice runs in Discord's own web engine inside Duocord, because Discord requires end-to-end encrypted calls. The call shows on the Lock Screen and in the Dynamic Island with Mute, Deafen and Leave.")
                }
                Section {
                    Toggle("Mark Messages as Read", isOn: $settings.markReadOnServer)
                    Toggle("Send Typing Indicator", isOn: $settings.sendTypingIndicator)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Reading a channel tells Discord you've read it, so your other devices stay in sync, as Discord's own apps do.")
                }
                Section {
                    Toggle("Channel List Ends at the Fold", isOn: $settings.followFold)
                } header: {
                    Text("iPhone Duo")
                } footer: {
                    Text("When iPhone Duo rests half-open like a book, servers and channels fill the left page and the conversation fills the right.")
                }
                Section {
                    LabeledContent("Account Risk") {
                        Text("Unofficial client").foregroundStyle(.orange)
                    }
                    Text("Discord's Terms of Service don't allow third-party clients that use your account's token, and Discord can act against accounts that use them.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                } header: {
                    Text("About")
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .confirmationDialog("Sign out of Discord on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) {
                                close()
                                model.signOut()
                            }
                        } message: {
                            Text("Your session token is removed from this iPhone's Keychain.")
                        }
                }
            }
            // On the sidebar page the form gets no margin beside the server rail by itself.
            .contentMargins(.horizontal, closePanel == nil ? nil : 12, for: .scrollContent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { close() } }
            }
        }
    }

    private var themePicker: some View {
        @Bindable var settings = settings
        return Picker("Theme", selection: $settings.appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// Accent colour swatches; the chosen one carries a check. They share the
/// row's width so they fit the narrow sidebar page too.
struct AccentPicker: View {
    @Binding var selection: AccentChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accent")
            HStack(spacing: 0) {
                ForEach(AccentChoice.allCases) { accent in
                    Button {
                        selection = accent
                    } label: {
                        // Up to 28 pt, smaller on the narrow sidebar page so they never touch.
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: accent.hex)))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 28, maxHeight: 28)
                            .overlay {
                                if selection == accent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accent.title)
                    .accessibilityAddTraits(selection == accent ? .isSelected : [])
                    .accessibilityIdentifier("accent-\(accent.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
