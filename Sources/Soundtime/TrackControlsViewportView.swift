import AppKit

final class TrackControlsViewportView: NSView {
    var onVerticalScroll: ((Float) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViewportClipping()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViewportClipping()
    }

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

    private func configureViewportClipping() {
        wantsLayer = true
        layer?.masksToBounds = true
    }
}
