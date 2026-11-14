import XCTest
import SwiftUI
@testable import DuocordNative

@MainActor
final class MediaViewerZoomTests: XCTestCase {
    func testResizeKeepsZoomedRegionAndNewImageResetsToFit() {
        let url = URL(string: "mock://image/zoom/1200x900")!
        let scroll = MediaZoomView()
        scroll.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        scroll.configure(url: url, imageSize: CGSize(width: 400, height: 300), label: "Image")
        scroll.layoutIfNeeded()
        scroll.setZoomScale(3, animated: false)
        scroll.contentOffset = CGPoint(x: 340, y: 145)
        // The viewport center is at 45%, 55% of the image.
        scroll.frame.size = CGSize(width: 700, height: 400)
        scroll.configure(url: url, imageSize: CGSize(width: 533, height: 400), label: "Image")
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 3, accuracy: 0.001)
        XCTAssertEqual((scroll.contentOffset.x + 350) / scroll.contentSize.width, 0.45, accuracy: 0.001)
        XCTAssertEqual((scroll.contentOffset.y + 200) / scroll.contentSize.height, 0.55, accuracy: 0.001)

        scroll.configure(url: URL(string: "mock://image/other/1200x900")!,
                         imageSize: CGSize(width: 533, height: 400), label: "Other image")
        XCTAssertEqual(scroll.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(scroll.contentOffset.x, -scroll.contentInset.left, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.contentInset.top, accuracy: 1)
    }

    func testOpenedImageKeepsZoomAndAllowsPanningAfterViewUpdate() throws {
        let url = URL(string: "mock://image/zoom/1200x900")!
        let item = MediaItem(url: url, openURL: url, width: 1200, height: 900,
                             isVideo: false, isSpoiler: false, alt: "Zoom fixture")
        let host = UIHostingController(rootView: MediaViewer(item: item))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func zoomView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.maximumZoomScale > 1 { return scroll }
            return view.subviews.lazy.compactMap { zoomView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(zoomView(in: host.view), "An opened image must support native pinch zoom and pan")
        XCTAssertNotNil(scroll.pinchGestureRecognizer)
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
        scroll.setZoomScale(3, animated: false)
        scroll.contentOffset = CGPoint(x: 120, y: 90)
        let offset = scroll.contentOffset

        host.rootView = MediaViewer(item: item)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(scroll.zoomScale, 3, accuracy: 0.001, "Zoom must persist after release and SwiftUI updates")
        XCTAssertEqual(scroll.contentOffset.x, offset.x, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        scroll.contentOffset.x += 60
        XCTAssertEqual(scroll.contentOffset.x, offset.x + 60, accuracy: 1, "A zoomed image must remain pannable")
    }
}
