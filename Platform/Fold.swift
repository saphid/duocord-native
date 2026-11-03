import Observation
import SwiftUI
import UIKit

/// The device posture as the layout needs it.
enum Posture: Equatable {
    /// One flat panel (outer display, or the inner display fully open).
    case flat
    /// Half-open with a vertical fold: two pages side by side.
    case book(foldMinX: CGFloat, foldWidth: CGFloat)
    /// Half-open with a horizontal fold: screen above, controls below.
    case tableTop(foldMinY: CGFloat, foldHeight: CGFloat)
}

/// The fold (an active division region) and the window's size class.
@Observable
final class FoldState {
    var foldFrame: CGRect?
    var windowSize: CGSize = .zero
    var isCompact = true
    var hingeAngle: Double?

    var posture: Posture {
        guard let fold = foldFrame else { return .flat }
        if fold.height > fold.width {
            // Only a fold near the middle splits the window into pages.
            guard windowSize.width > 0, fold.minX > windowSize.width * 0.25, fold.maxX < windowSize.width * 0.75 else { return .flat }
            return .book(foldMinX: fold.minX, foldWidth: fold.width)
        }
        guard windowSize.height > 0, fold.minY > windowSize.height * 0.25, fold.maxY < windowSize.height * 0.75 else { return .flat }
        return .tableTop(foldMinY: fold.minY, foldHeight: fold.height)
    }

    var postureName: String {
        switch posture {
        case .flat: isCompact ? "compact" : "regular"
        case .book: "book"
        case .tableTop: "tableTop"
        }
    }
}

/// Reports the fold crossing the window into `FoldState`. Re-queries on
/// every layout pass and whenever the hinge moves.
struct FoldReader: UIViewRepresentable {
    let state: FoldState

    func makeUIView(context: Context) -> FoldReaderView {
        let view = FoldReaderView()
        view.state = state
        return view
    }

    func updateUIView(_ view: FoldReaderView, context: Context) {
        view.state = state
        view.setNeedsLayout()
    }
}

final class FoldReaderView: UIView {
    weak var state: FoldState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addInteraction(UIHingeInteraction { [weak self] _, update in
            self?.state?.hingeAngle = update.hinge.map { Double($0.angle) }
            self?.setNeedsLayout()
            self?.updateFold()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFold()
    }

    private func updateFold() {
        guard let state else { return }
        var fold = reservedRegions(kind: .division).first { $0.isActive && bounds.intersects($0.frame) }?.frame
        #if DEBUG
        if let fake = DebugFold.frame(in: bounds.size) { fold = fake }
        #endif
        if state.foldFrame != fold { state.foldFrame = fold }
        if state.windowSize != bounds.size { state.windowSize = bounds.size }
    }
}

#if DEBUG
/// `-DuocordFakeFold book|tabletop` simulates a half-open fold where the
/// simulator can't produce one (table-top, portrait book).
enum DebugFold {
    static func frame(in size: CGSize) -> CGRect? {
        switch UserDefaults.standard.string(forKey: "DuocordFakeFold") {
        case "book": CGRect(x: size.width / 2 - 20, y: 0, width: 40, height: size.height)
        case "tabletop": CGRect(x: 0, y: size.height / 2 - 20, width: size.width, height: 40)
        default: nil
        }
    }
}
#endif
