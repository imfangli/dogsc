import AppKit
import SwiftUI

/// Local scratch text belongs to the recorder, not the recorded project.
/// Debounce typing, then flush on hide/termination so closing never loses a draft.
@MainActor
final class RecorderMemoStore: ObservableObject {
    private enum Key {
        static let text = "recorder.memo.text"
        static let fontSize = "recorder.memo.font-size"
        static let opacity = "recorder.memo.background-opacity"
        static let hidesBlankLines = "recorder.memo.hides-blank-lines"
    }

    @Published var text: String { didSet { scheduleSave() } }
    @Published var fontSize: Double { didSet { scheduleSave() } }
    @Published var opacity: Double { didSet { scheduleSave() } }
    @Published var hidesBlankLines: Bool { didSet { scheduleSave() } }
    @Published var isEditing: Bool
    private let defaults: UserDefaults
    private var pendingSave: Task<Void, Never>?
    private var hasChanges = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedText = defaults.string(forKey: Key.text) ?? ""
        text = savedText
        let savedSize = defaults.object(forKey: Key.fontSize) as? Double ?? 22
        let savedOpacity = defaults.object(forKey: Key.opacity) as? Double ?? 0.92
        fontSize = savedSize.isFinite ? min(max(savedSize, 16), 40) : 22
        opacity = savedOpacity.isFinite ? min(max(savedOpacity, 0.55), 1) : 0.92
        hidesBlankLines = defaults.bool(forKey: Key.hidesBlankLines)
        isEditing = savedText.isEmpty
        // Retired presentation preferences must not affect the remaining memo.
        defaults.removeObject(forKey: "recorder.memo.compact")
        defaults.removeObject(forKey: "recorder.memo.compact-background-opacity")
    }

    private func scheduleSave() {
        hasChanges = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.save()
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasChanges else { return }
        hasChanges = false
        defaults.set(text, forKey: Key.text)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(opacity, forKey: Key.opacity)
        defaults.set(hidesBlankLines, forKey: Key.hidesBlankLines)
    }
}

@MainActor
final class RecorderMemoController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RecorderMemoController()
    @Published private(set) var isVisible = false
    let store = RecorderMemoStore()
    let speech = RecorderMemoSpeechController()
    private var panel: RecorderMemoPanel?
    private var screenObserver: NSObjectProtocol?
    private var shouldResumeAfterSelection = false
    private let frameKey = "recorder.memo.frame"

    func configure(model: AppModel) {
        speech.configure(model: model, store: store)
    }

    func toggle(relativeTo owner: NSWindow) {
        if isVisible { hide() } else { show(relativeTo: owner) }
    }

    private func show(relativeTo owner: NSWindow) {
        RecorderPopoverPresenter.shared.dismiss()
        let panel = panel ?? makePanel()
        let savedFrame = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString)
        let screen = savedFrame.flatMap { frame in
            NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        } ?? owner.screen ?? NSScreen.main
        guard let screen else { return }
        let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let proposed: NSRect
        if let savedFrame, savedFrame.width.isFinite, savedFrame.height.isFinite,
           savedFrame.minX.isFinite, savedFrame.minY.isFinite,
           savedFrame.width >= Self.minimumWindowSize.width,
           savedFrame.height >= Self.minimumWindowSize.height {
            proposed = savedFrame
        } else {
            let size = NSSize(width: 390, height: 420)
            let above = owner.frame.maxY + 14
            let y = above + size.height <= safe.maxY ? above : owner.frame.minY - size.height - 14
            proposed = NSRect(x: owner.frame.maxX - size.width, y: y, width: size.width, height: size.height)
        }
        fit(panel, proposed: proposed, safe: safe)
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderMemo)
        // Independent window: no child-window link, no outside-click dismissal,
        // and showing it does not activate the app or take the typing focus.
        panel.orderFrontRegardless()
        isVisible = true
        animateRecorderOverlayIn(panel)
    }

    private func makePanel() -> RecorderMemoPanel {
        let panel = RecorderMemoPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = nil
        appLocalizeWindowTitle(panel, "备忘录")
        panel.identifier = NSUserInterfaceItemIdentifier("recorder.memo.window")
        // CaptureSurfaceFilter excludes this process's helper windows, including
        // memos opened mid-recording. Other recorders may capture the memo.
        panel.sharingType = .readOnly
        panel.onClose = { [weak self] in self?.hide() }
        panel.onMoveEnded = { [weak self] in
            self?.constrainToScreen()
            self?.saveFrame()
        }
        panel.contentViewController = Self.makeContentViewController(store: store, speech: speech,
            onClose: { [weak self] in self?.hide() })
        panel.delegate = self
        self.panel = panel
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainToScreen() }
        }
        return panel
    }

    static func makeContentViewController(store: RecorderMemoStore, speech: RecorderMemoSpeechController,
                                          onClose: @escaping () -> Void) -> NSViewController {
        let host = NSHostingController(rootView:
            RecorderMemoView(store: store, speech: speech, onClose: onClose)
                .appControlFocusAppearance())
        // Window geometry belongs to the user. SwiftUI must not derive the
        // panel's minimum height from the scrollable manuscript document.
        host.sizingOptions = []
        return host
    }

    func hide() {
        shouldResumeAfterSelection = false
        speech.stop()
        guard isVisible else { return }
        store.save()
        saveFrame()
        panel?.orderOut(nil)
        isVisible = false
    }

    func suspendForSelection() {
        let wasVisible = isVisible || shouldResumeAfterSelection
        hide()
        shouldResumeAfterSelection = wasVisible
    }

    func resumeAfterSelection(relativeTo owner: NSWindow) {
        guard shouldResumeAfterSelection else { return }
        shouldResumeAfterSelection = false
        show(relativeTo: owner)
    }

    func shutdown() {
        hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel?.close()
        panel = nil
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        constrainToScreen()
        saveFrame()
    }
    func windowDidResignKey(_ notification: Notification) { store.save() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
    }

    private func constrainToScreen() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        fit(panel, proposed: panel.frame, safe: screen.visibleFrame.insetBy(dx: 12, dy: 12))
    }

    private func fit(_ panel: NSWindow, proposed: NSRect, safe: NSRect) {
        let minimum = Self.minimumWindowSize
        let maximum = Self.maximumWindowSize
        let minSize = NSSize(width: min(minimum.width, safe.width), height: min(minimum.height, safe.height))
        let maxSize = NSSize(width: min(maximum.width, safe.width), height: min(maximum.height, safe.height))
        let width = min(max(proposed.width, minSize.width), maxSize.width)
        let height = min(max(proposed.height, minSize.height), maxSize.height)
        panel.setFrame(NSRect(x: min(max(proposed.minX, safe.minX), safe.maxX - width),
            y: min(max(proposed.minY, safe.minY), safe.maxY - height), width: width, height: height), display: true)
    }

    static let minimumWindowSize = NSSize(width: 300, height: 340)
    private static let maximumWindowSize = NSSize(width: 760, height: 1000)

    fileprivate static func sizingLimits(for window: NSWindow) -> (minimum: NSSize, maximum: NSSize) {
        var minimum = minimumWindowSize
        var maximum = maximumWindowSize
        if window is RecorderMemoPanel, let screen = window.screen ?? NSScreen.main {
            let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12).size
            minimum = NSSize(width: min(minimum.width, safe.width), height: min(minimum.height, safe.height))
            maximum = NSSize(width: min(maximum.width, safe.width), height: min(maximum.height, safe.height))
        }
        return (minimum, maximum)
    }

    static func applyWindowSizing(_ window: NSWindow, proposedFrame: NSRect? = nil) {
        let frame = proposedFrame ?? window.frame
        let (minimum, maximum) = sizingLimits(for: window)
        let size = NSSize(width: min(max(frame.width, minimum.width), maximum.width),
                          height: min(max(frame.height, minimum.height), maximum.height))
        let targetFrame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        if window.frame != targetFrame {
            // Preserve the top edge when clamping a previously smaller window.
            window.setFrame(targetFrame, display: true)
        }
        if window.frame != frame {
            window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        }
    }
}

private final class RecorderMemoPanel: NSPanel {
    var onClose: (() -> Void)?
    var onMoveEnded: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func performClose(_ sender: Any?) { onClose?() }
}

struct RecorderMemoButton: View {
    var size: CGFloat = 36
    @ObservedObject private var memo = RecorderMemoController.shared
    var body: some View {
        ZStack {
            if memo.isVisible {
                Circle().fill(RecorderStyle.selection).padding(3).transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Image(systemName: memo.isVisible ? "note.text" : "note.text").font(.system(size: 14, weight: .medium))
                .foregroundStyle(memo.isVisible ? RecorderStyle.ink : RecorderStyle.muted)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            RecorderActionTrigger(action: WindowCoordinator.toggleRecorderMemo,
                accessibilityLabel: appLocalized(memo.isVisible ? "收起备忘录" : "打开备忘录"),
                accessibilityIdentifier: "recorder.memo.toggle", cornerRadius: size / 2, highlightOpacity: 0.05)
        }
        .frame(width: size, height: size)
        .animation(RecorderMotion.quick, value: memo.isVisible)
        .help("备忘录")
    }
}

/// A sheet of notes and nothing else. The few controls it needs are glyphs
/// along the top edge; the words on it are the user's.
private struct RecorderMemoView: View {
    @ObservedObject var store: RecorderMemoStore
    @ObservedObject var speech: RecorderMemoSpeechController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            speechControls
                .padding(.horizontal, 18).padding(.bottom, 10)

            ZStack(alignment: .topLeading) {
                RecorderMemoTextView(text: $store.text, fontSize: store.fontSize, isEditing: store.isEditing,
                    hidesBlankLines: store.hidesBlankLines,
                    highlightedRange: speech.highlightedRange, scrollTargetRange: speech.readingRange, followRevision: speech.followRevision,
                    selectedRange: $speech.selectedRange)
                if store.text.isEmpty {
                    Text("写下或粘贴要讲的内容…")
                        .font(.system(size: store.fontSize))
                        .foregroundStyle(RecorderStyle.faint)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            settingsControls
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 16)
        }
        .foregroundStyle(RecorderStyle.ink)
        // Only the sheet fades. Fading the entire NSWindow would also wash out text.
        .background(RecorderStyle.base.opacity(store.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [RecorderStyle.edgeTop, RecorderStyle.edgeBottom],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            // An invisible corner still resizes; nothing is drawn for it.
            Color.clear.frame(width: 18, height: 18)
                .overlay { RecorderMemoWindowHandle(resizes: true) }
        }
        .background { RecorderMemoWindowConfiguration() }
        .animation(RecorderMotion.quick, value: store.isEditing)
        .accessibilityIdentifier("recorder.memo.content")
        .onChange(of: store.isEditing) { _, isEditing in
            if isEditing { speech.stop() }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            // The empty stretch of the bar is the handle the sheet moves by.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { RecorderMemoWindowHandle(resizes: false) }
            control(store.isEditing ? "pencil" : "eye", title: store.isEditing ? "切换到阅读，避免误改文稿" : "编辑备忘录") {
                store.isEditing.toggle()
                store.save()
            }
            .accessibilityIdentifier("recorder.memo.mode")
            control("textformat.size.smaller", title: "缩小备忘录字号", enabled: store.fontSize > 16) {
                store.fontSize = max(16, store.fontSize - 2)
            }
            control("textformat.size.larger", title: "放大备忘录字号", enabled: store.fontSize < 40) {
                store.fontSize = min(40, store.fontSize + 2)
            }
            Slider(value: $store.opacity, in: 0.55...1)
                .tint(RecorderStyle.chrome.opacity(0.7)).controlSize(.mini)
                .frame(width: 58).padding(.horizontal, 8)
                .help("背景不透明度")
                .accessibilityLabel("备忘录背景不透明度")
            control("xmark", title: "收起备忘录", action: onClose)
        }
        .frame(height: 40)
        .padding(.horizontal, 6)
    }

    private var settingsControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { store.hidesBlankLines }, set: { enabled in
                store.hidesBlankLines = enabled
                if enabled { store.isEditing = false }
            })) {
                Text("隐藏空行").font(.appUI(size: 11))
            }
            .toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("recorder.memo.hide-blank-lines")
            .help("阅读时隐藏空行，编辑时显示原稿")
            Spacer(minLength: 4)
        }
    }

    private var speechControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { speech.isEnabled }, set: { enabled in
                    if enabled != speech.isEnabled { speech.toggle() }
                })) {
                    Text(appLocalized("语音跟读")).font(.appUI(size: 11, weight: .semibold))
                }
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!speech.isSupported || (store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !speech.isEnabled))
                .accessibilityIdentifier("recorder.memo.speech.toggle")
                .help(appLocalized(speech.isEnabled ? "停止语音跟读" : "开始语音跟读"))
                Spacer(minLength: 0)
                if speech.isEnabled, !store.isEditing {
                    speechButton("从选中位置跟读", action: speech.startFromSelection)
                        .disabled(speech.isPreparing)
                        .accessibilityIdentifier("recorder.memo.speech.selection")
                }
            }
            HStack(alignment: .top, spacing: 7) {
                if speech.isPreparing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(speech.statusText)
                } else {
                    Image(systemName: speech.isEnabled ? "waveform" : "lock.shield")
                        .font(.appUI(size: 10)).accessibilityHidden(true)
                }
                Text(speechStatus).font(.appUI(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recorder.memo.speech.status")
                Spacer(minLength: 0)
                if speech.needsModelDownload, !speech.isPreparing {
                    speechButton("下载普通话模型", action: speech.downloadModel)
                } else if !speech.isEnabled, !speech.statusText.isEmpty, speech.isSupported,
                          !speech.isPreparing, !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speechButton("重试语音跟读", action: speech.toggle)
                }
            }
            .foregroundStyle(RecorderStyle.muted)
        }
    }

    private func speechButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(appLocalized(title)).font(.appUI(size: 10))
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .buttonStyle(RecorderButtonStyle())
    }

    private var speechStatus: String {
        if !speech.isSupported {
            if #available(macOS 26.0, *) { return appLocalized("此设备不支持本机语音识别") }
            return appLocalized("需要 macOS 26 或更高版本")
        }
        if !speech.statusText.isEmpty { return speech.statusText }
        if store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return appLocalized("请先写下文稿") }
        return appLocalized("仅在本机识别")
    }

    private func control(_ symbol: String, title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbol.hasPrefix("textformat") ? 15 : 12, weight: .semibold))
                .foregroundStyle(RecorderStyle.muted)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(RecorderCirclePressStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title))
    }

}

/// Also used by hosted tests: window limits follow the presentation rather
/// than the size of the scrollable manuscript.
private struct RecorderMemoWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.apply() }
    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) { view.teardown() }

    final class ConfigurationView: NSView {
        private weak var constrainedContent: NSView?
        private var sizeConstraints: [NSLayoutConstraint] = []
        private var sizingObservers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityHidden(true)
            removeObservers()
            guard let window else { removeConstraints(); return }
            for (name, object) in [(NSWindow.didChangeScreenNotification, window as AnyObject?),
                                   (NSApplication.didChangeScreenParametersNotification, nil)] {
                sizingObservers.append(NotificationCenter.default.addObserver(forName: name,
                    object: object, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    })
            }
            apply()
        }
        func apply() {
            guard let window, let content = window.contentView else { return }
            let frame = window.frame
            let limits = RecorderMemoController.sizingLimits(for: window)
            if constrainedContent !== content {
                removeConstraints()
                constrainedContent = content
                // NSWindow's min/max properties are ignored under Auto Layout.
                // Native constraints keep the limits independent of manuscript
                // length and SwiftUI's ideal size calculations.
                sizeConstraints = [
                    content.widthAnchor.constraint(greaterThanOrEqualToConstant: limits.minimum.width),
                    content.heightAnchor.constraint(greaterThanOrEqualToConstant: limits.minimum.height),
                    content.widthAnchor.constraint(lessThanOrEqualToConstant: limits.maximum.width),
                    content.heightAnchor.constraint(lessThanOrEqualToConstant: limits.maximum.height)
                ]
                NSLayoutConstraint.activate(sizeConstraints)
            } else {
                let values = [limits.minimum.width, limits.minimum.height, limits.maximum.width, limits.maximum.height]
                for (constraint, value) in zip(sizeConstraints, values) where constraint.constant != value {
                    constraint.constant = value
                }
            }
            RecorderMemoController.applyWindowSizing(window, proposedFrame: frame)
        }
        private func removeConstraints() {
            NSLayoutConstraint.deactivate(sizeConstraints)
            sizeConstraints = []
            constrainedContent = nil
        }
        private func removeObservers() {
            for observer in sizingObservers { NotificationCenter.default.removeObserver(observer) }
            sizingObservers = []
        }
        func teardown() {
            removeObservers()
            removeConstraints()
        }
    }
}

private struct RecorderMemoWindowHandle: NSViewRepresentable {
    let resizes: Bool
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.resizes = resizes
    }

    final class Handle: NSView {
        var resizes = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if !resizes {
                window.performDrag(with: event)
                (window as? RecorderMemoPanel)?.onMoveEnded?()
                return
            }
            let start = NSEvent.mouseLocation
            let frame = window.frame
            let limits = RecorderMemoController.sizingLimits(for: window)
            // Native event tracking ends on mouse-up; no display link or timer.
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = NSEvent.mouseLocation
                let width = min(max(frame.width + point.x - start.x, limits.minimum.width), limits.maximum.width)
                let height = min(max(frame.height + start.y - point.y, limits.minimum.height), limits.maximum.height)
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
            }
            window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        }
    }
}
