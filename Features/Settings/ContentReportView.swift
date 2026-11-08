import SwiftUI
import MessageUI

nonisolated struct ContentReportTarget: Equatable {
    let guildID: Snowflake?
    let channelID: Snowflake
    let messageID: Snowflake

    var link: String {
        "https://discord.com/channels/\(guildID?.description ?? "@me")/\(channelID)/\(messageID)"
    }
}

nonisolated struct ContentReportDraft {
    static let recipient = "saphid@gmail.com"
    static let discordReportingHelp = URL(string: "https://discord.com/safety/360044103651-reporting-abusive-behavior-to-discord")!

    enum Reason: String, CaseIterable, Identifiable {
        case harassment = "Harassment or bullying"
        case hate = "Hateful content"
        case sexual = "Sexual content"
        case violence = "Violence or threats"
        case spam = "Spam or scams"
        case other = "Something else"
        var id: String { rawValue }
    }

    let target: ContentReportTarget?
    let reason: Reason
    let details: String

    var subject: String { "[Duocord report] \(reason.rawValue)" }

    var body: String {
        """
        Duocord content report
        Reason: \(reason.rawValue)
        Message: \(target?.link ?? "No message selected")

        Details supplied by the reporter:
        \(details.trimmingCharacters(in: .whitespacesAndNewlines))

        Please do not include account tokens, passwords or unnecessary private content.
        """
    }

    var mailURL: URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+?=#")
        guard let subject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let body = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "mailto:\(Self.recipient)?subject=\(subject)&body=\(body)")
    }
}

struct ContentReportView: View {
    let target: ContentReportTarget?
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var reason: ContentReportDraft.Reason = .harassment
    @State private var details = ""
    @State private var composing = false
    @State private var status: String?

    private var draft: ContentReportDraft {
        ContentReportDraft(target: target, reason: reason, details: details)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isDemo {
                    Section {
                        Text("This is a fictional demo. Email and clipboard reporting are disabled here; no report will be sent.")
                    }
                }
                Section {
                    LabeledContent("To", value: ContentReportDraft.recipient)
                    Text("Reports go to Alex Southwell, Duocord's developer. Your email app sends the report only after you review it and choose Send.")
                        .font(.footnote)
                    if let target {
                        if isDemo {
                            Text(target.link).font(.footnote).textSelection(.disabled)
                        } else {
                            Text(target.link).font(.footnote).textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Private report")
                } footer: {
                    Text("Only the selected message link, reason and details you enter are included. Duocord does not attach message text, files or account credentials.")
                }
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ContentReportDraft.Reason.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Do not include tokens, passwords or unnecessary private content. The developer cannot remove messages from Discord's servers; report violations to Discord as well.")
                }
                Section {
                    Button("Review Email", systemImage: "envelope") { reviewEmail() }
                        .disabled(isDemo)
                        .opacity(isDemo ? 0.45 : 1)
                    Button("Copy Report", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = "To: \(ContentReportDraft.recipient)\nSubject: \(draft.subject)\n\n\(draft.body)"
                        status = "Report copied. Send it to \(ContentReportDraft.recipient). Nothing has been submitted by Duocord."
                    }
                    .disabled(isDemo)
                    .opacity(isDemo ? 0.45 : 1)
                    if let status { Text(status).font(.footnote).accessibilityIdentifier("reportStatus") }
                } footer: {
                    if isDemo { Text("Email and copying are unavailable in this fictional demo.") }
                }
                Section {
                    Link("How to Report to Discord", destination: ContentReportDraft.discordReportingHelp)
                    Text("You can also block the sender from their profile in Duocord. For an immediate threat to someone's safety, contact your local emergency service.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Report Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $composing) {
                ReportMailComposer(draft: draft) { result, error in
                    composing = false
                    if error != nil {
                        status = "Mail could not send the report. You can copy it and email it yourself."
                    } else {
                        switch result {
                        case .sent: status = "Email handed to Mail for sending. Delivery to the developer is not confirmed."
                        case .saved: status = "Draft saved in Mail. Your report has not been sent."
                        case .cancelled: status = "Email cancelled. Your report has not been sent."
                        case .failed: status = "Mail could not send the report. You can copy it and email it yourself."
                        @unknown default: status = "Delivery is not confirmed. Check your email app."
                        }
                    }
                }
            }
        }
    }

    private func reviewEmail() {
        guard !isDemo else { return }
        if MFMailComposeViewController.canSendMail() {
            composing = true
        } else if let url = draft.mailURL {
            openURL(url) { accepted in
                status = accepted
                    ? "Email opened. Review it and choose Send in your email app. Delivery is not confirmed."
                    : "No email app could open this report. Copy it and send it to \(ContentReportDraft.recipient)."
            }
        } else {
            status = "Email could not be prepared. Copy the report and send it yourself."
        }
    }
}

private struct ReportMailComposer: UIViewControllerRepresentable {
    let draft: ContentReportDraft
    let onFinish: (MFMailComposeResult, Error?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([ContentReportDraft.recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult, Error?) -> Void
        init(onFinish: @escaping (MFMailComposeResult, Error?) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result, error)
        }
    }
}
