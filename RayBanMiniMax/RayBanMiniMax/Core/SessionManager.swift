//
//  SessionManager.swift
//  RayBanMiniMax
//
//  Central orchestrator. Wires together:
//   * MetaWearables DAT SDK connection
//   * AudioPipeline (mic capture + TTS playback)
//   * CameraPipeline (vision frames)
//   * SpeechRecognizer (STT)
//   * MiniMaxClient (chat + TTS)
//   * ConversationStore (rolling context)
//   * ToolRegistry (function calling)
//
//  The flow is:
//
//    User speaks -> AudioPipeline chunks -> SpeechRecognizer -> transcript
//    -> MiniMaxClient.chatCompletion(messages + latest frame)
//    -> (optional) ToolRegistry.execute tool calls
//    -> MiniMaxClient.textToSpeech(text) -> AudioPipeline.playMP3
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

/// High-level connection state surfaced to the UI.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .idle:           return "Idle"
        case .connecting:     return "Connecting…"
        case .connected:      return "Connected"
        case .reconnecting:   return "Reconnecting…"
        case .failed(let m):  return "Failed: \(m)"
        }
    }

    var isActive: Bool {
        switch self {
        case .connected, .reconnecting: return true
        default: return false
        }
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

    // MARK: - Published state

    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var lastAssistantMessage: String = ""
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var lastError: String?
    @Published var settings = AppSettings.load()

    // MARK: - Internals

    private var chunkSubscription: AnyCancellable?
    private var reconnectTask: Task<Void, Never>?

    // The DAT SDK is loaded lazily and weakly; we don't import the module
    // unconditionally because the package may not be available when tests
    // run. The orchestrator calls into the SDK through `dat` below.
    private var dat: DATBridge?

    // MARK: - Init

    init(api: MiniMaxClient = MiniMaxClient()) {
        self.api = api
    }

    // MARK: - Bootstrap

    /// One-shot startup. Configures audio, requests permissions, and tries
    /// to connect to the glasses. Failures are surfaced in `lastError`.
    func bootstrap() {
        Task {
            await stt.requestAuthorization()
            do {
                try audio.configureSession()
            } catch {
                Logger.warn("Audio session config failed: \(error.localizedDescription)", category: .audio)
            }
            await connect()
        }
    }

    // MARK: - Connection

    /// Connect (or reconnect) to the Meta Ray-Ban Gen 2 glasses.
    func connect() async {
        guard !connection.isActive else { return }
        connection = .connecting
        do {
            let bridge = DATBridge()
            try await bridge.connect()
            self.dat = bridge

            // Wire audio: tap the SDK's audio input node, then start playback.
            if let audioInput = bridge.audioInputNode() {
                try audio.startCapture(from: audioInput)
            }
            try audio.preparePlayback()

            // Wire camera: forward the SDK's JPEG stream to the camera pipeline.
            let frames = bridge.cameraStream()
            camera.start(source: frames)

            // Wire STT: subscribe to audio chunks for optional on-device STT.
            chunkSubscription = audio.chunkPublisher
                .sink { [weak self] event in
                    self?.handleAudioChunk(event)
                }

            connection = .connected
            Logger.info("Session connected", category: .session)
        } catch {
            connection = .failed(error.localizedDescription)
            lastError = "Connection failed: \(error.localizedDescription)"
            Logger.error("Connect failed: \(error.localizedDescription)", category: .session)
        }
    }

    /// Disconnect gracefully and stop all subsystems.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        chunkSubscription?.cancel()
        chunkSubscription = nil
        audio.shutdown()
        camera.stop()
        stt.stop()
        dat?.disconnect()
        dat = nil
        connection = .idle
        Logger.info("Session disconnected", category: .session)
    }

    /// Reconnect after a transient failure.
    func reconnect() {
        disconnect()
        connection = .reconnecting
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await connect()
        }
    }

    // MARK: - Audio chunks (from AudioPipeline)

    private func handleAudioChunk(_ event: AudioChunkEvent) {
        // We don't run STT on every chunk. The SessionManager exposes
        // `transcribeLatestWindow()` for when we want to flush a window of
        // audio into the recognizer. For now, just log activity.
        if event.rms > 0.05 {
            Logger.debug("mic chunk rms=\(event.rms)", category: .audio)
        }
    }

    // MARK: - Main AI loop

    /// Run a single AI turn given a user transcript (already produced by STT
    /// or a manual text input). The latest camera frame is attached when
    /// `attachLatestFrame` is true.
    func ask(transcript text: String, attachLatestFrame: Bool = true) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isThinking = true
        defer { isThinking = false }

        // Build the user message (with optional image).
        let userContent: MessageContent
        let frame = attachLatestFrame ? camera.latestFrame : nil
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

        // Build messages (system + history).
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

            // If the model requested tool calls, execute them and re-query.
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

    /// Execute a batch of tool calls and return the corresponding
    /// `role: "tool"` messages ready to feed back into the model.
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

    /// Speak the given text through the glasses using MiniMax TTS.
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

    /// Stop any in-flight playback.
    func stopSpeaking() {
        audio.stopPlayback()
    }

    // MARK: - STT -> AI helper

    /// Listen for one utterance and feed it straight to the AI.
    func listenAndAsk() async {
        do {
            let transcript = try await stt.listenOnce()
            await ask(transcript: transcript, attachLatestFrame: settings.attachLatestFrame)
        } catch {
            lastError = "STT error: \(error.localizedDescription)"
            Logger.error("listenAndAsk failed: \(error.localizedDescription)", category: .stt)
        }
    }

    // MARK: - Camera capture (programmatic)

    /// Capture a still photo through the DAT bridge. The bridge routes the
    /// request to the SDK on real glasses; the simulator path returns a
    /// synthetic JPEG so the UI stays usable without hardware.
    func capturePhoto() async throws -> Data {
        guard let dat else {
            throw NSError(domain: "SessionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not connected to glasses."])
        }
        let data = try await dat.capturePhoto()
        // Immediately feed it into the camera pipeline so the user sees it.
        camera.ingest(jpegData: data)
        return data
    }

    // MARK: - Conversation management

    func clearConversation() {
        store.clear()
        lastAssistantMessage = ""
    }
}
