# RayBan AI

> **Turn your Meta Ray-Ban Gen 2 smart glasses into a MiniMax-M3-powered AI assistant.**

RayBan AI is a native iOS companion app built on Meta's official
[**Wearables Device Access Toolkit**](https://github.com/facebook/meta-wearables-dat-ios)
(DAT SDK, modules `MWDATCore` + `MWDATCamera`). It subscribes to the live
camera stream from your Meta Ray-Ban Gen 2 glasses, routes the user's
question plus the latest frame to the **MiniMax API** for chat + TTS, and
plays the spoken answer back through the iPhone (or AirPods / Bluetooth).

```
┌────────────────────────┐                  ┌──────────────────────────┐
│  Meta Ray-Ban Gen 2    │                  │   RayBan AI (iOS)        │
│  12MP cam  24fps raw   │───── DAT SDK ───▶│ CameraPipeline (1 fps)   │
│  5-mic     NOT public  │  (video only)    │                          │
│  speakers  NOT public  │                  │ iPhone mic → STT → text  │
│  (physical button OK)  │                  │ iPhone speaker ← TTS ← AI│
└────────────────────────┘                  └─────────────┬────────────┘
                                                          │
                                                ┌─────────▼─────────┐
                                                │   MiniMax API     │
                                                │  /chatcompletion  │
                                                │  /t2a_v2 (speech) │
                                                │   model: M3       │
                                                └───────────────────┘
```

## ⚠️ Honest architecture note

The DAT SDK **0.8.0** (verified against the upstream [CameraAccess sample](https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/CameraAccess))
ships only these modules:

| Module             | What it gives us                                          |
|--------------------|-----------------------------------------------------------|
| `MWDATCore`        | Device discovery, registration, session lifecycle         |
| `MWDATCamera`      | Live video stream + programmatic photo capture           |
| `MWDATDisplay`     | Render content on the glasses display (not used here)     |
| `MWDATMockDevice`  | Debug-only mock for the iOS Simulator                     |

It does **not** expose the glasses' microphone or speakers. So the voice
loop runs through the **iPhone's** built-in mic + speaker (or any
connected AirPods / Bluetooth, per `AVAudioSession` settings). The
glasses contribute vision and the physical capture button only.

When Meta ships audio APIs, the only files that need to change are
`Core/AudioPipeline.swift` and `Core/DATBridge.swift` — swap the input
node for the glasses' mic node the SDK hands us.

## ✨ Features

- **Live vision Q&A** — the latest glasses camera frame (throttled to
  ~1 fps from the 24 fps stream) is attached to every MiniMax chat
  request.
- **Hands-free voice loop** — iPhone mic → on-device STT → MiniMax chat
  → MiniMax TTS → iPhone speaker.
- **Concise responses** — system prompt instructs MiniMax-M3 to keep
  replies to 1–2 sentences, suitable for spoken delivery.
- **Function calling** — extensible tool registry; ships with
  `get_current_time` and `save_note`.
- **Native photo/video button preserved** — the glasses' physical
  shutter button continues to record to the Meta AI app. We only
  *subscribe* to the DAT SDK stream; we do not modify the native
  capture pipeline.
- **Programmatic high-res capture** — the in-app "Photo" button
  triggers `stream.capturePhoto(format: .jpeg)` and shows the result.
- **Dark, voice-first UI** — large status pill, live preview, tap-to-talk.

## 🧰 Tech stack

| Layer        | Choice                                                  |
|--------------|---------------------------------------------------------|
| Language     | Swift 6.0+                                              |
| UI           | SwiftUI (iOS 17+)                                       |
| Audio        | AVFoundation (`AVAudioEngine` + `AVAudioSession`)       |
| Speech-to-Text | `SFSpeechRecognizer` (on-device when available)       |
| Glasses      | [meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) via SPM |
| AI           | MiniMax Chat Completion v2 (`MiniMax-M3`)               |
| TTS          | MiniMax `speech-2.8-hd` (hex MP3 → `AVAudioPlayerNode`) |
| Build        | XcodeGen + Xcode 16+                                    |

## 📁 Project structure

```
RayBanMiniMax/
├── RayBanMiniMax/
│   ├── App/                # @main entry, Info.plist
│   ├── Core/               # SessionManager, AudioPipeline, CameraPipeline,
│   │                       # DATBridge, AppSettings
│   ├── API/                # MiniMaxClient + Codable models + config
│   ├── AI/                 # ConversationStore, SystemPrompts, ToolRegistry
│   ├── STT/                # SpeechRecognizer
│   ├── UI/                 # ContentView, ConnectionStatusView,
│   │                       # CameraPreviewView, SettingsView
│   ├── Utils/              # PCMConverter, HexDecoder, Logger
│   └── Resources/          # Assets, Config.template.plist
├── RayBanMiniMaxTests/     # XCTest target
├── scripts/
│   └── smoketest.sh        # Pure-utility smoke tests (no Xcode required)
├── project.yml             # XcodeGen spec (with real MetaWearables SDK)
├── Package.swift           # Auxiliary Swift Package for utility tests
└── README.md
```

## 🚀 Getting started

### 1. Prerequisites

| Requirement       | Version / Notes                                              |
|-------------------|--------------------------------------------------------------|
| macOS             | 14 (Sonoma) or later                                         |
| Xcode             | **16 or newer** (required — the DAT SDK needs Swift 6.0+)    |
| iPhone            | iOS 17+ device                                               |
| Glasses           | Meta Ray-Ban Gen 2 (Developer Mode enabled)                 |
| Meta AI app       | Installed, paired, latest version                            |
| MiniMax API key   | Get one at <https://platform.minimaxi.com>                   |
| XcodeGen          | `brew install xcodegen` (one-time)                           |

### 2. Clone and bootstrap

```bash
cd RayBanMiniMax
xcodegen generate          # one-time
open -a Xcode RayBanMiniMax.xcodeproj
# or
xcodebuild -scheme RayBanMiniMax \
           -destination 'platform=iOS,name=ahmad'\''s iPhone' \
           build
```

The first build will resolve the MetaWearables-DAT Swift package from
GitHub. After that, incremental builds are fast.

### 3. Add your MiniMax API key

There are three ways to provide the key. **Pick exactly one.**

a) **Build-time environment variable** (recommended for production)

   Set the `MINIMAX_API_KEY` env var in your Xcode scheme
   (`Edit Scheme → Run → Arguments → Environment Variables`).
   The `Info.plist` template expands `$(MINIMAX_API_KEY)` at build time.

b) **`Config.plist`** (recommended for development)

   ```bash
   cp Resources/Config.template.plist Resources/Config.plist
   $EDITOR Resources/Config.plist   # paste your real key
   ```

   `Config.plist` is git-ignored. Add it to the Xcode project as a build
   resource (or merge the values into Info.plist by hand).

c) **In-app at runtime**

   Open the app → tap the gear icon → paste your key → **Save API Key**.
   The key is stored in `UserDefaults` and never leaves the device except
   in the `Authorization` header of MiniMax API calls.

### 4. Enable Developer Mode on the glasses

1. Open the **Meta AI** app on the same iPhone.
2. Go to **Settings → Developer Mode** → toggle it on.
3. Pair the glasses if you haven't already.

### 5. Run the unit tests

```bash
xcodebuild test -project RayBanMiniMax.xcodeproj \
                -scheme RayBanMiniMax \
                -destination 'platform=iOS Simulator,name=iPhone 15'
```

Or `./scripts/smoketest.sh` for the pure-utility tests that need no
Xcode.

## 🧠 How it works

### Data flow — voice + vision mode

```
User speaks
  → iPhone mic (16 kHz Float32 PCM)
  → AudioPipeline chunks (100 ms, mono Int16)
  → SpeechRecognizer (on-device SFSpeechRecognizer)
  → transcript
  → MiniMaxClient.chatCompletion(messages + [optional DAT frame])
  → MiniMaxClient.textToSpeech(text)
  → AudioPipeline.playMP3
  → iPhone speaker (or AirPods / Bluetooth, 24 kHz Float32 PCM)
```

### Data flow — DAT camera stream

```
Glasses camera (24 fps raw video, via MWDATCamera.Stream)
  → DATBridge throttles to ~1 fps in `handleVideoFrame`
  → JPEG re-encode (q=0.7)
  → CameraPipeline.ingest(datFrame:)
  → latestFrame (UIImage + base64)
  → MiniMax vision request (when user asks)
```

### Native photo capture is **never** broken

The glasses' physical button operates completely independently of this
app. A short press takes a photo, a long press records video, and both
go straight to the Meta AI app gallery. We only *subscribe* to the DAT
SDK's video stream and call `stream.capturePhoto()` for the in-app
"Photo" button — we never touch the native capture pipeline.

## 🛠️ Function calling (custom tools)

Add a new tool in `AI/ToolRegistry.swift`:

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

The system prompt already mentions the available tools; the model will
emit `finish_reason: "tool_calls"` automatically, and `SessionManager`
executes the handlers and re-queries with `role: "tool"` messages.

## 🔑 API key security

- **Never** commit a real `MINIMAX_API_KEY`. `Config.plist`, `*.local`,
  and `.env` are in `.gitignore`.
- The key is only sent in the `Authorization: Bearer <key>` header.
- It is never written to disk in plaintext outside of `UserDefaults`
  (when entered at runtime via the Settings screen).
- The Info.plist value is read-only at runtime; changing it requires a
  rebuild.

## 🐞 Troubleshooting

| Problem                              | Fix                                                       |
|--------------------------------------|-----------------------------------------------------------|
| `Authentication failed for github.com` when building | The project now points at `facebook/meta-wearables-dat-ios`. Re-run `xcodegen generate`. |
| "Cannot find glasses"                | Re-pair in Meta AI; verify Bluetooth is on.               |
| "Developer Mode required"            | Toggle it under Meta AI → Settings → Developer Mode.      |
| "Authentication failed" (MiniMax 1004)| Wrong API key. Get a new one at platform.minimaxi.com.    |
| "Rate limit hit" (1002)              | Reduce query frequency; upgrade your plan.                |
| No audio on the iPhone                | Check `AudioPipeline` session activation; re-connect.     |
| Slow responses (5+ sec)               | Use Speech-2.8-Turbo for TTS; reduce `max_tokens`.       |
| `swift_tools_version 6.0` error       | Open the project in **Xcode 16+** (Xcode 15 is too old).  |

## 📚 Resources

- MiniMax API: <https://platform.minimaxi.com>
- Meta Wearables Dev Portal: <https://wearables.developer.meta.com>
- DAT SDK iOS: <https://github.com/facebook/meta-wearables-dat-ios>
- DAT SDK docs: <https://wearables.developer.meta.com/docs/develop/>

## 📄 License

MIT. See `LICENSE`.
