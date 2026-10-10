import AVFoundation
import AudioToolbox
import Foundation
import RecorderCore
import os
import VideoToolbox

final class MicrophoneRecorder: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "microphone-recorder"
    )
    private let session = AVCaptureSession()
    private let levelOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "cn.laogou.dogsc.microphone")
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private var sessionEventMonitor: MicrophoneCaptureSessionEventMonitor?

    // sessionQueue-confined state
    private var activity: CaptureActivity = .idle
    private var monitoringRequestID: UUID?
    private var liveAudioConsumers: [UUID: LiveAudioConsumer] = [:]
    private var startContinuation: (UUID, CheckedContinuation<Void, any Error>)?
    private var stopContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var recordingStartedAtStorage: Date?
    private var configuredDeviceUniqueID: String?
    /// Meter reads originate on the main actor while audio capture and AAC
    /// appends run on `sessionQueue`. Do not make the UI synchronously wait for
    /// that whole queue just to copy one scalar; a writer append or device
    /// transition could otherwise stall the complete recorder toolbar.
    private let normalizedInputLevelState = OSAllocatedUnfairLock(initialState: 0.0)
    private var unexpectedStopHandler: (@MainActor (any Error) -> Void)?
    private var recordingOutputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var expectedRecordingFormatDescription: CMFormatDescription?
    private var firstRecordedSampleTime: CMTime?
    private var firstRawPresentationTime: CMTime?
    private var lastRawPresentationTime: CMTime?
    private var lastRawDuration: CMTime = .zero
    private var accumulatedRawPauseDuration: CMTime = .zero
    private var expectedResumeRawTime: CMTime?
    private var isAwaitingResumeSample = false
    private var writerHasSamples = false
    private var droppedSamples = 0
    private var receivedSampleBuffers = 0
    private var appendedSampleBuffers = 0
    private var writerBackpressureDrops = 0
    private var invalidTimestampDrops = 0
    private var nonMonotonicTimestampDrops = 0
    private var formatChangeDrops = 0
    private var otherSampleDrops = 0
    private var firstDiagnosticHostTime: TimeInterval?
    private var lastDiagnosticHostTime: TimeInterval?
    private var maximumDiagnosticSampleInterval: TimeInterval = 0
    private var skipsNextDiagnosticSampleInterval = false
    private var lastCompletedDiagnostics: AudioCaptureDiagnostics?
    private var recordingIsPaused = false
    private var recordedPauseStartedAt: TimeInterval?
    private var recordedAccumulatedPause: TimeInterval = 0

    override init() {
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
        levelOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        sessionEventMonitor = MicrophoneCaptureSessionEventMonitor(session: session) {
            [weak self] event in
            self?.sessionQueue.async { [weak self] in
                self?.handleSessionEventLocked(event)
            }
        }
    }

    /// A mid-recording device disconnect (USB microphone pulled) ends the
    /// track without any explicit stop. Surface it so the app can warn the
    /// user instead of silently shipping a recording without microphone audio.
    var onUnexpectedStop: (@MainActor (any Error) -> Void)? {
        get { syncOnSessionQueue { unexpectedStopHandler } }
        set { syncOnSessionQueue { unexpectedStopHandler = newValue } }
    }

    var recordingStartedAt: Date? {
        syncOnSessionQueue { recordingStartedAtStorage }
    }

    func captureDiagnosticsSnapshot() async -> AudioCaptureDiagnostics? {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            return currentDiagnosticsLocked() ?? lastCompletedDiagnostics
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(
                    returning: currentDiagnosticsLocked() ?? lastCompletedDiagnostics
                )
            }
        }
    }

    func recordedSourceTime(atHostTime targetHostTime: TimeInterval) -> TimeInterval? {
        syncOnSessionQueue {
            guard activity.ownsRecordingOutput,
                  let firstRecordedSampleTime,
                  firstRecordedSampleTime.isNumeric,
                  firstRecordedSampleTime.seconds.isFinite else { return nil }
            var paused = recordedAccumulatedPause
            if let recordedPauseStartedAt,
               targetHostTime > recordedPauseStartedAt {
                paused += targetHostTime - recordedPauseStartedAt
            }
            // PRE-SYNC-004: map the microphone from its actual first sample on
            // the same host clock used by camera and ScreenCaptureKit. The old
            // `recordedDuration - callback wall time` estimate included file
            // output buffering latency and produced a different permanent trim
            // for camera and microphone.
            return max(targetHostTime - firstRecordedSampleTime.seconds - paused, 0)
        }
    }

    func startMonitoring(deviceUniqueID: String? = nil) async throws {
        guard await requestPermission() else {
            throw MicrophoneRecorderError.permissionDenied
        }
        try Task.checkCancellation()

        let requestID = UUID()
        let cancellation = CaptureCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        guard !activity.ownsRecordingOutput else {
                            throw MicrophoneRecorderError.recordingFailed(
                                "录制期间不能更换麦克风"
                            )
                        }
                        try configureLocked(deviceUniqueID: deviceUniqueID)
                        guard !cancellation.isCancelled else {
                            throw CancellationError()
                        }
                        monitoringRequestID = requestID
                        activity = .livePreview(requestID)
                        if !session.isRunning { session.startRunning() }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.cancelMonitoringLocked(requestID: requestID)
            }
        }
    }

    func stopMonitoring() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopLiveMonitoringLocked()
                continuation.resume()
            }
        }
    }

    /// Subscribers share the existing input during recording, including while
    /// the file writer is paused. A requested device cannot reconfigure a live
    /// recording or another subscriber's session.
    func acquireLiveAudio(deviceUniqueID: String? = nil) async throws -> MicrophoneAudioLease {
        guard await requestPermission() else {
            throw MicrophoneRecorderError.permissionDenied
        }
        try Task.checkCancellation()
        let requestID = UUID()
        let cancellation = CaptureCancellationFlag()
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<MicrophoneAudioLease, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        if !activity.ownsRecordingOutput,
                           monitoringRequestID == nil,
                           liveAudioConsumers.isEmpty {
                            try configureLocked(deviceUniqueID: deviceUniqueID)
                        }
                        guard let configuredDeviceUniqueID,
                              session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                                .contains(where: { $0.device.isConnected }) else {
                            throw MicrophoneLiveAudioError.deviceDisconnected
                        }
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let stream = AsyncThrowingStream<MicrophoneAudioSample, any Error>
                            .makeStream(bufferingPolicy: .bufferingNewest(32))
                        stream.continuation.onTermination = { [weak self] _ in
                            self?.sessionQueue.async { [weak self] in
                                self?.releaseLiveAudioLocked(requestID: requestID)
                            }
                        }
                        liveAudioConsumers[requestID] = LiveAudioConsumer(
                            continuation: stream.continuation
                        )
                        let lease = MicrophoneAudioLease(
                            samples: stream.stream,
                            deviceUniqueID: configuredDeviceUniqueID
                        ) { [self] in
                            await releaseLiveAudio(requestID: requestID)
                        }
                        if !session.isRunning { session.startRunning() }
                        scheduleLiveAudioTimeoutLocked(requestID: requestID)
                        continuation.resume(returning: lease)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            do {
                try Task.checkCancellation()
                return lease
            } catch {
                await lease.release()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.releaseLiveAudioLocked(requestID: requestID)
            }
        }
    }

    func requestIdleResourceRelease() {
        sessionQueue.async { [self] in releaseIdleResourcesLocked() }
    }

    func releaseIdleResourcesSynchronously() {
        syncOnSessionQueue { releaseIdleResourcesLocked() }
    }

    func releaseDisconnectedDevice() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                finishLiveAudioConsumersLocked(throwing: MicrophoneLiveAudioError.deviceDisconnected)
                guard !activity.ownsRecordingOutput else {
                    continuation.resume()
                    return
                }
                releaseIdleResourcesLocked()
                continuation.resume()
            }
        }
    }

    func normalizedInputLevel() -> Double {
        normalizedInputLevelState.withLock { $0 }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let inputLevel = Self.inputLevel(from: sampleBuffer)
            ?? Self.inputLevel(from: connection.audioChannels)
            ?? 0
        normalizedInputLevelState.withLock { $0 = inputLevel }
        publishLiveAudioLocked(sampleBuffer)
        guard activity.recordingRequestID != nil else { return }
        do {
            try appendRecordingSampleLocked(sampleBuffer)
        } catch {
            failRecordingLocked(error, reportsUnexpectedStop: activity.isRecording)
        }
    }

    func start(to outputURL: URL, deviceUniqueID: String? = nil) async throws {
        guard await requestPermission() else {
            throw MicrophoneRecorderError.permissionDenied
        }
        try Task.checkCancellation()

        let requestID = UUID()
        let cancellation = CaptureCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        guard !activity.ownsRecordingOutput else {
                            throw MicrophoneRecorderError.recordingFailed(
                                "上一次麦克风录制尚未结束"
                            )
                        }
                        try configureLocked(deviceUniqueID: deviceUniqueID)
                        guard !cancellation.isCancelled else {
                            throw CancellationError()
                        }
                        resetRecordingStateLocked(cancelWriter: true)
                        lastCompletedDiagnostics = nil
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            try FileManager.default.removeItem(at: outputURL)
                        }
                        recordingOutputURL = outputURL
                        activity = .starting(requestID)
                        startContinuation = (requestID, continuation)
                        if !session.isRunning { session.startRunning() }
                        Self.logger.notice(
                            "microphone start requested device=\(deviceUniqueID ?? "automatic", privacy: .public)"
                        )
                        scheduleStartTimeoutLocked(requestID: requestID)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.cancelRecordingStartLocked(requestID: requestID)
            }
        }
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func stop() async throws {
        let waiterID = UUID()
        let cancellation = CaptureCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    requestStopLocked(waiterID: waiterID, continuation: continuation)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.cancelStopWaiterLocked(waiterID: waiterID)
            }
        }
    }

    func pause() {
        sessionQueue.async { [self] in
            guard case .recording = activity, !recordingIsPaused else { return }
            recordingIsPaused = true
            // A deliberate pause is not an audio delivery stall.
            skipsNextDiagnosticSampleInterval = true
            if let lastRawPresentationTime {
                expectedResumeRawTime = lastRawPresentationTime + lastRawDuration
            }
            recordedPauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        }
    }

    func resume() {
        sessionQueue.async { [self] in
            guard case .recording = activity, recordingIsPaused else { return }
            let resumedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if let recordedPauseStartedAt {
                recordedAccumulatedPause += max(resumedAt - recordedPauseStartedAt, 0)
                self.recordedPauseStartedAt = nil
            }
            recordingIsPaused = false
            isAwaitingResumeSample = expectedResumeRawTime != nil
        }
    }

    private struct LiveAudioConsumer {
        let continuation: AsyncThrowingStream<MicrophoneAudioSample, any Error>.Continuation
        var hasReceivedAudio = false
    }

    private func releaseLiveAudio(requestID: UUID) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                releaseLiveAudioLocked(requestID: requestID)
                continuation.resume()
            }
        }
    }

    private func releaseLiveAudioLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let consumer = liveAudioConsumers.removeValue(forKey: requestID) else { return }
        consumer.continuation.finish()
        stopSessionIfUnownedLocked()
    }

    private func publishLiveAudioLocked(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !liveAudioConsumers.isEmpty,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMAudioFormatDescriptionGetStreamBasicDescription(description)?
                .pointee.mFormatID == kAudioFormatLinearPCM else { return }
        let sample = MicrophoneAudioSample(sampleBuffer: sampleBuffer)
        var terminated: [UUID] = []
        for (requestID, consumer) in liveAudioConsumers {
            liveAudioConsumers[requestID]?.hasReceivedAudio = true
            if case .terminated = consumer.continuation.yield(sample) {
                terminated.append(requestID)
            }
        }
        for requestID in terminated { releaseLiveAudioLocked(requestID: requestID) }
    }

    private func finishLiveAudioConsumersLocked(throwing error: any Error) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let consumers = Array(liveAudioConsumers.values)
        liveAudioConsumers.removeAll()
        for consumer in consumers { consumer.continuation.finish(throwing: error) }
    }

    private func scheduleLiveAudioTimeoutLocked(requestID: UUID) {
        sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  let consumer = liveAudioConsumers[requestID],
                  !consumer.hasReceivedAudio else { return }
            liveAudioConsumers.removeValue(forKey: requestID)
            consumer.continuation.finish(throwing: MicrophoneLiveAudioError.noAudio)
            stopSessionIfUnownedLocked()
        }
    }

    private func restoreLiveActivityLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if let monitoringRequestID {
            activity = .livePreview(monitoringRequestID)
        } else {
            activity = .idle
        }
    }

    private func stopSessionIfUnownedLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !activity.ownsRecordingOutput,
              monitoringRequestID == nil,
              liveAudioConsumers.isEmpty else { return }
        if session.isRunning { session.stopRunning() }
        resetNormalizedInputLevel()
    }

    private func handleSessionEventLocked(_ event: MicrophoneCaptureSessionEvent) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let error: MicrophoneLiveAudioError
        switch event {
        case let .disconnected(uniqueID):
            guard uniqueID == configuredDeviceUniqueID else { return }
            error = .deviceDisconnected
        case let .runtimeError(reason):
            guard activity.ownsRecordingOutput || monitoringRequestID != nil
                    || !liveAudioConsumers.isEmpty else { return }
            error = .captureFailed(reason)
        }
        Self.logger.error("microphone session failed: \(error.localizedDescription, privacy: .public)")
        finishLiveAudioConsumersLocked(throwing: error)
        monitoringRequestID = nil
        // Input loss is not an encoder failure. Stop accepting samples but
        // preserve and finalize the audio already written before the device
        // disappeared; cancelWriting would remove that useful partial track.
        if session.isRunning { session.stopRunning() }
        resetNormalizedInputLevel()
        finalizeInterruptedRecordingLocked(error)
        releaseIdleResourcesLocked()
    }

    private func finalizeInterruptedRecordingLocked(_ error: any Error) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        switch activity {
        case let .starting(requestID), let .recording(requestID):
            let reportsUnexpectedStop = activity.isRecording
            let failure = error as? MicrophoneRecorderError
                ?? MicrophoneRecorderError.recordingFailed(error.localizedDescription)
            guard writerHasSamples, writer?.status == .writing, writerInput != nil else {
                failRecordingLocked(failure, reportsUnexpectedStop: reportsUnexpectedStop)
                return
            }
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                pending.1.resume(throwing: failure)
            }
            // Copy the handler before an asynchronous finish. AppModel's
            // handler carries this recording's identity even after a restart.
            let handler = reportsUnexpectedStop ? unexpectedStopHandler : nil
            activity = .stopping(requestID)
            finishWriterLocked(requestID: requestID)
            if let handler { Task { @MainActor in handler(failure) } }
        case .stopping:
            // A disconnect can race an explicit stop. finishWriting is already
            // in flight and its existing callback/timeout owns completion.
            return
        case .idle, .livePreview:
            return
        }
    }

    private func configureLocked(deviceUniqueID: String?) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let device = try CaptureDeviceCatalog.resolveLiveDevice(
            role: .microphone,
            selectedUniqueID: deviceUniqueID
        )

        let hasConnectedInput = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .contains { $0.uniqueID == device.uniqueID && $0.isConnected }
        let hasLevelOutput = session.outputs.contains { $0 === levelOutput }
        if configuredDeviceUniqueID == device.uniqueID,
           hasConnectedInput,
           hasLevelOutput {
            return
        }

        // Changing the recorder's device is an explicit boundary. Speech can
        // retry against the new input; no old lease silently starts delivering
        // a different microphone's audio.
        if configuredDeviceUniqueID != nil {
            finishLiveAudioConsumersLocked(throwing: MicrophoneLiveAudioError.deviceChanged)
        }
        if session.isRunning { session.stopRunning() }
        let input = try AVCaptureDeviceInput(device: device)
        configuredDeviceUniqueID = nil
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for existingInput in session.inputs { session.removeInput(existingInput) }
        guard session.canAddInput(input) else {
            throw MicrophoneRecorderError.recordingFailed("无法配置所选麦克风")
        }
        session.addInput(input)
        if !hasLevelOutput {
            guard session.canAddOutput(levelOutput) else {
                throw MicrophoneRecorderError.recordingFailed("无法创建麦克风电平监听")
            }
            session.addOutput(levelOutput)
        }
        configuredDeviceUniqueID = device.uniqueID
        resetNormalizedInputLevel()
    }

    private func requestStopLocked(
        waiterID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        switch activity {
        case .idle, .livePreview:
            restoreLiveActivityLocked()
            stopSessionIfUnownedLocked()
            continuation.resume()
        case let .starting(requestID):
            stopContinuations[waiterID] = continuation
            activity = .stopping(requestID)
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                pending.1.resume(throwing: CancellationError())
            }
            finishWriterLocked(requestID: requestID)
        case let .recording(requestID):
            stopContinuations[waiterID] = continuation
            activity = .stopping(requestID)
            finishWriterLocked(requestID: requestID)
        case .stopping:
            stopContinuations[waiterID] = continuation
        }
    }

    private func cancelMonitoringLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard monitoringRequestID == requestID else { return }
        stopLiveMonitoringLocked()
    }

    private func stopLiveMonitoringLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        monitoringRequestID = nil
        if !activity.ownsRecordingOutput { restoreLiveActivityLocked() }
        stopSessionIfUnownedLocked()
    }

    private func releaseIdleResourcesLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        monitoringRequestID = nil
        guard !activity.ownsRecordingOutput else { return }
        restoreLiveActivityLocked()
        guard liveAudioConsumers.isEmpty else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        activity = .idle
        configuredDeviceUniqueID = nil
        resetNormalizedInputLevel()
        resetRecordingStateLocked(cancelWriter: true)
    }

    private func cancelRecordingStartLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activity.recordingRequestID == requestID else { return }
        if let pending = startContinuation, pending.0 == requestID {
            startContinuation = nil
            pending.1.resume(throwing: CancellationError())
        }
        activity = .stopping(requestID)
        finishWriterLocked(requestID: requestID)
    }

    private func cancelStopWaiterLocked(waiterID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        stopContinuations.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }

    /// The metering UI and the recording file deliberately consume this same
    /// `AVCaptureAudioDataOutput` sample. The former two-output design waited
    /// for a file-output delegate and a data-output sample independently; some
    /// USB devices opened one branch without ever completing the other, leaving
    /// preparation stuck or an unfinalized M4A writing after the editor opened.
    private func appendRecordingSampleLocked(_ sampleBuffer: CMSampleBuffer) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let requestID: UUID
        switch activity {
        case let .starting(id), let .recording(id):
            requestID = id
        case .idle, .livePreview, .stopping:
            return
        }
        guard !recordingIsPaused else { return }
        receivedSampleBuffers += 1
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            droppedSamples += 1
            otherSampleDrops += 1
            return
        }
        let rawTime = sampleBuffer.presentationTimeStamp
        guard rawTime.isNumeric else {
            droppedSamples += 1
            invalidTimestampDrops += 1
            return
        }
        if let lastRawPresentationTime, rawTime < lastRawPresentationTime {
            droppedSamples += 1
            nonMonotonicTimestampDrops += 1
            return
        }
        let sampleFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        if let expectedRecordingFormatDescription,
           !CFEqual(sampleFormatDescription, expectedRecordingFormatDescription) {
            droppedSamples += 1
            formatChangeDrops += 1
            throw MicrophoneRecorderError.recordingFailed("麦克风格式在录制中发生变化")
        }
        expectedRecordingFormatDescription = expectedRecordingFormatDescription
            ?? sampleFormatDescription
        let diagnosticHostTime = rawTime.seconds
        if diagnosticHostTime.isFinite {
            if let lastDiagnosticHostTime, !skipsNextDiagnosticSampleInterval {
                maximumDiagnosticSampleInterval = max(
                    maximumDiagnosticSampleInterval,
                    diagnosticHostTime - lastDiagnosticHostTime
                )
            }
            firstDiagnosticHostTime = firstDiagnosticHostTime ?? diagnosticHostTime
            lastDiagnosticHostTime = diagnosticHostTime
            skipsNextDiagnosticSampleInterval = false
        }

        if isAwaitingResumeSample, let expectedResumeRawTime {
            let interruption = rawTime - expectedResumeRawTime
            if interruption.isNumeric, interruption > .zero {
                accumulatedRawPauseDuration = accumulatedRawPauseDuration + interruption
            }
            self.expectedResumeRawTime = nil
            isAwaitingResumeSample = false
        }

        if writer == nil {
            try createWriterLocked(from: sampleBuffer)
        }
        guard let writer, let writerInput else {
            throw MicrophoneRecorderError.recordingFailed("麦克风编码器未就绪")
        }
        let firstRaw = firstRawPresentationTime ?? rawTime
        firstRawPresentationTime = firstRaw
        guard let adjusted = SampleBufferTimeRetimer.retimed(
            sampleBuffer,
            subtracting: firstRaw + accumulatedRawPauseDuration
        ) else {
            otherSampleDrops += 1
            throw MicrophoneRecorderError.recordingFailed("无法对齐麦克风样本时间戳")
        }
        guard writer.status == .writing else {
            throw writer.error ?? MicrophoneRecorderError.recordingFailed(
                "麦克风编码器未处于写入状态"
            )
        }
        guard writerInput.isReadyForMoreMediaData else {
            droppedSamples += 1
            writerBackpressureDrops += 1
            return
        }
        guard writerInput.append(adjusted) else {
            otherSampleDrops += 1
            throw writer.error ?? MicrophoneRecorderError.recordingFailed("麦克风样本写入失败")
        }

        writerHasSamples = true
        appendedSampleBuffers += 1
        lastRawPresentationTime = rawTime
        let duration = sampleBuffer.duration
        lastRawDuration = duration.isNumeric && duration > .zero ? duration : .zero

        if firstRecordedSampleTime == nil,
           let hostTime = captureSampleHostTime(sampleBuffer, session: session) {
            firstRecordedSampleTime = CMTime(
                seconds: hostTime,
                preferredTimescale: 1_000_000_000
            )
            recordingStartedAtStorage = Date()
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                activity = .recording(requestID)
                pending.1.resume()
                Self.logger.notice(
                    "microphone first sample committed hostTime=\(hostTime, privacy: .public)"
                )
            }
        }
    }

    private func createWriterLocked(from sampleBuffer: CMSampleBuffer) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let outputURL = recordingOutputURL,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee else {
            throw MicrophoneRecorderError.recordingFailed("无法读取麦克风音频格式")
        }
        let sampleRate = basicDescription.mSampleRate.isFinite
            && basicDescription.mSampleRate > 0
            ? basicDescription.mSampleRate : 48_000
        let channels = max(Int(basicDescription.mChannelsPerFrame), 1)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels > 1 ? 192_000 : 128_000,
            ],
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else {
            throw MicrophoneRecorderError.recordingFailed("无法创建麦克风 AAC 音轨")
        }
        assetWriter.add(input)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? MicrophoneRecorderError.recordingFailed(
                "无法启动麦克风 AAC 编码器"
            )
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        writerInput = input
        Self.logger.notice(
            "microphone writer started sampleRate=\(sampleRate, privacy: .public) channels=\(channels, privacy: .public)"
        )
    }

    private func finishWriterLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .stopping(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        guard let writer, let writerInput, writerHasSamples else {
            completeStopLocked(requestID: requestID, result: .success(()))
            return
        }
        writerInput.markAsFinished()
        scheduleStopTimeoutLocked(requestID: requestID)
        writer.finishWriting { [weak self] in
            self?.sessionQueue.async { [weak self] in
                guard let self,
                      case let .stopping(activeRequestID) = self.activity,
                      activeRequestID == requestID else { return }
                guard let completedWriter = self.writer else {
                    self.completeStopLocked(
                        requestID: requestID,
                        result: .failure(MicrophoneRecorderError.recordingFailed(
                            "麦克风编码器在封装期间已释放"
                        ))
                    )
                    return
                }
                if completedWriter.status == .completed {
                    Self.logger.notice(
                        "microphone writer completed droppedSamples=\(self.droppedSamples, privacy: .public)"
                    )
                    self.completeStopLocked(requestID: requestID, result: .success(()))
                } else {
                    self.completeStopLocked(
                        requestID: requestID,
                        result: .failure(completedWriter.error ?? MicrophoneRecorderError.recordingFailed(
                            "麦克风文件没有完成封装"
                        ))
                    )
                }
            }
        }
    }

    private func completeStopLocked(
        requestID: UUID,
        result: Result<Void, any Error>
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .stopping(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        let pendingStops = Array(stopContinuations.values)
        stopContinuations.removeAll()
        if let completed = currentDiagnosticsLocked() {
            lastCompletedDiagnostics = completed
        }
        restoreLiveActivityLocked()
        stopSessionIfUnownedLocked()
        resetRecordingStateLocked(cancelWriter: false)
        switch result {
        case .success:
            pendingStops.forEach { $0.resume() }
        case let .failure(error):
            pendingStops.forEach { $0.resume(throwing: error) }
        }
    }

    private func failRecordingLocked(
        _ error: any Error,
        reportsUnexpectedStop: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let failure = error as? MicrophoneRecorderError
            ?? MicrophoneRecorderError.recordingFailed(error.localizedDescription)
        if let pending = startContinuation {
            startContinuation = nil
            pending.1.resume(throwing: failure)
        }
        let pendingStops = Array(stopContinuations.values)
        stopContinuations.removeAll()
        pendingStops.forEach { $0.resume(throwing: failure) }
        if let completed = currentDiagnosticsLocked() {
            lastCompletedDiagnostics = completed
        }
        writer?.cancelWriting()
        restoreLiveActivityLocked()
        stopSessionIfUnownedLocked()
        resetRecordingStateLocked(cancelWriter: false)
        guard reportsUnexpectedStop, let handler = unexpectedStopHandler else { return }
        Task { @MainActor in handler(failure) }
    }

    private func resetRecordingStateLocked(cancelWriter: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if cancelWriter,
           let writer,
           writer.status == .unknown || writer.status == .writing {
            writer.cancelWriting()
        }
        writer = nil
        writerInput = nil
        expectedRecordingFormatDescription = nil
        recordingOutputURL = nil
        recordingStartedAtStorage = nil
        firstRecordedSampleTime = nil
        firstRawPresentationTime = nil
        lastRawPresentationTime = nil
        lastRawDuration = .zero
        accumulatedRawPauseDuration = .zero
        expectedResumeRawTime = nil
        isAwaitingResumeSample = false
        writerHasSamples = false
        droppedSamples = 0
        receivedSampleBuffers = 0
        appendedSampleBuffers = 0
        writerBackpressureDrops = 0
        invalidTimestampDrops = 0
        nonMonotonicTimestampDrops = 0
        formatChangeDrops = 0
        otherSampleDrops = 0
        firstDiagnosticHostTime = nil
        lastDiagnosticHostTime = nil
        maximumDiagnosticSampleInterval = 0
        skipsNextDiagnosticSampleInterval = false
        recordingIsPaused = false
        recordedPauseStartedAt = nil
        recordedAccumulatedPause = 0
    }

    private func resetNormalizedInputLevel() {
        normalizedInputLevelState.withLock { $0 = 0 }
    }

    private func currentDiagnosticsLocked() -> AudioCaptureDiagnostics? {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard receivedSampleBuffers > 0 || appendedSampleBuffers > 0 else { return nil }
        let elapsed: TimeInterval
        if let firstDiagnosticHostTime, let lastDiagnosticHostTime {
            elapsed = max(
                lastDiagnosticHostTime
                    - firstDiagnosticHostTime
                    - recordedAccumulatedPause,
                0
            )
        } else {
            elapsed = 0
        }
        return AudioCaptureDiagnostics(
            receivedSampleBuffers: receivedSampleBuffers,
            appendedSampleBuffers: appendedSampleBuffers,
            writerBackpressureDrops: writerBackpressureDrops,
            invalidTimestampDrops: invalidTimestampDrops,
            nonMonotonicTimestampDrops: nonMonotonicTimestampDrops,
            formatChangeDrops: formatChangeDrops,
            otherDrops: otherSampleDrops,
            elapsed: elapsed,
            maximumSampleInterval: maximumDiagnosticSampleInterval
        )
    }

    private func scheduleStartTimeoutLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  case let .starting(activeRequestID) = activity,
                  activeRequestID == requestID,
                  let pending = startContinuation,
                  pending.0 == requestID else { return }
            startContinuation = nil
            pending.1.resume(
                throwing: MicrophoneRecorderError.recordingFailed(
                    "5 秒内没有收到并写入首个有效音频样本"
                )
            )
            restoreLiveActivityLocked()
            stopSessionIfUnownedLocked()
            resetRecordingStateLocked(cancelWriter: true)
        }
    }

    private func scheduleStopTimeoutLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        sessionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  case let .stopping(activeRequestID) = activity,
                  activeRequestID == requestID else { return }
            writer?.cancelWriting()
            completeStopLocked(
                requestID: requestID,
                result: .failure(MicrophoneRecorderError.recordingFailed(
                    "10 秒内没有完成音频文件封装"
                ))
            )
        }
    }

    private static func inputLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let format = formatPointer.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel > 0 else { return nil }

        var contiguousLength = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr,
        let dataPointer,
        contiguousLength > 0 else { return nil }

        let flags = format.mFormatFlags
        let bits = Int(format.mBitsPerChannel)
        let meanSquare: Double
        if flags & kAudioFormatFlagIsFloat != 0, bits == 32 {
            let count = contiguousLength / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsFloat != 0, bits == 64 {
            let count = contiguousLength / MemoryLayout<Double>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Double.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = samples[index]
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 16 {
            let count = contiguousLength / MemoryLayout<Int16>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int16.max)
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 32 {
            let count = contiguousLength / MemoryLayout<Int32>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int32.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int32.max)
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else {
            return nil
        }

        let rootMeanSquare = sqrt(max(meanSquare, 0))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return normalizedLevel(fromDecibels: decibels)
    }

    private static func inputLevel(from channels: [AVCaptureAudioChannel]) -> Double? {
        let finiteLevels = channels
            .map { Double($0.averagePowerLevel) }
            .filter(\.isFinite)
        guard let strongestLevel = finiteLevels.max() else { return nil }
        return normalizedLevel(fromDecibels: strongestLevel)
    }

    private static func normalizedLevel(fromDecibels decibels: Double) -> Double {
        let floorLevel = -52.0
        guard decibels > floorLevel else { return 0 }
        let normalized = (decibels - floorLevel) / -floorLevel
        return min(max(pow(normalized, 0.62), 0), 1)
    }

    private func syncOnSessionQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil { return operation() }
        return sessionQueue.sync(execute: operation)
    }
}

private enum MicrophoneCaptureSessionEvent: Sendable {
    case disconnected(String)
    case runtimeError(String)
}

/// Speech may own the input even when recording is disabled, so capture errors
/// must be observed here instead of depending on the toolbar device observer.
private final class MicrophoneCaptureSessionEventMonitor {
    private var observers: [NSObjectProtocol] = []

    init(
        session: AVCaptureSession,
        handler: @escaping @Sendable (MicrophoneCaptureSessionEvent) -> Void
    ) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            handler(.runtimeError(error?.localizedDescription ?? "Unknown audio capture error"))
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            handler(.disconnected(device.uniqueID))
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
