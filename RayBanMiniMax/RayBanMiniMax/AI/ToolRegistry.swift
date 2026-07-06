//
//  ToolRegistry.swift
//  RayBanMiniMax
//
//  Extensible registry of function-calling tools the AI can invoke. Each
//  tool is a Codable definition (sent to MiniMax) plus a Swift handler
//  that runs locally on the phone.
//
//  The minimal registry ships with two demos:
//    - get_current_time
//    - save_note
//

import Foundation

/// Result of a single tool invocation. The string is sent back to the
/// model as a `role: "tool"` message.
struct ToolInvocationResult {
    let name: String
    let output: String
    let isError: Bool

    static func success(_ name: String, _ output: String) -> ToolInvocationResult {
        return ToolInvocationResult(name: name, output: output, isError: false)
    }
    static func failure(_ name: String, _ output: String) -> ToolInvocationResult {
        return ToolInvocationResult(name: name, output: output, isError: true)
    }
}

/// A tool is a `ToolDefinition` (wire format) plus a handler. Handlers
/// receive the JSON argument dictionary and return a string the model can
/// read back.
struct Tool {
    let definition: ToolDefinition
    let handler: (_ arguments: [String: Any]) async -> ToolInvocationResult
}

/// Holds the active set of tools. Always safe to call from any actor; the
/// underlying array is small and append-only in practice.
final class ToolRegistry {
    private var toolsByName: [String: Tool] = [:]
    private let lock = NSLock()

    init() {
        // Demo tools ship by default.
        register(getCurrentTime())
        register(saveNote())
    }

    func register(_ tool: Tool) {
        lock.lock(); defer { lock.unlock() }
        toolsByName[tool.definition.function.name] = tool
    }

    var allTools: [Tool] {
        lock.lock(); defer { lock.unlock() }
        return Array(toolsByName.values)
    }

    var allDefinitions: [ToolDefinition] {
        return allTools.map { $0.definition }
    }

    func tool(named name: String) -> Tool? {
        lock.lock(); defer { lock.unlock() }
        return toolsByName[name]
    }

    /// Decode the JSON arguments string from a `ToolCall` into a dictionary.
    /// Returns an empty dict on parse failure (so handlers can still run).
    static func decodeArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return [:]
        }
        return dict
    }

    // MARK: - Built-in tools

    private func getCurrentTime() -> Tool {
        let definition = ToolDefinition(
            type: "function",
            function: ToolFunction(
                name: "get_current_time",
                description: "Return the current local date and time. Use this whenever the user asks 'what time is it' or for a timestamp.",
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "timezone": JSONSchemaProperty(
                            type: "string",
                            description: "Optional IANA timezone (e.g. 'America/Los_Angeles'). Defaults to the device timezone.",
                            enumValues: nil
                        )
                    ],
                    required: [],
                    description: nil
                )
            )
        )
        return Tool(definition: definition) { args in
            let tzName = args["timezone"] as? String
            let tz: TimeZone
            if let tzName, let resolved = TimeZone(identifier: tzName) {
                tz = resolved
            } else {
                tz = .current
            }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .medium
            formatter.timeZone = tz
            let stamp = formatter.string(from: Date())
            return .success("get_current_time", "It is now \(stamp) (\(tz.identifier)).")
        }
    }

    private func saveNote() -> Tool {
        let definition = ToolDefinition(
            type: "function",
            function: ToolFunction(
                name: "save_note",
                description: "Save a short note to the user's persistent notepad. Returns the saved text and timestamp.",
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "text": JSONSchemaProperty(
                            type: "string",
                            description: "The note text to save. Plain text, max 500 characters.",
                            enumValues: nil
                        )
                    ],
                    required: ["text"],
                    description: nil
                )
            )
        )
        return Tool(definition: definition) { args in
            guard let text = args["text"] as? String, !text.isEmpty else {
                return .failure("save_note", "Missing 'text' argument.")
            }
            let trimmed = String(text.prefix(500))
            let entry = NoteEntry(text: trimmed, savedAt: Date())
            NoteStore.shared.append(entry)
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return .success(
                "save_note",
                "Saved note: \"\(trimmed)\" at \(formatter.string(from: entry.savedAt))."
            )
        }
    }
}

// MARK: - Persistent note storage

struct NoteEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let savedAt: Date

    init(text: String, savedAt: Date, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
    }
}

/// Tiny on-disk store. Keeps the last 100 notes. Backed by JSON in the
/// app's Application Support directory.
final class NoteStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = NoteStore()
    private let url: URL
    private let maxNotes = 100
    private let queue = DispatchQueue(label: "NoteStore", qos: .utility)

    private(set) var notes: [NoteEntry] = []

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        self.url = base.appendingPathComponent("rayban-notes.json")
        load()
    }

    func append(_ note: NoteEntry) {
        queue.sync {
            notes.append(note)
            if notes.count > maxNotes {
                notes.removeFirst(notes.count - maxNotes)
            }
            persist()
        }
    }

    func clear() {
        queue.sync {
            notes.removeAll()
            persist()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([NoteEntry].self, from: data) {
            notes = decoded
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.error("NoteStore persist failed: \(error)", category: .tool)
        }
    }
}
