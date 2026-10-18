import RecorderCore
import SwiftUI

/// A compact direct-manipulation surface for normalized editor positions.
/// The visual pad, exact X/Y entry and reset action all share the caller's
/// single continuous interaction instead of exposing three competing paths.
struct EditorPositionPad: View {
    @GestureState private var draggedPoint: NormalizedPoint?
    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @State private var isCoordinateEditing = false

    let title: String
    var detail: String? = nil
    let point: NormalizedPoint
    let onChanged: (NormalizedPoint) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var onTextPreviewValidityChanged: (Bool) -> Void = { _ in }
    var snapsToGrid = true
    var compactLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)

                Spacer(minLength: 8)

                Button {
                    withAnimation(SpringMotion.snappy) {
                        onChanged(NormalizedPoint(x: 0.5, y: 0.5))
                        onEnded()
                    }
                } label: {
                    EditorSymbolLabel("居中", systemImage: "scope")
                        .font(.appUI(size: 10, weight: .semibold))
                }
                .buttonStyle(.editorGhost)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .controlSize(.small)
                .disabled(isCentered)
                .accessibilityLabel(String(format: appLocalized("居中%@"), appLocalized(title)))
            }

            if let detail {
                Text(appLocalized(detail))
                    .font(.appUI(size: 10))
                    .foregroundStyle(EditorTheme.chrome(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if compactLayout {
                HStack(spacing: 18) {
                    positionSurface
                    VStack(alignment: .trailing, spacing: 10) {
                        regionLabel
                        coordinateReadouts
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                positionSurface
                coordinateReadouts
            }
        }
    }

    private var coordinateReadouts: some View {
            EditorPairedParameterReadouts(
                first: EditorPairedParameterValue(
                    title: "X",
                    accessibilityTitle: String(format: appLocalized("%@ X 坐标"), appLocalized(title)),
                    value: clamp01(point.x),
                    range: 0...1,
                    displayText: EditorSliderValueFormat.percent.text(for: clamp01(point.x)),
                    inputFormat: .percent
                ),
                second: EditorPairedParameterValue(
                    title: "Y",
                    accessibilityTitle: String(format: appLocalized("%@ Y 坐标"), appLocalized(title)),
                    value: clamp01(point.y),
                    range: 0...1,
                    displayText: EditorSliderValueFormat.percent.text(for: clamp01(point.y)),
                    inputFormat: .percent
                ),
                onChanged: { x, y in
                    onChanged(NormalizedPoint(x: x, y: y))
                },
                onEnded: onEnded,
                onCancelled: onCancelled,
                onEditingChanged: { isCoordinateEditing = $0 },
                onTextPreviewValidityChanged: onTextPreviewValidityChanged,
                vertical: compactLayout
            )
    }

    private var positionSurface: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 12
            let usableWidth = max(proxy.size.width - inset * 2, 1)
            let usableHeight = max(proxy.size.height - inset * 2, 1)
            let displayedPoint = draggedPoint ?? point
            let x = inset + CGFloat(clamp01(displayedPoint.x)) * usableWidth
            let y = inset + CGFloat(clamp01(displayedPoint.y)) * usableHeight
            let isDirectlyEditing = draggedPoint != nil || isCoordinateEditing

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(insideTile ? EditorTheme.panelSurface : EditorTheme.chrome(isDirectlyEditing ? 0.065 : 0.045))
                    .animation(SpringMotion.hover, value: isDirectlyEditing)

                anchorDots(
                    inset: inset, usableWidth: usableWidth, usableHeight: usableHeight,
                    nearest: nearestAnchor(displayedPoint)
                )

                if isDirectlyEditing {
                    Path { path in
                        path.move(to: CGPoint(x: x, y: inset))
                        path.addLine(to: CGPoint(x: x, y: inset + usableHeight))
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: inset + usableWidth, y: y))
                    }
                    .stroke(
                        (palette?.stroke ?? EditorTheme.platinumAccent).opacity(0.5),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                    )
                    .allowsHitTesting(false)
                }

                // One flat ink puck. It glides to a new position and follows
                // the pointer exactly while it is being dragged.
                ZStack {
                    Circle()
                        .fill((palette?.fill ?? EditorTheme.platinumAccent).opacity(isDirectlyEditing ? 0.18 : 0))
                        .frame(width: 36, height: 36)
                    Circle()
                        .fill(palette?.fill ?? EditorTheme.platinumAccent)
                        .frame(width: 20, height: 20)
                    Circle()
                        .fill(palette?.ink ?? EditorTheme.onAccent)
                        .frame(width: 6, height: 6)
                }
                .scaleEffect(isDirectlyEditing && !RecorderMotion.reduces ? 1.1 : 1)
                .animation(SpringMotion.snappy, value: isDirectlyEditing)
                .position(x: x, y: y)
                .animation(isDirectlyEditing ? nil : SpringMotion.fluid, value: point)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($draggedPoint) { gesture, state, _ in
                        state = gesturePoint(
                            location: gesture.location,
                            size: proxy.size,
                            inset: inset
                        )
                    }
                    .onChanged { gesture in
                        onChanged(
                            gesturePoint(
                                location: gesture.location,
                                size: proxy.size,
                                inset: inset
                            )
                        )
                    }
                    .onEnded { _ in onEnded() }
            )
            .allowsHitTesting(!isCoordinateEditing)
            .accessibilityHidden(true)
        }
        .frame(width: compactLayout ? 158 : nil, height: compactLayout ? 112 : 128)
        .frame(maxWidth: compactLayout ? nil : .infinity)
    }

    /// Nine quiet dots mark where the position snaps; the nearest one wakes up.
    private func anchorDots(
        inset: CGFloat, usableWidth: CGFloat, usableHeight: CGFloat, nearest: (row: Int, column: Int)?
    ) -> some View {
        ZStack {
            ForEach(0..<9, id: \.self) { index in
                let row = index / 3
                let column = index % 3
                let awake = nearest.map { $0.row == row && $0.column == column } ?? false
                Circle()
                    .fill(EditorTheme.chrome(awake ? 0.5 : 0.22))
                    .frame(width: awake ? 7 : 4.5, height: awake ? 7 : 4.5)
                    .position(
                        x: inset + usableWidth * CGFloat(column) / 2,
                        y: inset + usableHeight * CGFloat(row) / 2
                    )
            }
        }
        .animation(SpringMotion.hover, value: nearest?.row)
        .animation(SpringMotion.hover, value: nearest?.column)
        .allowsHitTesting(false)
    }

    private func nearestAnchor(_ point: NormalizedPoint) -> (row: Int, column: Int)? {
        let steps = [0.0, 0.5, 1.0]
        guard let column = steps.firstIndex(where: { abs(point.x - $0) < 0.04 }),
              let row = steps.firstIndex(where: { abs(point.y - $0) < 0.04 }) else { return nil }
        return (row, column)
    }

    private var regionName: String {
        let names = [["左上", "上", "右上"], ["左", "居中", "右"], ["左下", "下", "右下"]]
        guard let anchor = nearestAnchor(draggedPoint ?? point) else { return "自定义" }
        return names[anchor.row][anchor.column]
    }

    private var regionLabel: some View {
        ZStack(alignment: .trailing) {
            Text(appLocalized(regionName))
                .id(regionName)
                .transition(.asymmetric(
                    insertion: .offset(y: 16).combined(with: .opacity),
                    removal: .offset(y: -16).combined(with: .opacity)
                ))
        }
        .font(.appUI(size: 22, weight: .semibold))
        .foregroundStyle(EditorTheme.primaryText)
        .frame(height: 28, alignment: .trailing)
        .clipped()
        .animation(RecorderMotion.reduces ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: regionName)
        .accessibilityHidden(true)
    }

    private var isCentered: Bool {
        abs(point.x - 0.5) < 0.000_5 && abs(point.y - 0.5) < 0.000_5
    }

    private func gesturePoint(
        location: CGPoint,
        size: CGSize,
        inset: CGFloat
    ) -> NormalizedPoint {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let normalized = NormalizedPoint(
            x: clamp01(Double((location.x - inset) / width)),
            y: clamp01(Double((location.y - inset) / height))
        )
        return snapsToGrid ? snappedToGrid(normalized) : normalized
    }

    private func snappedToGrid(_ point: NormalizedPoint) -> NormalizedPoint {
        let anchors = [0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
        func snap(_ value: Double) -> Double {
            anchors.first(where: { abs(value - $0) <= 0.035 }) ?? value
        }
        return NormalizedPoint(x: snap(point.x), y: snap(point.y))
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }
}

/// Transactional wrapper used by persistent canvas/camera style domains.
/// Animation and overlay inspectors keep their existing draft owners and use
/// `EditorPositionPad` directly.
struct EditorTransactionalPositionPad: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let point: Binding<NormalizedPoint>
    let commandScope: EditorInteractionCommandScope
    var selection: EditorSelection? = nil
    let actionName: String
    var snapsToGrid = true
    var compactLayout = false
    let onError: (String) -> Void

    var body: some View {
        EditorPositionPad(
            title: title,
            point: point.wrappedValue,
            onChanged: updatePoint,
            onEnded: commitPoint,
            onCancelled: cancelPoint,
            onTextPreviewValidityChanged: {
                updateEditorTextPreviewValidity(
                    store: editorStore, isValid: $0,
                    commandScope: commandScope, selection: selection,
                    actionName: actionName
                )
            },
            snapsToGrid: snapsToGrid,
            compactLayout: compactLayout
        )
    }

    private func updatePoint(_ updated: NormalizedPoint) {
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope,
            selection: selection
        )
        point.wrappedValue = updated
    }

    private func commitPoint() {
        updateEditorContinuousInteraction(
            store: editorStore,
            isEditing: false,
            commandScope: commandScope,
            actionName: actionName,
            onError: onError
        )
    }

    private func cancelPoint() {
        guard editorStore.interaction?.commandScope == commandScope else { return }
        if let selection, editorStore.interaction?.selection != selection { return }
        editorStore.cancelInteraction()
    }
}
