import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import DuocordNative

/// Paste into the real composer field (mounted through SwiftUI, so the
/// adapter's wiring is exercised) from the system pasteboard. The
/// pasteboard's previous contents are restored afterwards.
@MainActor
final class ComposerPasteTests: XCTestCase {
    private var window: UIWindow?
    private var savedItems: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        savedItems = UIPasteboard.general.items
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        UIPasteboard.general.items = savedItems
        super.tearDown()
    }

    private func png(_ color: UIColor = .systemPink) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
    }

    private func mount(_ draft: Draft) throws -> (AppModel, ComposerTextInput.Input) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = AppModel()
        model.selectedChannel = 11
        model.drafts[11] = draft
        model.composerContinuity.requestFocus(in: 11)
        let binding = Binding(get: { model.drafts[11] ?? Draft() }, set: { model.drafts[11] = $0 })
        let field = ComposerTextInput(draft: binding, model: model, channelID: 11, wantsFocus: true,
                                      maximumLines: 6, hasSuggestions: false, handleKey: { _ in .ignored })
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = UIHostingController(rootView: field.frame(width: 300).padding(40))
        window.makeKeyAndVisible()
        self.window = window
        var input: ComposerTextInput.Input?
        let deadline = Date.now.addingTimeInterval(5)
        while input == nil, Date.now < deadline {
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
            input = Self.find(in: window)
        }
        let found = try XCTUnwrap(input)
        found.becomeFirstResponder()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
        return (model, found)
    }

    private static func find(in view: UIView) -> ComposerTextInput.Input? {
        if let input = view as? ComposerTextInput.Input { return input }
        for subview in view.subviews { if let input = find(in: subview) { return input } }
        return nil
    }

    private let pasteAction = #selector(UIResponderStandardEditActions.paste(_:))

    /// UIKit may finish a text paste on a later turn of the run loop.
    private func paste(into input: ComposerTextInput.Input, until done: () -> Bool) {
        input.paste(nil)
        let deadline = Date.now.addingTimeInterval(2)
        while !done(), Date.now < deadline { RunLoop.main.run(until: Date.now.addingTimeInterval(0.05)) }
    }

    func testPastingImageDataAddsAnAttachmentAndKeepsText() throws {
        let (model, input) = try mount(Draft(text: "look"))
        let data = png()
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        XCTAssertTrue(input.canPerformAction(pasteAction, withSender: nil), "Paste must be offered for an image")
        paste(into: input) { model.drafts[11]?.attachments.isEmpty == false }
        let draft = try XCTUnwrap(model.drafts[11])
        XCTAssertEqual(draft.text, "look")
        XCTAssertEqual(draft.attachments.count, 1)
        XCTAssertEqual(draft.attachments.first?.data, data)
        XCTAssertEqual(draft.attachments.first?.contentType, "image/png")
        XCTAssertEqual(draft.attachments.first?.filename.hasSuffix(".png"), true)
        XCTAssertNotNil(draft.attachments.first?.thumbnail)
    }

    func testPastingCopiedImagesAddsOneAttachmentEach() throws {
        let (model, input) = try mount(Draft())
        UIPasteboard.general.images = [UIImage(data: png(.systemBlue))!, UIImage(data: png(.systemGreen))!]
        XCTAssertTrue(input.canPerformAction(pasteAction, withSender: nil))
        paste(into: input) { model.drafts[11]?.attachments.isEmpty == false }
        let attachments = model.drafts[11]?.attachments ?? []
        XCTAssertEqual(attachments.count, 2)
        XCTAssertTrue(attachments.allSatisfy { UIImage(data: $0.data) != nil && $0.contentType.hasPrefix("image/") })
        XCTAssertEqual(model.drafts[11]?.text, "")
    }

    func testTextPasteIsUnchanged() throws {
        let (model, input) = try mount(Draft(text: "hi "))
        input.selectedRange = NSRange(location: 3, length: 0)
        UIPasteboard.general.string = "there"
        XCTAssertTrue(input.canPerformAction(pasteAction, withSender: nil))
        paste(into: input) { model.drafts[11]?.text == "hi there" }
        XCTAssertEqual(model.drafts[11]?.text, "hi there")
        XCTAssertEqual(model.drafts[11]?.attachments.count, 0)
    }

    /// An edit changes text only (the attachment button is disabled too).
    func testImagePasteIsRefusedWhileEditingAMessage() throws {
        var draft = Draft(text: "fixed typo")
        draft.editing = Message(id: 42, channelID: 11, guildID: nil, author: User(id: 7, username: "you"),
                                content: "fixed tpyo", timestamp: "")
        let (model, input) = try mount(draft)
        UIPasteboard.general.setData(png(), forPasteboardType: UTType.png.identifier)
        XCTAssertFalse(input.canPerformAction(pasteAction, withSender: nil))
        paste(into: input) { false }
        XCTAssertEqual(model.drafts[11]?.attachments.count, 0)
        XCTAssertEqual(model.drafts[11]?.text, "fixed typo")
    }
}
