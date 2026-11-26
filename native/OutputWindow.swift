import AppKit

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// OBS 采集用的纯净输出窗口：只有换脸画面，无任何控件。
final class OutputWindowController: NSObject, NSWindowDelegate {
    private(set) var window: OutputWindow?
    private var outputView: OutputView?
    var onClose: (() -> Void)?

    func show(image: CGImage?) {
        if window == nil {
            createWindow()
        }
        if let image {
            outputView?.image = image
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ image: CGImage) {
        outputView?.image = image
    }

    func close() {
        window?.close()
    }

    private func createWindow() {
        let window = OutputWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "实时换脸输出"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = true
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let view = OutputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        window.contentView = view
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.center()

        self.window = window
        self.outputView = view
    }

    func windowWillClose(_ notification: Notification) {
        NSCursor.unhide()
        onClose?()
    }
}

final class OutputView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    private var hideTimer: Timer?
    private var cursorHidden = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        scheduleHideCursor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image else {
            let text = "等待换脸画面…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35)
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let rect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            (text as NSString).draw(in: rect, withAttributes: attrs)
            return
        }

        let imageSize = NSSize(width: image.width, height: image.height)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = NSRect(
            x: (bounds.width - drawSize.width) / 2,
            y: (bounds.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: rect)
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        showCursor()
        scheduleHideCursor()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            window?.close()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                window?.toggleFullScreen(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func scheduleHideCursor() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            guard let self, self.window != nil else { return }
            if !self.cursorHidden {
                NSCursor.hide()
                self.cursorHidden = true
            }
        }
    }

    private func showCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    deinit {
        hideTimer?.invalidate()
        if cursorHidden { NSCursor.unhide() }
    }
}
