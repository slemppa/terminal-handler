import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// UI state shared by the panel and the SwiftUI view.
@Observable
final class IslandState {
    var expanded = false
    /// Opened with the hotkey: ⌘1…⌘9 and Esc are live until it closes.
    var keyboardMode = false
    /// The island's laid-out size, used for hit testing.
    var islandSize = CGSize(width: 120, height: 28)
    var menuBarHeight: CGFloat = 28
}

/// Borderless, non-activating panel pinned to the top centre of the main display.
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
    static let panelSize = CGSize(width: 520, height: 560)

    private let model: AppModel
    private let state = IslandState()
    private let panel = IslandPanel()
    private var mouseTimer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var autoCollapseAt: Date?

    init(model: AppModel) {
        self.model = model
        let host = FirstMouseHostingView(rootView: IslandView(model: model, state: state, controller: self))
        host.sizingOptions = []
        panel.contentView = host
        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
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

    private var screen: NSScreen? { NSScreen.screens.first }

    private func positionPanel() {
        guard let screen else { return }
        let frame = screen.frame
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        state.menuBarHeight = menuBar > 0 ? menuBar : 28
        let size = Self.panelSize
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The island's current rect in screen coordinates, padded for easier hover.
    private var hitRect: CGRect {
        guard let screen else { return .zero }
        let size = state.islandSize
        let pad: CGFloat = state.expanded ? 6 : 10
        return CGRect(x: screen.frame.midX - size.width / 2 - pad, y: screen.frame.maxY - size.height - pad,
                      width: size.width + pad * 2, height: size.height + pad)
    }

    // MARK: Mouse

    private func trackMouse() {
        let inside = hitRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let now = Date.now
        if inside {
            outsideSince = nil
            autoCollapseAt = nil
            if insideSince == nil { insideSince = now }
            if !state.expanded, let since = insideSince, now.timeIntervalSince(since) >= 0.15 {
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
        guard !state.expanded else { return }
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
