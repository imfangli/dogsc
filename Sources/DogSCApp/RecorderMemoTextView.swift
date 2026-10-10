import AppKit
import SwiftUI

/// NSTextView supplies IME, plain-text paste, native undo and smooth scrolling.
/// Updating settings never replaces text or selection during marked-text input.
struct RecorderMemoTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let isEditing: Bool
    var isCompact = false
    var hidesBlankLines = false
    let highlightedRange: NSRange?
    let scrollTargetRange: NSRange?
    let followRevision: UInt64
    @Binding var selectedRange: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, selectedRange: $selectedRange) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // A scroll viewport fits the offered space, not its NSTextView's full
        // document height. Unspecified sizes are only a compact ideal size.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 180
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MemoScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = MemoTextView(frame: .zero)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isCompact = isCompact
        view.textColor = isCompact ? .white : RecorderStyle.inkNSColor
        view.insertionPointColor = view.textColor ?? RecorderStyle.inkNSColor
        view.focusRingType = .none
        view.setAccessibilityLabel(appLocalized("备忘录文稿"))
        view.string = text
        view.delegate = context.coordinator
        scroll.documentView = view
        scroll.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.cancelScrollAnimation() }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.selectedRange = $selectedRange
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.isApplyingViewUpdate = true
        defer { context.coordinator.isApplyingViewUpdate = false }
        view.isEditable = isEditing
        view.isSelectable = true
        (view as? MemoTextView)?.isCompact = isCompact
        let textColor = isCompact ? NSColor.white : RecorderStyle.inkNSColor
        if view.textColor != textColor { view.textColor = textColor }
        view.insertionPointColor = textColor
        (scroll as? MemoScrollView)?.usesTransparentScroller = isCompact
        scroll.scrollerKnobStyle = isCompact ? .light : .default
        let inset = NSSize(width: isCompact ? 8 : 14, height: isCompact ? 8 : 14)
        if view.textContainerInset != inset {
            view.textContainerInset = inset
            scroll.needsLayout = true
        }
        if view.string != text, !view.hasMarkedText() { view.string = text }
        if view.font?.pointSize != CGFloat(fontSize), !view.hasMarkedText() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.35
            paragraph.paragraphSpacing = fontSize * 0.5
            view.font = .systemFont(ofSize: fontSize)
            view.defaultParagraphStyle = paragraph
            view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: (view.string as NSString).length))
        }
        let blankLinesChanged = view.layoutManager.map {
            context.coordinator.blankLineLayout.update(text: view.string,
                isEnabled: hidesBlankLines && !isEditing, layoutManager: $0)
        } ?? false
        if blankLinesChanged {
            context.coordinator.cancelScrollAnimation()
            scroll.needsLayout = true
            scroll.layoutSubtreeIfNeeded()
        }
        context.coordinator.updateHighlight(isEditing ? nil : highlightedRange, in: view)
        if context.coordinator.followRevision != followRevision || blankLinesChanged {
            context.coordinator.followRevision = followRevision
            if !isEditing, let scrollTargetRange {
                context.coordinator.follow(scrollTargetRange, in: view, scroll: scroll)
            }
        }
        if isEditing || highlightedRange == nil { context.coordinator.cancelScrollAnimation() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelScrollAnimation()
        (scroll as? MemoScrollView)?.onUserScroll = nil
        if let view = scroll.documentView as? NSTextView {
            view.delegate = nil
            view.layoutManager?.delegate = nil
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var selectedRange: Binding<NSRange>
        let blankLineLayout = MemoBlankLineLayoutDelegate()
        var isApplyingViewUpdate = false
        var followRevision: UInt64 = 0
        private var highlightedRange: NSRange?
        private var highlightedText = ""
        private var scrollAnimation: Task<Void, Never>?

        init(text: Binding<String>, selectedRange: Binding<NSRange>) {
            self.text = text
            self.selectedRange = selectedRange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingViewUpdate, let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingViewUpdate, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            if selectedRange.wrappedValue != range { selectedRange.wrappedValue = range }
        }

        func updateHighlight(_ requestedRange: NSRange?, in view: NSTextView) {
            let range = requestedRange.flatMap { validRange($0, in: view) }
            guard range != highlightedRange || highlightedText != view.string else { return }
            let fullRange = NSRange(location: 0, length: (view.string as NSString).length)
            let previousRange = highlightedText == view.string
                ? highlightedRange.map { NSIntersectionRange($0, fullRange) } : fullRange
            if let previousRange {
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previousRange)
            }
            if let range {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor,
                    value: NSColor(RecorderStyle.mint).withAlphaComponent(0.23), forCharacterRange: range)
            }
            highlightedRange = range
            highlightedText = view.string
        }

        func follow(_ range: NSRange, in view: NSTextView, scroll: NSScrollView) {
            cancelScrollAnimation()
            guard let range = validRange(range, in: view),
                  let scroll = scroll as? MemoScrollView, !scroll.isUserScrolling,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let tail = (view.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
            let glyphs = layout.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let clip = scroll.contentView
            let start = clip.bounds.origin
            let y = min(max(line.minY + view.textContainerInset.height - clip.bounds.height / 3, 0),
                        max(view.bounds.height - clip.bounds.height, 0))
            let target = NSPoint(x: start.x, y: y)
            guard abs(target.y - start.y) > 1 else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clip.scroll(to: target)
                scroll.reflectScrolledClipView(clip)
                return
            }
            // Native wheel/scrollbar input cancels this animation immediately.
            // A later reliable speech update resumes following without altering selection.
            scrollAnimation = Task { @MainActor [weak scroll] in
                let began = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    guard let scroll, !scroll.isUserScrolling else { return }
                    let fraction = min((ProcessInfo.processInfo.systemUptime - began) / 0.3, 1)
                    let eased = 1 - pow(1 - fraction, 3)
                    scroll.contentView.scroll(to: NSPoint(x: target.x, y: start.y + (target.y - start.y) * eased))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if fraction >= 1 { return }
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
        }

        func cancelScrollAnimation() {
            scrollAnimation?.cancel()
            scrollAnimation = nil
        }

        private func validRange(_ range: NSRange, in view: NSTextView) -> NSRange? {
            let string = view.string as NSString
            let length = string.length
            guard range.location != NSNotFound, range.location >= 0, range.location < length,
                  range.length > 0, range.length <= length - range.location else { return nil }
            // Never paint half an emoji, surrogate pair, or combining sequence.
            return string.rangeOfComposedCharacterSequences(for: range)
        }
    }

    final class MemoTextView: NSTextView {
        var isCompact = false {
            didSet { if oldValue != isCompact { refreshTextColors() } }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            // Refresh glyph attributes and caret without replacing the text,
            // selection or IME marked range. Transparent prompts stay white.
            refreshTextColors()
        }

        private func refreshTextColors() {
            let color = isCompact ? NSColor.white : RecorderStyle.inkNSColor
            textColor = color
            insertionPointColor = color
            needsDisplay = true
        }
    }

    final class MemoScrollView: NSScrollView {
        var onUserScroll: (() -> Void)?
        var usesTransparentScroller = false {
            didSet {
                guard usesTransparentScroller != oldValue else { return }
                (verticalScroller as? MemoScroller)?.hidesTrack = usesTransparentScroller
                scrollerStyle = usesTransparentScroller ? .overlay : NSScroller.preferredScrollerStyle
                needsLayout = true
            }
        }
        private var isSizingDocument = false
        private var isTouchScrolling = false
        private var isMomentumScrolling = false
        private var isDraggingScroller = false
        private var userScrollUntil = 0.0

        var isUserScrolling: Bool {
            isTouchScrolling || isMomentumScrolling || isDraggingScroller || ProcessInfo.processInfo.systemUptime < userScrollUntil
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        // AppKit reapplies the system preference when input devices or the
        // "Show scroll bars" setting changes. The transparent reader keeps
        // overlay scrollers even when that preference is "Always".
        override var scrollerStyle: NSScroller.Style {
            get { super.scrollerStyle }
            set { super.scrollerStyle = usesTransparentScroller ? .overlay : newValue }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let scroller = MemoScroller()
            scroller.onTracking = { [weak self] tracking in
                self?.isDraggingScroller = tracking
                self?.userScrollUntil = ProcessInfo.processInfo.systemUptime + 0.15
                if tracking { self?.onUserScroll?() }
            }
            scroller.onTrackClick = { [weak self] in
                self?.userScrollUntil = ProcessInfo.processInfo.systemUptime + 0.15
                self?.onUserScroll?()
            }
            verticalScroller = scroller
        }

        required init?(coder: NSCoder) { super.init(coder: coder) }

        override func scrollWheel(with event: NSEvent) {
            onUserScroll?()
            if event.phase.isEmpty, event.momentumPhase.isEmpty {
                isTouchScrolling = false
                isMomentumScrolling = false
            }
            if event.phase.contains(.began) || event.phase.contains(.changed) || event.phase.contains(.mayBegin) {
                isTouchScrolling = true
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                isTouchScrolling = false
            }
            if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
                isMomentumScrolling = true
            } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                isMomentumScrolling = false
            }
            userScrollUntil = ProcessInfo.processInfo.systemUptime + 0.15
            super.scrollWheel(with: event)
        }

        override func layout() {
            super.layout()
            guard !isSizingDocument, let view = documentView as? NSTextView else { return }
            isSizingDocument = true
            defer { isSizingDocument = false }
            let viewport = contentSize
            view.minSize = NSSize(width: 0, height: viewport.height)
            if view.frame.width != viewport.width {
                view.setFrameSize(NSSize(width: viewport.width, height: max(view.frame.height, viewport.height)))
            }
            if let layout = view.layoutManager, let container = view.textContainer {
                layout.ensureLayout(for: container)
                let documentHeight = ceil(layout.usedRect(for: container).maxY + view.textContainerInset.height * 2)
                let height = max(documentHeight, viewport.height)
                if abs(view.frame.height - height) > 0.5 {
                    view.setFrameSize(NSSize(width: viewport.width, height: height))
                }
            }
        }
    }

    final class MemoScroller: NSScroller {
        var onTracking: ((Bool) -> Void)?
        var onTrackClick: (() -> Void)?
        var hidesTrack = false {
            didSet { if hidesTrack != oldValue { needsDisplay = true } }
        }

        // Custom scrollers otherwise force AppKit to use an opaque legacy
        // track. Keep native overlay drawing and parts-based knob tracking.
        override class var isCompatibleWithOverlayScrollers: Bool { true }

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
            if !hidesTrack { super.drawKnobSlot(in: slotRect, highlight: flag) }
        }

        override func testPart(_ point: NSPoint) -> NSScroller.Part {
            let part = super.testPart(point)
            if part != .noPart, NSApp.currentEvent?.type == .leftMouseDown {
                onTrackClick?()
            }
            return part
        }

        override func trackKnob(with event: NSEvent) {
            onTracking?(true)
            defer { onTracking?(false) }
            super.trackKnob(with: event)
        }
    }
}
