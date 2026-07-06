//
//  MiniMaxClientTests.swift
//  RayBanMiniMaxTests
//
//  Unit tests for the MiniMax API client. These run as part of the iOS
//  Xcode test target (which has XCTest available). The pure-utility smoke
//  tests cover the same surface on macOS via scripts/smoketest.sh.
//

import XCTest
@testable import RayBanMiniMax

final class MiniMaxClientTests: XCTestCase {

    // MARK: - URLProtocol stub

    final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let handler = StubURLProtocol.handler else { return }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession!
    private var client: MiniMaxClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        client = MiniMaxClient(session: session)
        APIConfig.setUserAPIKey("test-key-123")
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: "MINIMAX_API_KEY")
        super.tearDown()
    }

    // MARK: - Chat completion

    func testChatCompletion_returnsContent() async throws {
        let json = """
        {
          "id": "abc",
          "object": "chat.completion",
          "created": 1700000000,
          "model": "MiniMax-M3",
          "choices": [
            {"index": 0, "finish_reason": "stop",
             "message": {"role": "assistant", "content": "Hello there!"}}
          ],
          "usage": {"total_tokens": 12, "prompt_tokens": 8, "completion_tokens": 4},
          "base_resp": {"status_code": 0, "status_msg": ""}
        }
        """.data(using: .utf8)!

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, json)
        }

        let messages = [ChatMessage(role: .user, content: .text("hi"))]
        let result = try await client.chatCompletion(messages: messages)
        XCTAssertEqual(result.content, "Hello there!")
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(result.usage?.totalTokens, 12)
    }

    func testChatCompletion_throwsOnBaseRespError() async throws {
        let json = """
        {
          "id": "x", "choices": [],
          "base_resp": {"status_code": 1004, "status_msg": "auth failed"}
        }
        """.data(using: .utf8)!

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json)
        }

        do {
            _ = try await client.chatCompletion(messages: [])
            XCTFail("Expected error to be thrown")
        } catch let error as MiniMaxError {
            XCTAssertEqual(error.code, 1004)
        }
    }

    func testChatCompletion_throwsOnEmptyAPIKey() async {
        APIConfig.setUserAPIKey("")
        do {
            _ = try await client.chatCompletion(messages: [])
            XCTFail("Expected error for empty API key")
        } catch let error as MiniMaxError {
            XCTAssertEqual(error.code, MiniMaxErrorCode.authFailed.rawValue)
        }
    }

    func testChatCompletion_sendsBearerToken() async throws {
        var capturedAuth: String?
        StubURLProtocol.handler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let json = """
            {"choices": [{"finish_reason": "stop",
              "message": {"role": "assistant", "content": "ok"}}],
             "base_resp": {"status_code": 0, "status_msg": ""}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json)
        }
        _ = try await client.chatCompletion(messages: [ChatMessage(role: .user, content: .text("hi"))])
        XCTAssertEqual(capturedAuth, "Bearer test-key-123")
    }

    func testChatCompletion_parsesToolCalls() async throws {
        let json = """
        {
          "id": "x",
          "choices": [{
            "index": 0, "finish_reason": "tool_calls",
            "message": {
              "role": "assistant", "content": "",
              "tool_calls": [{
                "id": "call_1", "type": "function",
                "function": {"name": "get_current_time", "arguments": "{}"}
              }]
            }
          }],
          "base_resp": {"status_code": 0, "status_msg": ""}
        }
        """.data(using: .utf8)!

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json)
        }
        let result = try await client.chatCompletion(messages: [])
        XCTAssertTrue(result.hasToolCalls)
        XCTAssertEqual(result.toolCalls.first?.function.name, "get_current_time")
    }

    // MARK: - TTS

    func testTextToSpeech_decodesHex() async throws {
        let hex = "48656c6c6f"  // "Hello"
        let json = """
        {
          "base_resp": {"status_code": 0, "status_msg": ""},
          "data": {"audio": "\(hex)", "status": 2}
        }
        """.data(using: .utf8)!

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer test-key-123")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json)
        }
        let audio = try await client.textToSpeech(text: "Hello")
        XCTAssertEqual(audio, Data("Hello".utf8))
    }

    func testTextToSpeech_throwsOnMissingAudio() async {
        let json = """
        {
          "base_resp": {"status_code": 0, "status_msg": ""},
          "data": {"audio": "", "status": 0}
        }
        """.data(using: .utf8)!

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json)
        }
        do {
            _ = try await client.textToSpeech(text: "hi")
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }
}
