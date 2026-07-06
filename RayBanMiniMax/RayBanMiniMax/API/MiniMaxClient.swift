//
//  MiniMaxClient.swift
//  RayBanMiniMax
//
//  Async/await + completion-based client for the MiniMax Chat Completion v2
//  and Text-to-Speech v2 endpoints. Designed for low-latency voice loops
//  through Meta Ray-Ban Gen 2 smart glasses.
//
//  All requests authenticate with a Bearer token from `APIConfig.apiKey`.
//

import Foundation

/// A single response unit from the chat completion endpoint. We always return
/// the full assistant message; callers that want streaming can use the
/// `streamChatCompletion` API.
struct ChatCompletionResult {
    let content: String
    let finishReason: String?
    let toolCalls: [ToolCall]
    let usage: Usage?
    let model: String?

    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

actor MiniMaxClient {
    // MARK: - Configuration

    private let session: URLSession
    private let chatURL: URL
    private let ttsURL: URL

    init(session: URLSession = .shared,
         chatURL: URL = APIConfig.Endpoint.chat,
         ttsURL: URL = APIConfig.Endpoint.tts) {
        self.session = session
        self.chatURL = chatURL
        self.ttsURL = ttsURL
    }

    // MARK: - Chat Completion (non-streaming)

    /// Send a non-streaming chat completion request.
    ///
    /// - Parameters:
    ///   - messages: Conversation history, oldest first.
    ///   - model: The MiniMax model to use.
    ///   - temperature: Sampling temperature. Defaults to the model's recommended value.
    ///   - maxTokens: Max tokens to generate. Defaults to the model's recommended value.
    ///   - tools: Optional function-calling tool definitions.
    func chatCompletion(
        messages: [ChatMessage],
        model: MiniMaxModel = APIConfig.Defaults.model,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        tools: [ToolDefinition]? = nil
    ) async throws -> ChatCompletionResult {
        let key = APIConfig.currentAPIKey()
        guard !key.isEmpty else {
            throw MiniMaxError(code: MiniMaxErrorCode.authFailed.rawValue,
                               message: "Missing MINIMAX_API_KEY. Set it in Settings.",
                               httpStatus: nil)
        }

        let body = ChatCompletionRequest(
            model: model.rawValue,
            messages: messages,
            stream: false,
            maxTokens: maxTokens ?? model.maxTokens,
            temperature: temperature ?? model.defaultTemperature,
            topP: 0.95,
            tools: tools,
            toolChoice: tools == nil ? nil : "auto",
            maskSensitiveInfo: false,
            responseFormat: nil
        )

        let request = try makeRequest(url: chatURL, apiKey: key, body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return try mapChatResponse(decoded)
    }

    // MARK: - Text-to-Speech

    /// Synthesize speech and return raw MP3 bytes.
    ///
    /// - Parameters:
    ///   - text: The text to speak. Max 10,000 characters.
    ///   - voiceId: MiniMax voice id (e.g. "English_expressive_narrator").
    ///   - model: HD or turbo.
    ///   - emotion: MiniMax TTS emotion tag.
    ///   - speed: Voice speed multiplier.
    ///   - pitch: Voice pitch shift in semitones.
    ///   - sampleRate: Output sample rate. The DAT SDK glasses expect 24 kHz,
    ///                 but MiniMax TTS returns 32 kHz by default. We decode and
    ///                 resample in the audio pipeline.
    func textToSpeech(
        text: String,
        voiceId: String = APIConfig.Defaults.voiceId,
        model: TTSModel = APIConfig.Defaults.ttsModel,
        emotion: TTSEmotion = .neutral,
        speed: Double = 1.0,
        pitch: Int = 0,
        volume: Double = 1.0,
        sampleRate: Int = APIConfig.Defaults.ttsSampleRate
    ) async throws -> Data {
        let key = APIConfig.currentAPIKey()
        guard !key.isEmpty else {
            throw MiniMaxError(code: MiniMaxErrorCode.authFailed.rawValue,
                               message: "Missing MINIMAX_API_KEY. Set it in Settings.",
                               httpStatus: nil)
        }

        let trimmed = String(text.prefix(10_000))
        let body = TTSRequest(
            model: model.rawValue,
            text: trimmed,
            stream: false,
            outputFormat: "hex",
            languageBoost: "auto",
            voiceSetting: VoiceSetting(
                voiceId: voiceId,
                speed: speed,
                vol: volume,
                pitch: pitch,
                emotion: emotion.rawValue
            ),
            audioSetting: AudioSetting(
                sampleRate: sampleRate,
                bitrate: APIConfig.Defaults.ttsBitrate,
                format: "mp3",
                channel: 1
            )
        )

        let request = try makeRequest(url: ttsURL, apiKey: key, body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(TTSResponse.self, from: data)

        if let baseResp = decoded.baseResp, baseResp.statusCode != 0 {
            throw MiniMaxError(
                code: baseResp.statusCode,
                message: baseResp.statusMsg.isEmpty ? "TTS failed" : baseResp.statusMsg,
                httpStatus: nil
            )
        }

        guard let hex = decoded.data?.audio, !hex.isEmpty else {
            throw MiniMaxError(
                code: MiniMaxErrorCode.internalError.rawValue,
                message: "TTS response missing audio payload.",
                httpStatus: nil
            )
        }

        guard let audio = Data(hexString: hex) else {
            throw MiniMaxError(
                code: MiniMaxErrorCode.parameter.rawValue,
                message: "TTS audio was not valid hex.",
                httpStatus: nil
            )
        }

        Logger.debug("TTS returned \(audio.count) bytes (hex=\(hex.count) chars)",
                     category: .tts)
        return audio
    }

    // MARK: - Internal

    private func makeRequest<Body: Encodable>(url: URL, apiKey: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let encoder = JSONEncoder()
        // Default encoding already uses the keys we declared; no custom strategy needed.
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxError(code: -1, message: "Invalid response", httpStatus: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            Logger.warn("MiniMax HTTP \(http.statusCode): \(body)", category: .api)
            throw MiniMaxError(
                code: http.statusCode,
                message: body,
                httpStatus: http.statusCode
            )
        }
    }

    private func mapChatResponse(_ resp: ChatCompletionResponse) throws -> ChatCompletionResult {
        if let baseResp = resp.baseResp, baseResp.statusCode != 0 {
            throw MiniMaxError(
                code: baseResp.statusCode,
                message: baseResp.statusMsg.isEmpty ? "Chat failed" : baseResp.statusMsg,
                httpStatus: nil
            )
        }
        guard let choice = resp.choices.first else {
            throw MiniMaxError(
                code: MiniMaxErrorCode.internalError.rawValue,
                message: "MiniMax returned no choices.",
                httpStatus: nil
            )
        }
        return ChatCompletionResult(
            content: choice.message.content ?? "",
            finishReason: choice.finishReason,
            toolCalls: choice.message.toolCalls ?? [],
            usage: resp.usage,
            model: resp.model
        )
    }
}
