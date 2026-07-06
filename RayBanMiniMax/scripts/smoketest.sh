#!/usr/bin/env bash
#
# scripts/smoketest.sh
# Build and run the pure-utility smoke tests.
# Requires: Swift 5.9+ (no iOS SDK or XCTest required).
#

set -euo pipefail

cd "$(dirname "$0")/.."

OUT="smoke"
mkdir -p "$OUT"
TMP="$OUT/main.swift"

cat > "$TMP" <<'SWIFT'
import Foundation

func expect(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond {
        print("  ✓ \(msg)")
    } else {
        print("  ✗ \(msg) (\(file):\(line))")
        exit(1)
    }
}

print("== PCMConverter ==")
expect(PCMConverter.floatToInt16([0]) == Data([0x00, 0x00]), "floatToInt16 zero")
expect(PCMConverter.floatToInt16([1.0]) == Data([0xff, 0x7f]), "floatToInt16 +1.0")
expect(PCMConverter.floatToInt16([-1.0]) == Data([0x01, 0x80]), "floatToInt16 -1.0")
expect(PCMConverter.floatToInt16([2.0, -2.0]) == Data([0xff, 0x7f, 0x01, 0x80]), "floatToInt16 clamp")
let roundtrip = PCMConverter.int16ToFloat(PCMConverter.floatToInt16([0.5, -0.5]))
expect(roundtrip.count == 2, "roundtrip count")
expect(abs(roundtrip[0] - 0.5) < 0.001, "roundtrip 0.5")
expect(PCMConverter.resample([0.1, 0.2, 0.3, 0.4], from: 16000, to: 16000) == [0.1, 0.2, 0.3, 0.4], "resample pass-through")
expect(PCMConverter.resample([0, 1, 0, 1], from: 16000, to: 8000).count == 2, "resample downsample")
expect(PCMConverter.resample([0, 1, 0, 1], from: 8000, to: 16000).count == 8, "resample upsample")
let norm = PCMConverter.normalize([0.1, 0.2, -0.4, 0.0], target: 0.95)
let peak = norm.map(abs).max() ?? 0
expect(abs(peak - 0.95) < 0.0001, "normalize")
expect(PCMConverter.rms([0, 0, 0]) == 0, "rms silence")
expect(abs(PCMConverter.rms([1, -1]) - 1.0) < 0.0001, "rms full scale")

print("== HexDecoder ==")
expect(Data(hexString: "48656c6c6f") == Data("Hello".utf8), "hex ASCII")
expect(Data(hexString: "DEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]), "hex uppercase")
expect(Data(hexString: "") == Data(), "hex empty")
expect(Data(hexString: "ZZ") == nil, "hex invalid")
expect(Data(hexString: "1") == nil, "hex odd length")

print("== ToolRegistry ==")
let reg = ToolRegistry()
let names = reg.allTools.map { $0.definition.function.name }
expect(names.contains("get_current_time"), "tool get_current_time")
expect(names.contains("save_note"), "tool save_note")
let args = ToolRegistry.decodeArguments("{\"text\":\"hi\"}")
expect(args["text"] as? String == "hi", "decodeArguments ok")
let empty = ToolRegistry.decodeArguments("not json")
expect(empty.isEmpty, "decodeArguments malformed")

print("== APIConfig ==")
APIConfig.setUserAPIKey("test-key")
expect(APIConfig.currentAPIKey() == "test-key", "API key round-trip")
expect(APIConfig.hasAPIKey, "hasAPIKey")

print("== SystemPrompts ==")
let sys = SystemPrompts.build()
expect(sys.contains("RayBan AI"), "default system prompt")

print("== MiniMax Models ==")
let sysMsg = ChatMessage(role: .system, content: .text("hi"))
expect(sysMsg.role == .system, "system role")
let encoder = JSONEncoder()
let textMsg = ChatMessage(role: .user, content: .text("hello"))
let json = String(data: try! encoder.encode(textMsg), encoding: .utf8)!
expect(json.contains("\"role\":\"user\""), "user role encoded")
expect(json.contains("\"content\":\"hello\""), "text content encoded")

let responseJson = """
{"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "Hi back!"}}], "base_resp": {"status_code": 0, "status_msg": ""}}
""".data(using: .utf8)!
let resp = try! JSONDecoder().decode(ChatCompletionResponse.self, from: responseJson)
expect(resp.choices[0].message.content == "Hi back!", "response decoded")

let ttsRespJson = """
{"base_resp": {"status_code": 0, "status_msg": ""}, "data": {"audio": "48656c6c6f", "status": 2}}
""".data(using: .utf8)!
let ttsResp = try! JSONDecoder().decode(TTSResponse.self, from: ttsRespJson)
let decodedAudio = Data(hexString: ttsResp.data?.audio ?? "")!
expect(decodedAudio == Data("Hello".utf8), "tts audio decoded")

let err = MiniMaxError(code: 1004, message: "auth", httpStatus: nil)
expect(err.errorDescription?.contains("authentication") == true, "auth error message")

let rateErr = MiniMaxError(code: 1002, message: "rate", httpStatus: nil)
expect(rateErr.errorDescription?.contains("rate") == true, "rate limit message")

expect(MiniMaxModel.m3.maxTokens == 8192, "M3 max tokens")
expect(MiniMaxModel.text01.maxTokens == 2048, "Text-01 max tokens")

print("\nAll smoke tests passed.")
SWIFT

swiftc \
  -o "$OUT/smoke" \
  "$TMP" \
  RayBanMiniMax/API/APIConfig.swift \
  RayBanMiniMax/API/MiniMaxClient.swift \
  RayBanMiniMax/API/MiniMaxModels.swift \
  RayBanMiniMax/AI/ConversationStore.swift \
  RayBanMiniMax/AI/SystemPrompts.swift \
  RayBanMiniMax/AI/ToolRegistry.swift \
  RayBanMiniMax/Utils/HexDecoder.swift \
  RayBanMiniMax/Utils/Logger.swift \
  RayBanMiniMax/Utils/PCMConverter.swift

"$OUT/smoke"
rm -rf "$OUT"
