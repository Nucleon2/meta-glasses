# RayBan AI

> **Turn your Meta Ray-Ban Gen 2 smart glasses into a MiniMax-M3-powered AI assistant.**

RayBan AI is a native iOS companion app that uses Meta's official **Wearables
Device Access Toolkit (DAT SDK)** to subscribe to the live camera stream and
microphone of your Meta Ray-Ban Gen 2 glasses, route everything to the
**MiniMax API** for chat + TTS, and play the AI's spoken reply back through
the glasses' open-ear speakers — all while leaving the glasses' native
photo / video capture pipeline completely untouched.

```
┌────────────────────────┐                  ┌──────────────────────────┐
│  Meta Ray-Ban Gen 2    │                  │   RayBan AI (iOS)        │
│  12MP cam  ~1 fps JPEG │───── DAT SDK ───▶│ CameraPipeline (frames)  │
│  5-mic    16 kHz PCM   │                  │ AudioPipeline  (chunks)  │
│  speakers 24 kHz PCM   │◀──── DAT SDK ────│ TTS playback             │
└────────────────────────┘                  └─────────────┬────────────┘
                                                          │
                                                ┌─────────▼─────────┐
                                                │   MiniMax API     │
                                                │  /chatcompletion  │
                                                │  /t2a_v2 (speech) │
                                                │   model: M3       │
                                                └───────────────────┘
```

## ✨ Features

- **Live vision Q&A** — the latest glasses camera frame is attached to every
  MiniMax chat request so the model can describe what you're looking at.
- **Hands-free voice loop** — glasses mic → on-device STT → MiniMax chat →
  MiniMax TTS → glasses speakers.
- **Concise responses** — system prompt instructs MiniMax-M3 to keep replies
  to 1–2 sentences, suitable for spoken delivery.
- **Function calling** — extensible tool registry; ships with `get_current_time`
  and `save_note`. Add your own with a few lines of Swift.
- **Camera + audio passthrough preserved** — pressing the glasses' shutter
  button still records to the Meta AI app. RayBan AI only subscribes to the
  SDK stream; it never touches the native capture pipeline.
- **Dark, voice-first UI** — large status pill, live preview, and a single
  tap-to-talk button.

## 🧰 Tech stack

| Layer        | Choice                                                 |
|--------------|--------------------------------------------------------|
| Language     | Swift 5.9+                                             |
| UI           | SwiftUI (iOS 17+)                                      |
| Audio        | AVFoundation (AVAudioEngine + AVAudioSession)          |
| Speech-to-Text | `SFSpeechRecognizer` (on-device when available)      |
| Glasses      | MetaWearables SDK via SPM                              |
| AI           | MiniMax Chat Completion v2 (`MiniMax-M3`)              |
| TTS          | MiniMax `speech-2.8-hd` (hex MP3 → AVAudioPlayerNode)  |
| Build        | XcodeGen + xcodebuild                                  |

## 📁 Project structure

```
RayBanMiniMax/
├── RayBanMiniMax/
│   ├── App/                # @main entry, Info.plist
│   ├── Core/               # SessionManager, AudioPipeline, CameraPipeline,
│   │                       # DATBridge, AppSettings
│   ├── API/                # MiniMaxClient + Codable models + config
│   ├── AI/                 # ConversationStore, SystemPrompts, ToolRegistry
│   ├── STT/                # SpeechRecognizer (SFSpeechRecognizer wrapper)
│   ├── UI/                 # ContentView, ConnectionStatusView,
│   │                       # CameraPreviewView, SettingsView
│   ├── Utils/              # PCMConverter, HexDecoder, Logger
│   └── Resources/          # Assets, Config.template.plist
├── RayBanMiniMaxTests/     # Unit tests (XCTest, run via xcodebuild test)
├── scripts/
│   └── smoketest.sh        # Pure-utility smoke tests (no iOS SDK required)
├── project.yml             # XcodeGen spec
├── Package.swift           # SPM target for pure-utility smoke tests
├── Config.template.plist   # Template for Config.plist (real API key file)
└── README.md
```

## 🚀 Getting started

### 1. Prerequisites

| Requirement       | Version / Notes                                     |
|-------------------|------------------------------------------------------|
| macOS             | 14 (Sonoma) or later                                 |
| Xcode             | 15.4+ (Xcode 16 recommended for Swift 5.9+)          |
| iPhone            | iOS 17+ device                                       |
| Glasses           | Meta Ray-Ban Gen 2 (Developer Mode enabled)         |
| Meta AI app       | Installed, paired, latest version                    |
| MiniMax API key   | Get one at <https://platform.minimaxi.com>            |
| XcodeGen          | `brew install xcodegen` (one-time)                   |

### 2. Clone and bootstrap

```bash
git clone <your-fork-url> RayBanAI
cd RayBanAI/RayBanMiniMax

# Generate the Xcode project from project.yml
xcodegen generate

# (Optional) Run pure-utility smoke tests
./scripts/smoketest.sh
```

### 3. Add your MiniMax API key

There are three ways to provide the key. **Pick exactly one.**

a) **Info.plist at build time** (recommended for production)

   Set the `MINIMAX_API_KEY` environment variable in your Xcode scheme
   (`Edit Scheme → Run → Arguments → Environment Variables`).
   The `Info.plist` template expands `$(MINIMAX_API_KEY)` automatically.

b) **`Config.plist`** (recommended for development)

   ```bash
   cp Resources/Config.template.plist Resources/Config.plist
   $EDITOR Resources/Config.plist   # paste your real key
   ```

   `Config.plist` is git-ignored. Add it to the Xcode project as a build
   resource (or merge the values into Info.plist by hand).

c) **In-app at runtime**

   Open the app, tap the gear icon, paste your key, and tap **Save API Key**.
   The key is stored in `UserDefaults` and never leaves the device except
   in the `Authorization` header of MiniMax API calls.

### 4. Build & run

```bash
xcodebuild -project RayBanMiniMax.xcodeproj \
           -scheme RayBanMiniMax \
           -destination 'platform=iOS,name=Your iPhone' \
           build

# Or just open in Xcode and ⌘R
open RayBanMiniMax.xcodeproj
```

The first build will resolve the MetaWearables Swift package. After that,
incremental builds are fast.

### 5. Enable Developer Mode on the glasses

1. Open the **Meta AI** app on the same iPhone.
2. Go to **Settings → Developer Mode** and toggle it on.
3. Pair the glasses if you haven't already.

### 6. Run the unit tests

```bash
xcodebuild test -project RayBanMiniMax.xcodeproj \
                -scheme RayBanMiniMax \
                -destination 'platform=iOS Simulator,name=iPhone 15'
```

## 🧠 How it works

### Data flow — voice mode

```
User speaks
  → glasses mic (16 kHz Float32 PCM)
  → AudioPipeline chunks (100 ms, mono Int16)
  → SpeechRecognizer (on-device SFSpeechRecognizer)
  → transcript
  → MiniMaxClient.chatCompletion(messages + [optional image])
  → MiniMaxClient.textToSpeech(text)
  → AudioPipeline.playMP3
  → glasses speakers (24 kHz Float32 PCM)
```

### Data flow — vision mode

The camera pipeline receives ~1 JPEG per second from the DAT SDK, keeps the
most recent frame in memory, and base64-encodes it for the chat API:

```swift
let userMessage = ChatMessage(
    role: .user,
    content: .parts([
        ContentPart(type: .text, text: "What am I looking at?"),
        ContentPart(
            type: .imageURL,
            imageURL: ImageURL(
                url: "data:image/jpeg;base64,\(camera.latestFrame!.base64)",
                detail: "auto"
            )
        )
    ])
)
```

### Native capture is **never** broken

The glasses' physical button operates **completely independently** of your
app. A short press takes a photo, a long press records video, and both go
straight to the Meta AI app gallery. RayBan AI only *subscribes* to the DAT
SDK's camera publisher; it does not modify, intercept, or replace the
native capture pipeline. Programmatic captures via
`SessionManager.capturePhoto()` are also supported for the in-app "Photo"
button.

## 🛠️ Function calling (custom tools)

Add a new tool in three steps:

1. **Define it** in `AI/ToolRegistry.swift`:

   ```swift
   registry.register(Tool(
       definition: ToolDefinition(
           type: "function",
           function: ToolFunction(
               name: "send_message",
               description: "Send a text message to a contact.",
               parameters: JSONSchema(...)
           )
       ),
       handler: { args in
           let contact = args["contact"] as? String ?? ""
           let body    = args["body"]    as? String ?? ""
           // ... call Messages, return a one-line summary
           return .success("send_message", "Sent \"\(body)\" to \(contact).")
       }
   ))
   ```

2. The system prompt already mentions the available tools; the model will
   emit `finish_reason: "tool_calls"` automatically.

3. The `SessionManager.ask` orchestrator executes the tool calls, sends the
   results back as `role: "tool"` messages, and continues the loop.

## 🔑 API key security

- **Never** commit a real `MINIMAX_API_KEY` to git. `Config.plist`,
  `*.local`, and `.env` are all in `.gitignore`.
- The key is only sent in the `Authorization: Bearer <key>` header.
- It is never written to disk in plaintext outside of `UserDefaults`
  (when entered at runtime via the Settings screen).
- The Info.plist value is read-only at runtime; changing it requires a
  rebuild.

## 🐞 Troubleshooting

| Problem                              | Fix                                                    |
|--------------------------------------|--------------------------------------------------------|
| "Cannot find glasses"                | Re-pair in Meta AI; verify Bluetooth is on.            |
| "Developer Mode required"            | Toggle it under Meta AI → Settings → Developer Mode.   |
| "Authentication failed" (code 1004)  | Wrong API key. Get a new one at platform.minimaxi.com. |
| "Rate limit hit" (code 1002)         | Reduce query frequency; upgrade your plan.             |
| No audio from glasses                | Check `AudioPipeline` session activation; re-connect.  |
| Choppy TTS playback                  | Increase audio buffer size; check network latency.     |
| Slow responses (5+ sec)              | Use Speech-2.8-Turbo for TTS; reduce max_tokens.       |
| xcodebuild can't find SDK            | `xcode-select -s /Applications/Xcode.app/Contents/Developer` |

## 📚 Resources

- MiniMax API docs: <https://platform.minimaxi.com>
- Meta Wearables Dev Portal: <https://developers.meta.com/wearables>
- MetaWearables SDK (iOS): <https://github.com/meta-quest/MetaWearables-SDK-iOS>
- VisionClaw (reference implementation):
  <https://github.com/sseanliu/VisionClaw>

## 📄 License

MIT. See `LICENSE` (add one if shipping publicly).
