import AppKit

final class TrackControlsViewportView: NSView {
    var onVerticalScroll: ((Float) -> Void)?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }

        onVerticalScroll?(Float(-event.scrollingDeltaY))
    }
}
