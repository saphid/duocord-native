import XCTest
import SwiftUI
import UIKit
@testable import DuocordNative

/// The real RootView in a window on the test host's scene, driven by the
/// in-process MockDiscord (no network, no account). Measures what UIKit
/// actually laid out. `wide` forces regular width at about the inner
/// display's landscape size, so the sidebar and conversation sit side by side.
@MainActor
final class DuoLayoutTests: XCTestCase {
    private var window: UIWindow?
    private let wide = CGSize(width: 1000, height: 704)

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    @discardableResult
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() && Date.now < deadline {
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date.now.addingTimeInterval(seconds))
    }

    private func host(size: CGSize? = nil) throws -> (AppModel, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = AppModel(notificationAPI: MockDiscord())
        model.start()
        let root = RootView()
            .environment(model)
            .environment(model.store)
            .environment(model.settings)
            .environment(model.fold)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        let controller = UIHostingController(rootView: root)
        if size != nil { controller.traitOverrides.horizontalSizeClass = .regular }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        if let size { window.frame = CGRect(origin: .zero, size: size) }
        self.window = window
        XCTAssertTrue(spin { model.store.isReady })
        model.select(guild: 910_000_000_000_000_000)
        model.select(channel: MockDiscord.generalChannel)
        XCTAssertTrue(spin { self.views(ComposerTextInput.Input.self, in: window).first != nil })
        settle(1.2)
        return (model, window)
    }

    private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var found: [T] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Visible accessibility elements with this label, as the user's assistive tech sees them.
    private func elements(labelled label: String, in window: UIWindow) -> [NSObject] {
        var stack: [NSObject] = [window]
        var found: [NSObject] = []
        var seen = 0
        while let node = stack.popLast(), seen < 20_000 {
            seen += 1
            if let view = node as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if node.isAccessibilityElement, node.accessibilityLabel == label { found.append(node) }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count { if let child = node.accessibilityElement(at: index) as? NSObject { stack.append(child) } }
            } else if let children = node.accessibilityElements as? [NSObject] {
                stack.append(contentsOf: children)
            }
            if let view = node as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    /// Element frames are in screen coordinates; the wide window starts at the screen origin.
    private func onScreen(_ label: String, in window: UIWindow) -> Bool {
        elements(labelled: label, in: window).contains { $0.accessibilityFrame.minY >= 0 && $0.accessibilityFrame.maxY <= window.bounds.maxY }
    }

    // MARK: Bottom inset with the keyboard hidden

    /// The home indicator needs 20 pt (the whole bottom inset UIKit gives a
    /// home-indicator iPad). An iPhone's larger inset (34 pt, iPhone Duo
    /// too) adds room for its corners that bottom controls don't need.
    private let indicatorClearance: CGFloat = 20

    func testComposerSitsJustAboveHomeIndicatorWithKeyboardHidden() throws {
        let (model, window) = try host(size: wide)
        XCTAssertFalse(model.keyboardVisible)
        XCTAssertGreaterThan(window.safeAreaInsets.bottom, indicatorClearance, "Needs a home-indicator inset larger than the clearance")
        let input = try XCTUnwrap(views(ComposerTextInput.Input.self, in: window).first)
        // Field: 9 pt padding under the text; controls: 6 pt under the field.
        let fieldBottom = input.convert(input.bounds, to: window).maxY + 9
        let gap = window.bounds.maxY - fieldBottom
        XCTAssertEqual(gap, indicatorClearance + 6, accuracy: 1,
                       "composer field bottom is \(gap) pt above the screen edge (safe area \(window.safeAreaInsets.bottom))")
    }

    func testSidebarFooterSitsJustAboveHomeIndicator() throws {
        let (model, window) = try host(size: wide)
        model.columnVisibility = .all
        settle()
        XCTAssertGreaterThan(window.safeAreaInsets.bottom, indicatorClearance)
        let settings = try XCTUnwrap(elements(labelled: "Settings", in: window).first)
        let gap = window.bounds.maxY - settings.accessibilityFrame.midY
        // The row: a 44 pt button with 6 pt padding under it.
        XCTAssertEqual(gap, indicatorClearance + 6 + 22, accuracy: 1,
                       "account row centre is \(gap) pt above the screen edge (safe area \(window.safeAreaInsets.bottom))")
    }

    /// With the keyboard up the controls still ride directly on it.
    func testComposerStillSitsOnTheKeyboard() throws {
        let (model, window) = try host()
        var keyboard: CGRect?
        let token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { note in
            keyboard = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        }
        defer { NotificationCenter.default.removeObserver(token); window.endEditing(true); settle(0.5) }
        let input = try XCTUnwrap(views(ComposerTextInput.Input.self, in: window).first)
        input.becomeFirstResponder()
        guard spin(until: { keyboard != nil && model.keyboardVisible }, timeout: 5), let screenFrame = keyboard else {
            throw XCTSkip("No software keyboard appeared on this simulator (hardware keyboard connected?)")
        }
        settle()
        let keyboardTop = window.convert(screenFrame, from: window.screen.coordinateSpace).minY
        let controlsBottom = input.convert(input.bounds, to: window).maxY + 9 + 6
        XCTAssertEqual(controlsBottom, keyboardTop, accuracy: 1, "controls end at \(controlsBottom), keyboard starts at \(keyboardTop)")
    }

    // MARK: Hidden sidebar stays reachable

    /// Scrolls the real message list back and forth, as reading does; on
    /// iOS 27 that minimises the title bar by default.
    private func scrollHistoryAndBack(_ window: UIWindow) throws {
        let list = try XCTUnwrap(views(UICollectionView.self, in: window).first { $0.accessibilityIdentifier == "messageList" })
        let latest = list.contentOffset.y
        for step in 1...6 {
            list.setContentOffset(CGPoint(x: 0, y: latest - CGFloat(step) * 150), animated: true)
            settle(0.4)
        }
        for step in 1...6 {
            list.setContentOffset(CGPoint(x: 0, y: latest - 900 + CGFloat(step) * 150), animated: true)
            settle(0.4)
        }
    }

    func testHiddenSidebarRevealAndTitleSurviveScrolling() throws {
        let (model, window) = try host(size: wide)
        withAnimation(.snappy(duration: 0.3)) { model.columnVisibility = .detailOnly }
        settle()
        XCTAssertTrue(onScreen("Show Sidebar", in: window))
        XCTAssertTrue(onScreen("general", in: window))
        try scrollHistoryAndBack(window)
        XCTAssertTrue(onScreen("Show Sidebar", in: window), "the only way back to the sidebar scrolled away")
        XCTAssertTrue(onScreen("general", in: window), "the conversation title scrolled away")
        XCTAssertTrue(onScreen("Inbox", in: window))
    }

    /// The sidebar can also be hidden after the bar has minimised.
    func testHidingSidebarAfterScrollingKeepsReveal() throws {
        let (model, window) = try host(size: wide)
        model.columnVisibility = .all
        settle()
        try scrollHistoryAndBack(window)
        withAnimation(.snappy(duration: 0.3)) { model.columnVisibility = .detailOnly }
        settle(1.2)
        XCTAssertTrue(onScreen("Show Sidebar", in: window), "the only way back to the sidebar is off screen")
        model.columnVisibility = .all
        settle()
        XCTAssertTrue(onScreen("Hide Sidebar", in: window))
    }
}
