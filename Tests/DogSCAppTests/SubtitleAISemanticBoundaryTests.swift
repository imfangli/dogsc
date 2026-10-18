import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

/// Exercises the request seam and the persistent subtitle timing contract.
/// Stubbed model responses isolate regrouping from model quality and networking.
@MainActor
final class SubtitleAISemanticBoundaryTests: XCTestCase {
    private let configuration = SubtitleAIConfiguration(
        baseURL: "https://example.invalid/v1", model: "test-model")

    func testBoundaryReviewKeepsChineseWordTogetherAndUsesOriginalTiming() async throws {
        let words = semanticWords(["我们就可以去念", "但是", "它有一个问", "题", "他只能按照固定速度播放"])
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                XCTAssertEqual(input.units.map(\.id), Array(1...5))
                XCTAssertEqual(input.existingGroups, [
                    .init(unitIDs: [1, 2, 3], text: "我们就可以去念，但是它有一个问"),
                    .init(unitIDs: [4, 5], text: "题，它只能按照固定速度播放"),
                ])
                return try semanticResponse([
                    .init(unitIDs: [1, 2, 3, 4], text: "我们就可以去念，但是它有一个问题。"),
                    .init(unitIDs: [5], text: "它只能按照固定速度播放。"),
                ], includeInventedTimes: true)
            }
            XCTAssertEqual(input.task, "proofread")
            if input.units.first?.id == 1 {
                return try semanticResponse([.init(unitIDs: [1, 2, 3], text: "我们就可以去念，但是它有一个问")])
            }
            return try semanticResponse([.init(unitIDs: [4, 5], text: "题，它只能按照固定速度播放")])
        }

        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 3).correct(
            words: words, script: "", theme: "", configuration: configuration)
        let document = try semanticDocument(words: words, groups: groups)
        XCTAssertEqual(document.cues.map(\.text), ["我们就可以去念，但是它有一个问题", "它只能按照固定速度播放"])
        let cues = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 5)
        XCTAssertEqual(cues.map(\.startTime), [0, 4])
        XCTAssertEqual(cues.map(\.endTime), [4, 5])
        XCTAssertEqual(SubtitleSRTExporter.export(cues),
            "1\n00:00:00,000 --> 00:00:04,000\n我们就可以去念，但是它有一个问题\n\n2\n00:00:04,000 --> 00:00:05,000\n它只能按照固定速度播放\n")
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try semanticInput($0).task }, ["proofread", "proofread", "reviewBoundary"])
    }

    func testBoundaryReviewPreservesCorrectedEnglishTermAndRegroupsItsUnits() async throws {
        let words = semanticWords(["然后", "他还可以有一个", "这个", " show", " speakernotes", "就是这样的一个窗口"])
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                XCTAssertEqual(input.units.map(\.id), Array(1...6))
                XCTAssertEqual(input.units[4].text, " speakernotes", "The original ASR unit remains the timing anchor")
                XCTAssertEqual(input.existingGroups, [
                    .init(unitIDs: [1, 2, 3, 4], text: "然后它还可以有一个这个 show"),
                    .init(unitIDs: [5, 6], text: "Speaker Notes 就是这样的一个窗口"),
                ], "Boundary review receives first-pass spelling and term corrections")
                return try semanticResponse([
                    .init(unitIDs: [1, 2, 3], text: "然后它还可以有一个这个"),
                    .init(unitIDs: [4, 5], text: "Show Speaker Notes"),
                    .init(unitIDs: [6], text: "就是这样的一个窗口"),
                ])
            }
            XCTAssertEqual(input.task, "proofread")
            if input.units.first?.id == 1 {
                return try semanticResponse([.init(unitIDs: [1, 2, 3, 4], text: "然后它还可以有一个这个 show")])
            }
            return try semanticResponse([.init(unitIDs: [5, 6], text: "Speaker Notes 就是这样的一个窗口")])
        }

        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 4).correct(
            words: words, script: "", theme: "", configuration: configuration)
        let document = try semanticDocument(words: words, groups: groups)
        XCTAssertEqual(document.cues.map(\.text), ["然后它还可以有一个这个", "Show Speaker Notes", "就是这样的一个窗口"])
        XCTAssertEqual(document.cues[1].wordIDs, Array(words[3...4].map(\.id)))
        let cues = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 6)
        XCTAssertEqual(cues.map(\.startTime), [0, 3, 5])
        XCTAssertEqual(cues.map(\.endTime), [3, 5, 6])
        XCTAssertEqual(SubtitleSRTExporter.export(cues),
            "1\n00:00:00,000 --> 00:00:03,000\n然后它还可以有一个这个\n\n2\n00:00:03,000 --> 00:00:05,000\nShow Speaker Notes\n\n3\n00:00:05,000 --> 00:00:06,000\n就是这样的一个窗口\n")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testBoundaryReviewMovesWholeClauseWithChineseWordInsteadOfOnlyLastCharacter() async throws {
        let words = semanticWords(["再一个是它生成字幕这一块", "在", " AI", "中", "文", "这块处理得并不是很好", "识别出来并不是很准确"])
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                XCTAssertEqual(input.units.map(\.id), Array(1...7))
                return try semanticResponse([
                    .init(unitIDs: [1], text: "再一个是它生成字幕这一块"),
                    .init(unitIDs: [2, 3, 4, 5, 6, 7], text: "在 AI 中文这块处理得并不是很好，识别出来并不是很准确"),
                ])
            }
            XCTAssertEqual(input.task, "proofread")
            if input.units.first?.id == 1 {
                return try semanticResponse([.init(unitIDs: [1, 2, 3, 4], text: "再一个是它生成字幕这一块，在 AI 中")])
            }
            return try semanticResponse([.init(unitIDs: [5, 6, 7], text: "文这块处理得并不是很好，识别出来并不是很准确")])
        }

        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 4).correct(
            words: words, script: "", theme: "", configuration: configuration)
        let document = try semanticDocument(words: words, groups: groups)
        XCTAssertEqual(document.cues.map(\.text), [
            "再一个是它生成字幕这一块", "在 AI 中文这块处理得并不是很好，识别出来并不是很准确",
        ])
        XCTAssertEqual(document.cues.map(\.wordIDs), [[words[0].id], Array(words[1...].map(\.id))])
        let cues = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 7)
        XCTAssertEqual(cues.map(\.startTime), [0, 1])
        XCTAssertEqual(cues.map(\.endTime), [1, 7])
        XCTAssertEqual(SubtitleSRTExporter.export(cues),
            "1\n00:00:00,000 --> 00:00:01,000\n再一个是它生成字幕这一块\n\n2\n00:00:01,000 --> 00:00:07,000\n在 AI 中文这块处理得并不是很好，识别出来并不是很准确\n")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testBoundaryReviewDoesNotCrossProtectedManualCue() async throws {
        let words = semanticWords(["一个", "问", "人工保留", "题", "继续"])
        var document = SubtitleDocument(words: words, cues: words.map {
            SubtitleCue(wordIDs: [$0.id], text: $0.text)
        })
        let manualID = document.cues[2].id
        try document.updateCueText(id: manualID, text: "人工确认过的字幕")
        let manualCue = document.cues[2]
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            XCTAssertEqual(input.task, "proofread", "Manual ownership is a hard boundary for seam repair")
            guard input.task == "proofread" else { throw SubtitleAIError.invalidResponse }
            return try semanticResponse([.init(unitIDs: input.units.map(\.id), text: input.units.first?.id == 1 ? "一个问" : "题，继续")])
        }

        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 2).correct(
            words: words, protectedWordIDs: [words[2].id], script: "", theme: "", configuration: configuration)
        try document.applyCorrections(groups)
        XCTAssertEqual(document.words, words)
        XCTAssertEqual(document.cues.first { $0.id == manualID }, manualCue)
        XCTAssertEqual(document.cues.map(\.text), ["一个问", "人工确认过的字幕", "题，继续"])
        XCTAssertEqual(groups.flatMap(\.wordIDs), words.enumerated().filter { $0.offset != 2 }.map { $0.element.id })
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try semanticInput($0).units.map(\.id) }, [[1, 2], [4, 5]])
    }

    func testInvalidLaterBoundaryReviewReturnsNoPartialDocumentChanges() async throws {
        let words = semanticWords(["第一个", "问", "题和", "第二个问", "题", "继续"])
        var document = SubtitleDocument()
        document.setRecognizedWords(words)
        let original = document
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                if input.units.last?.id == 4 {
                    return try semanticResponse([
                        .init(unitIDs: [1, 2, 3], text: "第一个问题和"),
                        .init(unitIDs: [4], text: "第二个问"),
                    ])
                }
                // The first repair succeeded; a later repair must still pass
                // exact ID coverage before any result is returned to the editor.
                let ids = input.units.map(\.id)
                return try semanticResponse([.init(unitIDs: Array(ids.dropLast()), text: "遗漏了一个单元")])
            }
            XCTAssertEqual(input.task, "proofread")
            let text: String
            switch input.units.first?.id {
            case 1: text = "第一个问"
            case 3: text = "题和第二个问"
            default: text = "题继续"
            }
            return try semanticResponse([.init(unitIDs: input.units.map(\.id), text: text)])
        }

        do {
            let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 2).correct(
                words: words, script: "", theme: "", configuration: configuration)
            try document.applyCorrections(groups)
            XCTFail("An invalid later repair must prevent the complete result from being applied")
        } catch {
            XCTAssertEqual(error as? SubtitleAIError, .invalidResponse)
        }
        XCTAssertEqual(document, original)
        let requests = await transport.requests
        XCTAssertEqual(try requests.filter { try semanticInput($0).task == "reviewBoundary" }.count, 2)
    }

    func testBoundaryReviewLeavesOtherCuesOutsideWindowUnchanged() async throws {
        let words = semanticWords(["前", "段", "一个", "问", "题", "继续", "后", "段"])
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                XCTAssertEqual(input.units.map(\.id), [3, 4, 5, 6])
                return try semanticResponse([
                    .init(unitIDs: [3, 4, 5], text: "一个问题"),
                    .init(unitIDs: [6], text: "继续"),
                ])
            }
            if input.units.first?.id == 1 {
                return try semanticResponse([
                    .init(unitIDs: [1, 2], text: "前段已经校对"),
                    .init(unitIDs: [3, 4], text: "一个问"),
                ])
            }
            return try semanticResponse([
                .init(unitIDs: [5, 6], text: "题，继续"),
                .init(unitIDs: [7, 8], text: "后段已经校对"),
            ])
        }
        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 4).correct(
            words: words, script: "", theme: "", configuration: configuration)
        let document = try semanticDocument(words: words, groups: groups)
        XCTAssertEqual(document.cues.map(\.text), ["前段已经校对", "一个问题", "继续", "后段已经校对"])
        XCTAssertEqual(document.cues.map(\.wordIDs), [
            Array(words[0...1].map(\.id)), Array(words[2...4].map(\.id)),
            [words[5].id], Array(words[6...7].map(\.id)),
        ])
    }

    func testRepeatedModelMergesCannotGrowBoundaryWindowWithoutLimit() async throws {
        let words = semanticWords(["一", "二", "三", "四", "五", "六"])
        let transport = SemanticSubtitleTransport { request in
            let input = try semanticInput(request)
            if input.task == "reviewBoundary" {
                XCTAssertLessThanOrEqual(input.units.count, 4)
            }
            return try semanticResponse([.init(unitIDs: input.units.map(\.id), text: "已校对")])
        }
        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 2).correct(
            words: words, script: "", theme: "", configuration: configuration)
        _ = try semanticDocument(words: words, groups: groups)
        let requests = await transport.requests
        let reviews = try requests.filter { try semanticInput($0).task == "reviewBoundary" }
        XCTAssertEqual(reviews.count, 1, "A subsequent oversized window retains the existing correction")
        XCTAssertEqual(groups.map(\.wordIDs), [Array(words[0...3].map(\.id)), Array(words[4...5].map(\.id))])
    }

    private func semanticDocument(words: [SubtitleWord], groups: [SubtitleCorrectionGroup]) throws -> SubtitleDocument {
        XCTAssertEqual(groups.flatMap(\.wordIDs), words.map(\.id))
        var document = SubtitleDocument()
        document.setRecognizedWords(words)
        try document.applyCorrections(groups)
        XCTAssertEqual(document.words, words, "Regrouping must preserve every original ASR timing anchor")
        XCTAssertTrue(document.cues.allSatisfy { !$0.isManuallyEdited && $0.manualSourceRanges == nil })
        try document.validate()
        return document
    }
}

private actor SemanticSubtitleTransport: SubtitleAITransport {
    private(set) var requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) async throws -> Data

    init(responder: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.responder = responder
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = try await responder(request)
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url),
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
}

private struct SemanticInput: Decodable, Sendable {
    struct Unit: Decodable, Sendable {
        let id: Int
        let text: String
    }
    let task: String
    let units: [Unit]
    let existingGroups: [SemanticGroup]?
}

private struct SemanticGroup: Codable, Equatable, Sendable {
    let unitIDs: [Int]
    let text: String
}

private func semanticWords(_ texts: [String]) -> [SubtitleWord] {
    texts.enumerated().map { index, text in
        SubtitleWord(text: text, sourceRanges: [.init(start: Double(index), end: Double(index + 1))])
    }
}

private func semanticInput(_ request: URLRequest) throws -> SemanticInput {
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    let content = try XCTUnwrap(messages.last?["content"])
    return try JSONDecoder().decode(SemanticInput.self, from: Data(content.utf8))
}

private func semanticResponse(_ groups: [SemanticGroup], includeInventedTimes: Bool = false) throws -> Data {
    let encoded = try JSONEncoder().encode(groups)
    var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    if includeInventedTimes {
        for index in values.indices {
            values[index]["start"] = 999
            values[index]["end"] = 1_000
        }
    }
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["groups": values]), as: UTF8.self)
    return try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content], "finish_reason": "stop"]],
    ])
}
