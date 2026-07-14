import XCTest
@testable import Speek

final class LLMPolishStageTests: XCTestCase {

    // MARK: - URL construction

    func testEndpointWithV1GetsChatCompletions() {
        XCTAssertEqual(
            LLMPolishStage.chatCompletionsURL(endpoint: "http://localhost:11434/v1")?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
    }

    func testEndpointWithoutV1GetsV1Inserted() {
        XCTAssertEqual(
            LLMPolishStage.chatCompletionsURL(endpoint: "http://localhost:1234")?.absoluteString,
            "http://localhost:1234/v1/chat/completions"
        )
    }

    func testTrailingSlashesAreTrimmed() {
        XCTAssertEqual(
            LLMPolishStage.chatCompletionsURL(endpoint: "https://api.openai.com/v1///")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testEmptyAndGarbageEndpointsRejected() {
        XCTAssertNil(LLMPolishStage.chatCompletionsURL(endpoint: ""))
        XCTAssertNil(LLMPolishStage.chatCompletionsURL(endpoint: "   "))
        XCTAssertNil(LLMPolishStage.chatCompletionsURL(endpoint: "not a url"))
        XCTAssertNil(LLMPolishStage.chatCompletionsURL(endpoint: "ftp://example.com"))
    }

    // MARK: - Local endpoint detection

    func testLocalEndpoints() {
        func isLocal(_ s: String) -> Bool {
            guard let url = URL(string: s) else { return false }
            return LLMPolishStage.isLocalEndpoint(url)
        }
        XCTAssertTrue(isLocal("http://localhost:11434"))
        XCTAssertTrue(isLocal("http://127.0.0.1:1234"))
        XCTAssertTrue(isLocal("http://192.168.1.5:8080"))
        XCTAssertTrue(isLocal("http://10.0.0.2"))
        XCTAssertTrue(isLocal("http://mymac.local:1234"))
        XCTAssertFalse(isLocal("https://api.openai.com"))
        XCTAssertFalse(isLocal("https://api.groq.com"))
    }

    // MARK: - Request building

    func testRequestIncludesAuthHeaderWhenKeyPresent() throws {
        let config = LLMPolishStage.Config(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: "sk-test")
        let req = try XCTUnwrap(LLMPolishStage.buildRequest(config: config, transcript: "hello"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testRequestOmitsAuthHeaderWhenKeyEmpty() throws {
        let config = LLMPolishStage.Config(endpoint: "http://localhost:11434/v1", model: "llama3.2", apiKey: "")
        let req = try XCTUnwrap(LLMPolishStage.buildRequest(config: config, transcript: "hello"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestBodyContainsModelAndTranscript() throws {
        let config = LLMPolishStage.Config(endpoint: "http://localhost:11434/v1", model: "llama3.2", apiKey: "")
        let req = try XCTUnwrap(LLMPolishStage.buildRequest(config: config, transcript: "meet on monday no wait tuesday"))
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "llama3.2")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(content.contains("meet on monday no wait tuesday"))
        XCTAssertTrue(content.contains("transcript cleaner"))
    }

    // MARK: - Response parsing

    func testParsesStandardResponse() {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"Meet on Tuesday."}}]}
        """.utf8)
        XCTAssertEqual(LLMPolishStage.parseResponse(data), "Meet on Tuesday.")
    }

    func testParseTrimsWhitespace() {
        let data = Data("""
        {"choices":[{"message":{"content":"\\n  Meet on Tuesday.  \\n"}}]}
        """.utf8)
        XCTAssertEqual(LLMPolishStage.parseResponse(data), "Meet on Tuesday.")
    }

    func testParseStripsThinkBlock() {
        let data = Data("""
        {"choices":[{"message":{"content":"<think>The user said monday then corrected to tuesday so I keep tuesday</think>\\nMeet on Tuesday."}}]}
        """.utf8)
        XCTAssertEqual(LLMPolishStage.parseResponse(data), "Meet on Tuesday.")
    }

    func testParseRejectsMalformedResponses() {
        XCTAssertNil(LLMPolishStage.parseResponse(Data("not json".utf8)))
        XCTAssertNil(LLMPolishStage.parseResponse(Data("{}".utf8)))
        XCTAssertNil(LLMPolishStage.parseResponse(Data("{\"choices\":[]}".utf8)))
    }

    // MARK: - Availability

    func testAvailabilityRules() async {
        // Local endpoint, no key → available.
        let local = LLMPolishStage(config: .init(endpoint: "http://localhost:11434/v1", model: "llama3.2", apiKey: ""))
        let localAvailable = await local.isAvailable
        XCTAssertTrue(localAvailable)

        // Remote endpoint, no key → unavailable.
        let remoteNoKey = LLMPolishStage(config: .init(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: ""))
        let remoteNoKeyAvailable = await remoteNoKey.isAvailable
        XCTAssertFalse(remoteNoKeyAvailable)

        // Remote endpoint with key → available.
        let remoteKey = LLMPolishStage(config: .init(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: "sk-x"))
        let remoteKeyAvailable = await remoteKey.isAvailable
        XCTAssertTrue(remoteKeyAvailable)

        // No model → unavailable.
        let noModel = LLMPolishStage(config: .init(endpoint: "http://localhost:11434/v1", model: "", apiKey: ""))
        let noModelAvailable = await noModel.isAvailable
        XCTAssertFalse(noModelAvailable)
    }

    // MARK: - Fail-open

    func testRunFailsOpenOnConnectionRefused() async {
        // Port 9 (discard) refuses connections immediately — run() must
        // return the input unchanged, not throw or hang.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 2
        sessionConfig.timeoutIntervalForResource = 3
        let stage = LLMPolishStage(
            config: .init(endpoint: "http://127.0.0.1:9/v1", model: "llama3.2", apiKey: ""),
            urlSession: URLSession(configuration: sessionConfig)
        )
        let out = await stage.run("hello world um testing", context: nil)
        XCTAssertEqual(out, PolishResult(text: "hello world um testing", mergedFragment: false))
    }

    // MARK: - Context prompts

    func testUserMessagePlainWithoutContext() {
        let msg = LLMPolishStage.userMessage(transcript: "hello", context: nil)
        XCTAssertTrue(msg.contains("Transcript:\nhello"))
        XCTAssertFalse(msg.contains("unfinished sentence fragment"))
    }

    func testUserMessageContextInformedAppend() {
        let ctx = PolishContext(preceding: "We shipped the release yesterday.", fragment: "")
        let msg = LLMPolishStage.userMessage(transcript: "and it went well", context: ctx)
        XCTAssertTrue(msg.contains("We shipped the release yesterday."))
        XCTAssertTrue(msg.contains("NEVER repeat it"))
        XCTAssertFalse(msg.contains("unfinished sentence fragment"))
    }

    func testUserMessageMergeMode() {
        let ctx = PolishContext(preceding: "First sentence.", fragment: "and then we went to")
        let msg = LLMPolishStage.userMessage(transcript: "the store no wait the market", context: ctx)
        XCTAssertTrue(msg.contains("and then we went to"))
        XCTAssertTrue(msg.contains("the store no wait the market"))
        XCTAssertTrue(msg.contains("fragment merged with the new dictation"))
    }

    func testMergeModeSetsMergedFlagPathOnlyWithFragment() async {
        // No fragment → even with preceding context, result must not claim merge.
        let stage = LLMPolishStage(
            config: .init(endpoint: "http://127.0.0.1:9/v1", model: "m", apiKey: ""),
            urlSession: {
                let c = URLSessionConfiguration.ephemeral
                c.timeoutIntervalForRequest = 2
                return URLSession(configuration: c)
            }()
        )
        let out = await stage.run("hello", context: PolishContext(preceding: "Prior.", fragment: ""))
        XCTAssertFalse(out.mergedFragment)
    }
}
