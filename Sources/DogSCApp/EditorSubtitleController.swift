import Combine
import Foundation
import RecorderCore

/// One operation per editor. Results are committed only to the exact input
/// snapshot that produced them; edits and cancellation cannot be overwritten.
@MainActor
final class EditorSubtitleController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var startedAt: Date?
    @Published var errorMessage: String?
    @Published private(set) var needsModelDownload = false
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    static func inputIsUnchanged(_ original: RecorderProject, current: RecorderProject) -> Bool {
        original.timeline == current.timeline && original.media == current.media
            && original.audio == current.audio && original.subtitles == current.subtitles
    }

    func cancel() {
        operationID = UUID()
        task?.cancel()
        task = nil
        isBusy = false
        status = ""
        startedAt = nil
        progress = 0
    }

    func generate(store: EditorStore, media: EditorPreparedMedia, downloadModel: Bool = false) {
        guard !isBusy else { return }
        guard #available(macOS 26, *) else {
            errorMessage = appLocalized("生成字幕需要 macOS 26 或更高版本")
            return
        }
        let snapshot = store.project
        let token = begin(status: "准备识别")
        let owner = self
        let recognizer = SubtitleSpeechRecognizer()
        let request = SubtitleSpeechRequest(
            media: media.composition, project: snapshot,
            audioSource: snapshot.subtitles.audioSource,
            sourceDuration: media.plan.timelineMap.fullSourceDuration,
            script: snapshot.subtitles.script, theme: snapshot.subtitles.theme,
            downloadModel: downloadModel
        )
        task = Task { [weak self] in
            do {
                let words = try await recognizer.generate(request) { update in
                    Task { @MainActor in
                        guard owner.operationID == token else { return }
                        owner.progress = update.fraction
                        switch update.phase {
                        case .preparing: owner.status = "准备识别"
                        case .downloadingModel: owner.status = "下载识别模型"
                        case .transcribing: owner.status = "正在生成字幕"
                        }
                    }
                }
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                guard Self.inputIsUnchanged(snapshot, current: store.project) else {
                    throw SubtitleEditorError.inputChanged
                }
                var replacement = store.project
                replacement.subtitles.words = words
                replacement.subtitles.cues = SubtitleSegmentation.cues(for: words)
                replacement.subtitles.enabled = true
                replacement.subtitles.generationSignature = Self.audioSignature(for: snapshot)
                try store.replaceProject(with: replacement, actionName: "生成字幕")
                self.finish(token)
            } catch {
                guard let self, self.operationID == token else { return }
                if !Task.isCancelled {
                    self.needsModelDownload = (error as? SubtitleSpeechError) == .modelRequired
                    self.errorMessage = appErrorDescription(error)
                }
                self.finish(token)
            }
        }
    }

    func correct(store: EditorStore) {
        guard !isBusy, !store.project.subtitles.words.isEmpty else { return }
        let configuration: SubtitleAIConfiguration
        do { configuration = try SubtitleAISettings.load() }
        catch { errorMessage = appErrorDescription(error); return }
        let snapshot = store.project
        let token = begin(status: "正在校对字幕")
        let owner = self
        task = Task { [weak self] in
            do {
                let groups = try await SubtitleAIClient().correct(
                    words: snapshot.subtitles.words,
                    protectedWordIDs: Set(snapshot.subtitles.cues.filter(\.isManuallyEdited).flatMap(\.wordIDs)),
                    script: snapshot.subtitles.script,
                    theme: snapshot.subtitles.theme, configuration: configuration
                ) { fraction in
                    Task { @MainActor in
                        guard owner.operationID == token else { return }
                        owner.progress = fraction
                    }
                }
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                guard Self.inputIsUnchanged(snapshot, current: store.project) else {
                    throw SubtitleEditorError.inputChanged
                }
                var replacement = store.project
                guard !groups.isEmpty else { self.finish(token); return }
                try replacement.subtitles.applyCorrections(groups)
                try store.replaceProject(with: replacement, actionName: "AI 校对字幕")
                self.finish(token)
            } catch {
                guard let self, self.operationID == token else { return }
                if !Task.isCancelled { self.errorMessage = appErrorDescription(error) }
                self.finish(token)
            }
        }
    }

    /// Timeline cuts and playback rates are intentionally absent: source
    /// anchors follow them. Audio content/alignment changes require a new ASR.
    static func audioSignature(for project: RecorderProject) -> String {
        struct Signature: Encodable {
            let source: SubtitleAudioSource
            let screen: ProjectMediaReference?
            let microphone: ProjectMediaReference?
            let audio: AudioStyle?
            let overrides: [Override]
        }
        struct Override: Encodable {
            let id: String
            let value: PrimarySegmentAudioOverrides
        }
        let source = project.subtitles.audioSource
        let value = Signature(
            source: source, screen: project.media?.screen,
            microphone: source == .system ? nil : project.media?.microphone,
            audio: source == .finalMix ? project.audio : nil,
            overrides: source == .finalMix ? project.timeline.primarySegmentAudioOverrides
                .map { Override(id: $0.key.uuidString, value: $0.value) }
                .sorted { $0.id < $1.id } : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value).base64EncodedString()) ?? ""
    }

    private func begin(status: String) -> UUID {
        operationID = UUID()
        errorMessage = nil
        needsModelDownload = false
        isBusy = true
        startedAt = Date()
        progress = 0
        self.status = status
        return operationID
    }

    private func finish(_ token: UUID) {
        guard operationID == token else { return }
        operationID = UUID()
        isBusy = false
        startedAt = nil
        status = ""
        task = nil
    }
}

enum SubtitleEditorError: LocalizedError {
    case inputChanged
    var errorDescription: String? {
        appLocalized("处理期间项目已发生变化，请重新生成或校对字幕")
    }
}
