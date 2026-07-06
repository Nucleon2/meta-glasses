//
//  ToolRegistryTests.swift
//

import Testing
@testable import RayBanMiniMaxCore

@Suite("ToolRegistry")
struct ToolRegistryTests {

    @Test("Built-in tools registered")
    func builtInRegistered() {
        let registry = ToolRegistry()
        let names = registry.allTools.map { $0.definition.function.name }
        #expect(names.contains("get_current_time"))
        #expect(names.contains("save_note"))
    }

    @Test("get_current_time handler returns a string")
    func getCurrentTime() async {
        let registry = ToolRegistry()
        let tool = registry.tool(named: "get_current_time")
        let result = await tool?.handler([:]) ?? .failure("get_current_time", "")
        #expect(result.isError == false)
        #expect(result.output.contains("It is now"))
    }

    @Test("save_note appends to store")
    func saveNoteAppends() async {
        let registry = ToolRegistry()
        let tool = registry.tool(named: "save_note")
        let before = NoteStore.shared.notes.count
        let result = await tool?.handler(["text": "Buy milk"]) ?? .failure("save_note", "")
        #expect(result.isError == false)
        #expect(NoteStore.shared.notes.count > before)
        #expect(NoteStore.shared.notes.last?.text == "Buy milk")
    }

    @Test("save_note requires text")
    func saveNoteRequiresText() async {
        let registry = ToolRegistry()
        let tool = registry.tool(named: "save_note")
        let result = await tool?.handler([:]) ?? .failure("save_note", "")
        #expect(result.isError == true)
    }

    @Test("Decode arguments parses JSON")
    func decodeArguments_parses() {
        let args = ToolRegistry.decodeArguments("{\"text\":\"hello\"}")
        #expect(args["text"] as? String == "hello")
    }

    @Test("Decode arguments handles malformed")
    func decodeArguments_malformed() {
        let args = ToolRegistry.decodeArguments("not json")
        #expect(args.isEmpty)
    }
}
