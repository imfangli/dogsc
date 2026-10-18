import AppKit
import SwiftUI

/// Observes only the NSWindow that hosts this editor. A resign-key event ends
/// any transient editor gesture through the store's shared lifecycle policy,
/// so no half-finished preview survives a window switch.
struct EditorWindowLifecycleBridge: NSViewRepresentable {
    let projectTitle: String
    let onResignKey: @MainActor () -> Void
    var onActivityChanged: @MainActor (Bool) -> Void = { _ in }
    var onScreenSizeChanged: @MainActor (CGSize?) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowObservationView {
        WindowObservationView(
            projectTitle: projectTitle,
            onResignKey: onResignKey,
            onActivityChanged: onActivityChanged,
            onScreenSizeChanged: onScreenSizeChanged
        )
    }

    func updateNSView(_ view: WindowObservationView, context: Context) {
        view.projectTitle = projectTitle
        view.onResignKey = onResignKey
        view.onActivityChanged = onActivityChanged
        view.onScreenSizeChanged = onScreenSizeChanged
        view.updateWindowTitle()
    }

    static func dismantleNSView(_ view: WindowObservationView, coordinator: Void) {
        view.invalidate()
    }
}

final class WindowObservationView: NSView {
    var projectTitle: String
    var onResignKey: @MainActor () -> Void
    var onActivityChanged: @MainActor (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    var onScreenSizeChanged: @MainActor (CGSize?) -> Void
    private var lastScreenSize: CGSize?
    private var lastActivity: Bool?

    init(
        projectTitle: String,
        onResignKey: @escaping @MainActor () -> Void,
        onActivityChanged: @escaping @MainActor (Bool) -> Void,
        onScreenSizeChanged: @escaping @MainActor (CGSize?) -> Void
    ) {
        self.projectTitle = projectTitle
        self.onResignKey = onResignKey
        self.onActivityChanged = onActivityChanged
        self.onScreenSizeChanged = onScreenSizeChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        updateWindowTitle()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .appLanguageDidChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowTitle() }
            })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onResignKey() }
            })
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didExposeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScreenSize() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScreenSize() }
            })
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignTrafficLights() }
            })
        }
        updateScreenSize()
        updateActivity()
        DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
    }

    override func layout() {
        super.layout()
        alignTrafficLights()
    }

    /// The editor draws its own 46 pt title bar. Grow the native title-bar
    /// strip to the same height and centre the traffic lights in it, so the
    /// window controls sit on the bar's midline like every other control.
    private func alignTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview else { return }
        let barHeight = EditorChromeMetrics.titleBarHeight
        let windowHeight = window.frame.height
        let containerFrame = NSRect(x: 0, y: windowHeight - barHeight,
                                    width: window.frame.width, height: barHeight)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebarView.frame != container.bounds { titlebarView.frame = container.bounds }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let origin = NSPoint(
                x: 16 + CGFloat(index) * 20,
                y: ((barHeight - button.frame.height) / 2).rounded()
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    private func updateScreenSize() {
        guard let size = window?.screen?.visibleFrame.size, size != lastScreenSize else { return }
        lastScreenSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastScreenSize == size else { return }
            self.onScreenSizeChanged(size)
        }
    }

    private func updateActivity() {
        let active = NSApp.isActive && !NSApp.isHidden && window?.isMiniaturized == false
            && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        guard active != lastActivity else { return }
        lastActivity = active
        // NSView attachment may occur during SwiftUI's update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastActivity == active else { return }
            self.onActivityChanged(active)
        }
    }

    func updateWindowTitle() {
        guard let window else { return }
        let trimmed = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = trimmed.isEmpty
            ? "\(AppIdentity.displayName) \(appLocalized("编辑器"))"
            : "\(trimmed) — \(AppIdentity.displayName)"
    }

    func invalidate() {
        stopObserving()
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        lastActivity = nil
        lastScreenSize = nil
    }
}

private struct EditorActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var editorIsActive: Bool {
        get { self[EditorActivityKey.self] }
        set { self[EditorActivityKey.self] = newValue }
    }
}
