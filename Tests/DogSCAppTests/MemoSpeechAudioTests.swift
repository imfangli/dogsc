import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import DogSCApp
import RecorderCore

@MainActor
final class MemoSpeechAudioTests: XCTestCase {
    func testPCMConversionPreservesIntegerMonoAndFloatStereo() throws {
        for (commonFormat, rate, channels, interleaved) in [
            (AVAudioCommonFormat.pcmFormatInt16, 44_100.0, AVAudioChannelCount(1), true),
            (.pcmFormatFloat32, 48_000.0, AVAudioChannelCount(2), false),
        ] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: rate, channels: channels, interleaved: interleaved))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            pcm.frameLength = 128
            for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0x12, Int(buffer.mDataByteSize)) }
            }
            let sample = try makeSample(pcm, at: CMTime(value: 3, timescale: 1))
            let copy = try MemoSpeechPCMBuffer.copy(sample)
            XCTAssertEqual(copy.format, format)
            XCTAssertEqual(copy.frameLength, pcm.frameLength)
            XCTAssertEqual(sample.presentationTimeStamp, CMTime(value: 3, timescale: 1))
            let original = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let copied = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            XCTAssertEqual(original.count, copied.count)
            for index in original.indices {
                let source = try XCTUnwrap(original[index].mData)
                let destination = try XCTUnwrap(copied[index].mData)
                XCTAssertNotEqual(source, destination)
                XCTAssertEqual(memcmp(source, destination, Int(original[index].mDataByteSize)), 0)
            }
        }
    }

    func testLeaseConcurrentReleaseIsIdempotent() async {
        let counter = ReleaseCounter()
        let stream = AsyncThrowingStream<MicrophoneAudioSample, any Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let lease = MicrophoneAudioLease(samples: stream.stream, deviceUniqueID: "test") { await counter.increment() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { await lease.release() } }
        }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        stream.continuation.finish()
    }

    /// Opt-in integration against the actual installed Apple model. Input is
    /// a local, synthetic voice file; no microphone or network is used.
    func testInstalledAppleSpeechWithSyntheticAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["DOGSC_SPEECH_TEST_AUDIO"] else {
            throw XCTSkip("Set DOGSC_SPEECH_TEST_AUDIO to a local Mandarin audio file for the system integration test.")
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("Requires macOS 26 and SpeechTranscriber.")
        }
        let script = "先把需要介绍的内容粘贴到备忘录里面，然后打开语音跟读开关。接下来可以从文稿中间开始朗读，软件会自动找到对应的句子。最后检查录制画面和麦克风声音，确认已经做好准备工作。"
        let recognizer = MemoSpeechRecognizer()
        try await recognizer.prepare(script: script, downloadModel: false, progress: { _ in })
        let input = AsyncThrowingStream<MicrophoneAudioSample, any Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let lease = MicrophoneAudioLease(samples: input.stream, deviceUniqueID: "synthetic") { input.continuation.finish() }
        let output = try await recognizer.start(lease: lease)
        let matchingInput = AsyncThrowingStream<MemoSpeechText, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let matcher = MemoScriptMatcher(text: script, anchor: nil)
        let matches = await matcher.matches(from: matchingInput.stream)
        var tracking = 0
        let matchingTask = Task {
            do {
                for try await match in matches {
                    if match.isTracking { tracking += 1 }
                }
            } catch { XCTFail("Matching stream failed: \(error)") }
        }
        var snapshots: [MemoSpeechText] = []
        var recognitionError: (any Error)?
        let resultTask = Task {
            do {
                for try await value in output {
                    snapshots.append(value)
                    matchingInput.continuation.yield(value)
                }
            } catch {
                recognitionError = error
            }
            matchingInput.continuation.finish()
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            // Capture-sized packets expose resampling frame rounding that a
            // 100 ms file chunk (an exact ratio) hides.
            let frames: AVAudioFrameCount = 512
            var offset: AVAudioFramePosition = 0
            while offset < file.length {
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
                try file.read(into: pcm, frameCount: frames)
                guard pcm.frameLength > 0 else { break }
                let pts = CMTime(value: offset, timescale: CMTimeScale(file.processingFormat.sampleRate))
                input.continuation.yield(MicrophoneAudioSample(sampleBuffer: try makeSample(pcm, at: pts)))
                offset += AVAudioFramePosition(pcm.frameLength)
                try await Task.sleep(for: .seconds(Double(pcm.frameLength) / file.processingFormat.sampleRate))
            }
            try await Task.sleep(for: .seconds(2))
            await recognizer.cancel()
            await resultTask.value
            await matchingTask.value
        } catch {
            await recognizer.cancel()
            await resultTask.value
            await matchingTask.value
            throw error
        }
        XCTAssertNil(recognitionError, "The live engine must accept the complete short-packet stream: \(String(describing: recognitionError))")
        XCTAssertFalse(snapshots.isEmpty, "The installed model should return live recognition snapshots.")
        if tracking == 0 {
            let began = snapshots.first?.timestamp ?? 0
            for value in snapshots {
                print("Synthetic ASR probe \(value.revision), time=\(value.timestamp - began), final=\(value.isFinal): \(value.text)")
            }
        }
        XCTAssertGreaterThan(tracking, 0, "Actual Apple transcriptions should locate the synthetic manuscript.")
        print("Apple Speech integration: \(snapshots.count) snapshots, \(tracking) reliable manuscript matches")
    }

    private func makeSample(_ pcm: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertEqual(created, noErr)
        let result = try XCTUnwrap(sample)
        let set = CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
        XCTAssertEqual(set, noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }
}

private actor ReleaseCounter {
    var count = 0
    func increment() { count += 1 }
}
