import AppKit
import QuickLookUI

/// Drives the system Quick Look panel — the same preview Finder shows when you
/// press Space on a file.
///
/// Quick Look normally finds its data source by walking the responder chain,
/// which a pure SwiftUI scene has no convenient hook into. Rather than bridge a
/// first responder just for this, the presenter hands itself to the shared panel
/// directly and keeps itself alive as a singleton for as long as the panel is up
/// (`QLPreviewPanel` holds its data source weakly, so a short-lived object would
/// leave the panel blank).
final class QuickLookPresenter: NSObject {

    static let shared = QuickLookPresenter()

    private var url: URL?

    private override init() { super.init() }

    /// Previews `path`, or brings the panel down if it is already showing it —
    /// matching Finder, where Space toggles.
    func present(path: String) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, url?.path == path {
            panel.orderOut(nil)
            return
        }

        url = URL(fileURLWithPath: path)
        panel.dataSource = self
        panel.delegate = self

        if panel.isVisible {
            // Already open on a different item: reload rather than re-key the
            // window, which would steal focus back from the map on every arrow.
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the panel if it is showing. Used when the previewed item is trashed.
    func dismiss() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        url = nil
    }
}

extension QuickLookPresenter: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}

extension QuickLookPresenter: QLPreviewPanelDelegate {
    /// Lets the panel zoom out to the map instead of just fading, and keeps
    /// keyboard handling inside the panel while it is up.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { false }
}
