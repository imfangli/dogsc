import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import Speech
import XCTest
@testable import DogSCApp

@MainActor
final class SubtitleSpeechTests: XCTestCase {
    func testEnglishContextFindsTermsWithoutChineseSpaces() {
        let terms = SubtitleSpeechContext.englishTerms(in: "今天介绍Orca软件，IDE里有Agent，也支持GPT-4和AI。")
        XCTAssertEqual(terms, ["AI", "Agent", "GPT-4", "IDE", "Orca"])
    }

    func testTimingUsesAttributedUnitsWithoutInventingCharacterTimes() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Speech timing attributes") }
        var first = AttributedString("介绍 ")
        first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.5, preferredTimescale: 1_000))
        var second = AttributedString("Orca")
        second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1.8, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.6, preferredTimescale: 1_000))
        let text = first + second + AttributedString("。")
        let units = SubtitleSpeechTiming.timedUnits(text: text,
            fallback: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 1_000)))
        XCTAssertEqual(units, [
            .init(text: "介绍 ", start: 1, end: 1.5),
            .init(text: "Orca。", start: 1.8, end: 2.4)
        ])
    }

    func testAbsentWordTimesFallBackToSingleOriginalResultInterval() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Speech timing attributes") }
        var first = AttributedString("已经定位")
        first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.6, preferredTimescale: 1_000))
        let text = first + AttributedString("未提供内部时间的长句")
        let units = SubtitleSpeechTiming.timedUnits(text: text,
            fallback: CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 1_000),
                duration: CMTime(seconds: 2, preferredTimescale: 1_000)))
        XCTAssertEqual(units, [.init(text: "已经定位未提供内部时间的长句", start: 3, end: 5)])
    }

    func testIdenticalTimedRunsAreOneIndivisibleUnit() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Speech timing attributes") }
        let range = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 1_000),
            duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        var first = AttributedString("👩🏽‍💻")
        first.audioTimeRange = range
        var second = AttributedString("café")
        second.audioTimeRange = range
        // A second attribute forces separate runs with the same audio range.
        second.inlinePresentationIntent = .stronglyEmphasized
        let units = SubtitleSpeechTiming.timedUnits(text: first + second, fallback: range)
        XCTAssertEqual(units, [.init(text: "👩🏽‍💻café", start: 2, end: 3)])
    }

    /// Opt-in offline integration: no microphone and no external AI request.
    /// The fixture should exceed eight seconds to catch rolling-window reuse.
    func testInstalledAppleModelCollectsFinalTimedFilmTranscript() async throws {
        guard let path = ProcessInfo.processInfo.environment["DOGSC_SUBTITLE_TEST_AUDIO"] else {
            throw XCTSkip("Set DOGSC_SUBTITLE_TEST_AUDIO to a local synthetic Mandarin audio fixture")
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("Requires macOS 26 and the Apple speech engine")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(tracks.first)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 8)
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        let microphone = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        try microphone.insertTimeRange(range, of: sourceTrack, at: .zero)
        let project = RecorderProject(media: ProjectMediaManifest(screen: .init(relativePath: "screen.mov"),
            microphone: .init(relativePath: "microphone.aiff")))
        let mediaRange = try XCTUnwrap(MediaTimeRange(start: 0, duration: duration))
        let plan = try ProjectTimelineMediaPlan(project: project, primaryVideoRange: mediaRange,
            microphoneRange: mediaRange)
        let media = TimelineCompositionBundle(plan: plan, primaryComposition: composition,
            primaryVideoTrack: video, primaryVideoTracks: [video], primaryVideoComposition: nil,
            systemAudioTrack: nil, microphoneAudioTrack: microphone, cameraComposition: nil, cameraVideoTrack: nil)
        let recognizer = SubtitleSpeechRecognizer()
        let words = try await recognizer.generate(.init(media: media, project: project,
            audioSource: .microphone, sourceDuration: duration))
        XCTAssertGreaterThan(words.count, 10)
        XCTAssertTrue(words.allSatisfy { !$0.sourceRanges.isEmpty && $0.sourceRanges.allSatisfy(\.isValid) })
        XCTAssertLessThan(words.first?.sourceRanges.first?.start ?? .infinity, 8)
        XCTAssertGreaterThan(words.last?.sourceRanges.last?.end ?? 0, 8)
        XCTAssertEqual(Set(words.map(\.id)).count, words.count)
    }
}
