import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// UI state shared by the panel and the SwiftUI view.
@Observable
final class IslandState {
    static let pillHeight: CGFloat = 30

    var expanded = false
    /// Opened with the hotkey: ⌘1…⌘9 and Esc are live until it closes.
    var keyboardMode = false
    /// The list opens downwards in the top half of the screen, upwards in the bottom half.
    var opensDownward = true
    var dragging = false
    /// The island's frame inside the panel (top-left origin), used for hit testing.
    var islandFrame = CGRect.zero
}

/// Borderless, non-activating panel that floats above every app and Space.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandController {
    static let panelSize = CGSize(width: 440, height: 600)
    /// Half the expanded width plus a margin, so the open list stays on screen.
    private static let edgeInset: CGFloat = 214
    private static let anchorKey = "islandAnchor"

    private let model: AppModel
    private let state = IslandState()
    private let panel = IslandPanel()
    private var mouseTimer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var autoCollapseAt: Date?
    /// Centre of the pill in screen coordinates.
    private var anchor: CGPoint
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?

    init(model: AppModel) {
        self.model = model
        anchor = Self.savedAnchor() ?? Self.defaultAnchor()
        let host = FirstMouseHostingView(rootView: IslandView(model: model, state: state, controller: self))
        host.sizingOptions = []
        panel.contentView = host
        placePanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.anchor = self.clamped(self.anchor)
                self.placePanel()
            }
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        let toggle = HotkeyDefaults.toggle
        HotkeyCenter.shared.register(id: 1, keyCode: toggle.keyCode, modifiers: toggle.modifiers) { [weak self] in
            self?.toggleFromKeyboard()
        }
    }

    // MARK: Placement

    private static func defaultAnchor() -> CGPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - edgeInset - 20, y: visible.maxY - IslandState.pillHeight / 2 - 12)
    }

    private static func savedAnchor() -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: anchorKey) as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens.first
    }

    /// Keeps the pill fully visible and far enough from the sides for the open list.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let visible = screen(containing: point)?.visibleFrame else { return point }
        let half = IslandState.pillHeight / 2
        let inset = min(Self.edgeInset, visible.width / 2)
        return CGPoint(x: min(max(point.x, visible.minX + inset), visible.maxX - inset),
                       y: min(max(point.y, visible.minY + half + 4), visible.maxY - half - 4))
    }

    /// Positions the panel so the pill sits on `anchor` and the list has room to open.
    private func placePanel() {
        let size = Self.panelSize
        if let screen = screen(containing: anchor) {
            state.opensDownward = anchor.y > screen.visibleFrame.midY
        }
        let half = IslandState.pillHeight / 2
        let pad: CGFloat = 12 // IslandView's vertical padding, room for the shadow
        let y = state.opensDownward ? anchor.y + half + pad - size.height : anchor.y - half - pad
        panel.setFrame(CGRect(x: anchor.x - size.width / 2, y: y, width: size.width, height: size.height), display: true)
    }

    /// The island's rect in screen coordinates, padded for easier hover.
    private var hitRect: CGRect {
        let f = state.islandFrame
        let rect = CGRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
        return rect.insetBy(dx: state.expanded ? -6 : -8, dy: state.expanded ? -6 : -8)
    }

    // MARK: Dragging

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, anchor)
            state.dragging = true
            setExpanded(false)
        }
        guard let start = dragStart else { return }
        anchor = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        placePanel()
    }

    func dragEnded() {
        dragStart = nil
        state.dragging = false
        anchor = clamped(anchor)
        placePanel()
        UserDefaults.standard.set([anchor.x, anchor.y], forKey: Self.anchorKey)
        insideSince = nil
    }

    // MARK: Mouse

    private func trackMouse() {
        guard !state.dragging else { return }
        let inside = hitRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let now = Date.now
        if inside {
            outsideSince = nil
            autoCollapseAt = nil
            if insideSince == nil { insideSince = now }
            // A held mouse button means a drag may be starting: don't open under it.
            if !state.expanded, NSEvent.pressedMouseButtons == 0, let since = insideSince, now.timeIntervalSince(since) >= 0.25 {
                setExpanded(true)
            }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            guard state.expanded, !state.keyboardMode else { return }
            if let deadline = autoCollapseAt {
                if now >= deadline { setExpanded(false) }
            } else if let since = outsideSince, now.timeIntervalSince(since) >= 0.3 {
                setExpanded(false)
            }
        }
    }

    // MARK: Expansion

    /// A new question: pop open for a while unless Sami is already in it.
    func questionArrived() {
        guard !state.expanded, !state.dragging else { return }
        setExpanded(true)
        autoCollapseAt = Date.now.addingTimeInterval(6)
    }

    func collapse() { setExpanded(false) }

    private func toggleFromKeyboard() {
        if state.expanded && state.keyboardMode {
            setExpanded(false)
        } else {
            setExpanded(true)
            setKeyboardMode(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        if !expanded {
            autoCollapseAt = nil
            setKeyboardMode(false)
        }
    }

    private func setKeyboardMode(_ on: Bool) {
        guard state.keyboardMode != on else { return }
        state.keyboardMode = on
        let center = HotkeyCenter.shared
        if on {
            center.register(id: 2, keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.collapse() }
            for (index, code) in HotkeyDefaults.digitKeyCodes.enumerated() {
                center.register(id: UInt32(10 + index), keyCode: UInt32(code), modifiers: UInt32(cmdKey)) { [weak self] in
                    self?.jump(toRowAt: index)
                }
            }
        } else {
            center.unregister(id: 2)
            for index in HotkeyDefaults.digitKeyCodes.indices { center.unregister(id: UInt32(10 + index)) }
        }
    }

    // MARK: Actions

    func jump(toRowAt index: Int) {
        guard model.rows.indices.contains(index) else { return }
        model.jump(to: model.rows[index].id)
        collapse()
    }

    func jump(to rowID: String) {
        model.jump(to: rowID)
        collapse()
    }
}
