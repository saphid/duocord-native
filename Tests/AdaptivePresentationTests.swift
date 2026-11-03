import XCTest
import SwiftUI
import Observation
@testable import DuocordNative

/// Model and actual sheet-binding lifecycle only; no mounted/fold runtime claim.
@MainActor
final class AdaptivePresentationTests: XCTestCase {
    private var routes: [AppSheet] {
        let url = URL(string: "https://example.invalid/fixture.png")!
        return [.search, .pins, .inbox, .settings, .friends, .threads(11), .threads(22),
                .reactions(channel: 11, message: 100, emoji: "👍"),
                .reactions(channel: 22, message: 100, emoji: "custom:42"),
                .emojiPicker(channel: 11, message: 100), .emojiPicker(channel: 22, message: 200),
                .notifications(.guild(9)), .notifications(.channel(guild: 9, channel: 11)),
                .notifications(.channel(guild: nil, channel: 22)), .user(77), .user(88),
                .media(MediaItem(url: url, openURL: url, width: 20, height: 30,
                                isVideo: false, isSpoiler: true, alt: "fixture")), .members, .servers]
    }

    private func fixture() -> AppModel {
        let model = AppModel(notificationAPI: MockDiscord())
        model.fold.isCompact = false
        model.selectedGuild = 9
        model.selectedChannel = 11
        model.drafts = [11: Draft(text: "draft A"), 22: Draft(text: "draft B")]
        return model
    }

    private func layout(_ model: AppModel, compact: Bool, tableTop: Bool = false) {
        model.fold.windowSize = CGSize(width: 900, height: 700)
        model.fold.foldFrame = tableTop ? CGRect(x: 0, y: 330, width: 900, height: 40) : nil
        model.fold.isCompact = compact
        model.sizeClassChanged(compact: compact)
    }

    private func assertConversation(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.selectedGuild, 9, file: file, line: line)
        XCTAssertEqual(model.selectedChannel, 11, file: file, line: line)
        XCTAssertEqual(model.drafts, [11: Draft(text: "draft A"), 22: Draft(text: "draft B")], file: file, line: line)
    }

    private func pending(_ model: AppModel, route: AppSheet = .search, tableTop: Bool = false) {
        model.present(route)
        model.sheet = .user(77)
        layout(model, compact: !tableTop, tableTop: tableTop)
    }

    private func dismiss(_ model: AppModel) {
        // The production MainView modifier uses this same binding and callback.
        let completion = model.sheetDismissal
        model.sheetBinding.wrappedValue = nil
        completion()
    }

    func testEveryRouteRegularToCompactAndBack() {
        for route in routes {
            let model = fixture()
            model.present(route)
            layout(model, compact: true)
            XCTAssertEqual(model.sheet, route, "\(route)")
            XCTAssertNil(model.sidebarPanel)
            layout(model, compact: false)
            XCTAssertEqual(model.sidebarPanel, route.opensInSidebar ? route : nil)
            XCTAssertEqual(model.sheet, route.opensInSidebar ? nil : route)
            assertConversation(model)
        }
    }

    func testEveryRouteRegularToTableTopAndBack() {
        for route in routes {
            let model = fixture()
            model.present(route)
            layout(model, compact: false, tableTop: true)
            XCTAssertEqual(model.sheet, route, "\(route)")
            XCTAssertNil(model.sidebarPanel)
            layout(model, compact: false)
            XCTAssertEqual(model.sidebarPanel, route.opensInSidebar ? route : nil)
            XCTAssertEqual(model.sheet, route.opensInSidebar ? nil : route)
            assertConversation(model)
        }
    }

    func testEveryRouteCompactToRegularAndBack() {
        for route in routes {
            let model = fixture()
            layout(model, compact: true)
            model.present(route)
            layout(model, compact: false)
            XCTAssertEqual(model.sidebarPanel, route.opensInSidebar ? route : nil)
            XCTAssertEqual(model.sheet, route.opensInSidebar ? nil : route)
            layout(model, compact: true)
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
            assertConversation(model)
        }
    }

    func testEveryRouteTableTopToRegularAndBack() {
        for route in routes {
            let model = fixture()
            layout(model, compact: false, tableTop: true)
            model.present(route)
            layout(model, compact: false)
            XCTAssertEqual(model.sidebarPanel, route.opensInSidebar ? route : nil)
            layout(model, compact: false, tableTop: true)
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
            assertConversation(model)
        }
    }

    func testRepeatedCallbacksHaveOnePresentationAndStableIntent() {
        for route in routes.filter(\.opensInSidebar) {
            let model = fixture()
            model.present(route)
            layout(model, compact: true)
            let intent = model.navigationIntent
            for _ in 0..<4 { model.sizeClassChanged(compact: true) }
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
            XCTAssertEqual(model.navigationIntent, intent)
            layout(model, compact: false)
            let regularIntent = model.navigationIntent
            for _ in 0..<4 { model.sizeClassChanged(compact: false) }
            XCTAssertNil(model.sheet)
            XCTAssertEqual(model.sidebarPanel, route)
            XCTAssertEqual(model.navigationIntent, regularIntent)
        }
    }

    func testAllSidebarTargetsWaitForEveryNontransferableModalThenDismiss() {
        for route in routes.filter(\.opensInSidebar) {
            for modal in routes.filter({ !$0.opensInSidebar }) {
                let model = fixture()
                model.present(route)
                model.sheet = modal
                layout(model, compact: true)
                XCTAssertEqual(model.sheet, modal)
                XCTAssertEqual(model.sidebarPanel, route)
                dismiss(model)
                XCTAssertEqual(model.sheet, route)
                XCTAssertNil(model.sidebarPanel)
                assertConversation(model)
            }
        }
    }

    func testTableTopPendingTransfersAfterDismissWithoutFoldCallback() {
        for route in routes.filter(\.opensInSidebar) {
            let model = fixture()
            pending(model, route: route, tableTop: true)
            XCTAssertEqual(model.sheet, .user(77))
            dismiss(model)
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
        }
    }

    func testBindingNilWaitsForDismissCompletionDespiteLayoutCallbacks() {
        let model = fixture()
        pending(model)
        model.sheetBinding.wrappedValue = nil
        for _ in 0..<3 { model.sizeClassChanged(compact: true) }
        XCTAssertNil(model.sheet, "Do not present into an in-progress dismissal")
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, .search)
        XCTAssertNil(model.sidebarPanel)
    }

    func testRegularBeforeModalDismissRetainsOnlySidebar() {
        let model = fixture()
        pending(model)
        layout(model, compact: false)
        dismiss(model)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.sidebarPanel, .search)
        model.sheetDidDismiss()
        XCTAssertNil(model.sheet)
    }

    func testRegularBetweenBindingNilAndDismissRetainsOnlySidebar() {
        let model = fixture()
        pending(model)
        model.sheetBinding.wrappedValue = nil
        layout(model, compact: false)
        model.sheetDidDismiss()
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.sidebarPanel, .search)
    }

    func testCompactAgainBeforeDismissTransfersOnce() {
        let model = fixture()
        pending(model)
        model.sheetBinding.wrappedValue = nil
        layout(model, compact: false)
        layout(model, compact: true)
        XCTAssertNil(model.sheet)
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, .search)
        XCTAssertNil(model.sidebarPanel)
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, .search)
    }

    func testExplicitPanelCloseDoesNotResurrect() {
        let model = fixture()
        pending(model)
        model.sidebarPanel = nil
        dismiss(model)
        layout(model, compact: false)
        layout(model, compact: true)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testReplacementPresentationCancelsObsoletePendingRoute() {
        for route in routes {
            let model = fixture()
            pending(model)
            model.present(route)
            model.sheetDidDismiss() // stale old-modal completion
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
            dismiss(model)
            layout(model, compact: false)
            XCTAssertNil(model.sheet)
            XCTAssertNil(model.sidebarPanel)
        }
    }

    func testDirectSheetReplacementCancelsObsoletePendingRoute() {
        let model = fixture()
        pending(model)
        model.sheet = .user(88)
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, .user(88))
        dismiss(model)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testNavigationCancelsPendingWithoutClosingUnrelatedModal() {
        let model = fixture()
        pending(model)
        model.select(channel: nil)
        XCTAssertEqual(model.sheet, .user(77))
        dismiss(model)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testDirectSelectionChangeCancelsPending() {
        for changeGuild in [false, true] {
            let model = fixture()
            pending(model)
            if changeGuild { model.selectedGuild = 10 } else { model.selectedChannel = 22 }
            dismiss(model)
            XCTAssertNil(model.sheet)
            XCTAssertNil(model.sidebarPanel)
        }
    }

    func testPendingReplacementSidebarDoesNotRestoreOldTarget() {
        let model = fixture()
        pending(model, route: .threads(11))
        model.sidebarPanel = .threads(22)
        dismiss(model)
        XCTAssertNotEqual(model.sheet, .threads(11))
        XCTAssertNotEqual(model.sidebarPanel, .threads(11))
    }

    func testResetCancelsPendingAndLateCallbacks() {
        let model = fixture()
        pending(model)
        let oldBinding = model.sheetBinding
        model.resetPresentations()
        oldBinding.wrappedValue = nil
        model.sheetDidDismiss()
        layout(model, compact: false)
        layout(model, compact: true)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testStaleBindingCannotDismissNewRouteWithSameAppSheetID() {
        let model = fixture()
        layout(model, compact: true)
        let a = AppSheet.reactions(channel: 11, message: 100, emoji: "👍")
        let b = AppSheet.reactions(channel: 22, message: 100, emoji: "🔥")
        XCTAssertEqual(a.id, b.id, "Guard must use presentation generation, not AppSheet.id")
        model.present(a)
        let oldBinding = model.sheetBinding
        model.present(b)
        oldBinding.wrappedValue = nil
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, b)
        XCTAssertNil(model.sidebarPanel)
    }

    func testStaleBindingCannotDismissReopenedEqualRoute() {
        let model = fixture()
        layout(model, compact: true)
        model.present(.pins)
        let oldBinding = model.sheetBinding
        dismiss(model)
        model.present(.pins)
        oldBinding.wrappedValue = nil
        model.sheetDidDismiss()
        XCTAssertEqual(model.sheet, .pins)
    }

    func testTransferChangesNavigationIntentButNotLookupContext() {
        let model = fixture()
        for route in [AppSheet.search, .pins] {
            layout(model, compact: false)
            model.present(route)
            let context = LookupContext(model: model, store: model.store)
            let intent = model.navigationIntent
            layout(model, compact: true)
            XCTAssertNotEqual(model.navigationIntent, intent, "Transfer keeps existing people-navigation cancellation")
            XCTAssertEqual(LookupContext(model: model, store: model.store), context)
            XCTAssertEqual(model.sheet, route)
            XCTAssertNil(model.sidebarPanel)
            assertConversation(model)
        }
    }

    func testActualCompletionBeforeBindingResetTransfersPendingOnce() {
        for tableTop in [false, true] {
            let model = fixture()
            pending(model, route: .threads(22), tableTop: tableTop)
            let binding = model.sheetBinding
            let completed = model.sheetDismissal
            completed()
            XCTAssertEqual(model.sheet, .threads(22))
            XCTAssertNil(model.sidebarPanel)
            binding.wrappedValue = nil
            completed()
            XCTAssertEqual(model.sheet, .threads(22))
            XCTAssertNil(model.sidebarPanel)
        }
    }

    func testActualCompletionAfterBindingResetUsesCurrentLayout() {
        for tableTop in [false, true] {
            let model = fixture()
            pending(model, route: .emojiPicker(channel: 22, message: 200), tableTop: tableTop)
            let binding = model.sheetBinding
            let completed = model.sheetDismissal
            binding.wrappedValue = nil
            XCTAssertNil(model.sheet)
            completed()
            XCTAssertEqual(model.sheet, .emojiPicker(channel: 22, message: 200))
            XCTAssertNil(model.sidebarPanel)
        }
    }

    func testActualStaleCompletionCannotDismissReplacementOrItsPendingRoute() {
        let model = fixture()
        pending(model)
        let oldBinding = model.sheetBinding
        let oldCompletion = model.sheetDismissal
        model.present(.user(88))
        // A newer lookup now waits behind the replacement modal.
        model.sidebarPanel = .threads(22)
        let newBinding = model.sheetBinding
        let newCompletion = model.sheetDismissal
        oldCompletion()
        oldBinding.wrappedValue = nil
        XCTAssertEqual(model.sheet, .user(88))
        XCTAssertEqual(model.sidebarPanel, .threads(22))
        newBinding.wrappedValue = nil
        oldCompletion()
        XCTAssertNil(model.sheet, "Old completion cannot finish a newer dismissal")
        XCTAssertEqual(model.sidebarPanel, .threads(22))
        newCompletion()
        XCTAssertEqual(model.sheet, .threads(22))
        XCTAssertNil(model.sidebarPanel)
    }

    func testActualStaleCompletionCannotDismissEqualReopenedRoute() {
        let model = fixture()
        layout(model, compact: true)
        model.present(.pins)
        let oldCompletion = model.sheetDismissal
        dismiss(model)
        model.present(.pins)
        oldCompletion()
        XCTAssertEqual(model.sheet, .pins)
    }

    func testActualStaleCompletionAfterAdaptiveTransferCannotDismissNewSheet() {
        let model = fixture()
        layout(model, compact: true)
        model.present(.search)
        let oldBinding = model.sheetBinding
        let oldCompletion = model.sheetDismissal
        layout(model, compact: false)
        layout(model, compact: true)
        oldBinding.wrappedValue = nil
        oldCompletion()
        XCTAssertEqual(model.sheet, .search)
        XCTAssertNil(model.sidebarPanel)
    }

    func testEveryModalRetainsPriorityAndSidebarOnReturnBeforeDismiss() {
        for modal in routes {
            let model = fixture()
            model.present(.threads(99))
            model.sheet = modal
            let binding = model.sheetBinding
            let completed = model.sheetDismissal
            layout(model, compact: true)
            XCTAssertEqual(model.sheet, modal)
            XCTAssertEqual(model.sidebarPanel, .threads(99))
            layout(model, compact: false)
            XCTAssertEqual(model.sheet, modal, "Even a sidebar-capable unrelated modal keeps priority")
            XCTAssertEqual(model.sidebarPanel, .threads(99))
            binding.wrappedValue = nil
            completed()
            XCTAssertNil(model.sheet)
            XCTAssertEqual(model.sidebarPanel, .threads(99))
        }
    }

    func testActualCallbackAfterResetCannotClearNewPresentation() {
        let model = fixture()
        pending(model)
        let binding = model.sheetBinding
        let completed = model.sheetDismissal
        model.resetPresentations()
        model.present(.pins)
        binding.wrappedValue = nil
        completed()
        XCTAssertEqual(model.sheet, .pins)
        XCTAssertNil(model.sidebarPanel)
    }

    func testExplicitSameSelectionIntentCancelsPending() {
        let model = fixture()
        pending(model)
        model.selectedChannel = 11
        dismiss(model)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testMembersReplacementDoesNotResurrectPendingLookup() {
        let model = fixture()
        pending(model)
        model.toggleMembers()
        XCTAssertEqual(model.sheet, .members)
        dismiss(model)
        layout(model, compact: false)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.sidebarPanel)
    }

    func testBookUsesRegularSidebarAndTransitionsThroughTableTop() {
        for route in routes.filter(\.opensInSidebar) {
            let model = fixture()
            model.fold.windowSize = CGSize(width: 900, height: 700)
            model.fold.foldFrame = CGRect(x: 430, y: 0, width: 40, height: 700)
            model.present(route)
            model.sizeClassChanged(compact: false)
            XCTAssertEqual(model.sidebarPanel, route)
            layout(model, compact: false, tableTop: true)
            XCTAssertEqual(model.sheet, route)
            model.fold.foldFrame = CGRect(x: 430, y: 0, width: 40, height: 700)
            model.sizeClassChanged(compact: false)
            XCTAssertNil(model.sheet)
            XCTAssertEqual(model.sidebarPanel, route)
        }
    }

    func testTransfersPreserveAnchorsComposerSelectionAndFullDrafts() {
        let model = fixture()
        let user = User(id: 7, username: "fixture", globalName: nil, discriminator: nil, avatar: nil, bot: nil)
        let message = Message(id: 100, channelID: 11, guildID: 9, author: user, content: "fixture", timestamp: "")
        model.drafts[11]?.replyTo = message
        model.drafts[11]?.editing = message
        model.drafts[11]?.attachments = [DraftAttachment(filename: "offline.txt", data: Data([1, 2]), contentType: "text/plain")]
        let drafts = model.drafts
        let field = model.composerContinuity.attach(in: 11)
        model.composerContinuity.beganEditing(field, in: 11, selectedChannel: 11)
        model.composerContinuity.saveSelection(NSRange(location: 2, length: 1), text: "draft A", in: 11, owner: field)
        let anchor = ScrollAnchor(itemID: "message-100", offset: 12, pinnedToBottom: false)
        model.anchors[11] = anchor
        let visit = model.conversationVisit
        model.present(.pins)
        layout(model, compact: true)
        layout(model, compact: false, tableTop: true)
        layout(model, compact: false)
        XCTAssertEqual(model.drafts, drafts)
        XCTAssertEqual(model.anchors[11], anchor)
        XCTAssertEqual(model.conversationVisit, visit)
        XCTAssertTrue(model.composerContinuity.owns(field, in: 11))
        XCTAssertEqual(model.composerContinuity.selection(in: 11, text: "draft A"), NSRange(location: 2, length: 1))
    }


    func testEqualActiveReplacementRefreshesViewCallbackGeneration() {
        let model = fixture()
        layout(model, compact: true)
        model.present(.pins)
        let oldBinding = model.sheetBinding
        let oldCompletion = model.sheetDismissal
        var invalidated = false
        withObservationTracking {
            _ = model.sheetBinding
            _ = model.sheetDismissal
        } onChange: {
            invalidated = true
        }
        model.present(.pins)
        XCTAssertTrue(invalidated, "MainView must receive refreshed callbacks even for an equal active route")
        oldBinding.wrappedValue = nil
        oldCompletion()
        XCTAssertEqual(model.sheet, .pins)
        dismiss(model)
        XCTAssertNil(model.sheet)
    }

    func testReplacementDuringDismissalRemainsReachableAcrossLaterAdaptation() {
        for tableTop in [false, true] {
            for directAssignment in [false, true] {
                let model = fixture()
                pending(model, tableTop: tableTop)
                let staleBinding = model.sheetBinding
                let staleCompletion = model.sheetDismissal
                staleBinding.wrappedValue = nil
                if directAssignment { model.sheet = .pins } else { model.present(.pins) }
                XCTAssertEqual(model.sheet, .pins)
                XCTAssertNil(model.sidebarPanel)

                layout(model, compact: false)
                XCTAssertNil(model.sheet)
                XCTAssertEqual(model.sidebarPanel, .pins)
                layout(model, compact: !tableTop, tableTop: tableTop)
                staleBinding.wrappedValue = nil
                staleCompletion()
                model.sizeClassChanged(compact: !tableTop)
                XCTAssertEqual(model.sheet, .pins, "Replacement must not inherit the old dismissal barrier")
                XCTAssertNil(model.sidebarPanel)
                dismiss(model)
                XCTAssertNil(model.sheet)
                XCTAssertNil(model.sidebarPanel)
                assertConversation(model)
            }
        }
    }

    func testFreshMainViewCallbacksAfterBindingResetKeepDismissalGeneration() {
        let model = fixture()
        pending(model)
        model.sheetBinding.wrappedValue = nil
        // A body recomputation between binding reset and onDismiss must retain
        // the old modal generation, rather than orphaning the pending route.
        let recomputedCompletion = model.sheetDismissal
        recomputedCompletion()
        XCTAssertEqual(model.sheet, .search)
        XCTAssertNil(model.sidebarPanel)
    }

}
