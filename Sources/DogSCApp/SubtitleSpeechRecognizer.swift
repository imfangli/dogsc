import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import Speech

struct SubtitleSpeechProgress: Sendable {
    enum Phase: Sendable { case preparing, downloadingModel, transcribing }
    let phase: Phase
    let fraction: Double
}

/// Prepared compositions are read-only snapshots shared by preview/export.
/// The recognition reader owns its reader and PCM buffers, never live capture.
struct SubtitleSpeechRequest: @unchecked Sendable {
    let media: TimelineCompositionBundle
    let project: RecorderProject
    let audioSource: SubtitleAudioSource
    let sourceDuration: Double
    let script: String
    let theme: String
    let downloadModel: Bool

    init(media: TimelineCompositionBundle, project: RecorderProject,
        audioSource: SubtitleAudioSource, sourceDuration: Double,
        script: String = "", theme: String = "", downloadModel: Bool = false) {
        self.media = media
        self.project = project
        self.audioSource = audioSource
        self.sourceDuration = sourceDuration
        self.script = script
        self.theme = theme
        self.downloadModel = downloadModel
    }
}

enum SubtitleSpeechError: LocalizedError, Equatable {
    case unsupported, localeUnavailable, modelRequired, invalidAudio, noAudio, noSpeech, busy
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: appLocalized("生成字幕需要 macOS 26 或更新版本及支持本机识别的设备")
        case .localeUnavailable: appLocalized("普通话模型不可用")
        case .modelRequired: appLocalized("下载普通话模型后即可生成字幕")
        case .invalidAudio: appLocalized("无法读取字幕音频，请检查项目素材")
        case .noAudio: appLocalized("所选声音来源没有可识别的音轨")
        case .noSpeech: appLocalized("没有识别到口播，请检查声音来源后重试")
        case .busy: appLocalized("字幕生成正在进行中")
        case .recognitionFailed: appLocalized("字幕识别失败，请重试")
        }
    }
}

@available(macOS 26, *)
actor SubtitleSpeechRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var reader: SubtitlePCMReader?
    private var localeLease: SpeechLocaleLease?
    private var running = false
    private var cancelled = false

    func generate(
        _ request: SubtitleSpeechRequest,
        progress: @escaping @Sendable (SubtitleSpeechProgress) -> Void = { _ in }
    ) async throws -> [SubtitleWord] {
        guard !running else { throw SubtitleSpeechError.busy }
        running = true
        cancelled = false
        do {
            let words = try await withTaskCancellationHandler {
                try await perform(request, progress: progress)
            } onCancel: { [weak self] in
                Task { await self?.cancel() }
            }
            try checkCancellation()
            await cleanup()
            try checkCancellation()
            running = false
            progress(.init(phase: .transcribing, fraction: 1))
            return words
        } catch {
            await cleanup()
            running = false
            if cancelled || Task.isCancelled { throw CancellationError() }
            if let error = error as? SubtitleSpeechError { throw error }
            throw SubtitleSpeechError.recognitionFailed
        }
    }

    func cancel() async {
        cancelled = true
        await reader?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private func perform(_ request: SubtitleSpeechRequest,
        progress: @escaping @Sendable (SubtitleSpeechProgress) -> Void) async throws -> [SubtitleWord] {
        try checkCancellation()
        let hasSelectedAudio: Bool
        switch request.audioSource {
        case .microphone: hasSelectedAudio = request.media.microphoneAudioTrack != nil
        case .system: hasSelectedAudio = request.media.systemAudioTrack != nil
        case .finalMix: hasSelectedAudio = request.media.microphoneAudioTrack != nil || request.media.systemAudioTrack != nil
        }
        guard hasSelectedAudio else { throw SubtitleSpeechError.noAudio }
        guard SpeechTranscriber.isAvailable else { throw SubtitleSpeechError.unsupported }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
        else { throw SubtitleSpeechError.localeUnavailable }
        progress(.init(phase: .preparing, fraction: 0))
        // Final results only: retain the whole film rather than the short
        // rolling/revisable transcript used by live memo following.
        let transcriber = SpeechTranscriber(locale: locale,
            transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        localeLease = try await SpeechLocaleReservations.shared.acquire(locale: locale)
        try checkCancellation()
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard request.downloadModel else { throw SubtitleSpeechError.modelRequired }
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progressTask = Task {
                    while !Task.isCancelled {
                        progress(.init(phase: .downloadingModel,
                            fraction: installation.progress.fractionCompleted))
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    }
                }
                defer { progressTask.cancel() }
                try await installation.downloadAndInstall()
            }
        }
        try checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let context = AnalysisContext()
        context.contextualStrings[.general] = SubtitleSpeechContext.englishTerms(in: request.script + " " + request.theme)
        try await analyzer.setContext(context)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw SubtitleSpeechError.invalidAudio }
        try checkCancellation()
        try await analyzer.prepareToAnalyze(in: format)
        try checkCancellation()
        let reader = try SubtitlePCMReader(request: request, targetFormat: format, progress: progress)
        self.reader = reader
        let collector = SubtitleSpeechResultCollector()
        let results = Task {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    await collector.receive(result)
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
        do {
            progress(.init(phase: .transcribing, fraction: 0))
            _ = try await analyzer.analyzeSequence(SubtitlePCMSequence(reader: reader))
            try checkCancellation()
            // EOF is not a recognition result. Explicit finalization flushes
            // the last utterance before reading the collector's final units.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
            try checkCancellation()
            let units = await collector.units()
            var words: [SubtitleWord] = []
            for unit in units {
                let start = max(unit.start, 0)
                let end = min(unit.end, request.media.plan.outputDuration)
                guard start.isFinite, end.isFinite, end > start else { continue }
                let ranges = try SubtitleDocument.sourceRanges(
                    for: SubtitleTimeRange(start: start, end: end),
                    timeline: request.project.timeline, sourceDuration: request.sourceDuration)
                guard !ranges.isEmpty else { continue }
                words.append(SubtitleWord(text: unit.text, sourceRanges: ranges))
            }
            guard !words.isEmpty else { throw SubtitleSpeechError.noSpeech }
            return words
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await results.value
            throw error
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func cleanup() async {
        await reader?.cancel()
        reader = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        let localeLease = self.localeLease
        self.localeLease = nil
        await localeLease?.release()
    }
}

struct SubtitleRecognizedUnit: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum SubtitleSpeechContext {
    static func englishTerms(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]*(?:[._+\\-][A-Za-z0-9]+)*")
        else { return [] }
        let terms = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let term = String(text[range])
            return (2...48).contains(term.count) ? term : nil
        }
        return Array(Set(terms).sorted().prefix(64))
    }
}

@available(macOS 26, *)
private actor SubtitleSpeechResultCollector {
    private var segments: [(range: CMTimeRange, units: [SubtitleRecognizedUnit])] = []

    func receive(_ result: SpeechTranscriber.Result) {
        guard result.isFinal, result.range.start.isNumeric, result.range.duration.isNumeric else { return }
        let units = SubtitleSpeechTiming.timedUnits(text: result.text, fallback: result.range)
        // An engine may replace a prior audio interval even in final-only
        // mode. Replace overlapping result intervals; never append revisions.
        segments.removeAll { CMTimeRangeGetIntersection($0.range, otherRange: result.range).duration > .zero }
        segments.append((result.range, units))
    }

    func units() -> [SubtitleRecognizedUnit] {
        segments.sorted { $0.range.start < $1.range.start }.flatMap(\.units)
    }
}

@available(macOS 26, *)
enum SubtitleSpeechTiming {
    static func timedUnits(text: AttributedString, fallback: CMTimeRange) -> [SubtitleRecognizedUnit] {
        let runs = text.runs
        var units: [SubtitleRecognizedUnit] = []
        for run in runs {
            let value = String(text[run.range].characters)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Un-timed punctuation/whitespace belongs to the adjacent spoken
            // unit. It cannot create an invented word boundary for AI splits.
            guard let range = run.audioTimeRange,
                  range.start.isNumeric, range.duration.isNumeric, range.duration > .zero else {
                if value.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
                    guard !units.isEmpty else { continue }
                    let last = units.removeLast()
                    units.append(.init(text: last.text + value, start: last.start, end: last.end))
                } else {
                    // A transcript missing timing is one anchored result,
                    // not synthetic evenly-spaced character timestamps.
                    return [.init(text: String(text.characters), start: fallback.start.seconds,
                        end: CMTimeRangeGetEnd(fallback).seconds)]
                }
                continue
            }
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            if let previous = units.last, previous.start == start, previous.end == end {
                units.removeLast()
                units.append(.init(text: previous.text + value, start: start, end: end))
            } else {
                units.append(.init(text: value, start: start, end: end))
            }
        }
        if units.isEmpty, !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.init(text: String(text.characters), start: fallback.start.seconds,
                end: CMTimeRangeGetEnd(fallback).seconds)]
        }
        return units
    }
}

/// Pull-based input has one in-flight PCM buffer. Speech controls the reader's
/// pace so long films cannot grow a queue or silently discard audio packets.
@available(macOS 26, *)
private struct SubtitlePCMSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let reader: SubtitlePCMReader
    struct AsyncIterator: AsyncIteratorProtocol {
        let reader: SubtitlePCMReader
        mutating func next() async throws -> AnalyzerInput? { try await reader.next() }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(reader: reader) }
}

@available(macOS 26, *)
private actor SubtitlePCMReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let target: AVAudioFormat
    private let duration: Double
    private let progress: @Sendable (SubtitleSpeechProgress) -> Void
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var nextEndFrame: Int64 = 0
    private var reachedEOF = false
    private var cancelled = false
    private var lastProgress = -1.0

    init(request: SubtitleSpeechRequest, targetFormat: AVAudioFormat,
        progress: @escaping @Sendable (SubtitleSpeechProgress) -> Void) throws {
        target = targetFormat
        duration = request.media.plan.outputDuration
        self.progress = progress
        guard duration.isFinite, duration > 0 else { throw SubtitleSpeechError.invalidAudio }
        let media = request.media
        let tracks: [AVAssetTrack]
        switch request.audioSource {
        case .microphone: tracks = [media.microphoneAudioTrack].compactMap { $0 }
        case .system: tracks = [media.systemAudioTrack].compactMap { $0 }
        case .finalMix: tracks = [media.systemAudioTrack, media.microphoneAudioTrack].compactMap { $0 }
        }
        guard !tracks.isEmpty else { throw SubtitleSpeechError.noAudio }
        reader = try AVAssetReader(asset: media.primaryComposition)
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        if request.audioSource == .finalMix {
            output.audioMix = TimelineCompositionBuilder.audioMix(
                systemTrack: media.systemAudioTrack,
                systemVolume: request.project.audio.isSystemMuted ? 0 : Float(min(max(request.project.audio.systemVolume, 0), 1)),
                primarySegmentRanges: media.primarySegmentAudioMixRanges(audio: request.project.audio,
                    overrides: request.project.timeline.primarySegmentAudioOverrides),
                microphoneTrack: media.microphoneAudioTrack,
                microphoneVolume: request.project.audio.isMicrophoneMuted ? 0 : Float(min(max(request.project.audio.microphoneVolume, 0), 1)),
                requiresTimePitchProcessing: media.requiresAudioTimePitchProcessing,
                timePitchAlgorithm: .spectral)
        } else {
            // A specifically selected track is recognized even when muted in
            // the final mix. Retiming still matches the edited video clock.
            output.audioMix = TimelineCompositionBuilder.audioMix(
                systemTrack: request.audioSource == .system ? media.systemAudioTrack : nil, systemVolume: 1,
                microphoneTrack: request.audioSource == .microphone ? media.microphoneAudioTrack : nil,
                microphoneVolume: 1, requiresTimePitchProcessing: media.requiresAudioTimePitchProcessing,
                timePitchAlgorithm: .spectral)
        }
        if media.requiresAudioTimePitchProcessing { output.audioTimePitchAlgorithm = .spectral }
        guard reader.canAdd(output) else { throw SubtitleSpeechError.invalidAudio }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        guard reader.startReading() else { throw SubtitleSpeechError.invalidAudio }
    }

    func cancel() { cancelled = true; reader.cancelReading() }

    func next() throws -> AnalyzerInput? {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        while !reachedEOF {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw SubtitleSpeechError.invalidAudio }
                if reader.status == .cancelled { throw CancellationError() }
                reachedEOF = true
                break
            }
            let source = try MemoSpeechPCMBuffer.copy(sample)
            if let sourceFormat, sourceFormat != source.format { throw SubtitleSpeechError.invalidAudio }
            if sourceFormat == nil {
                sourceFormat = source.format
                if source.format != target {
                    guard let converter = AVAudioConverter(from: source.format, to: target)
                    else { throw SubtitleSpeechError.invalidAudio }
                    self.converter = converter
                }
            }
            let buffer: AVAudioPCMBuffer
            if let converter {
                let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * target.sampleRate / source.format.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
                else { throw SubtitleSpeechError.invalidAudio }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return source
                }
                guard status != .error else { throw SubtitleSpeechError.invalidAudio }
                buffer = converted
            } else { buffer = source }
            guard buffer.frameLength > 0 else { continue }
            let time = try startTime(sample.presentationTimeStamp, frames: buffer.frameLength)
            let fraction = min(max(sample.presentationTimeStamp.seconds / duration, 0), 0.99)
            if fraction - lastProgress >= 0.005 {
                lastProgress = fraction
                progress(.init(phase: .transcribing, fraction: fraction))
            }
            return AnalyzerInput(buffer: buffer, bufferStartTime: time)
        }
        if let converter {
            guard let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096)
            else { throw SubtitleSpeechError.invalidAudio }
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else { throw SubtitleSpeechError.invalidAudio }
            if tail.frameLength > 0 {
                return AnalyzerInput(buffer: tail, bufferStartTime: try startTime(nil, frames: tail.frameLength))
            }
            self.converter = nil
        }
        return nil
    }

    private func startTime(_ captured: CMTime?, frames: AVAudioFrameCount) throws -> CMTime {
        guard target.sampleRate.isFinite, target.sampleRate > 0,
              target.sampleRate.rounded() == target.sampleRate,
              target.sampleRate <= Double(Int32.max) else { throw SubtitleSpeechError.invalidAudio }
        let scale = CMTimeScale(target.sampleRate)
        var start = nextEndFrame
        if let captured {
            guard captured.isNumeric else { throw SubtitleSpeechError.invalidAudio }
            start = max(start, CMTimeConvertScale(captured, timescale: scale, method: .roundTowardPositiveInfinity).value)
        }
        let (end, overflow) = start.addingReportingOverflow(Int64(frames))
        guard !overflow else { throw SubtitleSpeechError.invalidAudio }
        nextEndFrame = end
        return CMTime(value: start, timescale: scale)
    }
}
