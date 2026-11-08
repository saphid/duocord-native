import XCTest
@testable import DuocordNative

final class ContentReportTests: XCTestCase {
    @MainActor
    func testHistoryReportLinkUsesKnownServerWithoutChangingPrivateMessageLinks() throws {
        let data = Data(#"{"id":"3","channel_id":"2","author":{"id":"4","username":"reporter"},"content":"private text"}"#.utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertNil(message.guildID)
        let mock = MockDiscord()
        func list(guildID: Snowflake?) -> MessageListController {
            MessageListController(timeline: MessageTimeline(channelID: 2), store: DiscordStore(), api: mock,
                                  guildID: guildID, title: "test", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
        }
        let serverTarget = list(guildID: 1).reportTarget(for: message)
        XCTAssertEqual(serverTarget.link, "https://discord.com/channels/1/2/3")
        XCTAssertEqual(list(guildID: nil).reportTarget(for: message).link, "https://discord.com/channels/@me/2/3")
        let draft = ContentReportDraft(target: serverTarget, reason: .other, details: "")
        XCTAssertTrue(draft.body.contains(serverTarget.link))
        XCTAssertFalse(draft.body.contains(message.content))
    }

    func testReportContainsOnlySelectedIdentifiersAndReporterDetails() {
        let target = ContentReportTarget(guildID: 1, channelID: 2, messageID: 3)
        let draft = ContentReportDraft(target: target, reason: .spam, details: "  Please investigate.  ")
        XCTAssertTrue(draft.body.contains("https://discord.com/channels/1/2/3"))
        XCTAssertTrue(draft.body.contains("Please investigate."))
        XCTAssertFalse(draft.body.contains("  Please investigate.  "))
        XCTAssertFalse(draft.body.contains("Authorization:"))
    }

    func testPrivateMessageLinkAndUnselectedReportStayDistinct() {
        let target = ContentReportTarget(guildID: nil, channelID: 2, messageID: 3)
        XCTAssertEqual(target.link, "https://discord.com/channels/@me/2/3")
        let draft = ContentReportDraft(target: nil, reason: .other, details: "")
        XCTAssertTrue(draft.body.contains("No message selected"))
        XCTAssertFalse(draft.body.contains("https://discord.com/channels/"))
    }

    func testMailURLPreservesUnicodeAndDoesNotInjectRecipientsOrHeaders() throws {
        let details = "a+b & café? #\nBcc: victim@example.com\n原因"
        let draft = ContentReportDraft(target: nil, reason: .other, details: details)
        let url = try XCTUnwrap(draft.mailURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, ContentReportDraft.recipient)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "subject" })?.value, draft.subject)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "body" })?.value, draft.body)
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }
}
