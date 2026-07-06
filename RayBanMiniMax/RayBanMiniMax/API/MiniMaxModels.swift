//
//  MiniMaxModels.swift
//  RayBanMiniMax
//
//  Codable request/response models for the MiniMax Chat Completion v2 and
//  Text-to-Speech v2 endpoints. Field names match the published API schema.
//

import Foundation

// MARK: - Chat Completion

/// Top-level request body for `POST /v1/text/chatcompletion_v2`.
struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let tools: [ToolDefinition]?
    let toolChoice: String?
    let maskSensitiveInfo: Bool?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case toolChoice = "tool_choice"
        case maskSensitiveInfo = "mask_sensitive_info"
        case responseFormat = "response_format"
    }
}

/// Structured response format (Text-01 only). Provide a JSON schema to
/// constrain the model's output to a specific shape.
struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: [String: AnyEncodable]?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

/// A single chat message. Content is polymorphic: either a plain string, or
/// an array of text + image parts (for vision). We model both cases.
struct ChatMessage: Codable {
    let role: Role
    let name: String?
    /// `String` for text-only messages; `[ContentPart]` for multimodal.
    /// Custom encoding to keep the wire format compact and unambiguous.
    let content: MessageContent
    /// Tool-call ID for messages with role == .tool.
    let toolCallID: String?
    /// When the assistant requests tool calls, the model returns this array.
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, name, content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    enum Role: String, Codable {
        case system, user, assistant, tool
    }

    init(role: Role,
         content: MessageContent,
         name: String? = nil,
         toolCallID: String? = nil,
         toolCalls: [ToolCall]? = nil) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

/// A content part inside a multimodal message.
struct ContentPart: Codable {
    enum Kind: String, Codable {
        case text
        case imageURL = "image_url"
    }

    let type: Kind
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

struct ImageURL: Codable {
    let url: String
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case url, detail
    }
}

/// Polymorphic message content that encodes as a bare string when textual
/// and as a JSON array when multimodal.
enum MessageContent: Codable {
    case text(String)
    case parts([ContentPart])

    // MARK: Encoding

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try container.encode(s)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    // MARK: Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
            return
        }
        if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "ChatMessage content must be String or [ContentPart]."
        )
    }
}

// MARK: - Function calling

struct ToolDefinition: Codable {
    let type: String  // Always "function"
    let function: ToolFunction

    enum CodingKeys: String, CodingKey {
        case type, function
    }
}

struct ToolFunction: Codable {
    let name: String
    let description: String
    let parameters: JSONSchema
}

/// Minimal JSON-Schema-style parameter description. We keep it flexible so
/// the model can express arrays, enums, and nested objects.
struct JSONSchema: Codable {
    let type: String
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?
    let description: String?
}

struct JSONSchemaProperty: Codable {
    let type: String
    let description: String?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

/// A tool call emitted by the model.
struct ToolCall: Codable {
    let id: String
    let type: String  // "function"
    let function: FunctionCall

    enum CodingKeys: String, CodingKey {
        case id, type, function
    }
}

struct FunctionCall: Codable {
    let name: String
    /// Arguments as a JSON string, per OpenAI-compatible spec.
    let arguments: String
}

// MARK: - Response

struct ChatCompletionResponse: Decodable {
    let id: String?
    let created: Int?
    let model: String?
    let object: String?
    let choices: [Choice]
    let usage: Usage?
    let baseResp: BaseResp?

    enum CodingKeys: String, CodingKey {
        case id, created, model, object, choices, usage
        case baseResp = "base_resp"
    }
}

struct Choice: Decodable {
    let index: Int?
    let finishReason: String?
    let message: ResponseMessage

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

struct ResponseMessage: Decodable {
    let role: String?
    let name: String?
    /// Content is always a string in non-streaming responses. Multimodal
    /// content is only sent as the request payload.
    let content: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, name, content
        case toolCalls = "tool_calls"
    }
}

struct Usage: Decodable {
    let totalTokens: Int?
    let promptTokens: Int?
    let completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

struct BaseResp: Decodable {
    let statusCode: Int
    let statusMsg: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMsg = "status_msg"
    }
}

// MARK: - TTS

struct TTSRequest: Encodable {
    let model: String
    let text: String
    let stream: Bool
    let outputFormat: String
    let languageBoost: String?
    let voiceSetting: VoiceSetting
    let audioSetting: AudioSetting

    enum CodingKeys: String, CodingKey {
        case model, text, stream
        case outputFormat = "output_format"
        case languageBoost = "language_boost"
        case voiceSetting = "voice_setting"
        case audioSetting = "audio_setting"
    }
}

struct VoiceSetting: Encodable {
    let voiceId: String
    let speed: Double
    let vol: Double
    let pitch: Int
    let emotion: String

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case speed, vol, pitch, emotion
    }
}

struct AudioSetting: Encodable {
    let sampleRate: Int
    let bitrate: Int
    let format: String
    let channel: Int

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case bitrate, format, channel
    }
}

struct TTSResponse: Decodable {
    let baseResp: BaseResp?
    let data: TTSData?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case data
    }
}

struct TTSData: Decodable {
    let audio: String?       // hex-encoded MP3
    let status: Int?
    let subtitle: [TTSSubtitle]?
}

struct TTSSubtitle: Decodable {
    let text: String
    let startTime: Int?
    let endTime: Int?
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case text, index
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

// MARK: - Errors

/// MiniMax error codes from `base_resp.status_code`.
enum MiniMaxErrorCode: Int {
    case unknown = 1000
    case timeout = 1001
    case rateLimited = 1002
    case authFailed = 1004
    case insufficientBalance = 1008
    case internalError = 1013
    case outputContent = 1027
    case tokenLimit = 1039
    case parameter = 2013

    var humanMessage: String {
        switch self {
        case .unknown:            return "An unknown MiniMax error occurred."
        case .timeout:            return "MiniMax timed out. Try again."
        case .rateLimited:        return "MiniMax rate limit hit. Slow down a bit."
        case .authFailed:         return "MiniMax authentication failed. Check your API key in Settings."
        case .insufficientBalance: return "MiniMax account out of credits. Top up at platform.minimax.io."
        case .internalError:      return "MiniMax server error. Try again shortly."
        case .outputContent:      return "MiniMax flagged the output. Please rephrase."
        case .tokenLimit:         return "Context too long. Start a new conversation."
        case .parameter:          return "Bad parameters sent to MiniMax."
        }
    }
}

struct MiniMaxError: LocalizedError, Equatable {
    let code: Int
    let message: String
    let httpStatus: Int?

    var errorDescription: String? {
        if let http = httpStatus, http != 200 {
            return "HTTP \(http): \(message)"
        }
        if let mapped = MiniMaxErrorCode(rawValue: code) {
            return mapped.humanMessage
        }
        return message
    }

    static func == (lhs: MiniMaxError, rhs: MiniMaxError) -> Bool {
        return lhs.code == rhs.code && lhs.message == rhs.message && lhs.httpStatus == rhs.httpStatus
    }
}

// MARK: - Helpers

/// Type-erasing Encodable for ad-hoc JSON values (e.g., response_format.json_schema).
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        self._encode = value.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
