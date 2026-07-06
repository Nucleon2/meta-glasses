//
//  ConversationStore.swift
//  RayBanMiniMax
//
//  In-memory rolling history of the last N conversation turns. Used as the
//  context window for every MiniMax chat completion call.
//

import Foundation

/// A single turn. We store it as `ChatMessage` so it can be fed directly
/// to `MiniMaxClient.chatCompletion`.
struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    let role: ChatMessage.Role
    let content: String
    let hasImage: Bool
    let timestamp: Date

    init(role: ChatMessage.Role,
         content: String,
         hasImage: Bool = false,
         id: UUID = UUID(),
         timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.hasImage = hasImage
        self.timestamp = timestamp
    }

    func toChatMessage() -> ChatMessage {
        return ChatMessage(role: role, content: .text(content))
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    /// The user can change this from settings.
    @Published var maxTurns: Int = 20

    @Published private(set) var turns: [ConversationTurn] = []

    /// Append a turn. Older turns are evicted once `maxTurns` is exceeded.
    func append(_ turn: ConversationTurn) {
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    /// Drop all history.
    func clear() {
        turns.removeAll()
    }

    /// Build the messages array (system + history) ready to send to MiniMax.
    /// `extraSystemPrompt` is appended after the default prompt; useful for
    /// tool-calling passes.
    func messagesForRequest(systemPrompt: String,
                            extraSystemPrompt: String? = nil) -> [ChatMessage] {
        var systemContent = systemPrompt
        if let extra = extraSystemPrompt, !extra.isEmpty {
            systemContent += "\n\n" + extra
        }
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: .text(systemContent))
        ]
        for turn in turns {
            messages.append(turn.toChatMessage())
        }
        return messages
    }
}
