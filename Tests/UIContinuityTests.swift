import XCTest
import SwiftUI
import UIKit
@testable import DuocordNative

@MainActor
final class UIContinuityTests: XCTestCase {
    func testBookClosedAndTabletopReconstructionRetainResponderIntentAndSelection() {
        let state = ComposerContinuity()
        let channel: Snowflake = 11
        let text = "Draft 👩🏽‍💻 with a selection"
        let selection = NSRange(text.range(of: "👩🏽‍💻 with")!, in: text)
        var field = state.attach(in: channel)
        state.beganEditing(field, in: channel, selectedChannel: channel)
        state.saveSelection(selection, text: text, in: channel, owner: field)

        // NavigationSplitView collapse and the table-top NavigationStack/deck
        // handoff both replace native fields for the same conversation.
        for _ in 0..<4 {
            state.endedEditing(field, in: channel, isAttached: false)
            state.detach(field, in: channel)
            field = state.attach(in: channel)
            XCTAssertTrue(state.shouldFocus(field, in: channel, selectedChannel: channel))
            XCTAssertEqual(state.selection(in: channel, text: text), selection)
        }
    }

    func testReplacedFieldCannotDismissOrOverwriteNewField() {
        let state = ComposerContinuity()
        let old = state.attach(in: 11)
        state.beganEditing(old, in: 11, selectedChannel: 11)
        let replacement = state.attach(in: 11)
        let selection = NSRange(location: 2, length: 3)
        state.saveSelection(selection, text: "abcdef", in: 11, owner: replacement)
        state.endedEditing(old, in: 11, isAttached: true)
        state.saveSelection(NSRange(location: 0, length: 0), text: "abcdef", in: 11, owner: old)
        state.detach(old, in: 11)
        XCTAssertTrue(state.shouldFocus(replacement, in: 11, selectedChannel: 11))
        XCTAssertEqual(state.selection(in: 11, text: "abcdef"), selection)
    }

    func testExplicitDismissalSurvivesReconstruction() {
        let state = ComposerContinuity()
        let old = state.attach(in: 11)
        state.beganEditing(old, in: 11, selectedChannel: 11)
        state.endedEditing(old, in: 11, isAttached: true)
        state.detach(old, in: 11)
        let replacement = state.attach(in: 11)
        XCTAssertFalse(state.shouldFocus(replacement, in: 11, selectedChannel: 11))
        state.requestFocus(in: 11) // An explicit Reply/Edit may focus again.
        XCTAssertTrue(state.shouldFocus(replacement, in: 11, selectedChannel: 11))
    }

    func testDeferredEndEditingDoesNotCancelNewReplyOrEditFocusRequest() {
        let state = ComposerContinuity()
        let field = state.attach(in: 11)
        state.beganEditing(field, in: 11, selectedChannel: 11)
        let endingRevision = state.focusRevision
        state.requestFocus(in: 11)
        state.endedEditing(field, in: 11, isAttached: true, revision: endingRevision)
        XCTAssertTrue(state.shouldFocus(field, in: 11, selectedChannel: 11))
        state.endedEditing(field, in: 11, isAttached: true, revision: state.focusRevision)
        XCTAssertFalse(state.shouldFocus(field, in: 11, selectedChannel: 11))
    }

    func testChannelChangeClearsFocusWithoutLosingPerChannelSelection() {
        let model = AppModel()
        model.selectedChannel = 11
        let field = model.composerContinuity.attach(in: 11)
        model.composerContinuity.beganEditing(field, in: 11, selectedChannel: model.selectedChannel)
        model.composerContinuity.saveSelection(NSRange(location: 1, length: 2), text: "first", in: 11)
        model.selectedChannel = 11
        XCTAssertTrue(model.composerContinuity.shouldFocus(field, in: 11, selectedChannel: model.selectedChannel))
        model.selectedChannel = 12
        model.composerContinuity.saveSelection(NSRange(location: 3, length: 0), text: "second", in: 12)
        model.composerContinuity.beganEditing(field, in: 11, selectedChannel: model.selectedChannel)
        XCTAssertNil(model.composerContinuity.focusedChannel)
        XCTAssertFalse(model.composerContinuity.shouldFocus(field, in: 11, selectedChannel: model.selectedChannel))
        model.selectedChannel = 11
        XCTAssertNil(model.composerContinuity.focusedChannel)
        XCTAssertEqual(model.composerContinuity.selection(in: 11, text: "first"), NSRange(location: 1, length: 2))
        XCTAssertEqual(model.composerContinuity.selection(in: 12, text: "second"), NSRange(location: 3, length: 0))
        model.selectedChannel = nil
        XCTAssertNil(model.composerContinuity.focusedChannel)
    }

    func testSelectionIsTiedToExactTextAndUsesUTF16() {
        let state = ComposerContinuity()
        let text = "🙂e\u{301} draft"
        let selection = NSRange(text.range(of: "draft")!, in: text)
        state.saveSelection(selection, text: text, in: 11)
        XCTAssertEqual(state.selection(in: 11, text: text), selection)
        let replacement = "👩🏽‍💻 new edit"
        XCTAssertEqual(state.selection(in: 11, text: replacement), NSRange(location: replacement.utf16.count, length: 0))
        state.saveSelection(NSRange(location: NSNotFound, length: 1), text: text, in: 11)
        XCTAssertEqual(state.selection(in: 11, text: text), selection)
        state.saveSelection(NSRange(location: 1, length: 0), text: text, in: 11) // Inside the emoji's surrogate pair.
        XCTAssertEqual(state.selection(in: 11, text: text), selection)
    }

    func testDismantlingNativeAdapterCapturesSelectionAndPreservesFocusIntent() {
        let model = AppModel()
        model.selectedChannel = 11
        model.drafts[11] = Draft(text: "native draft")
        let binding = Binding(get: { model.drafts[11]! }, set: { model.drafts[11] = $0 })
        let adapter = ComposerTextInput(draft: binding, model: model, channelID: 11, wantsFocus: true,
                                        maximumLines: 6, hasSuggestions: false, handleKey: { _ in .ignored })
        let coordinator = adapter.makeCoordinator()
        let view = ComposerTextInput.Input()
        view.text = "native draft"
        view.selectedRange = NSRange(location: 3, length: 4)
        coordinator.textViewDidBeginEditing(view)
        coordinator.textViewDidEndEditing(view)
        ComposerTextInput.dismantleUIView(view, coordinator: coordinator)
        XCTAssertNil(view.delegate)
        XCTAssertEqual(model.composerContinuity.selection(in: 11, text: "native draft"), NSRange(location: 3, length: 4))
        let replacement = adapter.makeCoordinator()
        XCTAssertTrue(model.composerContinuity.shouldFocus(replacement.lease, in: 11, selectedChannel: 11))
        coordinator.textViewDidBeginEditing(view)
        XCTAssertTrue(model.composerContinuity.owns(replacement.lease, in: 11))
    }

    func testCanonicallyEqualReplacementDoesNotReuseDifferentUTF16Offsets() {
        let state = ComposerContinuity()
        let decomposed = "e\u{301} draft"
        let composed = "é draft"
        XCTAssertEqual(decomposed, composed)
        XCTAssertNotEqual(decomposed.utf16.count, composed.utf16.count)
        state.saveSelection(NSRange(location: 2, length: 0), text: decomposed, in: 11)
        XCTAssertEqual(state.selection(in: 11, text: composed), NSRange(location: composed.utf16.count, length: 0))
        state.saveSelection(NSRange(location: 1, length: 0), text: composed, in: 11)
        XCTAssertEqual(state.selection(in: 11, text: composed), NSRange(location: 1, length: 0))
    }

    func testNativeAdapterDoesNotSaveSelectionFromReplacedText() {
        let model = AppModel()
        model.selectedChannel = 11
        model.drafts[11] = Draft(text: "new edit")
        let binding = Binding(get: { model.drafts[11]! }, set: { model.drafts[11] = $0 })
        let adapter = ComposerTextInput(draft: binding, model: model, channelID: 11, wantsFocus: false,
                                        maximumLines: 6, hasSuggestions: false, handleKey: { _ in .ignored })
        let coordinator = adapter.makeCoordinator()
        let view = ComposerTextInput.Input()
        view.text = "old draft"
        view.selectedRange = NSRange(location: 0, length: 0)
        coordinator.saveSelection(view)
        XCTAssertEqual(model.composerContinuity.selection(in: 11, text: "new edit"), NSRange(location: 8, length: 0))
    }

    func testContinuityResetDropsFocusSelectionAndOldOwnership() {
        let state = ComposerContinuity()
        let field = state.attach(in: 11)
        state.requestFocus(in: 11)
        state.saveSelection(NSRange(location: 1, length: 0), text: "draft", in: 11, owner: field)
        state.reset()
        XCTAssertNil(state.focusedChannel)
        XCTAssertFalse(state.owns(field, in: 11))
        XCTAssertEqual(state.selection(in: 11, text: "draft"), NSRange(location: 5, length: 0))
    }

    func testReactorProfileCanUseRESTUserAbsentFromStore() {
        let reactor = User(id: 77, username: "reactor", globalName: "Reactor", discriminator: nil, avatar: nil, bot: nil)
        let store = DiscordStore()
        XCTAssertNil(store.users[reactor.id])
        XCTAssertEqual(UserProfileView.resolveUser(reactor.id, cached: store.users[reactor.id], fallback: reactor), reactor)
        var cached = reactor
        cached.globalName = "Updated profile"
        XCTAssertEqual(UserProfileView.resolveUser(reactor.id, cached: cached, fallback: reactor), cached)
        XCTAssertNil(UserProfileView.resolveUser(88, cached: cached, fallback: reactor))
    }

    func testReactionsUseCompactSheetOrRegularSidebarWithoutChangingConversation() {
        let model = AppModel()
        model.selectedChannel = 11
        let route = AppSheet.reactions(channel: 11, message: 100, emoji: "👍")
        model.fold.isCompact = true
        model.present(route)
        XCTAssertEqual(model.sheet, route)
        XCTAssertEqual(model.selectedChannel, 11)
        model.fold.isCompact = false
        model.sizeClassChanged(compact: false)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.sidebarPanel, route)
        XCTAssertEqual(model.selectedChannel, 11)
    }

    func testDeleteConfirmationUsesStandardAlertInConversationPresentationContext() {
        let model = AppModel()
        let list = MessageListController(timeline: model.timeline(for: 11), store: model.store, api: model.api,
                                         guildID: nil, title: "Fixture", subtitle: "", icon: "number", anchor: nil, unreadAfter: nil)
        list.loadViewIfNeeded()
        XCTAssertTrue(list.definesPresentationContext)
        let message = Message(id: 100, channelID: 11, guildID: nil, author: User(id: 1, username: "me", globalName: nil,
                              discriminator: nil, avatar: nil, bot: nil), content: "fixture", timestamp: "")
        let alert = list.deleteConfirmation(for: message)
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .destructive])
        XCTAssertEqual(alert.actions.map(\.title), ["Cancel", "Delete"])
        XCTAssertEqual(alert.view.accessibilityIdentifier, "confirmDelete")
        // This creates no window and presents nothing; placement remains a
        // separate platform verification task.
        list.confirmDelete(message)
        XCTAssertNil(list.presentedViewController)
    }
}
