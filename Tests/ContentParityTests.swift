import XCTest
import UIKit
@testable import DuocordNative

@MainActor
final class ContentParityTests: XCTestCase {
    private var context: RenderContext {
        RenderContext(userName: { _ in nil }, channelName: { _ in "fold-ideas" }, role: { _ in nil },
                      baseFont: Theme.body, textColor: Theme.textPrimary)
    }

    private func render(_ message: Message) -> RenderedMessage {
        MessageBuilder.build(message, previous: nil,
                             inputs: MessageBuilder.Inputs(name: message.author.displayName, color: .white, mentioned: false, replyName: nil, replyColor: nil),
                             context: context, sendState: nil)
    }

    private func text(_ cards: [RenderedEmbed]) -> String {
        cards.flatMap { card in
            let values: [NSAttributedString?] = [card.author, card.title, card.body, card.footer] + card.fields.flatMap { [$0.name, $0.value] }
            return values.compactMap { $0?.string }
        }.joined(separator: "\n")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func update(_ message: Message, _ fields: [String: Any]) throws -> MessageUpdate {
        var fields = fields
        fields["id"] = message.id.description
        fields["channel_id"] = message.channelID.description
        return try decode(MessageUpdate.self, fields)
    }

    func testForwardSnapshotRetainsBodyMediaEmbedsAndAttribution() throws {
        let message = try MockDiscord.contentParityFixtures()[0]
        XCTAssertEqual(message.messageReference?.type, 1)
        let rendered = render(message)
        let strings = text(rendered.embeds)
        XCTAssertTrue(strings.contains("Forwarded"))
        XCTAssertTrue(strings.contains("Keep the question readable."))
        XCTAssertTrue(strings.contains("From #fold-ideas"))
        XCTAssertTrue(strings.contains("Original research"))
        XCTAssertTrue(strings.contains("research-notes.txt"))
        XCTAssertTrue(strings.contains("An earlier forwarded note."))
        XCTAssertEqual(rendered.embeds.compactMap(\.image).count, 1)
        XCTAssertTrue(rendered.accessibilityText.contains("Forwarded"))
        XCTAssertTrue(rendered.accessibilityText.contains("Fold study with two readable pages"))
        XCTAssertEqual(rendered.embeds.first?.titleURL?.absoluteString,
                       "https://discord.com/channels/910000000000000000/910000000000000104/1434105987072000000")
    }

    func testPollLabelsEmojiCountsFinalizationAndReadOnlyState() throws {
        let fixtures = try MockDiscord.contentParityFixtures()
        let active = render(fixtures[1])
        let poll = try XCTUnwrap(active.embeds.first)
        XCTAssertTrue(text([poll]).contains("Which layout"))
        XCTAssertTrue(text([poll]).contains("📖"))
        XCTAssertTrue(text([poll]).contains("12 votes · 80% of selections · You voted"))
        XCTAssertTrue(text([poll]).contains("3 votes · 20% of selections"))
        XCTAssertTrue(text([poll]).contains("Read-only · Voting is not supported here."))
        XCTAssertTrue(text([poll]).contains("Multiple answers allowed"))
        XCTAssertNotNil(poll.fields[1].name.attribute(.attachment, at: 0, effectiveRange: nil), "Custom emoji uses the existing static emoji renderer")
        let final = render(fixtures[2])
        XCTAssertTrue(text(final.embeds).contains("Final results"))
        XCTAssertTrue(text(final.embeds).contains("Ended"))
        XCTAssertTrue(final.accessibilityText.contains("Tea"))
        XCTAssertTrue(text(render(fixtures[4]).embeds).contains("Poll ended: Tea or coffee?"))
        XCTAssertFalse(render(fixtures[4]).accessibilityText.contains("did something"))
    }

    func testComponentsKeepSourceOrderMediaFilesLinksAndInteractionFallbacks() throws {
        let message = try MockDiscord.contentParityFixtures()[3]
        let rendered = render(message)
        let strings = text(rendered.embeds)
        XCTAssertTrue(strings.contains("Field notes"))
        XCTAssertTrue(strings.contains("section with a thumbnail"))
        XCTAssertTrue(strings.contains("File: layout-notes.txt"))
        XCTAssertTrue(strings.contains("Approve layout · Interaction not supported"))
        XCTAssertTrue(strings.contains("Choose a review topic · Selection not supported"))
        XCTAssertTrue(strings.contains("Readability"))
        XCTAssertTrue(strings.contains("unknown future component is still readable"))
        XCTAssertTrue(strings.contains("Unsupported component (type 99)"))
        XCTAssertEqual(rendered.embeds.compactMap(\.image).count, 3)
        XCTAssertTrue(rendered.media.isEmpty, "Referenced component attachments must not also render above the container")
        XCTAssertTrue(rendered.files.isEmpty)
        let link = rendered.embeds.first { $0.title?.string.contains("Read the layout notes") == true }
        XCTAssertEqual(link?.titleURL?.absoluteString, "https://example.com/layout-notes")
        let images = rendered.embeds.compactMap(\.image)
        XCTAssertEqual(images[1].openURL.absoluteString, "mock://image/component-gallery/1000x700")
        let first = try XCTUnwrap(strings.range(of: "Field notes"))
        let second = try XCTUnwrap(strings.range(of: "section with a thumbnail"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertTrue(rendered.accessibilityText.contains("Choose a review topic"))
    }

    func testPrimaryContentCacheEncodeDecodeRoundtrip() throws {
        for fixture in try MockDiscord.contentParityFixtures() {
            let data = try JSONEncoder().encode(fixture)
            let restored = try JSONDecoder().decode(Message.self, from: data)
            XCTAssertEqual(restored, fixture)
            XCTAssertEqual(text(render(restored).embeds), text(render(fixture).embeds))
        }
    }

    func testSourceAndHeightKeysInvalidateForSameCountContentChanges() throws {
        let fixtures = try MockDiscord.contentParityFixtures()
        var forward = fixtures[0]
        let oldForward = render(forward)
        forward.messageSnapshots[0].content += "\nA different forwarded body, without changing the snapshot count."
        XCTAssertNotEqual(oldForward.source, render(forward).source)
        XCTAssertNotEqual(oldForward.contentKey, render(forward).contentKey)
        forward.messageSnapshots[0].attachments[0].height = 2000
        XCTAssertNotEqual(oldForward.source, render(forward).source)
        var poll = fixtures[1]
        let oldPoll = render(poll)
        poll.poll?.results?.answerCounts?[0].count = 40
        XCTAssertNotEqual(oldPoll.source, render(poll).source)
        XCTAssertNotEqual(oldPoll.contentKey, render(poll).contentKey)
        var components = fixtures[3]
        let oldComponents = render(components)
        components.components[0].components[0].content = "Changed text in the same container"
        XCTAssertNotEqual(oldComponents.source, render(components).source)
        XCTAssertNotEqual(oldComponents.contentKey, render(components).contentKey)
    }

    func testPartialUpdatesRetainOmittedFieldsAndExplicitlyClearContent() throws {
        var original = try MockDiscord.contentParityFixtures()[0]
        original.poll = try MockDiscord.contentParityFixtures()[1].poll
        original.components = try MockDiscord.contentParityFixtures()[3].components
        let timeline = MessageTimeline(channelID: original.channelID)
        timeline.receive(original)
        timeline.update(try update(original, ["content": "A new caption"]))
        XCTAssertEqual(timeline.messages[0].messageSnapshots, original.messageSnapshots)
        XCTAssertEqual(timeline.messages[0].poll, original.poll)
        XCTAssertEqual(timeline.messages[0].components, original.components)
        timeline.update(try update(original, ["components": 42, "message_snapshots": "bad shape", "poll": false]))
        XCTAssertEqual(timeline.messages[0].components, original.components, "Malformed partial fields retain readable content")
        XCTAssertEqual(timeline.messages[0].messageSnapshots, original.messageSnapshots)
        XCTAssertEqual(timeline.messages[0].poll, original.poll)
        timeline.update(try update(original, ["components": [], "message_snapshots": [], "poll": NSNull()]))
        XCTAssertTrue(timeline.messages[0].components.isEmpty)
        XCTAssertTrue(timeline.messages[0].messageSnapshots.isEmpty)
        XCTAssertNil(timeline.messages[0].poll)
        XCTAssertEqual(timeline.messages[0].content, "A new caption")
    }

    func testResultsOnlyPollUpdatePreservesQuestionLabelsAndExistingCounts() throws {
        let original = try MockDiscord.contentParityFixtures()[1]
        let timeline = MessageTimeline(channelID: original.channelID)
        timeline.receive(original)
        timeline.update(try update(original, ["poll": ["results": ["answer_counts": [["id": 1, "count": 20], ["id": 2, "count": 5]]]]]))
        XCTAssertEqual(timeline.messages[0].poll?.question, original.poll?.question)
        XCTAssertEqual(timeline.messages[0].poll?.answers, original.poll?.answers)
        timeline.update(try update(original, ["poll": ["results": ["is_finalized": true]]]))
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?.first?.count, 20)
        XCTAssertTrue(text(render(timeline.messages[0]).embeds).contains("Final results"))
    }

    func testIncomingVoteEventsUpdateKnownResultsWithoutInteractions() throws {
        let original = try MockDiscord.contentParityFixtures()[1]
        let center = MessageCenter()
        let timeline = center.timeline(for: original.channelID)
        timeline.receive(original)
        func vote(_ name: String, answer: Int, user: String = "7") throws {
            let data = try JSONSerialization.data(withJSONObject: ["d": ["channel_id": original.channelID.description,
                "message_id": original.id.description, "user_id": user, "answer_id": answer]])
            center.handle(GatewayDispatch(name: name, data: data), me: 8)
        }
        try vote("MESSAGE_POLL_VOTE_ADD", answer: 2)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 4)
        try vote("MESSAGE_POLL_VOTE_REMOVE", answer: 2)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 3)
        try vote("MESSAGE_POLL_VOTE_ADD", answer: 2, user: "8")
        try vote("MESSAGE_POLL_VOTE_ADD", answer: 2, user: "8")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 4, "Own duplicate confirmation is idempotent")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].meVoted, true)
        try vote("MESSAGE_POLL_VOTE_ADD", answer: 999)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?.count, 2)
        timeline.update(try update(original, ["poll": ["results": ["is_finalized": true]]]))
        try vote("MESSAGE_POLL_VOTE_ADD", answer: 2)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 4, "Final totals remain final")
    }

    func testContentUpdatesSurviveEditHTTPResponseAndFailure() async throws {
        for failing in [false, true] {
            var original = try MockDiscord.contentParityFixtures()[1]
            original.content = "Before edit"
            let timeline = MessageTimeline(channelID: original.channelID)
            timeline.receive(original)
            let api = ScriptedWrites()
            let request = timeline.sendEdit(original.id, content: "Edited caption", api: api)
            for _ in 0..<100 where api.edits.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
            guard !api.edits.isEmpty else { XCTFail("Edit never reached the isolated scripted API"); return }
            timeline.update(try update(original, ["poll": ["results": ["is_finalized": true]],
                                                 "components": [["type": 10, "content": "Arrived during edit"]]]))
            if failing { api.failEdit(0) }
            else {
                var response = original
                response.content = "Edited caption"
                response.editedTimestamp = "2026-11-01T01:00:00Z"
                api.answerEdit(0, with: response)
            }
            _ = await request?.value
            XCTAssertEqual(timeline.messages[0].poll?.results?.isFinalized, true)
            XCTAssertEqual(timeline.messages[0].components.first?.content, "Arrived during edit")
            XCTAssertEqual(timeline.messages[0].content, failing ? "Before edit" : "Edited caption")
        }
    }

    func testStaleContentEchoDuringEditDoesNotOverwriteNewPrimaryContent() async throws {
        var original = try MockDiscord.contentParityFixtures()[3]
        original.content = "Before edit"
        original.editedTimestamp = "2026-11-01T01:00:00Z"
        let timeline = MessageTimeline(channelID: original.channelID)
        timeline.receive(original)
        let api = ScriptedWrites()
        let request = timeline.sendEdit(original.id, content: "Current edit", api: api)
        for _ in 0..<100 where api.edits.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        guard !api.edits.isEmpty else { XCTFail("Edit never reached the isolated scripted API"); return }
        timeline.update(try update(original, ["edited_timestamp": "2026-11-01T00:00:00Z", "components": []]))
        api.failEdit(0)
        _ = await request?.value
        XCTAssertEqual(timeline.messages[0].components, original.components)
    }

    func testMalformedSiblingsDoNotEraseReadableContent() throws {
        var message = try MockDiscord.contentParityFixtures()[3]
        message.components = try decode([MessageComponent].self, [
            ["type": 17, "components": [42, ["type": 10, "content": "Readable sibling"], ["type": 12, "items": [false, ["media": ["url": "mock://image/sibling/100x100"]]]]]]
        ])
        let rendered = render(message)
        XCTAssertTrue(text(rendered.embeds).contains("Readable sibling"))
        XCTAssertEqual(rendered.embeds.compactMap(\.image).count, 1)
    }

    func testComponentDecodeAndRenderingHaveDepthNodeAndTextBudgets() throws {
        var tree: [String: Any] = ["type": 10, "content": "Very deep text"]
        for _ in 0..<30 { tree = ["type": 17, "components": [tree]] }
        var message = try MockDiscord.contentParityFixtures()[3]
        message.components = try decode([MessageComponent].self, [tree])
        XCTAssertTrue(text(render(message).embeds).contains("Additional content omitted"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object["components"] = (0..<200).map { ["type": 10, "content": "Block \($0)"] }
        message = try decode(Message.self, object)
        XCTAssertLessThanOrEqual(message.components.count, ContentDecoding.nodeLimit + 1)
        XCTAssertLessThanOrEqual(render(message).embeds.count, 81)
        message.components = try decode([MessageComponent].self, [["type": 10, "content": String(repeating: "long text ", count: 4000)]])
        XCTAssertLessThanOrEqual(message.components[0].content?.count ?? 0, ContentDecoding.textLimit + 32)
        XCTAssertTrue(text(render(message).embeds).contains("Additional"))
    }

    func testSnapshotDecodeDepthIsBoundedAndVisible() throws {
        var snapshot: [String: Any] = ["message": ["content": "Too deep"]]
        for _ in 0..<20 { snapshot = ["message": ["content": "Outer snapshot", "message_snapshots": [snapshot]]] }
        var message = try MockDiscord.contentParityFixtures()[0]
        // Decode through Message so the shared per-message snapshot budget runs.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object["message_snapshots"] = [snapshot]
        message = try decode(Message.self, object)
        XCTAssertTrue(text(render(message).embeds).contains("Additional content omitted"))
        XCTAssertFalse(text(render(message).embeds).contains("Too deep"))
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)), message)
    }

    func testNarrowAndLargeTextLayoutsContainAllMeasuredContent() throws {
        let fixtures = try MockDiscord.contentParityFixtures()
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
                for fixture in fixtures {
                    let rendered = render(fixture)
                    let widths: [CGFloat] = [240, 320, 466, 543]
                    for width in widths {
                        let layout = MessageLayoutEngine.layout(rendered, width: width)
                        XCTAssertTrue(layout.height.isFinite)
                        XCTAssertGreaterThan(layout.height, 0)
                        XCTAssertEqual(layout.embeds.count, rendered.embeds.count)
                        var bottom = layout.body?.maxY ?? 0
                        for (card, frames) in zip(rendered.embeds, layout.embeds) {
                            XCTAssertGreaterThanOrEqual(frames.frame.minY, bottom)
                            XCTAssertLessThanOrEqual(frames.frame.maxX, width - MessageMetrics.sideInset + 0.5)
                            let children = [frames.author, frames.title, frames.body, frames.footer, frames.image, frames.thumbnail].compactMap { $0 } + frames.fields.flatMap { [$0.name, $0.value] }
                            for child in children {
                                XCTAssertGreaterThanOrEqual(child.width, 0)
                                XCTAssertGreaterThanOrEqual(child.minY, frames.frame.minY)
                                XCTAssertLessThanOrEqual(child.maxY, frames.frame.maxY + 0.5)
                                XCTAssertLessThanOrEqual(child.maxX, frames.frame.maxX + 0.5)
                            }
                            if let body = card.body, let frame = frames.body {
                                XCTAssertGreaterThanOrEqual(frame.height, TextMeasurer.size(body, width: frame.width).height)
                            }
                            if card.titleURL != nil { XCTAssertGreaterThanOrEqual(frames.title?.height ?? 0, 44) }
                            bottom = frames.frame.maxY
                        }
                        XCTAssertGreaterThanOrEqual(layout.height, bottom)
                    }
                }
            }
        }
    }

    func testNarrowEmbedThumbnailStacksInsteadOfCrushingText() throws {
        var message = try MockDiscord.contentParityFixtures()[0]
        message.messageSnapshots[0].embeds = [try decode(Embed.self, [
            "title": "Long title", "description": "Readable body beside a thumbnail at wide widths, stacked when narrow.",
            "thumbnail": ["url": "mock://image/thumb/320x320", "width": 320, "height": 320]
        ])]
        let rendered = render(message)
        let layout = MessageLayoutEngine.layout(rendered, width: 240)
        let index = try XCTUnwrap(rendered.embeds.firstIndex { $0.title?.string == "Long title" })
        let frames = layout.embeds[index]
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames.thumbnail).minY, try XCTUnwrap(frames.body).maxY)
        XCTAssertGreaterThan(try XCTUnwrap(frames.body).width, 100)
    }

    func testSpoilerContainersDoNotLeakTextOrLinksIntoAccessibility() throws {
        var message = try MockDiscord.contentParityFixtures()[3]
        message.components = try decode([MessageComponent].self, [["type": 17, "spoiler": true, "components": [
            ["type": 10, "content": "Hidden reveal"],
            ["type": 2, "style": 5, "label": "Secret button", "url": "https://example.com/secret"],
            ["type": 12, "items": [["media": ["url": "mock://image/secret/320x320"], "description": "Secret picture"]]]
        ]]])
        let rendered = render(message)
        XCTAssertFalse(rendered.accessibilityText.contains("Hidden reveal"))
        XCTAssertFalse(rendered.accessibilityText.contains("Secret button"))
        XCTAssertFalse(rendered.accessibilityText.contains("Secret picture"))
        XCTAssertTrue(rendered.embeds.compactMap(\.titleURL).isEmpty)
        XCTAssertTrue(rendered.embeds.compactMap(\.image).allSatisfy(\.isSpoiler))
    }

    func testForwardedComponentSpoilersDoNotExposeDuplicateAttachments() throws {
        let gallery: [String: Any] = ["type": 12, "items": [["media": ["url": "attachment://classified.png"], "spoiler": true]]]
        let inherited: [String: Any] = ["type": 17, "spoiler": true, "components": [
            ["type": 12, "items": [["media": ["url": "attachment://classified.png"]]]]
        ]]
        for component in [gallery, inherited] {
            var message = try MockDiscord.contentParityFixtures()[0]
            message.messageSnapshots = [try decode(MessageSnapshot.self, ["message": [
                "attachments": [["id": "111", "filename": "classified.png", "size": 100,
                                  "url": "mock://image/classified/320x320", "width": 320, "height": 320,
                                  "content_type": "image/png"]],
                "components": [component]
            ]])]
            let rendered = render(message)
            let images = rendered.embeds.compactMap(\.image)
            XCTAssertEqual(images.count, 1, "A component-owned snapshot attachment must render only in its component")
            XCTAssertTrue(images.allSatisfy(\.isSpoiler))
            XCTAssertFalse(rendered.accessibilityText.contains("classified"))
        }
    }

    func testComponentFileUsesResolvedAttachmentSpoilerMarkers() throws {
        for (filename, flags) in [("SPOILER_secret.txt", 0), ("secret.txt", 8)] {
            var message = try MockDiscord.contentParityFixtures()[3]
            message.attachments = [try decode(Attachment.self, [
                "id": "112", "filename": filename, "size": 100, "flags": flags,
                "url": "https://example.com/secret-file", "content_type": "text/plain"
            ])]
            message.components = try decode([MessageComponent].self, [
                ["type": 13, "file": ["url": "attachment://" + filename]]
            ])
            let rendered = render(message)
            XCTAssertTrue(text(rendered.embeds).contains("Spoiler file"))
            XCTAssertFalse(text(rendered.embeds).contains("secret"))
            XCTAssertFalse(rendered.accessibilityText.contains("secret"))
            XCTAssertTrue(rendered.embeds.compactMap(\.titleURL).isEmpty)
            XCTAssertTrue(rendered.embeds.compactMap(\.url).isEmpty)
            XCTAssertTrue(rendered.files.isEmpty)
        }
    }

    func testPollVoteEventsReachTimelineThroughAppDispatch() async throws {
        let original = try MockDiscord.contentParityFixtures()[1]
        let model = AppModel()
        model.store.apply(ready: try decode(ReadyPayload.self, ["user": ["id": "8", "username": "me"], "guilds": []]))
        let timeline = model.timeline(for: original.channelID)
        timeline.receive(original)
        func vote(_ name: String, user: String) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["d": ["channel_id": original.channelID.description,
                "message_id": original.id.description, "user_id": user, "answer_id": 2]])
            await model.handle(GatewayDispatch(name: name, data: data))
        }
        try await vote("MESSAGE_POLL_VOTE_ADD", user: "7")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 4)
        try await vote("MESSAGE_POLL_VOTE_REMOVE", user: "7")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 3)
        try await vote("MESSAGE_POLL_VOTE_ADD", user: "8")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 4)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].meVoted, true)
        try await vote("MESSAGE_POLL_VOTE_REMOVE", user: "8")
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].count, 3)
        XCTAssertEqual(timeline.messages[0].poll?.results?.answerCounts?[1].meVoted, false)
    }

    func testContentRichMessagesStillRespectTheTimelineWindow() throws {
        let fixture = try MockDiscord.contentParityFixtures()[0]
        let timeline = MessageTimeline(channelID: fixture.channelID)
        for index in 0..<(MessageTimeline.windowLimit + 10) {
            var message = fixture
            message.id = Snowflake(fixture.id.raw + UInt64(index))
            timeline.receive(message)
        }
        XCTAssertEqual(timeline.messages.count, MessageTimeline.windowLimit)
        XCTAssertEqual(timeline.messages.first?.id.raw, fixture.id.raw + 10)
        XCTAssertTrue(timeline.hasMoreBefore)
    }

    func testCardLinkHasAnActualMeasuredControlAndForwardsItsURL() throws {
        var message = try MockDiscord.contentParityFixtures()[3]
        message.attachments = []
        message.components = try decode([MessageComponent].self, [["type": 2, "style": 5, "label": "Read the notes", "url": "https://example.com/notes"]])
        let rendered = render(message)
        let layout = MessageLayoutEngine.layout(rendered, width: 320)
        let card = try XCTUnwrap(rendered.embeds.first)
        let frame = try XCTUnwrap(layout.embeds.first)
        let view = EmbedView(frame: frame.frame)
        var opened: URL?
        view.onOpenURL = { opened = $0 }
        view.configure(card, layout: frame)
        let control = try XCTUnwrap(view.subviews.compactMap { $0 as? UIControl }.first { !$0.isHidden })
        XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened?.absoluteString, "https://example.com/notes")
    }

    func testUnsupportedAndUnavailablePayloadsAreLabelled() throws {
        var message = try MockDiscord.contentParityFixtures()[3]
        message.components = []
        XCTAssertTrue(text(render(message).embeds).contains("App content unavailable"))
        message.components = try decode([MessageComponent].self, [
            ["type": 2, "style": 5, "label": "Unsafe URL", "url": "javascript:alert(1)"],
            ["type": 13, "file": ["url": "attachment://missing.txt"]],
            ["type": 12, "items": []]
        ])
        let rendered = render(message)
        XCTAssertTrue(rendered.embeds.compactMap(\.titleURL).isEmpty)
        XCTAssertTrue(text(rendered.embeds).contains("File unavailable"))
        XCTAssertTrue(text(rendered.embeds).contains("Media gallery unavailable"))
    }
}

