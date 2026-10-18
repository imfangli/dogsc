import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

final class EditorSubtitleExportTests: XCTestCase {
    func testSelectedRangeClipsBothEdgesAndRebasesCorrectedText() throws {
        let project = subtitleProject()
        let range = try XCTUnwrap(MediaTimeRange(start: 0.5, duration: 2))
        let contents = try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 4, outputRange: range)

        XCTAssertEqual(contents,
            "1\n00:00:00,000 --> 00:00:00,300\n首句校对文本\n\n2\n00:00:00,600 --> 00:00:01,400\nSpeaker Notes 校对术语\n\n3\n00:00:01,700 --> 00:00:02,000\n尾句 AI 校对文本\n")
        XCTAssertFalse(contents.contains("原始"), "Selection edges retain displayed corrections even inside a timed ASR unit")
    }

    func testSelectedRangeOmitsCuesOutsideItsWindow() throws {
        let project = subtitleProject()
        let range = try XCTUnwrap(MediaTimeRange(start: 1, duration: 1))
        XCTAssertEqual(try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 4, outputRange: range),
            "1\n00:00:00,100 --> 00:00:00,900\nSpeaker Notes 校对术语\n")
    }

    func testFullExportClipsLastCueAtOutputDuration() throws {
        XCTAssertEqual(try EditorSubtitleExport.contents(project: subtitleProject(),
            sourceDuration: 4, outputDuration: 3.5),
            "1\n00:00:00,200 --> 00:00:00,800\n首句校对文本\n\n2\n00:00:01,100 --> 00:00:01,900\nSpeaker Notes 校对术语\n\n3\n00:00:02,200 --> 00:00:02,800\n尾句 AI 校对文本\n\n4\n00:00:03,100 --> 00:00:03,500\n最后一句校对文本\n")
    }

    func testDisabledBurnInStillExportsIndependentSubtitles() throws {
        var project = subtitleProject()
        let enabled = try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 4)
        project.subtitles.enabled = false
        XCTAssertEqual(try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 4), enabled)
        XCTAssertFalse(enabled.isEmpty)
    }

    func testCutsReorderAndPlaybackRatesUseFinalProjectClock() throws {
        let words = [
            SubtitleWord(text: "原始第一", sourceRanges: [.init(start: 0.2, end: 0.8)]),
            SubtitleWord(text: "原始第二", sourceRanges: [.init(start: 1.2, end: 1.8)]),
            SubtitleWord(text: "原始第三", sourceRanges: [.init(start: 3.2, end: 3.8)]),
        ]
        let project = RecorderProject(
            timeline: ProjectTimeline(sourceSequence: .edited([
                RecordingSegment(sourceStart: 3, sourceDuration: 1, playbackRate: 2),
                RecordingSegment(sourceStart: 1, sourceDuration: 1, playbackRate: 0.5),
            ])),
            subtitles: SubtitleDocument(enabled: true, words: words, cues: [
                .init(wordIDs: [words[0].id], text: "第一句校对文本"),
                .init(wordIDs: [words[1].id], text: "第二句校对文本"),
                .init(wordIDs: [words[2].id], text: "第三句校对文本"),
            ]))

        XCTAssertEqual(try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 2.5),
            "1\n00:00:00,100 --> 00:00:00,400\n第三句校对文本\n\n2\n00:00:00,900 --> 00:00:02,100\n第二句校对文本\n")
        let range = try XCTUnwrap(MediaTimeRange(start: 0.25, duration: 1))
        XCTAssertEqual(try EditorSubtitleExport.contents(project: project,
            sourceDuration: 4, outputDuration: 2.5, outputRange: range),
            "1\n00:00:00,000 --> 00:00:00,150\n第三句校对文本\n\n2\n00:00:00,650 --> 00:00:01,000\n第二句校对文本\n")
        XCTAssertEqual(project.subtitles.words, words)
    }

    func testEmptyWindowExportsNoSubtitleEntries() throws {
        let range = try XCTUnwrap(MediaTimeRange(start: 2, duration: 0.1))
        XCTAssertEqual(try EditorSubtitleExport.contents(project: subtitleProject(),
            sourceDuration: 4, outputDuration: 4, outputRange: range), "")
    }

    func testSubtitlePathSharesFinalMediaNameAndDirectory() {
        let media = URL(fileURLWithPath: "/tmp/作品导出/屏幕 演示-30fps-2.mp4")
        XCTAssertEqual(EditorSubtitleExport.outputURL(for: media),
            URL(fileURLWithPath: "/tmp/作品导出/屏幕 演示-30fps-2.srt"))
        XCTAssertEqual(EditorSubtitleExport.outputURL(for: media.deletingPathExtension().appendingPathExtension("m4a")),
            URL(fileURLWithPath: "/tmp/作品导出/屏幕 演示-30fps-2.srt"))
    }

    private func subtitleProject() -> RecorderProject {
        let ranges: [SubtitleTimeRange] = [
            .init(start: 0.2, end: 0.8), .init(start: 1.1, end: 1.9),
            .init(start: 2.2, end: 2.8), .init(start: 3.1, end: 3.6),
        ]
        let words = ranges.enumerated().map { index, range in
            SubtitleWord(text: "原始单元\(index)", sourceRanges: [range])
        }
        let texts = ["首句校对文本", "Speaker Notes 校对术语", "尾句 AI 校对文本", "最后一句校对文本"]
        return RecorderProject(subtitles: SubtitleDocument(enabled: true, words: words,
            cues: zip(words, texts).map { .init(wordIDs: [$0.id], text: $1) }))
    }
}
