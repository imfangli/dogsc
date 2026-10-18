import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

@MainActor
final class SubtitleAIClientTests: XCTestCase {
    private let configuration = SubtitleAIConfiguration(baseURL: "https://example.invalid/v1", model: "test-model", apiKey: "secret-test-key")

    func testCorrectionSendsOnlyTextAndIDsAndFormatsResult() async throws {
        let words = makeWords(["今天", "介绍", "Orca"])
        let transport = SubtitleStubTransport { _, _ in
            try subtitleResponse(groups: [.init(unitIDs: [1, 2, 3], text: "今天介绍Orca。")])
        }
        let groups = try await SubtitleAIClient(transport: transport).correct(words: words,
            script: "介绍 Orca 的口播稿", theme: "开发工具", configuration: configuration)
        XCTAssertEqual(groups, [.init(wordIDs: words.map(\.id), text: "今天介绍 Orca")])
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-key")
        let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(requestJSON["response_format"])
        XCTAssertEqual(Set(requestJSON.keys), Set(["model", "messages"]))
        XCTAssertEqual(request.timeoutInterval, SubtitleAINetworkPolicy.requestTimeout)
        let messages = try XCTUnwrap(requestJSON["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.last?["content"])
        let input = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let units = try XCTUnwrap(input["units"] as? [[String: Any]])
        XCTAssertEqual(units.count, 3)
        XCTAssertTrue(units.allSatisfy { Set($0.keys) == Set(["id", "text"]) })
        XCTAssertEqual(units.compactMap { $0["id"] as? Int }, [1, 2, 3])
        XCTAssertEqual(input["script"] as? String, "介绍 Orca 的口播稿")
        XCTAssertEqual(input["theme"] as? String, "开发工具")
        XCTAssertFalse(content.contains("sourceRanges"))
        XCTAssertFalse(content.contains("secret-test-key"))
        XCTAssertTrue(words.allSatisfy { !content.contains($0.id.uuidString) })
    }

    func testInvalidOrderedCoverageRejected() async throws {
        let words = makeWords(["一", "二", "三"])
        for ids in [[3, 2, 1], [1, 3], [1, 2, 2], [1, 2, 3, 4], [0, 2, 3], [-1, 2, 3]] {
            let transport = SubtitleStubTransport { _, _ in
                try subtitleResponse(groups: [.init(unitIDs: ids, text: "字幕")])
            }
            do {
                _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                    script: "", theme: "", configuration: configuration)
                XCTFail("Invalid coverage was accepted")
            } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
        }
    }

    func testNonIntegerIDsAreRejected() async throws {
        let words = makeWords(["字幕"])
        for id in ["\"1\"", "1.5", "true", "null", "9223372036854775808", "\"\(words[0].id)\""] {
            let content = "{\"groups\":[{\"unitIDs\":[\(id)],\"text\":\"字幕\"}]}"
            let transport = SubtitleStubTransport { _, _ in try subtitleChat(content: content) }
            do {
                _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                    script: "", theme: "", configuration: configuration)
                XCTFail("Non-integer ID was accepted: \(id)")
            } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
        }
    }

    func testDefaultBatchLimitsAndAbsoluteIDsMapBackToOriginalWords() async throws {
        let words = makeWords((0..<600).map { "字\($0)" + ([255, 511].contains($0) ? "。" : "") })
        let transport = SubtitleStubTransport { request, _ in
            try subtitleResponse(groups: [.init(unitIDs: subtitleUnitIDs(request), text: "校对结果")])
        }
        let groups = try await SubtitleAIClient(transport: transport).correct(words: words,
            script: "", theme: "", configuration: configuration)
        XCTAssertEqual(groups.flatMap(\.wordIDs), words.map(\.id))
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try subtitleUnitIDs($0).count }, [256, 256, 88])
        XCTAssertEqual(try requests.map(subtitleUnitIDs).flatMap { $0 }, Array(1...600))
        XCTAssertTrue(requests.allSatisfy { request in
            guard let body = request.httpBody else { return false }
            let text = String(decoding: body, as: UTF8.self)
            return words.allSatisfy { !text.contains($0.id.uuidString) }
        })
    }

    func testDefaultCharacterLimitSplitsBeforeThreeThousandCharacters() async throws {
        let words = makeWords(Array(repeating: String(repeating: "字", count: 1_000) + "。", count: 4))
        let transport = SubtitleStubTransport { request, _ in
            try subtitleResponse(groups: [.init(unitIDs: subtitleUnitIDs(request), text: "校对结果")])
        }
        _ = try await SubtitleAIClient(transport: transport).correct(words: words,
            script: "", theme: "", configuration: configuration)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let units = try XCTUnwrap(try subtitleInput(request)["units"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(units.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }, 3_000)
        }
    }

    func testMalformedAndEmptyCorrectedTextRejected() async throws {
        let words = makeWords(["你好"])
        for content in ["not json", "{\"groups\":[]}",
            "{\"groups\":[{\"unitIDs\":[1],\"text\":\"。。。\"}]}"] {
            let transport = SubtitleStubTransport { _, _ in try subtitleChat(content: content) }
            do {
                _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                    script: "", theme: "", configuration: configuration)
                XCTFail("Malformed output was accepted")
            } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
        }
    }

    func testCompatibleMarkdownJSONAcceptedWithoutTrustingModelTimes() async throws {
        let words = makeWords(["你好"])
        let original = words[0].sourceRanges
        let content = "```json\n{\"groups\":[{\"unitIDs\":[1],\"text\":\"你好。\",\"start\":999,\"end\":1000}]}\n```"
        let transport = SubtitleStubTransport { _, _ in try subtitleChat(content: content) }
        let groups = try await SubtitleAIClient(transport: transport).correct(words: words,
            script: "", theme: "", configuration: configuration)
        XCTAssertEqual(groups[0].text, "你好")
        XCTAssertEqual(groups[0].wordIDs, [words[0].id])
        var document = SubtitleDocument()
        document.setRecognizedWords(words)
        try document.applyCorrections(groups)
        XCTAssertEqual(document.words[0].sourceRanges, original)
        XCTAssertNil(document.cues[0].manualSourceRanges)
        XCTAssertEqual(words[0].sourceRanges, original)
    }

    func testTruncatedModelResponseIsRejected() async throws {
        let words = makeWords(["你好"])
        let transport = SubtitleStubTransport { _, _ in
            let groupsData = try JSONEncoder().encode([SubtitleTestCorrectionGroup(unitIDs: [1], text: "你好")])
            let content = "{\"groups\":" + String(decoding: groupsData, as: UTF8.self) + "}"
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "length"]]])
        }
        do {
            _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                script: "", theme: "", configuration: configuration)
            XCTFail("Truncated response was accepted")
        } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
    }

    func testProviderErrorsNeverExposeResponseBody() async throws {
        let words = makeWords(["你好"])
        for (status, expected) in [(401, SubtitleAIError.authenticationFailed),
            (403, .authenticationFailed), (404, .endpointNotFound), (301, .redirected),
            (307, .redirected), (308, .redirected), (429, .rateLimited), (500, .serviceUnavailable)] {
            let transport = SubtitleStubTransport(statusCode: status) { _, _ in
                Data("secret-test-key private transcript".utf8)
            }
            do {
                _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                    script: "", theme: "", configuration: configuration)
                XCTFail("Service error was accepted")
            } catch {
                XCTAssertEqual(error as? SubtitleAIError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-test-key"))
            }
        }
    }

    func testLongBatchesHaveReadOnlyContextAndBoundedScript() async throws {
        let words = makeWords((0..<11).map { "字幕\($0)" })
        let transport = SubtitleStubTransport { request, _ in
            let input = try subtitleInput(request)
            if input["task"] as? String == "reviewBoundary" {
                let existing = try XCTUnwrap(input["existingGroups"] as? [[String: Any]])
                return try subtitleResponse(groups: existing.map {
                    .init(unitIDs: try XCTUnwrap($0["unitIDs"] as? [Int]),
                        text: try XCTUnwrap($0["text"] as? String))
                })
            }
            return try subtitleResponse(groups: [.init(unitIDs: subtitleUnitIDs(request), text: "校对结果")])
        }
        let script = String(repeating: "很长的口播参考稿。", count: 3_000)
        let groups = try await SubtitleAIClient(transport: transport, batchUnitLimit: 4).correct(
            words: words, script: script, theme: "", configuration: configuration)
        XCTAssertEqual(groups.flatMap(\.wordIDs), words.map(\.id))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        let batches = try requests.filter { try subtitleInput($0)["task"] as? String == "proofread" }
        XCTAssertEqual(batches.count, 3)
        for (index, request) in batches.enumerated() {
            let input = try subtitleInput(request)
            XCTAssertLessThanOrEqual((input["script"] as? String)?.count ?? 0, 6_000)
            XCTAssertLessThanOrEqual((input["units"] as? [[String: Any]])?.count ?? 0, 4)
            XCTAssertEqual(try subtitleUnitIDs(request), Array((index * 4 + 1)...min((index + 1) * 4, 11)))
            if index > 0 { XCTAssertFalse((input["contextBefore"] as? [String])?.isEmpty ?? true) }
        }
        for request in requests {
            XCTAssertLessThanOrEqual((try subtitleInput(request)["script"] as? String)?.count ?? 0, 6_000)
        }
    }

    func testProtectedManualGapCreatesSeparateBatches() async throws {
        let words = makeWords(["前", "手改", "后"])
        let transport = SubtitleStubTransport { request, _ in
            return try subtitleResponse(groups: [.init(unitIDs: subtitleUnitIDs(request), text: "校对")])
        }
        let groups = try await SubtitleAIClient(transport: transport).correct(words: words,
            protectedWordIDs: [words[1].id], script: "", theme: "", configuration: configuration)
        XCTAssertEqual(groups.map(\.wordIDs), [[words[0].id], [words[2].id]])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requests.map(subtitleUnitIDs), [[1], [3]])
    }

    func testReadOnlyContextIDCannotBeReturnedAsEditableUnit() async throws {
        let words = makeWords(["前", "手改", "后"])
        let transport = SubtitleStubTransport { _, _ in
            try subtitleResponse(groups: [.init(unitIDs: [1, 2], text: "企图包含手改内容")])
        }
        do {
            _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                protectedWordIDs: [words[1].id], script: "", theme: "", configuration: configuration)
            XCTFail("A protected context unit was accepted")
        } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
        let requests = await transport.requests
        let input = try subtitleInput(XCTUnwrap(requests.first))
        XCTAssertEqual(input["contextAfter"] as? [String], ["手改", "后"])
    }

    func testAllProtectedDoesNotMakeRequest() async throws {
        let words = makeWords(["手改"])
        let transport = SubtitleStubTransport { _, _ in throw SubtitleAIError.networkFailure }
        let groups = try await SubtitleAIClient(transport: transport).correct(words: words,
            protectedWordIDs: Set(words.map(\.id)), script: "", theme: "", configuration: configuration)
        XCTAssertTrue(groups.isEmpty)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLaterBatchFailureReturnsNoPartialChangesAndSafeError() async throws {
        let words = makeWords(["前", "后"])
        let transport = SubtitleStubTransport { request, index in
            if index == 1 { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "secret-test-key private transcript"]) }
            return try subtitleResponse(groups: [.init(unitIDs: subtitleUnitIDs(request), text: "结果")])
        }
        do {
            _ = try await SubtitleAIClient(transport: transport, batchUnitLimit: 1).correct(
                words: words, script: "", theme: "", configuration: configuration)
            XCTFail("Expected atomic failure")
        } catch {
            XCTAssertEqual(error as? SubtitleAIError, .networkFailure)
            XCTAssertFalse(error.localizedDescription.contains("secret-test-key"))
            XCTAssertFalse(error.localizedDescription.contains("private transcript"))
        }
        XCTAssertEqual(words.map(\.text), ["前", "后"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "A failed request is not retried automatically")
    }

    func testSafeNetworkErrorClassificationDoesNotExposeSensitiveUserInfo() async throws {
        let words = makeWords(["字幕"])
        let cases: [(URLError.Code, SubtitleAIError)] = [
            (.timedOut, .timedOut), (.cannotFindHost, .dnsFailure), (.dnsLookupFailed, .dnsFailure),
            (.cannotConnectToHost, .connectionFailure), (.networkConnectionLost, .connectionFailure),
            (.secureConnectionFailed, .tlsFailure), (.serverCertificateUntrusted, .tlsFailure),
            (.serverCertificateHasBadDate, .tlsFailure), (.serverCertificateHasUnknownRoot, .tlsFailure),
            (.serverCertificateNotYetValid, .tlsFailure), (.clientCertificateRequired, .tlsFailure),
            (.clientCertificateRejected, .tlsFailure), (.appTransportSecurityRequiresSecureConnection, .insecureHTTPBlocked),
            (.notConnectedToInternet, .offline), (.dataNotAllowed, .offline), (.badServerResponse, .networkFailure)
        ]
        for (code, expected) in cases {
            let transport = SubtitleStubTransport { _, _ in
                throw NSError(domain: NSURLErrorDomain, code: code.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "secret-test-key private transcript",
                        NSURLErrorFailingURLStringErrorKey: "https://example.invalid/?key=secret-test-key"])
            }
            do {
                _ = try await SubtitleAIClient(transport: transport).correct(words: words,
                    script: "", theme: "", configuration: configuration)
                XCTFail("Expected network failure")
            } catch {
                XCTAssertEqual(error as? SubtitleAIError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-test-key"))
                XCTAssertFalse(error.localizedDescription.contains("private transcript"))
                XCTAssertFalse(error.localizedDescription.contains("example.invalid"))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testSharedTimeoutPolicyHasNoOldTwoMinuteResourceLimit() {
        XCTAssertEqual(SubtitleAINetworkPolicy.requestTimeout, 300)
        XCTAssertEqual(SubtitleAINetworkPolicy.resourceTimeout, 600)
        let settings = SubtitleAINetworkPolicy.sessionConfiguration()
        XCTAssertEqual(settings.timeoutIntervalForRequest, 300)
        XCTAssertEqual(settings.timeoutIntervalForResource, 600)
        XCTAssertNil(settings.urlCache)
    }

    func testConnectionProbeSendsOnlyMinimalFixedPrompt() async throws {
        let transport = SubtitleStubTransport { _, _ in try subtitleChat(content: "OK") }
        try await SubtitleAIClient(transport: transport).testConnection(configuration: configuration)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.timeoutInterval, 300)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "messages"]))
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "Reply OK"]])
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("secret-test-key"))
    }

    func testConnectionProbeUsesSameHTTPErrorMappingAndRejectsMalformedEnvelope() async throws {
        let badPath = SubtitleStubTransport(statusCode: 404) { _, _ in Data() }
        do {
            try await SubtitleAIClient(transport: badPath).testConnection(configuration: configuration)
            XCTFail("Invalid path was accepted")
        } catch { XCTAssertEqual(error as? SubtitleAIError, .endpointNotFound) }
        for data in [Data("OK".utf8), try JSONSerialization.data(withJSONObject: ["choices": []])] {
            let transport = SubtitleStubTransport { _, _ in data }
            do {
                try await SubtitleAIClient(transport: transport).testConnection(configuration: configuration)
                XCTFail("Malformed chat envelope was accepted")
            } catch { XCTAssertEqual(error as? SubtitleAIError, .invalidResponse) }
        }
    }

    func testCancellationReachesTransport() async throws {
        let words = makeWords(["你好"])
        let transport = SubtitleStubTransport { _, _ in
            try await Task.sleep(for: .seconds(10))
            return Data()
        }
        let task = Task {
            try await SubtitleAIClient(transport: transport).correct(words: words,
                script: "", theme: "", configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEndpointNormalizationAndCredentialRejection() throws {
        for (base, expected) in [
            ("https://example.invalid", "https://example.invalid/v1/chat/completions"),
            ("https://example.invalid/custom/", "https://example.invalid/custom/chat/completions"),
            ("https://example.invalid/v1/chat/completions/", "https://example.invalid/v1/chat/completions")
        ] {
            XCTAssertEqual(try SubtitleAIConfiguration(baseURL: base, model: "test").endpoint().absoluteString, expected)
        }
        for base in ["https://user:secret@example.invalid/v1", "https://example.invalid/v1?api_key=secret", "file:///tmp/key"] {
            XCTAssertThrowsError(try SubtitleAIConfiguration(baseURL: base, model: "test").endpoint())
        }
    }

    func testSettingsKeepAPIKeyOutOfUserDefaults() throws {
        let name = "DogSC-Subtitle-AI-Test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = SubtitleMemoryKeyStore()
        try SubtitleAISettings.save(configuration, defaults: defaults, keyStore: keys)
        XCTAssertEqual(try SubtitleAISettings.load(defaults: defaults, keyStore: keys), configuration)
        let values = try XCTUnwrap(defaults.persistentDomain(forName: name))
        XCTAssertEqual(Set(values.keys), Set(["subtitleAI.baseURL", "subtitleAI.model"]))
        XCTAssertFalse(String(describing: values).contains("secret-test-key"))
    }

    private func makeWords(_ texts: [String]) -> [SubtitleWord] {
        texts.enumerated().map { index, text in
            SubtitleWord(text: text, sourceRanges: [.init(start: Double(index), end: Double(index + 1))])
        }
    }
}

private actor SubtitleStubTransport: SubtitleAITransport {
    private(set) var requests: [URLRequest] = []
    let statusCode: Int
    let responder: @Sendable (URLRequest, Int) async throws -> Data
    init(statusCode: Int = 200, responder: @escaping @Sendable (URLRequest, Int) async throws -> Data) {
        self.statusCode = statusCode
        self.responder = responder
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        let data = try await responder(request, index)
        return (data, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private final class SubtitleMemoryKeyStore: SubtitleAPIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func read() throws -> String { lock.withLock { value } }
    func write(_ value: String) throws { lock.withLock { self.value = value } }
}

private struct SubtitleTestCorrectionGroup: Encodable {
    let unitIDs: [Int]
    let text: String
}
private func subtitleResponse(groups: [SubtitleTestCorrectionGroup]) throws -> Data {
    let groupsData = try JSONEncoder().encode(groups)
    return try subtitleChat(content: "{\"groups\":" + String(decoding: groupsData, as: UTF8.self) + "}")
}
private func subtitleChat(content: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
}
private func subtitleInput(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    let content = try XCTUnwrap(messages.last?["content"])
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
}
private func subtitleUnitIDs(_ request: URLRequest) throws -> [Int] {
    let input = try subtitleInput(request)
    let units = try XCTUnwrap(input["units"] as? [[String: Any]])
    return try units.map { try XCTUnwrap($0["id"] as? Int) }
}
