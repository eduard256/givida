import SwiftUI
import AppKit

@main
struct gividaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindow: OverlayWindow?
    var borderWindow: BorderWindow?
    let recorder = ScreenRecorder()
    var statusMenuItem: NSMenuItem!
    var recordMenuItem: NSMenuItem!
    var pauseMenuItem: NSMenuItem!
    var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request accessibility permission
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("[givida] Accessibility not granted yet — hotkeys won't work until enabled")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "givida")
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        recordMenuItem = NSMenuItem(title: "Start Recording (⌥⌘R)", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(recordMenuItem)

        pauseMenuItem = NSMenuItem(title: "Pause (⌥⌘P)", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem.isEnabled = false
        menu.addItem(pauseMenuItem)

        menu.addItem(NSMenuItem.separator())

        let areaMenu = NSMenu()
        areaMenu.addItem(NSMenuItem(title: "1:1", action: #selector(selectArea1x1), keyEquivalent: ""))
        areaMenu.addItem(NSMenuItem(title: "16:9", action: #selector(selectArea16x9), keyEquivalent: ""))
        areaMenu.addItem(NSMenuItem(title: "9:16", action: #selector(selectArea9x16), keyEquivalent: ""))
        areaMenu.addItem(NSMenuItem(title: "Free", action: #selector(selectAreaFree), keyEquivalent: ""))
        let areaItem = NSMenuItem(title: "Select Area", action: nil, keyEquivalent: "")
        areaItem.submenu = areaMenu
        menu.addItem(areaItem)

        let typingZoomItem = NSMenuItem(title: "Zoom on Typing (⌥⌘K)", action: #selector(toggleTypingZoom), keyEquivalent: "")
        typingZoomItem.state = recorder.typingZoomEnabled ? .on : .off
        menu.addItem(typingZoomItem)

        menu.addItem(NSMenuItem(title: "Save Folder: \(savedFolderName())", action: #selector(chooseSaveFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu

        // Load typing zoom preference
        if UserDefaults.standard.object(forKey: "typingZoomEnabled") != nil {
            recorder.typingZoomEnabled = UserDefaults.standard.bool(forKey: "typingZoomEnabled")
        }

        // Setup global hotkeys
        setupHotkeys()

        // Recorder state callback
        recorder.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.updateMenuState(state)
            }
        }

        // Show saved border if exists
        showSavedBorder()
    }

    func setupHotkeys() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
            let optCmd: CGEventFlags = [.maskAlternate, .maskCommand]

            if type == .keyDown {
                // Option+Command+R — record
                if flags.contains(.maskAlternate) && flags.contains(.maskCommand) && keyCode == 15 {
                    Task { @MainActor in appDelegate.toggleRecording() }
                    return nil // swallow event
                }
                // Option+Command+P — pause
                if flags.contains(.maskAlternate) && flags.contains(.maskCommand) && keyCode == 35 {
                    Task { @MainActor in appDelegate.togglePause() }
                    return nil
                }
                // Option+Command+K — toggle typing zoom
                if flags.contains(.maskAlternate) && flags.contains(.maskCommand) && keyCode == 40 {
                    Task { @MainActor in appDelegate.toggleTypingZoom() }
                    return nil
                }
                // Option+Command+Z — zoom start
                if flags.contains(.maskAlternate) && flags.contains(.maskCommand) && keyCode == 6 {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat == 0 {
                        appDelegate.recorder.startZoom()
                    }
                    return nil
                }

                // Typing zoom: detect regular character input (no modifiers or just shift)
                let modifiersExceptShift = flags.subtracting(.maskShift).subtracting(.maskNonCoalesced)
                let isPlainKey = modifiersExceptShift.rawValue & (CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue) == 0
                if isPlainKey {
                    appDelegate.recorder.onKeyTyped()
                }
            }

            if type == .keyUp {
                // Ctrl+Option+Z released — zoom stop
                if keyCode == 6 && appDelegate.recorder.isZooming {
                    appDelegate.recorder.stopZoom()
                    return nil
                }
            }

            if type == .flagsChanged {
                // If option or command released while zooming
                if appDelegate.recorder.isZooming {
                    if !flags.contains(.maskAlternate) || !flags.contains(.maskCommand) {
                        appDelegate.recorder.stopZoom()
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("[givida] Failed to create event tap — check Accessibility permissions")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Setup zoom preview callback
        recorder.onZoomPreview = { [weak self] rect in
            self?.updateZoomPreview(rect)
        }
    }

    func updateZoomPreview(_ rect: CGRect) {
        guard recorder.state == .recording || recorder.state == .paused else { return }
        guard let window = borderWindow else { return }

        let padding: CGFloat = 4
        let windowRect = rect.insetBy(dx: -padding, dy: -padding)
        window.setFrame(windowRect, display: false)

        if let borderView = window.contentView as? BorderView {
            borderView.selectionSize = rect.size
            borderView.frame = NSRect(origin: .zero, size: windowRect.size)
            borderView.needsDisplay = true
        }
    }

    func updateMenuState(_ state: ScreenRecorder.State) {
        switch state {
        case .idle:
            statusMenuItem.title = "Status: Idle"
            recordMenuItem.title = "Start Recording (⌥⌘R)"
            pauseMenuItem.title = "Pause (⌥⌘P)"
            pauseMenuItem.isEnabled = false
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "givida")
            }
        case .recording:
            statusMenuItem.title = "Status: Recording"
            recordMenuItem.title = "Stop Recording (⌥⌘R)"
            pauseMenuItem.title = "Pause (⌥⌘P)"
            pauseMenuItem.isEnabled = true
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "givida recording")
            }
        case .paused:
            statusMenuItem.title = "Status: Paused"
            recordMenuItem.title = "Stop Recording (⌥⌘R)"
            pauseMenuItem.title = "Resume (⌥⌘P)"
            pauseMenuItem.isEnabled = true
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "givida paused")
            }
        }
    }

    @objc func toggleRecording() {
        if recorder.state == .idle {
            // Collect window numbers to exclude from capture
            Task {
                try? await recorder.startRecording()
            }
        } else {
            Task {
                await recorder.stopRecording()
            }
        }
    }

    @objc func togglePause() {
        recorder.togglePause()
    }

    enum AspectMode { case square, widescreen, portrait, free }

    func selectAreaWithMode(_ mode: AspectMode) {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        guard let screen = NSScreen.main else { return }
        let overlay = OverlayWindow(screen: screen, delegate: self, aspectMode: mode)
        overlayWindow = overlay
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
    }

    @objc func selectArea1x1() { selectAreaWithMode(.square) }
    @objc func selectArea16x9() { selectAreaWithMode(.widescreen) }
    @objc func selectArea9x16() { selectAreaWithMode(.portrait) }
    @objc func selectAreaFree() { selectAreaWithMode(.free) }

    func showSavedBorder() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "areaX") != nil else { return }

        let x = defaults.double(forKey: "areaX")
        let y = defaults.double(forKey: "areaY")
        let w = defaults.double(forKey: "areaW")
        let h = defaults.double(forKey: "areaH")

        guard w > 0 && h > 0 else { return }

        let rect = NSRect(x: x, y: y, width: w, height: h)
        borderWindow = BorderWindow(rect: rect)
        borderWindow?.orderFront(nil)
    }

    func areaSelected(rect: NSRect) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        // Save to UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(rect.origin.x, forKey: "areaX")
        defaults.set(rect.origin.y, forKey: "areaY")
        defaults.set(rect.width, forKey: "areaW")
        defaults.set(rect.height, forKey: "areaH")

        // Show dashed border
        borderWindow?.orderOut(nil)
        borderWindow = nil
        let border = BorderWindow(rect: rect)
        borderWindow = border
        border.orderFront(nil)
    }

    func savedFolderName() -> String {
        if let path = UserDefaults.standard.string(forKey: "saveFolder") {
            return (path as NSString).lastPathComponent
        }
        return "Desktop"
    }

    @objc func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose folder to save recordings"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "saveFolder")
            // Update menu item title
            if let menu = statusItem.menu,
               let item = menu.items.first(where: { $0.title.hasPrefix("Save Folder:") }) {
                item.title = "Save Folder: \(url.lastPathComponent)"
            }
        }
    }

    @objc func toggleTypingZoom() {
        recorder.typingZoomEnabled.toggle()
        UserDefaults.standard.set(recorder.typingZoomEnabled, forKey: "typingZoomEnabled")
        // Update menu item
        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.title == "Zoom on Typing" }) {
            item.state = recorder.typingZoomEnabled ? .on : .off
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Overlay Window (darkened screen with selection square)

class OverlayWindow: NSWindow {
    weak var selectionDelegate: AppDelegate?

    init(screen: NSScreen, delegate: AppDelegate, aspectMode: AppDelegate.AspectMode = .square) {
        self.selectionDelegate = delegate
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlayView = OverlayView(frame: screen.frame, delegate: delegate, aspectMode: aspectMode)
        self.contentView = overlayView
        self.makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class OverlayView: NSView {
    weak var selectionDelegate: AppDelegate?

    private var dragStart: NSPoint?
    private var currentRect: NSRect?
    private var isDragging = false
    private var isMoving = false
    private var isResizing = false
    private var moveOffset: NSPoint = .zero
    private var resizeCorner: Int = -1 // 0=TL, 1=TR, 2=BL, 3=BR
    private var aspectMode: AppDelegate.AspectMode = .square

    private let confirmButtonSize: CGFloat = 36

    // Returns aspect ratio (width/height), nil for free mode
    private var aspectRatio: CGFloat? {
        switch aspectMode {
        case .square: return 1.0
        case .widescreen: return 16.0 / 9.0
        case .portrait: return 9.0 / 16.0
        case .free: return nil
        }
    }

    init(frame: NSRect, delegate: AppDelegate, aspectMode: AppDelegate.AspectMode = .square) {
        self.selectionDelegate = delegate
        self.aspectMode = aspectMode
        super.init(frame: frame)

        // Load saved area if exists
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "areaX") != nil {
            let x = defaults.double(forKey: "areaX")
            let y = defaults.double(forKey: "areaY")
            let w = defaults.double(forKey: "areaW")
            let h = defaults.double(forKey: "areaH")
            if w > 0 && h > 0 {
                currentRect = NSRect(x: x, y: y, width: w, height: h)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Dark overlay
        NSColor.black.withAlphaComponent(0.5).setFill()
        dirtyRect.fill()

        // Clear the selected area
        if let rect = currentRect {
            NSColor.clear.setFill()
            let path = NSBezierPath(rect: rect)
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setBlendMode(.copy)
            path.fill()

            // White border around selection
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 2
            borderPath.stroke()

            // Corner handles
            let handleSize: CGFloat = 10
            NSColor.white.setFill()
            for corner in corners(of: rect) {
                let handleRect = NSRect(x: corner.x - handleSize/2, y: corner.y - handleSize/2, width: handleSize, height: handleSize)
                NSBezierPath(ovalIn: handleRect).fill()
            }

            // Confirm button (checkmark) inside the selection, bottom center
            let btnX = rect.midX - confirmButtonSize/2
            let btnY = rect.minY + 10
            let btnRect = NSRect(x: btnX, y: btnY, width: confirmButtonSize, height: confirmButtonSize)

            NSColor.white.setFill()
            NSBezierPath(roundedRect: btnRect, xRadius: 8, yRadius: 8).fill()

            // Draw checkmark
            let checkPath = NSBezierPath()
            NSColor.black.setStroke()
            checkPath.lineWidth = 3
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            checkPath.move(to: NSPoint(x: btnRect.minX + 10, y: btnRect.midY))
            checkPath.line(to: NSPoint(x: btnRect.midX - 2, y: btnRect.minY + 10))
            checkPath.line(to: NSPoint(x: btnRect.maxX - 10, y: btnRect.maxY - 10))
            checkPath.stroke()
        }
    }

    private func corners(of rect: NSRect) -> [NSPoint] {
        [
            NSPoint(x: rect.minX, y: rect.maxY), // TL
            NSPoint(x: rect.maxX, y: rect.maxY), // TR
            NSPoint(x: rect.minX, y: rect.minY), // BL
            NSPoint(x: rect.maxX, y: rect.minY), // BR
        ]
    }

    private func cornerIndex(at point: NSPoint, in rect: NSRect) -> Int? {
        let threshold: CGFloat = 15
        for (i, corner) in corners(of: rect).enumerated() {
            if hypot(point.x - corner.x, point.y - corner.y) < threshold {
                return i
            }
        }
        return nil
    }

    private func confirmButtonRect() -> NSRect? {
        guard let rect = currentRect else { return nil }
        let btnX = rect.midX - confirmButtonSize/2
        let btnY = rect.minY + 10
        return NSRect(x: btnX, y: btnY, width: confirmButtonSize, height: confirmButtonSize)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check confirm button
        if let btnRect = confirmButtonRect(), btnRect.contains(point) {
            if let rect = currentRect {
                selectionDelegate?.areaSelected(rect: rect)
            }
            return
        }

        if let rect = currentRect {
            // Check corner resize
            if let corner = cornerIndex(at: point, in: rect) {
                isResizing = true
                resizeCorner = corner
                return
            }

            // Check move
            if rect.contains(point) {
                isMoving = true
                moveOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                return
            }
        }

        // New selection
        isDragging = true
        dragStart = point
        currentRect = nil
    }

    private func sizeForDrag(dx: CGFloat, dy: CGFloat) -> NSSize {
        if let ratio = aspectRatio {
            // Constrained aspect ratio: use the dominant axis
            let w = abs(dx)
            let h = abs(dy)
            if w / ratio > h {
                return NSSize(width: w, height: w / ratio)
            } else {
                return NSSize(width: h * ratio, height: h)
            }
        } else {
            return NSSize(width: abs(dx), height: abs(dy))
        }
    }

    private func clampRect(_ rect: NSRect) -> NSRect {
        let bounds = self.bounds
        var r = rect
        // Clamp size to screen
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        // Re-enforce aspect ratio after clamping
        if let ratio = aspectRatio {
            if r.width / ratio > r.height {
                r.size.width = r.height * ratio
            } else {
                r.size.height = r.width / ratio
            }
        }
        r.size.width = max(r.width, 20)
        r.size.height = max(r.height, 20)
        // Clamp position
        r.origin.x = max(0, min(r.origin.x, bounds.width - r.width))
        r.origin.y = max(0, min(r.origin.y, bounds.height - r.height))
        return r
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDragging, let start = dragStart {
            let dx = point.x - start.x
            let dy = point.y - start.y
            let size = sizeForDrag(dx: dx, dy: dy)
            let x = dx >= 0 ? start.x : start.x - size.width
            let y = dy >= 0 ? start.y : start.y - size.height
            currentRect = clampRect(NSRect(x: x, y: y, width: size.width, height: size.height))
            needsDisplay = true
        } else if isMoving, let rect = currentRect {
            let newX = point.x - moveOffset.x
            let newY = point.y - moveOffset.y
            currentRect = clampRect(NSRect(x: newX, y: newY, width: rect.width, height: rect.height))
            needsDisplay = true
        } else if isResizing, let rect = currentRect {
            let oppositeCorners = [3, 2, 1, 0]
            let anchorCorner = corners(of: rect)[oppositeCorners[resizeCorner]]

            let dx = point.x - anchorCorner.x
            let dy = point.y - anchorCorner.y
            let size = sizeForDrag(dx: dx, dy: dy)

            let x = dx >= 0 ? anchorCorner.x : anchorCorner.x - size.width
            let y = dy >= 0 ? anchorCorner.y : anchorCorner.y - size.height
            currentRect = clampRect(NSRect(x: x, y: y, width: size.width, height: size.height))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isMoving = false
        isResizing = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            selectionDelegate?.overlayWindow?.orderOut(nil)
            selectionDelegate?.overlayWindow = nil
            selectionDelegate?.showSavedBorder()
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Border Window (dashed outline of saved area)

class BorderWindow: NSWindow {
    init(rect: NSRect) {
        let padding: CGFloat = 4
        let windowRect = rect.insetBy(dx: -padding, dy: -padding)
        super.init(contentRect: windowRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = false

        let borderView = BorderView(frame: NSRect(origin: .zero, size: windowRect.size), selectionSize: rect.size)
        self.contentView = borderView
    }
}

class BorderView: NSView {
    var selectionSize: NSSize

    init(frame: NSRect, selectionSize: NSSize) {
        self.selectionSize = selectionSize
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let padding: CGFloat = 4
        let innerRect = NSRect(x: padding, y: padding, width: selectionSize.width, height: selectionSize.height)

        let path = NSBezierPath(rect: innerRect)
        path.lineWidth = 2
        let pattern: [CGFloat] = [6, 4]
        path.setLineDash(pattern, count: 2, phase: 0)

        NSColor.systemPurple.withAlphaComponent(0.7).setStroke()
        path.stroke()
    }
}

