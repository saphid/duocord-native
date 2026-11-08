import XCTest
@testable import DuocordNative

@MainActor
final class ContentSafetyTests: XCTestCase {
    private func fixture() -> (DiscordStore, Channel) {
        let store = DiscordStore()
        store.apply(ready: MockDiscord().readyPayload())
        return (store, store.channel(MockDiscord.generalChannel)!)
    }

    func testOrdinaryChannelRetainsAccess() {
        let (store, channel) = fixture()
        XCTAssertEqual(store.contentAccess(to: channel), .allowed)
        XCTAssertTrue(store.canView(channel))
    }

    func testAgeRestrictionDeniesChannelAndActions() {
        let (store, original) = fixture()
        var channel = original; channel.nsfw = true
        store.upsert(channel: channel)
        XCTAssertEqual(store.contentAccess(to: channel.id), .ageRestricted)
        XCTAssertFalse(store.canView(channel))
        XCTAssertEqual(store.capability(.viewChannel, in: channel).reasons, [.contentRestricted])
    }

    func testThreadInheritsRestrictedParent() {
        let (store, original) = fixture()
        var channel = original; channel.nsfw = true
        store.upsert(channel: channel)
        let thread = Channel(id: 1001, type: .publicThread, guildID: channel.guildID, parentID: channel.id)
        store.upsert(channel: thread)
        XCTAssertEqual(store.contentAccess(to: thread), .ageRestricted)
        XCTAssertFalse(store.canView(thread))
        XCTAssertFalse(store.threads(in: channel.id).contains { $0.id == thread.id })
    }

    func testMissingParentAndCycleStayUnavailable() {
        let (store, channel) = fixture()
        var thread = Channel(id: 1002, type: .publicThread, guildID: channel.guildID, parentID: 1003)
        store.upsert(channel: thread)
        XCTAssertEqual(store.contentAccess(to: thread), .unavailable)
        let parent = Channel(id: 1003, type: .category, guildID: channel.guildID, parentID: thread.id)
        store.upsert(channel: parent)
        XCTAssertEqual(store.contentAccess(to: thread), .unavailable)
        thread.nsfw = true; store.upsert(channel: thread)
        XCTAssertEqual(store.contentAccess(to: thread), .ageRestricted)
        XCTAssertEqual(store.contentAccess(to: 999), .unavailable)
    }

    func testPartialUpdateCannotRemoveRestrictionOrAncestry() {
        let (store, original) = fixture()
        var channel = original; channel.nsfw = true
        store.upsert(channel: channel)
        let partial = Channel(id: channel.id, type: channel.type, guildID: channel.guildID, name: "Renamed")
        store.upsert(channel: partial)
        XCTAssertEqual(store.contentAccess(to: channel.id), .ageRestricted)
        XCTAssertEqual(store.channel(channel.id)?.parentID, channel.parentID)
        var checked = partial; checked.nsfw = false
        store.upsert(channel: checked)
        XCTAssertEqual(store.contentAccess(to: channel.id), .allowed)
    }

    func testRestrictedExcerptCannotBeRevealed() {
        let (store, original) = fixture()
        var channel = original; channel.nsfw = true
        store.upsert(channel: channel)
        let message = Message(id: 2001, channelID: channel.id, guildID: channel.guildID,
                              author: MockDiscord().users[0], content: "Sensitive content", timestamp: "2026-11-08T00:00:00Z")
        let reveal = ExcerptRevealScope(message: message, store: store)
        let excerpt = MessageExcerptPresentation(message: message, store: store, reveal: reveal)
        XCTAssertTrue(excerpt.restricted)
        XCTAssertTrue(excerpt.concealed)
        XCTAssertNil(excerpt.avatarUser)
        XCTAssertTrue(excerpt.segments.isEmpty)
        XCTAssertFalse(excerpt.text.contains("Sensitive content"))
        XCTAssertFalse(store.shouldNotify(message))
    }

    func testDirectNavigationCannotRevealRestrictedMessage() {
        let (store, original) = fixture()
        let model = AppModel(store: store)
        var channel = original; channel.nsfw = true
        store.upsert(channel: channel)
        model.open(channel: channel.id, message: 2002)
        XCTAssertNil(model.selectedChannel)
        XCTAssertNil(model.revealRequest)
    }

    func testCategoryRestrictionPropagatesToNestedChannel() {
        let (store, original) = fixture()
        var category = Channel(id: 3001, type: .category, guildID: original.guildID)
        category.nsfw = true
        store.upsert(channel: category)
        let child = Channel(id: 3002, type: .text, guildID: original.guildID, parentID: category.id)
        store.upsert(channel: child)
        store.upsert(channel: Channel(id: child.id, type: .text, guildID: original.guildID, name: "Partial update"))
        XCTAssertEqual(store.contentAccess(to: child.id), .ageRestricted)
        XCTAssertEqual(store.channel(child.id)?.parentID, category.id)
    }

    func testNewRestrictionSuppressesPreviouslyNotifiableMessage() {
        let (store, _) = fixture()
        let author = MockDiscord().users[0]
        var dm = Channel(id: 4001, type: .dm, recipients: [author])
        store.upsert(channel: dm)
        let message = Message(id: 4002, channelID: dm.id, guildID: nil, author: author,
                              content: "Sensitive content", timestamp: "2026-11-08T00:00:00Z")
        XCTAssertTrue(store.shouldNotify(message))
        dm.nsfw = true; store.upsert(channel: dm)
        XCTAssertFalse(store.shouldNotify(message))
    }

    func testForumWithMissingParentCannotBeRevealed() {
        let (store, _) = fixture()
        let forum = ForumView(channel: Channel(id: 5001, type: .forum))
        let post = Channel(id: 5002, type: .publicThread, name: "Sensitive title", parentID: 5001)
        let presentation = forum.postPresentation(post, firstMessage: nil, store: store)
        XCTAssertEqual(presentation.title, "Content unavailable")
        XCTAssertNil(presentation.excerpt)
        XCTAssertNil(presentation.revealScope)
    }

    func testForumWithUnavailableMessageDoesNotOfferReveal() {
        let (store, _) = fixture()
        let channel = Channel(id: 5001, type: .forum)
        store.upsert(channel: channel)
        let post = Channel(id: 5002, type: .publicThread, name: "Post title", parentID: channel.id)
        store.upsert(channel: post)
        let first = Message(id: 5003, channelID: 5999, guildID: nil, author: MockDiscord().users[0],
                            content: "Unverified content", timestamp: "2026-11-08T00:00:00Z")
        let presentation = ForumView(channel: channel).postPresentation(post, firstMessage: first, store: store)
        XCTAssertEqual(presentation.title, "Content unavailable")
        XCTAssertNil(presentation.excerpt)
        XCTAssertNil(presentation.revealScope)
    }

}
