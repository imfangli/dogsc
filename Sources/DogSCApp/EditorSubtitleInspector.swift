import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorSubtitleInspector: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    @ObservedObject var controller: EditorSubtitleController
    @State private var showsAISettings = false
    @State private var scriptDraft = ""
    @State private var themeDraft = ""
    @State private var selectedID: UUID?
    @State private var selectedFragmentID: String?
    @State private var resolvedRows: [ResolvedSubtitleCue] = []
    @State private var textDraft = ""
    @State private var startDraft = ""
    @State private var endDraft = ""
    @State private var splitBoundary: Double?
    @State private var firstSplitText = ""
    @State private var secondSplitText = ""
    @State private var styleInteractionID: UUID?
    @FocusState private var referenceFocus: ReferenceField?
    private enum ReferenceField { case script, theme }

    private var document: SubtitleDocument { editorStore.previewProject.subtitles }
    private var sourceDuration: Double { mediaSession.mediaPlan?.timelineMap.fullSourceDuration ?? 0 }
    private var resolved: [ResolvedSubtitleCue] { resolvedRows }
    private var selectedRow: ResolvedSubtitleCue? { resolved.first { $0.id == selectedFragmentID } }
    private var selectedCue: SubtitleCue? { document.cues.first { $0.id == selectedID } }
    private var canGenerate: Bool {
        guard #available(macOS 26, *), case .ready = mediaSession.state else { return false }
        switch document.audioSource {
        case .microphone: return mediaSession.inventories.microphone.hasAudio
        case .system: return mediaSession.inventories.source.hasAudio
        case .finalMix: return mediaSession.inventories.microphone.hasAudio || mediaSession.inventories.source.hasAudio
        }
    }
    private var hasCorrectableWords: Bool {
        let protected = Set(document.cues.filter(\.isManuallyEdited).flatMap(\.wordIDs))
        return document.words.contains { !protected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            generationSection
            if controller.isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(appLocalized(controller.status)).font(.appUI(.caption))
                        Spacer()
                        Button(appLocalized("取消")) { controller.cancel() }.buttonStyle(.editorQuiet)
                    }
                    ProgressView(value: controller.progress, total: 1).tint(EditorTheme.selectionTint)
                }
                .accessibilityIdentifier("editor.subtitles.progress")
            }
            if let message = controller.errorMessage {
                Text(message).font(.appUI(.caption)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("editor.subtitles.error")
            }
            referenceSection.disabled(controller.isBusy)
            if !document.words.isEmpty {
                styleSection.disabled(controller.isBusy)
                if document.generationSignature != nil,
                   document.generationSignature != EditorSubtitleController.audioSignature(for: editorStore.project) {
                    Text(appLocalized("声音来源或对齐已改变，建议重新生成字幕"))
                        .font(.appUI(.caption)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if selectedCue != nil { editingSection.disabled(controller.isBusy) }
                subtitleList.disabled(controller.isBusy)
            }
        }
        .sheet(isPresented: $showsAISettings) { SubtitleAISettingsSheet() }
        .onAppear { syncReferences(); refreshRows() }
        .onChange(of: referenceFocus) { old, new in
            if old != nil, old != new { commitReferences() }
        }
        .onChange(of: editorStore.project.subtitles.script) { _, _ in
            if referenceFocus != .script { scriptDraft = document.script }
        }
        .onChange(of: editorStore.project.subtitles.theme) { _, _ in
            if referenceFocus != .theme { themeDraft = document.theme }
        }
        .onChange(of: editorStore.project.subtitles.cues) { _, _ in
            refreshRows()
            if let row = selectedRow ?? resolved.first(where: { $0.cueID == selectedID }) {
                select(row, seek: false)
            } else { clearSelection() }
        }
        .onChange(of: editorStore.project.subtitles.words) { _, _ in refreshRows() }
        .onChange(of: editorStore.project.timeline.sourceSequence) { _, _ in refreshRows(); clearSelection() }
        .onChange(of: sourceDuration) { _, _ in refreshRows(); clearSelection() }
        .onDisappear { styleEditingChanged(false); commitReferences() }
        .accessibilityIdentifier("editor.subtitles.inspector")
    }

    private var generationSection: some View {
        EditorInspectorSection("生成与校对") {
            Picker(appLocalized("声音来源"), selection: Binding(
                get: { document.audioSource },
                set: { value in edit("选择字幕声音来源") { $0.audioSource = value } }
            )) {
                Text(appLocalized("麦克风口播")).tag(SubtitleAudioSource.microphone)
                Text(appLocalized("系统声音")).tag(SubtitleAudioSource.system)
                Text(appLocalized("成片混音")).tag(SubtitleAudioSource.finalMix)
            }
            .disabled(controller.isBusy)
            .accessibilityIdentifier("editor.subtitles.source")
            HStack(spacing: 8) {
                Button(appLocalized(document.words.isEmpty ? "生成字幕" : "重新生成")) { generate() }
                    .buttonStyle(.editorPrimary)
                    .disabled(!canGenerate || controller.isBusy)
                    .accessibilityIdentifier("editor.subtitles.generate")
                Button(appLocalized("AI 校对")) {
                    styleEditingChanged(false)
                    commitReferences()
                    controller.correct(store: editorStore)
                }
                .buttonStyle(.editorQuiet)
                .disabled(!hasCorrectableWords || controller.isBusy)
                .accessibilityIdentifier("editor.subtitles.correct")
                Spacer(minLength: 0)
                Button { showsAISettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.editorQuiet)
                    .help(appLocalized("配置 AI 接口"))
                    .accessibilityLabel(appLocalized("配置 AI 接口"))
            }
            if controller.needsModelDownload {
                Button(appLocalized("下载普通话模型并生成")) { generate(downloadModel: true) }
                    .buttonStyle(.editorQuiet).disabled(controller.isBusy)
            }
            if #unavailable(macOS 26) {
                hint("生成字幕需要 macOS 26 或更高版本")
            } else if !canGenerate {
                hint("所选声音来源没有可识别的音轨")
            }
            if !document.words.isEmpty {
                hint("重新生成会替换现有字幕；AI 校对保留手工修改。所有修改均可撤销")
                Button(appLocalized("导出 SRT"), systemImage: "square.and.arrow.up") { exportSRT() }
                    .buttonStyle(.editorQuiet).disabled(resolved.isEmpty || controller.isBusy)
                    .accessibilityIdentifier("editor.subtitles.export-srt")
            }
        }
    }

    private var referenceSection: some View {
        EditorDisclosure("校对参考", detail: "可选") {
            TextField(appLocalized("视频主题"), text: $themeDraft).textFieldStyle(.roundedBorder)
                .focused($referenceFocus, equals: .theme)
            Text(appLocalized("口播稿")).font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
            TextEditor(text: $scriptDraft)
                .font(.appUI(size: 12)).scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 140).padding(8)
                .background(EditorTheme.chrome(0.035), in: RoundedRectangle(cornerRadius: 8))
                .focused($referenceFocus, equals: .script)
                .accessibilityLabel(appLocalized("口播稿"))
            hint("稿件和主题仅辅助纠错，字幕以实际口播为准")
        }
    }

    private var styleSection: some View {
        EditorDisclosure("字幕样式", detail: "全片") {
            EditorToggle(isOn: Binding(get: { document.enabled }, set: { value in
                edit("切换字幕显示") { $0.enabled = value }
            }), title: "显示并烧录字幕")
            EditorHexColorInput(title: "字幕颜色", value: document.style.textColor,
                onEditingChanged: styleEditingChanged) { color in previewStyle { $0.textColor = color } }
            EditorHexColorInput(title: "字幕底板颜色", value: document.style.backgroundColor,
                onEditingChanged: styleEditingChanged) { color in previewStyle { $0.backgroundColor = color } }
            styleSlider("字幕字号", value: \.fontSize, range: 18...96, percent: false)
            styleSlider("底板不透明度", value: \.backgroundOpacity, range: 0...1, percent: true)
            styleSlider("底部距离", value: \.bottomInset, range: 0...0.4, percent: true)
        }
    }

    private func styleSlider(_ title: String, value keyPath: WritableKeyPath<SubtitleStyle, Double>,
                             range: ClosedRange<Double>, percent: Bool) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(appLocalized(title)).font(.appUI(.caption))
                Spacer()
                Text(String(format: percent ? "%.0f%%" : "%.0f", document.style[keyPath: keyPath] * (percent ? 100 : 1)))
                    .font(.appUI(size: 11, design: .monospaced)).foregroundStyle(EditorTheme.secondaryText)
            }
            Slider(value: Binding(get: { document.style[keyPath: keyPath] },
                                  set: { new in previewStyle { $0[keyPath: keyPath] = new } }),
                   in: range, onEditingChanged: styleEditingChanged)
                .accessibilityLabel(appLocalized(title))
        }
    }

    private var editingSection: some View {
        EditorInspectorSection("编辑字幕") {
            TextEditor(text: $textDraft).font(.appUI(size: 14)).scrollContentBackground(.hidden)
                .frame(height: 82).padding(8)
                .background(EditorTheme.chrome(0.035), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(appLocalized("字幕文字"))
            HStack(spacing: 8) {
                timeField("开始", text: $startDraft)
                timeField("结束", text: $endDraft)
                Button(appLocalized("应用")) { applyDraft() }.buttonStyle(.editorPrimary)
            }
            HStack {
                Button(appLocalized("拆分")) { prepareSplit() }
                    .disabled(selectedCue == nil)
                Button(appLocalized("与下一条合并")) { mergeNext() }.disabled(nextRow == nil)
                Spacer()
                Button { editSelected("删除字幕") { document, id in try document.updateCueText(id: id, text: "") } }
                    label: { Image(systemName: "trash") }
                    .accessibilityLabel(appLocalized("删除字幕"))
            }
            .buttonStyle(.editorQuiet)
            if let boundary = splitBoundary, selectedCue != nil {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(appLocalized("分界时间"), value: Binding(
                        get: { boundary }, set: { splitBoundary = $0 }
                    ), format: .number.precision(.fractionLength(3))).textFieldStyle(.roundedBorder)
                    TextField(appLocalized("前一条"), text: $firstSplitText, axis: .vertical).textFieldStyle(.roundedBorder)
                    TextField(appLocalized("后一条"), text: $secondSplitText, axis: .vertical).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(appLocalized("取消")) { splitBoundary = nil }
                        Button(appLocalized("确认拆分")) {
                            let didSplit = editSelected("拆分字幕") { document, id in try document.splitCue(id: id, atOutputTime: boundary,
                                firstText: firstSplitText, secondText: secondSplitText,
                                timeline: editorStore.project.timeline, sourceDuration: sourceDuration) }
                            if didSplit { splitBoundary = nil }
                        }
                    }.buttonStyle(.editorQuiet)
                }
            }
        }
    }

    private var subtitleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appLocalized("字幕列表")).font(EditorTypography.panelTitle)
                Spacer()
                Text("\(resolved.count)").font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
            }
            LazyVStack(spacing: 5) {
                ForEach(resolved) { row in
                    Button { select(row) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(String(format: "%.2f – %.2f", row.startTime, row.endTime))
                                    .font(.appUI(size: 10, design: .monospaced))
                                    .foregroundStyle(EditorTheme.secondaryText)
                                Spacer()
                                if row.requiresReview {
                                    Text(appLocalized("待复核")).font(.appUI(size: 10)).foregroundStyle(.orange)
                                }
                            }
                            Text(row.text).font(.appUI(size: 12)).foregroundStyle(EditorTheme.primaryText)
                                .lineLimit(3).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selectedFragmentID == row.id ? EditorTheme.selectionWash : EditorTheme.chrome(0.035),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(row.startTime), \(row.text)")
                }
            }
        }
    }

    private func hint(_ key: String) -> some View {
        Text(appLocalized(key)).font(.appUI(.caption2)).foregroundStyle(EditorTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func timeField(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appLocalized(key)).font(.appUI(.caption2)).foregroundStyle(EditorTheme.secondaryText)
            TextField("0.000", text: text).textFieldStyle(.roundedBorder)
                .font(.appUI(size: 11, design: .monospaced)).accessibilityLabel(appLocalized(key))
        }
    }
    private func syncReferences() { scriptDraft = document.script; themeDraft = document.theme }
    private func refreshRows() {
        resolvedRows = (try? document.resolvedCues(timeline: editorStore.project.timeline, sourceDuration: sourceDuration)) ?? []
    }
    private func clearSelection() { selectedID = nil; selectedFragmentID = nil; splitBoundary = nil }
    private func commitReferences() {
        guard !controller.isBusy, scriptDraft != document.script || themeDraft != document.theme else { return }
        edit("修改字幕校对参考") { $0.script = scriptDraft; $0.theme = themeDraft }
    }
    private func generate(downloadModel: Bool = false) {
        styleEditingChanged(false)
        commitReferences()
        guard let media = mediaSession.prepared else { return }
        controller.generate(store: editorStore, media: media, downloadModel: downloadModel)
    }
    @discardableResult
    private func edit(_ name: String, _ update: (inout SubtitleDocument) throws -> Void) -> Bool {
        do {
            var project = editorStore.project
            try update(&project.subtitles)
            try editorStore.replaceProject(with: project, actionName: name)
            return true
        } catch {
            controller.errorMessage = appErrorDescription(error)
            return false
        }
    }
    private func styleEditingChanged(_ editing: Bool) {
        if editing {
            editorStore.beginContinuousInteraction(commandScope: .project, commitsWhenReplacedAs: "调整字幕样式")
            styleInteractionID = editorStore.interaction?.id
        } else {
            guard let id = styleInteractionID, id == editorStore.interaction?.id else {
                styleInteractionID = nil
                return
            }
            do { _ = try editorStore.commitInteraction(actionName: "调整字幕样式") }
            catch { controller.errorMessage = appErrorDescription(error) }
            styleInteractionID = nil
        }
    }
    private func previewStyle(_ update: (inout SubtitleStyle) -> Void) {
        editorStore.beginContinuousInteraction(commandScope: .project, commitsWhenReplacedAs: "调整字幕样式")
        styleInteractionID = editorStore.interaction?.id
        editorStore.updateInteraction { update(&$0.subtitles.style) }
    }
    private func select(_ row: ResolvedSubtitleCue, seek: Bool = true) {
        selectedID = row.cueID
        selectedFragmentID = row.id
        textDraft = row.text
        startDraft = String(format: "%.3f", row.startTime)
        endDraft = String(format: "%.3f", row.endTime)
        splitBoundary = nil
        if seek { playbackController.seek(to: row.startTime) }
    }
    private func applyDraft() {
        guard selectedID != nil, let start = Double(startDraft), let end = Double(endDraft) else {
            controller.errorMessage = appLocalized("请输入有效的字幕起止时间")
            return
        }
        guard let row = selectedRow else { return }
        editSelected("编辑字幕") { document, id in
            try document.updateCueText(id: id, text: textDraft)
            if abs(start - row.startTime) > 0.0005 || abs(end - row.endTime) > 0.0005 {
                try document.updateCueTiming(id: id,
                    outputTimeRange: SubtitleTimeRange(start: start, end: end),
                    timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            }
        }
    }
    private var nextRow: ResolvedSubtitleCue? {
        guard let index = resolved.firstIndex(where: { $0.id == selectedFragmentID }),
              resolved.indices.contains(index + 1) else { return nil }
        return resolved[index + 1]
    }
    private func mergeNext() {
        guard let row = selectedRow, let next = nextRow else { return }
        var target = row.cueID
        let didMerge = edit("合并字幕") { document in
            target = try document.materializeResolvedCue(id: row.id, timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            let refreshed = try document.resolvedCues(timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            guard let freshNext = refreshed.first(where: {
                abs($0.startTime - next.startTime) < 0.00001 && abs($0.endTime - next.endTime) < 0.00001
            }) else { throw SubtitleEditingError.nonAdjacentCues }
            let nextID = try document.materializeResolvedCue(id: freshNext.id, timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            let order = try document.resolvedCues(timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            let starts = Dictionary(order.map { ($0.cueID, $0.startTime) }, uniquingKeysWith: min)
            document.cues.sort { (starts[$0.id] ?? .infinity) < (starts[$1.id] ?? .infinity) }
            try document.mergeCues(firstID: target, secondID: nextID)
        }
        guard didMerge else { return }
        refreshRows()
        if let row = resolved.first(where: { $0.cueID == target }) { select(row, seek: false) }
    }
    @discardableResult
    private func editSelected(_ name: String, _ update: (inout SubtitleDocument, UUID) throws -> Void) -> Bool {
        guard let row = selectedRow else { return false }
        var target = row.cueID
        let didEdit = edit(name) { document in
            if row.requiresReview || resolved.filter({ $0.cueID == row.cueID }).count > 1 {
                target = try document.materializeResolvedCue(id: row.id, timeline: editorStore.project.timeline, sourceDuration: sourceDuration)
            }
            try update(&document, target)
        }
        guard didEdit else { return false }
        refreshRows()
        if let row = resolved.first(where: { $0.cueID == target }) { select(row, seek: false) }
        else { clearSelection() }
        return true
    }
    private func prepareSplit() {
        guard selectedCue != nil, let row = selectedRow else { return }
        let playhead = playbackController.outputTime
        let boundary = playhead > row.startTime && playhead < row.endTime
            ? playhead : (row.startTime + row.endTime) / 2
        splitBoundary = boundary
        let characters = Array(textDraft)
        let fraction = (boundary - row.startTime) / max(row.endTime - row.startTime, 0.001)
        let textBoundary = min(max(Int(Double(characters.count) * fraction), 1), characters.count)
        firstSplitText = String(characters[..<textBoundary])
        secondSplitText = String(characters[textBoundary...])
    }
    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(editorStore.project.title).srt"
        panel.title = appLocalized("导出 SRT")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SubtitleSRTExporter.export(resolved).write(to: url, atomically: true, encoding: .utf8) }
        catch { controller.errorMessage = appErrorDescription(error) }
    }
}
