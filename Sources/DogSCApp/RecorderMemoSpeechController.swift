import AVFoundation
import Combine
import Foundation
import RecorderCore

/// UI state stays on MainActor; model preparation, audio conversion and script
/// matching run independently of both the UI and the recording writer.
@MainActor
final class RecorderMemoSpeechController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusText = ""
    @Published private(set) var highlightedRange: NSRange?
    @Published private(set) var readingRange: NSRange?
    @Published private(set) var followRevision: UInt64 = 0
    @Published private(set) var needsModelDownload = false
    @Published private(set) var isPreparing = false
    @Published var selectedRange = NSRange(location: 0, length: 0)

    var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    private weak var model: AppModel?
    private weak var store: RecorderMemoStore?
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var recognitionSession: (any MemoSpeechSession)?
    private var epoch = UUID()

    func configure(model: AppModel, store: RecorderMemoStore) {
        guard self.model !== model || self.store !== store else { return }
        stop()
        subscriptions.removeAll()
        self.model = model
        self.store = store
        store.$text.dropFirst().sink { [weak self] _ in
            self?.stop()
            self?.highlightedRange = nil
            self?.readingRange = nil
            self?.selectedRange = NSRange(location: 0, length: 0)
        }.store(in: &subscriptions)
        store.$isEditing.dropFirst().sink { [weak self] editing in
            if editing { self?.stop() }
        }.store(in: &subscriptions)
    }

    func toggle() {
        if isEnabled || isPreparing { stop() } else { start(download: false) }
    }

    func downloadModel() { start(download: true) }

    func startFromSelection() {
        guard let store, !store.isEditing, !store.text.isEmpty else { return }
        let offset = min(max(selectedRange.location, 0), (store.text as NSString).length)
        start(download: false, anchor: offset)
    }

    func stop() {
        epoch = UUID()
        let oldTask = task
        oldTask?.cancel()
        task = nil
        let oldSession = recognitionSession
        recognitionSession = nil
        let previousCleanup = cleanupTask
        cleanupTask = Task {
            await previousCleanup?.value
            await oldSession?.cancel()
            await oldTask?.value
        }
        isEnabled = false
        isPreparing = false
        needsModelDownload = false
        statusText = ""
    }

    private func start(download: Bool, anchor: Int? = nil) {
        stop()
        let previousCleanup = cleanupTask
        guard isSupported else {
            statusText = appLocalized("需要 macOS 26 或更高版本")
            return
        }
        guard let model, let store, !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = appLocalized("请先写下文稿")
            return
        }
        guard model.phase == .setup || model.phase == .preparing || model.phase == .recording else { return }
        store.isEditing = false
        let text = store.text
        let sessionID = epoch
        let anchor = anchor ?? highlightedRange?.location
        isEnabled = true
        isPreparing = true
        statusText = appLocalized(download ? "正在下载普通话模型…" : "准备中…")
        let selectedDevice = model.configuration.microphoneDeviceID
            ?? UserDefaults.standard.string(forKey: CaptureDevicePreferenceKey.microphoneID)
        let deviceID = model.availableMicrophones.contains(where: { $0.id == selectedDevice }) ? selectedDevice : nil
        let recorder = model.microphoneRecorder
        task = Task { @MainActor [weak self] in
            guard #available(macOS 26, *) else { return }
            // Finish the previous session's cancellation before reserving the
            // same model or acquiring a new microphone consumer.
            await previousCleanup?.value
            let recognizer = MemoSpeechRecognizer()
            guard let self, self.epoch == sessionID else { return }
            self.recognitionSession = recognizer
            do {
                let matcher = await Task.detached(priority: .userInitiated) {
                    MemoScriptMatcher(text: text, anchor: anchor)
                }.value
                try Task.checkCancellation()
                try await recognizer.prepare(script: text, downloadModel: download) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.epoch == sessionID else { return }
                        self.statusText = appLocalized("正在下载普通话模型…") + " \(Int(fraction * 100))%"
                    }
                }
                try Task.checkCancellation()
                guard self.epoch == sessionID else { throw CancellationError() }
                // This requests microphone access only after the local model
                // is ready. It never enables a project microphone track.
                let lease = try await recorder.acquireLiveAudio(deviceUniqueID: deviceID)
                if Task.isCancelled || self.epoch != sessionID {
                    await lease.release()
                    throw CancellationError()
                }
                let results: AsyncThrowingStream<MemoSpeechText, any Error>
                do {
                    results = try await recognizer.start(lease: lease)
                } catch {
                    await lease.release()
                    throw error
                }
                try Task.checkCancellation()
                guard self.epoch == sessionID else { throw CancellationError() }
                self.isPreparing = false
                self.statusText = appLocalized("正在聆听")
                let matches = await matcher.matches(from: results)
                for try await match in matches {
                    try Task.checkCancellation()
                    guard self.epoch == sessionID else { throw CancellationError() }
                    if match.isTracking, let range = match.sentenceRange {
                        self.highlightedRange = range
                        self.readingRange = match.matchedRange
                        // Advance even within one sentence so a manual scroll
                        // returns to the spoken passage on the next match.
                        self.followRevision &+= 1
                        self.statusText = appLocalized("正在聆听")
                    } else {
                        self.statusText = appLocalized("定位中…")
                    }
                }
                if self.epoch == sessionID, !Task.isCancelled { throw MemoSpeechError.audioEnded }
            } catch is CancellationError {
                // Hidden/replaced windows own their new state already.
            } catch MemoSpeechError.modelRequired {
                if self.epoch == sessionID {
                    self.isEnabled = false
                    self.isPreparing = false
                    self.needsModelDownload = true
                    self.statusText = appLocalized("下载普通话模型")
                }
            } catch {
                if self.epoch == sessionID {
                    self.isEnabled = false
                    self.isPreparing = false
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied
                        || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
                        self.statusText = appLocalized("请允许麦克风访问以使用语音跟读")
                    } else {
                        self.statusText = appErrorDescription(error)
                    }
                }
            }
            await recognizer.cancel()
            if self.epoch == sessionID {
                self.recognitionSession = nil
                self.task = nil
            }
        }
    }
}
