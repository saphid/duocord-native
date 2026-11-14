import SwiftUI
import UIKit

/// UIScrollView keeps the pinch's focal point and retains zoom and pan on release.
struct ZoomableMediaImage: UIViewRepresentable {
    let url: URL
    let imageSize: CGSize
    let label: String

    func makeUIView(context: Context) -> MediaZoomView { MediaZoomView() }

    func updateUIView(_ view: MediaZoomView, context: Context) {
        view.configure(url: url, imageSize: imageSize, label: label)
    }

    static func dismantleUIView(_ view: MediaZoomView, coordinator: ()) {
        view.imageView.playbackEnabled = false
        view.imageView.setImage(nil, size: .zero)
    }
}

final class MediaZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = RemoteImageView()
    private var source: URL?
    private var fittedSize = CGSize.zero
    private var viewportSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL, imageSize: CGSize, label: String) {
        imageView.accessibilityLabel = label
        let changedSource = source != url
        guard changedSource || fittedSize != imageSize else { return }
        let oldSize = fittedSize
        let focus = normalizedCenter(in: oldSize, viewport: viewportSize)
        let scale = changedSource ? 1 : zoomScale
        source = url
        fittedSize = imageSize
        setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize
        imageView.setImage(url, size: imageSize)
        setZoomScale(scale, animated: false)
        viewportSize = bounds.size
        centerImage()
        restoreCenter(changedSource ? CGPoint(x: 0.5, y: 0.5) : focus)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if viewportSize != bounds.size {
            let focus = normalizedCenter(in: fittedSize, viewport: viewportSize)
            viewportSize = bounds.size
            centerImage()
            restoreCenter(focus)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
    }

    private func normalizedCenter(in size: CGSize, viewport: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(x: (contentOffset.x + viewport.width / 2) / (size.width * zoomScale),
                       y: (contentOffset.y + viewport.height / 2) / (size.height * zoomScale))
    }

    private func restoreCenter(_ point: CGPoint) {
        contentOffset = CGPoint(
            x: min(max(-contentInset.left, point.x * contentSize.width - bounds.width / 2),
                   max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(-contentInset.top, point.y * contentSize.height - bounds.height / 2),
                   max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(x: point.x - target.width / 2, y: point.y - target.height / 2,
                            width: target.width, height: target.height), animated: true)
        }
    }
}
