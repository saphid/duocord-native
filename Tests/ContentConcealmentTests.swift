import XCTest
import UIKit
@testable import DuocordNative

@MainActor
final class ContentConcealmentTests: XCTestCase {
    private func fixture() -> (DiscordStore, Message) {
        let store = DiscordStore()
        store.apply(ready: MockDiscord().readyPayload())
        return (store, Message(id: 551, channelID: MockDiscord.generalChannel, guildID: nil, author: MockDiscord.blockedPerson,
                               content: "recognizable body ||hidden spoiler||", timestamp: "2026-11-01T00:00:00Z"))
    }

    private func render(_ message: Message, store: DiscordStore) -> RenderedMessage {
        let builder = MessageBuilder(store: store, guildID: message.guildID)
        return builder.render(message, previous: nil, context: builder.context(), sendState: nil)
    }

    private func descendants<T: UIView>(_ root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { child -> [T] in
            (child as? T).map { [$0] } ?? []
        } + root.subviews.flatMap { descendants($0, type) }
    }

    func testLookupConsumerConcealsBlockedBodyAndAttachmentSummaryBeforeExplicitReveal() {
        let (store, message) = fixture()
        let row = MessageResultRow(message: message)
        let hidden = row.presentation(store: store)
        XCTAssertTrue(hidden.concealed)
        XCTAssertNil(hidden.avatarUser)
        XCTAssertEqual(hidden.text, "Blocked message")
        var attachmentOnly = message
        attachmentOnly.content = ""
        attachmentOnly.attachments = [Attachment(id: 1, filename: "secret.txt", size: 1, url: "mock://secret")]
        let snippet = SnippetView(message: attachmentOnly).presentation(store: store)
        XCTAssertEqual(snippet.text, "Blocked message")
        XCTAssertNil(snippet.avatarUser)
    }

    func testLookupRevealIsScopedAndBlockTransitionsInvalidateItWithoutRevealingSpoilers() {
        let (store, message) = fixture()
        let token = ExcerptRevealScope(message: message, store: store)
        let shown = MessageResultRow(message: message).presentation(store: store, reveal: token)
        XCTAssertFalse(shown.concealed)
        XCTAssertTrue(shown.text.contains("recognizable body"))
        XCTAssertFalse(shown.text.contains("hidden spoiler"))
        var other = message; other.id = 552
        XCTAssertTrue(MessageResultRow(message: other).presentation(store: store, reveal: token).concealed)
        other = message; other.channelID = 553
        XCTAssertTrue(MessageResultRow(message: other).presentation(store: store, reveal: token).concealed)
        store.applyRelationship(Relationship(id: message.author.id, type: 1))
        XCTAssertFalse(MessageResultRow(message: message).presentation(store: store).concealed)
        store.applyRelationship(Relationship(id: message.author.id, type: 2))
        XCTAssertTrue(MessageResultRow(message: message).presentation(store: store, reveal: token).concealed)
    }

    func testGenericSpoilerFileBuilderAndActualFileViewConcealThenRevealThenOpen() throws {
        let (store, original) = fixture()
        for (filename, flags) in [("SPOILER_notes.txt", 0), ("notes.txt", 8)] {
            var message = original; message.author = MockDiscord().users[0]; message.content = ""
            message.attachments = [Attachment(id: 10, filename: filename, size: 42, url: "mock://files/secret", flags: flags)]
            let file = try XCTUnwrap(render(message, store: store).files.first)
            let view = FileView()
            var opened: [URL] = []; view.onTap = { opened.append($0) }
            view.configure(file)
            XCTAssertNil(view.url)
            XCTAssertEqual(view.accessibilityLabel, "Spoiler file")
            XCTAssertFalse(descendants(view, UILabel.self).contains { $0.text?.contains(filename) == true })
            XCTAssertTrue(view.accessibilityActivate())
            XCTAssertTrue(opened.isEmpty)
            XCTAssertEqual(view.url, file.url)
            XCTAssertTrue(view.accessibilityLabel?.contains(filename) == true)
            XCTAssertTrue(view.accessibilityActivate())
            XCTAssertEqual(opened, [file.url])
        }
    }

    func testMalformedImageFallbackFileAlsoConcealsSpoilerAndReuseCannotCarryReveal() throws {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = ""
        message.attachments = [Attachment(id: 10, filename: "SPOILER_image.png", size: 42, url: "mock://files/a", contentType: "image/png")]
        let first = try XCTUnwrap(render(message, store: store).files.first)
        let view = FileView(); view.configure(first)
        XCTAssertEqual(view.accessibilityLabel, "Spoiler file")
        XCTAssertTrue(view.accessibilityActivate())
        message.attachments[0].url = "mock://files/b"
        let second = try XCTUnwrap(render(message, store: store).files.first)
        view.configure(second)
        XCTAssertNil(view.url)
        XCTAssertEqual(view.accessibilityLabel, "Spoiler file")
        var opened: [URL] = []; view.onTap = { opened.append($0) }
        XCTAssertTrue(view.accessibilityActivate()); XCTAssertTrue(opened.isEmpty)
        view.configure(second)
        XCTAssertTrue(view.accessibilityActivate()); XCTAssertEqual(opened, [second.url])
    }

    func testNonspoilerFileAccessibilityActivationOpensNormallyThroughMessageCell() throws {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = ""
        message.attachments = [Attachment(id: 10, filename: "notes.txt", size: 42, url: "mock://files/plain")]
        let rendered = render(message, store: store)
        let cell = MessageCell(frame: .zero)
        cell.configure(rendered, layout: MessageLayoutEngine.layout(rendered, width: 400), width: 400)
        let view = try XCTUnwrap(descendants(cell, FileView.self).first)
        XCTAssertEqual(view.url?.absoluteString, "mock://files/plain")
        var opened: [URL] = []; view.onTap = { opened.append($0) }
        XCTAssertTrue(view.accessibilityActivate())
        XCTAssertEqual(opened, [URL(string: "mock://files/plain")!])
    }

    func testLottieOnlyMainMessageHasVisibleAndAccessibleFallbackInRealCell() {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = ""
        message.stickerItems = [StickerItem(id: 20, name: "Dancing friend", formatType: 3)]
        let rendered = render(message, store: store)
        let cell = MessageCell(frame: .zero)
        cell.configure(rendered, layout: MessageLayoutEngine.layout(rendered, width: 400), width: 400)
        XCTAssertTrue(rendered.accessibilityText.contains("Sticker: Dancing friend · Preview unavailable"))
        XCTAssertTrue(descendants(cell, RichTextView.self).contains { $0.attributedText?.string.contains("Sticker: Dancing friend · Preview unavailable") == true })
        XCTAssertTrue(rendered.media.isEmpty)
    }

    func testMixedStickerSequenceKeepsOrderSupportedMediaAndSingleBody() {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = "one body"
        message.stickerItems = [StickerItem(id: 20, name: "First raster", formatType: 1),
                                StickerItem(id: 21, name: "Middle Lottie", formatType: 3),
                                StickerItem(id: 22, name: "Last raster", formatType: 4)]
        let rendered = render(message, store: store)
        // Mixed sticker items must share an ordered presentation rather than split missing types away.
        let sequence = rendered.embeds.compactMap { $0.image?.alt ?? $0.body?.string }
        XCTAssertEqual(sequence, ["First raster", "Sticker: Middle Lottie · Preview unavailable", "Last raster"])
        XCTAssertEqual(rendered.body?.string, "one body")
        XCTAssertEqual(rendered.segments.count, 1)
        XCTAssertEqual(rendered.accessibilityText.components(separatedBy: "one body").count - 1, 1)
    }
    func testForumConsumerConcealsFirstPostAndRequiresItsOwnScopedReveal() throws {
        let (store, message) = fixture()
        let forum = ForumView(channel: try XCTUnwrap(store.channel(message.channelID)))
        let hidden = forum.excerptPresentation(message, store: store)
        XCTAssertTrue(hidden.concealed)
        XCTAssertEqual(hidden.text, "Blocked message")
        XCTAssertTrue(hidden.segments.isEmpty)
        let shown = forum.excerptPresentation(message, store: store, reveal: hidden.scope)
        XCTAssertTrue(shown.text.contains("recognizable body"))
        XCTAssertFalse(shown.text.contains("hidden spoiler"))
        var next = message; next.id = 777
        XCTAssertTrue(forum.excerptPresentation(next, store: store, reveal: hidden.scope).concealed)
    }

    func testExcerptAuthorAndSessionReplacementInvalidateRevealAndUnblockedSpoilersStayHidden() {
        let (store, message) = fixture()
        let scope = ExcerptRevealScope(message: message, store: store)
        var changed = message; changed.author = MockDiscord().users[0]
        XCTAssertFalse(SnippetView(message: changed).presentation(store: store).concealed)
        XCTAssertFalse(SnippetView(message: changed).presentation(store: store).text.contains("hidden spoiler"))
        store.applyRelationship(Relationship(id: changed.author.id, type: 2))
        XCTAssertTrue(MessageResultRow(message: changed).presentation(store: store, reveal: scope).concealed)
        store.apply(ready: MockDiscord().readyPayload())
        XCTAssertTrue(MessageResultRow(message: message).presentation(store: store, reveal: scope).concealed)
    }

    func testEmptyExcerptEmbedFallbackAlsoConcealsAndRetainsSpoilersAfterReveal() {
        let (store, original) = fixture()
        var message = original; message.content = ""
        message.embeds = [Embed(type: "rich", title: "visible ||secret embed||")]
        XCTAssertEqual(SnippetView(message: message).presentation(store: store).text, "Blocked message")
        let shown = SnippetView(message: message).presentation(store: store, reveal: ExcerptRevealScope(message: message, store: store))
        XCTAssertTrue(shown.text.contains("visible"))
        XCTAssertFalse(shown.text.contains("secret embed"))
    }

    func testSpoilerCellAccessibilityActionRevealsWithoutOpeningAndReuseClearsIdentity() throws {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = ""
        message.attachments = [Attachment(id: 10, filename: "SPOILER_notes.txt", size: 42, url: "mock://files/secret")]
        let recorder = FileTapRecorder()
        let cell = MessageCell(frame: .zero); cell.delegate = recorder
        func configure() {
            let rendered = render(message, store: store)
            cell.configure(rendered, layout: MessageLayoutEngine.layout(rendered, width: 400), width: 400)
        }
        configure()
        XCTAssertFalse(cell.accessibilityLabel?.contains("notes.txt") == true)
        XCTAssertFalse(cell.accessibilityCustomActions?.contains { $0.name.contains("notes.txt") } == true)
        let action = try XCTUnwrap(cell.accessibilityCustomActions?.first { $0.name == "Reveal spoiler file" })
        XCTAssertTrue(action.actionHandler?(action) == true)
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertEqual(action.name, "Open file SPOILER_notes.txt")
        XCTAssertTrue(action.actionHandler?(action) == true)
        XCTAssertEqual(recorder.urls, [URL(string: "mock://files/secret")!])
        message.id = 778 // Same attachment URL and filename, different message identity.
        configure()
        XCTAssertNil(descendants(cell, FileView.self).first?.url)
        let nextAction = try XCTUnwrap(cell.accessibilityCustomActions?.first { $0.name == "Reveal spoiler file" })
        XCTAssertTrue(nextAction.actionHandler?(nextAction) == true)
        XCTAssertEqual(recorder.urls.count, 1)
        cell.prepareForReuse()
        XCTAssertNil(descendants(cell, FileView.self).first?.url)
        XCTAssertFalse(cell.accessibilityCustomActions?.contains { $0.name.contains("notes.txt") } == true)
    }

    func testRasterOnlyStickerStillUsesExistingMediaPath() {
        let (store, original) = fixture()
        var message = original; message.author = MockDiscord().users[0]; message.content = ""
        message.stickerItems = [StickerItem(id: 30, name: "Raster", formatType: 1)]
        let rendered = render(message, store: store)
        XCTAssertEqual(rendered.media.map(\.alt), ["Raster"])
        XCTAssertTrue(rendered.embeds.isEmpty)
    }

    func testForumBlockedOwnerWithoutFirstMessageConcealsTitleAndCanReveal() throws {
        let (store, message) = fixture()
        let forumChannel = Channel(id: 9000, type: .forum)
        store.upsert(channel: forumChannel)
        let forum = ForumView(channel: forumChannel)
        var post = Channel(id: 9001, type: .publicThread, name: "recognizable blocked title", parentID: 9000)
        post.ownerID = message.author.id
        store.upsert(channel: post)
        let hidden = forum.postPresentation(post, firstMessage: nil, store: store)
        XCTAssertEqual(hidden.title, "Blocked post")
        XCTAssertNil(hidden.excerpt)
        let scope = try XCTUnwrap(hidden.revealScope)
        let revealed = forum.postPresentation(post, firstMessage: nil, store: store, reveal: scope)
        XCTAssertEqual(revealed.title, post.name)
        XCTAssertNil(revealed.revealScope)
        post.ownerID = MockDiscord().users[0].id
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store).title, post.name)
        XCTAssertNil(forum.postPresentation(post, firstMessage: nil, store: store).revealScope)
        post.ownerID = nil
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store).title, post.name)
    }

    func testForumOwnerRevealInvalidatesOnIdentityRelationshipAndSessionChanges() throws {
        let (store, message) = fixture()
        let forumChannel = Channel(id: 9000, type: .forum)
        store.upsert(channel: forumChannel)
        let forum = ForumView(channel: forumChannel)
        var post = Channel(id: 9001, type: .publicThread, name: "private title", parentID: 9000)
        post.ownerID = message.author.id
        store.upsert(channel: post)
        let scope = try XCTUnwrap(forum.postPresentation(post, firstMessage: nil, store: store).revealScope)
        var other = post; other.id = 9002
        XCTAssertEqual(forum.postPresentation(other, firstMessage: nil, store: store, reveal: scope).title, "Blocked post")
        let otherForum = ForumView(channel: Channel(id: 9100, type: .forum))
        XCTAssertEqual(otherForum.postPresentation(post, firstMessage: nil, store: store, reveal: scope).title, "Blocked post")
        other = post; other.ownerID = MockDiscord().users[0].id
        store.applyRelationship(Relationship(id: other.ownerID!, type: 2))
        XCTAssertEqual(forum.postPresentation(other, firstMessage: nil, store: store, reveal: scope).title, "Blocked post")
        store.applyRelationship(Relationship(id: message.author.id, type: 1))
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store, reveal: scope).title, post.name)
        store.applyRelationship(Relationship(id: message.author.id, type: 2))
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store, reveal: scope).title, "Blocked post")
        let renewed = try XCTUnwrap(forum.postPresentation(post, firstMessage: nil, store: store).revealScope)
        store.apply(ready: MockDiscord().readyPayload())
        store.upsert(channel: forumChannel)
        store.upsert(channel: post)
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store, reveal: renewed).title, "Blocked post")
    }

    func testForumFallbackRevealCannotRevealNewFirstMessage() throws {
        let (store, original) = fixture()
        let forumChannel = Channel(id: 9000, type: .forum)
        store.upsert(channel: forumChannel)
        let forum = ForumView(channel: forumChannel)
        var post = Channel(id: 9001, type: .publicThread, name: "private title", parentID: 9000)
        post.ownerID = original.author.id
        store.upsert(channel: post)
        let ownerScope = forum.postPresentation(post, firstMessage: nil, store: store).revealScope
        var first = original; first.id = post.id; first.channelID = post.id
        let hidden = forum.postPresentation(post, firstMessage: first, store: store, reveal: ownerScope)
        XCTAssertEqual(hidden.title, "Blocked post")
        XCTAssertEqual(hidden.excerpt?.text, "Blocked message")
        let messageScope = try XCTUnwrap(hidden.revealScope)
        let shown = forum.postPresentation(post, firstMessage: first, store: store, reveal: messageScope)
        XCTAssertEqual(shown.title, post.name)
        XCTAssertTrue(shown.excerpt?.text.contains("recognizable body") == true)
        XCTAssertFalse(shown.excerpt?.text.contains("hidden spoiler") == true)
        // An unavailable body must not reuse a previous message reveal for the owner fallback.
        XCTAssertEqual(forum.postPresentation(post, firstMessage: nil, store: store, reveal: messageScope).title, "Blocked post")
    }

}

@MainActor
private final class FileTapRecorder: MessageCellDelegate {
    var urls: [URL] = []
    func messageCell(_ cell: MessageCell, tap: RichTextView.Tap) { if case .link(let url) = tap { urls.append(url) } }
    func messageCell(_ cell: MessageCell, open media: MediaItem, from view: UIView) {}
    func messageCell(_ cell: MessageCell, toggleReaction emoji: Emoji, on message: Snowflake) {}
    func messageCell(_ cell: MessageCell, showReactions emoji: Emoji, on message: Snowflake) {}
    func messageCell(_ cell: MessageCell, addReactionTo message: Snowflake) {}
    func messageCell(_ cell: MessageCell, jumpTo message: Snowflake) {}
    func messageCell(_ cell: MessageCell, openUser user: Snowflake) {}
    func messageCell(_ cell: MessageCell, retry message: Snowflake) {}
    func messageCell(_ cell: MessageCell, discard message: Snowflake) {}
    func messageCell(_ cell: MessageCell, reply message: Snowflake) {}
}
