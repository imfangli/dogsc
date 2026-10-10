import AVFoundation
import CoreMedia
import XCTest
@testable import DogSCApp

@MainActor
final class MemoSpeechTimelineTests: XCTestCase {
    /// Capture delivers short source-rate packets; the converter rounds each
    /// output to whole target-rate frames. Using the unadjusted capture PTS
    /// overlaps the preceding output for these common microphone formats.
    func testResampledMicrophonePacketsNeverOverlap() throws {
        let targetRate = 16_000.0
        let targetFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
            channels: 1, interleaved: false
        ))
        for sourceRate in [44_100.0, 48_000.0] {
            for frames in [512, 1024] {
                let sourceFormat = try XCTUnwrap(AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                    channels: 1, interleaved: false
                ))
                let converter = try XCTUnwrap(AVAudioConverter(from: sourceFormat, to: targetFormat))
                let origin = CMTime(value: 3_000_000_123, timescale: 1_000_000_000)
                var timeline = MemoSpeechAudioTimeline()
                var previousEnd: CMTime?
                var lastCaptureStart = CMTime.zero
                var lastDuration = CMTime.zero
                var outputCount = 0
                for index in 0..<256 {
                    let captureStart = CMTime(
                        value: Int64(index * frames), timescale: CMTimeScale(sourceRate)
                    )
                    let raw = try makeCaptureSample(
                        format: sourceFormat, frames: frames, at: origin + captureStart
                    )
                    let source = try MemoSpeechPCMBuffer.copy(raw)
                    let capacity = AVAudioFrameCount(ceil(Double(frames) * targetRate / sourceRate) + 64)
                    let converted = try XCTUnwrap(AVAudioPCMBuffer(
                        pcmFormat: targetFormat, frameCapacity: capacity
                    ))
                    var supplied = false
                    var error: NSError?
                    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                        if supplied { inputStatus.pointee = .noDataNow; return nil }
                        supplied = true
                        inputStatus.pointee = .haveData
                        return source
                    }
                    if status == .error { throw try XCTUnwrap(error) }
                    guard converted.frameLength > 0 else { continue }
                    let start = try XCTUnwrap(timeline.startTime(
                        captureTime: raw.presentationTimeStamp,
                        frameCount: converted.frameLength, sampleRate: targetRate
                    ))
                    let context = "\(sourceRate) Hz, \(frames) source frames, packet \(index)"
                    XCTAssertEqual(start.timescale, CMTimeScale(targetRate), context)
                    if let previousEnd {
                        XCTAssertGreaterThanOrEqual(CMTimeCompare(start, previousEnd), 0, context)
                    } else {
                        XCTAssertEqual(CMTimeCompare(start, .zero), 0, context)
                    }
                    let duration = CMTime(
                        value: Int64(converted.frameLength), timescale: CMTimeScale(targetRate)
                    )
                    previousEnd = start + duration
                    lastCaptureStart = captureStart
                    lastDuration = duration
                    outputCount += 1
                }
                XCTAssertGreaterThan(outputCount, 200)
                // Rounding repairs must remain at frame precision instead of
                // accumulating a delay over hundreds of continuous packets.
                let finalEnd = try XCTUnwrap(previousEnd)
                XCTAssertLessThanOrEqual(
                    abs((finalEnd - (lastCaptureStart + lastDuration)).seconds),
                    2 / targetRate + 0.000_000_001
                )
            }
        }
    }

    func testRoundedAndBackwardsCaptureTimestampsClampToConvertedEnd() throws {
        var timeline = MemoSpeechAudioTimeline()
        let origin = CMTime(value: 123, timescale: 1)
        XCTAssertEqual(try XCTUnwrap(timeline.startTime(
            captureTime: origin, frameCount: 171, sampleRate: 16_000
        )).value, 0)
        let next = try XCTUnwrap(timeline.startTime(
            captureTime: origin + CMTime(value: 512, timescale: 48_000),
            frameCount: 170, sampleRate: 16_000
        ))
        XCTAssertEqual(next, CMTime(value: 171, timescale: 16_000))
        let backwards = try XCTUnwrap(timeline.startTime(
            captureTime: origin, frameCount: 160, sampleRate: 16_000
        ))
        XCTAssertEqual(backwards, CMTime(value: 341, timescale: 16_000))
    }

    func testTrueCaptureGapIsPreserved() throws {
        var timeline = MemoSpeechAudioTimeline()
        let origin = CMTime(value: 7, timescale: 1)
        _ = try XCTUnwrap(timeline.startTime(
            captureTime: origin, frameCount: 160, sampleRate: 16_000
        ))
        let afterGap = try XCTUnwrap(timeline.startTime(
            captureTime: origin + CMTime(value: 1, timescale: 2),
            frameCount: 160, sampleRate: 16_000
        ))
        XCTAssertEqual(afterGap, CMTime(value: 8_000, timescale: 16_000))
        XCTAssertEqual(afterGap.seconds - 0.01, 0.49, accuracy: 0.000_000_001)
        let next = try XCTUnwrap(timeline.startTime(
            captureTime: origin + CMTime(value: 51, timescale: 100),
            frameCount: 160, sampleRate: 16_000
        ))
        XCTAssertEqual(next, CMTime(value: 8_160, timescale: 16_000))
    }

    func testRelativeCaptureTimeRoundsUpToWholeTargetFrame() throws {
        var timeline = MemoSpeechAudioTimeline()
        let origin = CMTime(value: 1, timescale: 1)
        _ = try XCTUnwrap(timeline.startTime(
            captureTime: origin, frameCount: 1, sampleRate: 16_000
        ))
        let next = try XCTUnwrap(timeline.startTime(
            captureTime: origin + CMTime(value: 100, timescale: 44_100),
            frameCount: 1, sampleRate: 16_000
        ))
        // 100 source frames correspond to 36.281... target frames.
        XCTAssertEqual(next, CMTime(value: 37, timescale: 16_000))
    }

    func testInvalidAndEmptyBuffersDoNotEstablishOrAdvanceTimeline() throws {
        var timeline = MemoSpeechAudioTimeline()
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertNil(timeline.startTime(captureTime: time, frameCount: 160, sampleRate: 16_000))
        }
        XCTAssertNil(timeline.startTime(
            captureTime: CMTime(value: 1, timescale: 1), frameCount: 0, sampleRate: 16_000
        ))
        for rate in [0.0, -1.0, .nan, .infinity, 16_000.5, Double(Int32.max) + 1] {
            XCTAssertNil(timeline.startTime(
                captureTime: CMTime(value: 2, timescale: 1), frameCount: 160, sampleRate: rate
            ))
        }
        let origin = CMTime(value: 3, timescale: 1)
        XCTAssertEqual(try XCTUnwrap(timeline.startTime(
            captureTime: origin, frameCount: 160, sampleRate: 16_000
        )), CMTime(value: 0, timescale: 16_000))
        XCTAssertNil(timeline.startTime(
            captureTime: CMTime(value: 100, timescale: 1), frameCount: 0, sampleRate: 16_000
        ))
        XCTAssertNil(timeline.startTime(
            captureTime: CMTime(value: 100, timescale: 1), frameCount: 160, sampleRate: .nan
        ))
        let next = try XCTUnwrap(timeline.startTime(
            captureTime: origin + CMTime(value: 1, timescale: 100),
            frameCount: 160, sampleRate: 16_000
        ))
        XCTAssertEqual(next, CMTime(value: 160, timescale: 16_000))
    }

    private func makeCaptureSample(
        format: AVAudioFormat, frames: Int, at time: CMTime
    ) throws -> CMSampleBuffer {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        XCTAssertEqual(status, noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }
}
