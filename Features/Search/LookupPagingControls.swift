import SwiftUI

enum LookupPageProgress: Equatable {
    case ready, loading, failed(String), finished(String)
}

/// Explicit paging avoids scroll-triggered request loops on empty/overlapping pages.
struct LookupPagingControls: View {
    let progress: LookupPageProgress
    let loadMore: () -> Void
    let reload: () -> Void

    var body: some View {
        switch progress {
        case .ready:
            Button("Load More", action: loadMore)
                .accessibilityHint("Loads the next page and keeps current results")
                .accessibilityIdentifier("lookupLoadMore")
        case .loading:
            ProgressView("Loading more results")
        case .failed(let error):
            Text("Couldn't load more: \(error)").font(.footnote).foregroundStyle(Color.textMuted)
            Button("Retry Load More", action: loadMore)
                .accessibilityHint("Retries the same page and keeps current results")
        case .finished(let reason):
            if !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(Color.textMuted)
                Button("Reload Results", action: reload)
            }
        }
    }
}
