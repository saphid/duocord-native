import UIKit

/// A vertical list with caller-supplied exact row heights. Nothing is
/// estimated, so content above the viewport never resizes after the fact,
/// which is what makes anchoring exact. Short content sits at the bottom.
final class MessageListLayout: UICollectionViewLayout {
    private(set) var heights: [CGFloat] = []
    private var offsets: [CGFloat] = [0]
    private var topPadding: CGFloat = 0
    private var cache: [IndexPath: UICollectionViewLayoutAttributes] = [:]

    func setHeights(_ heights: [CGFloat]) {
        self.heights = heights
        offsets = [0]
        offsets.reserveCapacity(heights.count + 1)
        var running: CGFloat = 0
        for height in heights {
            running += height
            offsets.append(running)
        }
        cache.removeAll(keepingCapacity: true)
        invalidateLayout()
    }

    var totalHeight: CGFloat { offsets.last ?? 0 }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        let padding = max(0, visible - totalHeight)
        if padding != topPadding {
            topPadding = padding
            cache.removeAll(keepingCapacity: true)
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: totalHeight + topPadding)
    }

    func frame(at index: Int) -> CGRect {
        guard index >= 0, index < heights.count else { return .zero }
        return CGRect(x: 0, y: topPadding + offsets[index], width: collectionView?.bounds.width ?? 0, height: heights[index])
    }

    /// The first row whose bottom is below `y`.
    func index(at y: CGFloat) -> Int {
        let target = y - topPadding
        var low = 0, high = heights.count - 1
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid + 1] <= target { low = mid + 1 } else { high = mid }
        }
        return max(0, low)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !heights.isEmpty else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = self.index(at: rect.minY)
        while index < heights.count {
            let frame = self.frame(at: index)
            if frame.minY > rect.maxY { break }
            if let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)) { result.append(attributes) }
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < heights.count else { return nil }
        if let cached = cache[indexPath] { return cached }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(at: indexPath.item)
        cache[indexPath] = attributes
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width || newBounds.height != collectionView.bounds.height
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        super.invalidateLayout(with: context)
        cache.removeAll(keepingCapacity: true)
    }

    // Inserted rows fade in place; nothing slides.
    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes
        attributes?.alpha = 0
        return attributes
    }
}
