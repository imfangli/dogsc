import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import Speech

struct MemoSpeechText: Sendable {
    let text: String
    let isFinal: Bool
    let revision: UInt64
    let timestamp: TimeInterval
}

protocol MemoSpeechSession: Sendable {
    func cancel() async
}

enum MemoSpeechError: LocalizedError {
    case unsupported, localeUnavailable, modelRequired, invalidAudio, formatChanged, audioEnded, overloaded
    var errorDescription: String? {
        switch self {
        case .unsupported: appLocalized("此设备不支持本机语音识别")
        case .localeUnavailable: appLocalized("普通话模型不可用")
        case .modelRequired: appLocalized("下载普通话模型")
        case .invalidAudio: appLocalized("无法读取麦克风音频格式")
        case .formatChanged: appLocalized("麦克风连接已改变，请重新开启语音跟读")
        case .audioEnded: appLocalized("语音跟读已暂停，请重试")
        case .overloaded: appLocalized("语音跟读处理较慢，请重试")
        }
    }
}

/// Owns the new on-device Speech objects. The old SFSpeechRecognizer and its
/// cloud authorization path are intentionally not part of this session.
@available(macOS 26, *)
actor MemoSpeechRecognizer: MemoSpeechSession {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultContinuation: AsyncThrowingStream<MemoSpeechText, any Error>.Continuation?
    private var audioTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var lease: MicrophoneAudioLease?
    private var converter: AVAudioConverter?
    private var naturalFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var audioTimeline = MemoSpeechAudioTimeline()
    private var transcript = SpeechTranscriptWindow()
    private var revision: UInt64 = 0
    private var cancelled = false
    private var reservedLocale: Locale?
    private var cleanupTask: Task<Void, Never>?

    func prepare(
        script: String, downloadModel: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw MemoSpeechError.unsupported }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
        else { throw MemoSpeechError.localeUnavailable }
        try checkCancellation()
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber
        // Installed models are shared by the OS, but this app must first
        // reserve their locale before status(forModules:) reports readiness.
        let ownsReservation = try await AssetInventory.reserve(locale: locale)
        if cancelled || Task.isCancelled {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw CancellationError()
        }
        if ownsReservation { reservedLocale = locale }
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard downloadModel else { throw MemoSpeechError.modelRequired }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progressTask = Task {
                    while !Task.isCancelled {
                        progress(request.progress.fractionCompleted)
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    }
                }
                defer { progressTask.cancel() }
                try await request.downloadAndInstall()
            }
        }
        try checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let context = AnalysisContext()
        let terms = script.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { term in term.count >= 2 && term.count <= 48 && term.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) }
        context.contextualStrings[.general] = Array(Set(terms).sorted().prefix(64))
        try await analyzer.setContext(context)
        try checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw MemoSpeechError.invalidAudio }
        try checkCancellation()
        targetFormat = format
        try await analyzer.prepareToAnalyze(in: format)
        try checkCancellation()
    }

    func start(lease: MicrophoneAudioLease) async throws -> AsyncThrowingStream<MemoSpeechText, any Error> {
        try checkCancellation()
        guard let analyzer, let transcriber else { throw MemoSpeechError.unsupported }
        self.lease = lease
        let input = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let output = AsyncThrowingStream<MemoSpeechText, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        inputContinuation = input.continuation
        resultContinuation = output.continuation
        output.continuation.onTermination = { [weak self] _ in Task { await self?.cancel() } }
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    await self?.receive(result)
                }
            } catch {
                await self?.fail(error)
            }
        }
        try await analyzer.start(inputSequence: input.stream)
        try checkCancellation()
        audioTask = Task { [weak self] in
            do {
                for try await sample in lease.samples {
                    guard !Task.isCancelled else { return }
                    try await self?.consume(sample)
                }
                if !Task.isCancelled { await self?.fail(MemoSpeechError.audioEnded) }
            } catch {
                await self?.fail(error)
            }
        }
        return output.stream
    }

    func cancel() async {
        if let cleanupTask { await cleanupTask.value; return }
        cancelled = true
        audioTask?.cancel()
        resultTask?.cancel()
        audioTask = nil
        resultTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        resultContinuation?.finish()
        resultContinuation = nil
        let lease = self.lease
        self.lease = nil
        let analyzer = self.analyzer
        let reservedLocale = self.reservedLocale
        self.reservedLocale = nil
        self.analyzer = nil
        transcriber = nil
        converter = nil
        let cleanup = Task {
            await lease?.release()
            await analyzer?.cancelAndFinishNow()
            if let reservedLocale { await AssetInventory.release(reservedLocale: reservedLocale) }
        }
        cleanupTask = cleanup
        await cleanup.value
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func fail(_ error: any Error) async {
        guard !cancelled else { return }
        resultContinuation?.finish(throwing: error)
        await cancel()
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        guard !cancelled, result.range.start.isNumeric, result.range.duration.isNumeric else { return }
        let changed = transcript.update(
            text: String(result.text.characters), start: result.range.start.seconds,
            end: CMTimeRangeGetEnd(result.range).seconds, isFinal: result.isFinal
        )
        guard changed else { return }
        revision &+= 1
        resultContinuation?.yield(MemoSpeechText(
            text: transcript.text, isFinal: transcript.isFinal, revision: revision,
            timestamp: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func consume(_ sample: MicrophoneAudioSample) async throws {
        try checkCancellation()
        let raw = sample.sampleBuffer
        let source = try MemoSpeechPCMBuffer.copy(raw)
        let sourceFormat = source.format
        let frames = Int(source.frameLength)
        if let naturalFormat, naturalFormat != sourceFormat { throw MemoSpeechError.formatChanged }
        if naturalFormat == nil {
            guard let target = targetFormat else { throw MemoSpeechError.invalidAudio }
            naturalFormat = sourceFormat
            if sourceFormat != target {
                guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw MemoSpeechError.invalidAudio }
                self.converter = converter
            }
        }
        guard let targetFormat else { throw MemoSpeechError.invalidAudio }
        let pts = raw.presentationTimeStamp
        guard pts.isNumeric else { return }
        if let converter {
            let capacity = AVAudioFrameCount(ceil(Double(frames) * targetFormat.sampleRate / sourceFormat.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { throw MemoSpeechError.invalidAudio }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if status == .error { throw conversionError ?? MemoSpeechError.invalidAudio as NSError }
            if converted.frameLength > 0 {
                try yieldAudio(converted, capturedAt: pts)
            }
        } else {
            try yieldAudio(source, capturedAt: pts)
        }
    }

    private func yieldAudio(_ buffer: AVAudioPCMBuffer, capturedAt captureTime: CMTime) throws {
        guard let time = audioTimeline.startTime(captureTime: captureTime,
            frameCount: buffer.frameLength, sampleRate: buffer.format.sampleRate)
        else { throw MemoSpeechError.invalidAudio }
        // Never grow a seconds-long backlog or silently run speech against
        // stale audio if the system transcriber cannot keep up.
        if case .dropped = inputContinuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) {
            throw MemoSpeechError.overloaded
        }
    }
}
