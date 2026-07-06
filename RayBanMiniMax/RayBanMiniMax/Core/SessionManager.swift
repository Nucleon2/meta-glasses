//
//  SessionManager.swift
//  RayBanMiniMax
//
//  Central orchestrator. Wires together:
//   * DATBridge (real Meta Wearables SDK: video stream + photo capture)
//   * AudioPipeline (iPhone mic + speaker for the voice loop)
//   * CameraPipeline (consumes DATBridge video frames, base64 for AI)
//   * SpeechRecognizer (on-device STT from the iPhone mic)
//   * MiniMaxClient (chat + TTS)
//   * ConversationStore (rolling context)
//   * ToolRegistry (function calling)
//
//  Flow:
//    User speaks → iPhone mic → AudioPipeline chunks → SpeechRecognizer
//      → transcript → MiniMax chat (with latest DAT frame)
//      → MiniMax TTS → iPhone speaker
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

/// High-level connection state surfaced to the UI.
enum ConnectionState: Equatable {
    case idle
    case configuring
    case registering
    case ready
    case streaming
    case failed(String)
    case permissionDenied

    var label: String {
        switch self {
        case .idle:               return "Idle"
        case .configuring:        return "Configuring…"
        case .registering:        return "Registering with Meta…"
        case .ready:              return "Ready"
        case .streaming:          return "Streaming"
        case .permissionDenied:   return "Camera permission needed"
        case .failed(let m):      return "Failed: \(m)"
        }
    }

    var isActive: Bool {
        switch self {
        case .ready, .streaming, .registering: return true
        default: return false
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

@MainActor
final class SessionManager: ObservableObject {
    // MARK: - Subsystems

    let api: MiniMaxClient
    let audio = AudioPipeline()
    let camera = CameraPipeline()
    let stt = SpeechRecognizer()
    let store = ConversationStore()
    let tools = ToolRegistry()
    let bridge = DATBridge()

    // MARK: - Published state

    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var lastAssistantMessage: String = ""
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var lastError: String?
    @Published var settings = AppSettings.load()

    // MARK: - Internals

    private var stateObservation: Task<Void, Never>?

    init(api: MiniMaxClient = MiniMaxClient()) {
        self.api = api
        observeBridgeState()
    }

    private func observeBridgeState() {
        // Bridge is @MainActor; poll its published state.
        // (In a real implementation we'd use a Combine bridge.)
        stateObservation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                self.syncFromBridge()
            }
        }
    }

    private func syncFromBridge() {
        let bridgeState = bridge.state
        let mapped: ConnectionState
        switch bridgeState {
        case .idle:               mapped = .idle
        case .configuring:        mapped = .configuring
        case .registering:        mapped = .registering
        case .ready:              mapped = .ready
        case .streaming:          mapped = .streaming
        case .permissionDenied:   mapped = .permissionDenied
        case .failed(let m):      mapped = .failed(m)
        }
        if connection != mapped {
            connection = mapped
        }
    }

    // MARK: - Bootstrap

    /// One-shot startup. Configures audio, requests permissions, bootstraps
    /// the DAT bridge, and starts the video stream.
    func bootstrap() {
        Task {
            await stt.requestAuthorization()
            do {
                try audio.configureSession()
            } catch {
                Logger.warn("Audio session config failed: \(error.localizedDescription)",
                            category: .audio)
            }
            await connect()
        }
    }

    // MARK: - Connection

    /// Connect / start streaming. Idempotent.
    func connect() async {
        guard !connection.isActive && !connection.isStreaming else { return }
        await bridge.bootstrap()
        await camera.start(with: bridge)
        // Mic capture (for STT) — separate from the bridge.
        do {
            try audio.startCapture()
        } catch {
            Logger.warn("Mic capture failed: \(error.localizedDescription)", category: .audio)
        }
        do {
            try audio.preparePlayback()
        } catch {
            Logger.warn("Playback prepare failed: \(error.localizedDescription)", category: .audio)
        }
        Logger.info("Session connected", category: .session)
    }

    /// Disconnect gracefully and stop all subsystems.
    func disconnect() {
        audio.shutdown()
        camera.stop()
        stt.stop()
        bridge.shutdown()
        connection = .idle
        Logger.info("Session disconnected", category: .session)
    }

    /// Reconnect after a transient failure.
    func reconnect() {
        disconnect()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await connect()
        }
    }

    // MARK: - Programmatic photo capture

    /// Capture a still through the glasses' DAT bridge. The frame is also
    /// injected into the camera pipeline so the UI updates immediately.
    func capturePhoto() async throws -> Data {
        let photo = try await bridge.capturePhoto()
        camera.inject(jpegData: photo.jpegData)
        return photo.jpegData
    }

    // MARK: - Main AI loop

    /// Run a single AI turn given a user transcript. Attaches the latest
    /// camera frame from the glasses if `attachLatestFrame` is true.
    func ask(transcript text: String, attachLatestFrame: Bool = true) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isThinking = true
        defer { isThinking = false }

        let frame = attachLatestFrame ? camera.latestFrame : nil
        let userContent: MessageContent
        if let frame {
            var parts: [ContentPart] = [
                ContentPart(type: .text, text: trimmed, imageURL: nil)
            ]
            parts.append(ContentPart(
                type: .imageURL,
                text: nil,
                imageURL: ImageURL(
                    url: "data:image/jpeg;base64,\(frame.base64)",
                    detail: "auto"
                )
            ))
            userContent = .parts(parts)
        } else {
            userContent = .text(trimmed)
        }

        let userMessage = ChatMessage(role: .user, content: userContent)
        store.append(ConversationTurn(
            role: .user,
            content: trimmed,
            hasImage: frame != nil
        ))

        let toolDefs = tools.allDefinitions
        let useTools = !toolDefs.isEmpty
        let messages = store.messagesForRequest(
            systemPrompt: SystemPrompts.build(vision: frame != nil),
            extraSystemPrompt: useTools ? SystemPrompts.toolAssistant : nil
        ) + [userMessage]

        do {
            let first = try await api.chatCompletion(
                messages: messages,
                model: settings.chatModel,
                temperature: settings.temperature,
                maxTokens: settings.maxTokens,
                tools: useTools ? toolDefs : nil
            )

            var final = first
            if first.hasToolCalls {
                let toolMessages = await runTools(first.toolCalls)
                let followUp = messages + [
                    ChatMessage(
                        role: .assistant,
                        content: .text(first.content),
                        toolCalls: first.toolCalls
                    )
                ] + toolMessages
                final = try await api.chatCompletion(
                    messages: followUp,
                    model: settings.chatModel,
                    temperature: settings.temperature,
                    maxTokens: settings.maxTokens,
                    tools: toolDefs
                )
            }

            let responseText = final.content.trimmingCharacters(in: .whitespacesAndNewlines)
            store.append(ConversationTurn(role: .assistant, content: responseText))
            lastAssistantMessage = responseText
            lastError = nil
            Logger.info("AI response: \(responseText.prefix(80))…", category: .session)

            await speak(responseText)
        } catch {
            lastError = "AI error: \(error.localizedDescription)"
            Logger.error("AI error: \(error.localizedDescription)", category: .session)
            await speak("Sorry, I couldn't reach the AI service. Please try again.")
        }
    }

    private func runTools(_ calls: [ToolCall]) async -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for call in calls {
            guard let tool = tools.tool(named: call.function.name) else {
                messages.append(ChatMessage(
                    role: .tool,
                    content: .text("Unknown tool '\(call.function.name)'."),
                    toolCallID: call.id,
                    toolCalls: nil
                ))
                continue
            }
            let args = ToolRegistry.decodeArguments(call.function.arguments)
            let result = await tool.handler(args)
            Logger.info("Tool \(result.name) → \(result.output.prefix(120))", category: .tool)
            messages.append(ChatMessage(
                role: .tool,
                content: .text(result.output),
                toolCallID: call.id,
                toolCalls: nil
            ))
        }
        return messages
    }

    // MARK: - TTS playback

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let mp3 = try await api.textToSpeech(
                text: trimmed,
                voiceId: settings.voiceId,
                model: settings.ttsModel,
                emotion: settings.ttsEmotion,
                speed: settings.ttsSpeed,
                pitch: settings.ttsPitch,
                volume: settings.ttsVolume
            )
            try await audio.playMP3(mp3)
        } catch {
            lastError = "TTS error: \(error.localizedDescription)"
            Logger.error("TTS error: \(error.localizedDescription)", category: .tts)
        }
    }

    func stopSpeaking() { audio.stopPlayback() }

    // MARK: - STT -> AI helper

    func listenAndAsk() async {
        do {
            let transcript = try await stt.listenOnce()
            await ask(transcript: transcript, attachLatestFrame: settings.attachLatestFrame)
        } catch {
            lastError = "STT error: \(error.localizedDescription)"
            Logger.error("listenAndAsk failed: \(error.localizedDescription)", category: .stt)
        }
    }

    // MARK: - Conversation management

    func clearConversation() {
        store.clear()
        lastAssistantMessage = ""
    }
}
