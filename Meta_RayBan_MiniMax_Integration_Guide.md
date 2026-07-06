# Meta Ray-Ban Gen 2 + MiniMax API Integration Guide
## Intercept/Extend Architecture — Full Implementation Guide

> **Last Updated:** July 6, 2026  
> **Status:** Meta Wearables DAT SDK is in Developer Preview  
> **Goal:** Use any AI model (MiniMax) on Ray-Ban Meta Gen 2 while keeping native photo/video capture

---

## Table of Contents

1. [What You're Actually Building](#what-youre-actually-building)
2. [Architecture Overview](#architecture-overview)
3. [How It Works](#how-it-works)
4. [MiniMax API Integration](#minimax-api-integration)
5. [Step-by-Step Implementation](#step-by-step-implementation)
6. [Audio Pipeline](#audio-pipeline)
7. [Keeping Photo/Video Working](#keeping-photovideo-working)
8. [Adding Your Own Features](#adding-your-own-features)
9. [Critical Limitations](#critical-limitations)
10. [Existing Projects to Fork](#existing-projects-to-fork)
11. [Cost Estimates](#cost-estimates)
12. [Full Code Example](#full-code-example)
13. [Troubleshooting](#troubleshooting)
14. [Resources & Links](#resources--links)

---

## What You're Actually Building

**You are NOT replacing the OS.** The Meta Ray-Ban Gen 2 runs a locked-down embedded OS on a Qualcomm AR1 Gen 1 chip. Meta controls the bootloader, camera drivers, NPU acceleration, and wireless certification. You cannot replace the OS and keep camera/video working without Meta's closed-source drivers.

**Instead, you build a custom companion app** on your phone that sits between the glasses and the cloud, swapping out Meta AI for MiniMax API. This uses Meta's official **Device Access Toolkit (DAT SDK)** — a legitimate, sanctioned developer interface released in late 2025.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           META RAY-BAN GEN 2                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  12MP Cam   │  │ 5-Mic Array │  │Open-Ear Spk │  │  Snapdragon AR1     │ │
│  │  (POV)      │  │  (Audio In) │  │ (Audio Out) │  │  (Locked OS)        │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────────────────────┘ │
│         │                │                │                                    │
│         │  JPEG ~1fps    │  16kHz PCM     │  24kHz PCM                       │
│         │                │                │                                    │
│         └────────────────┴────────────────┘                                    │
│                          │                                                   │
│                    Bluetooth/Wi-Fi                                             │
└──────────────────────────┼───────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         YOUR PHONE (iOS/Android)                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              YOUR CUSTOM APP (VisionClaw-style)                      │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │    │
│  │  │ MetaWearables │  │ Audio Pipeline│  │   MiniMax Integration    │  │    │
│  │  │   DAT SDK     │  │  (PCM/I16)   │  │                          │  │    │
│  │  │               │  │              │  │  ┌────────────────────┐  │  │    │
│  │  │ • Camera sub  │  │ • Capture    │  │  │ Chat Completion    │  │  │    │
│  │  │ • Audio sub   │  │ • Resample   │  │  │ (MiniMax-M1)       │  │  │    │
│  │  │ • Registration│  │ • AEC        │  │  │                    │  │  │    │
│  │  │               │  │ • Playback   │  │  │ POST /v1/text/     │  │  │    │
│  │  │               │  │              │  │  │   chatcompletion_v2│  │  │    │
│  │  └──────┬───────┘  └──────┬───────┘  │  └────────────────────┘  │  │    │
│  │         │                 │          │                          │  │    │
│  │         │  Video Frames   │ Audio    │  ┌────────────────────┐  │  │    │
│  │         │  (~1 JPEG/sec)  │ Streams  │  │ TTS (Speech-2.8)   │  │  │    │
│  │         │                 │          │  │                    │  │  │    │
│  │         │                 │          │  │ POST /v1/t2a_v2    │  │  │    │
│  │         │                 │          │  │                    │  │  │    │
│  │         │                 │          │  └────────────────────┘  │  │    │
│  │         │                 │          │                          │  │    │
│  │         └─────────────────┴──────────┴──────────────────────────┘  │    │
│  │                              │                                        │    │
│  │                         Session Manager                              │    │
│  │                    (Orchestrates video→AI→audio flow)                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                           │                                                 │
│                           ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              Meta AI App (Required - handles pairing)                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CLOUD / BACKEND                                  │
│  ┌─────────────────────────────┐  ┌─────────────────────────────────────┐ │
│  │      MiniMax API              │  │      Optional: Custom Features      │ │
│  │  ┌─────────────────────────┐  │  │  ┌─────────────────────────────┐  │ │
│  │  │  Chat Completion v2     │  │  │  │  Memory / Context Store     │  │ │
│  │  │  (MiniMax-M1 / Text-01) │  │  │  │  (User preferences, history)│  │ │
│  │  │                         │  │  │  └─────────────────────────────┘  │ │
│  │  │  • Multimodal (text+img)│  │  │  ┌─────────────────────────────┐  │ │
│  │  │  • Function calling     │  │  │  │  Custom Tools / Actions     │  │ │
│  │  │  • 1M context window    │  │  │  │  (Calendar, notes, search)  │  │ │
│  │  └─────────────────────────┘  │  │  └─────────────────────────────┘  │ │
│  │  ┌─────────────────────────┐  │  │  ┌─────────────────────────────┐  │ │
│  │  │  TTS (Speech-2.8-HD)    │  │  │  │  WebRTC Signaling (opt)     │  │ │
│  │  │                         │  │  │  │  (Live POV streaming)       │  │ │
│  │  │  • 300+ voices          │  │  │  └─────────────────────────────┘  │ │
│  │  │  • Emotion control      │  │  │                                    │ │
│  │  │  • Sound tags           │  │  └─────────────────────────────────────┘ │
│  │  │  • Voice cloning        │  │
│  │  └─────────────────────────┘  │
│  └─────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## How It Works

### Data Flow: Voice Mode
```
User speaks → Glasses mic (16kHz PCM) → Phone app → Speech-to-Text 
→ MiniMax Chat API → MiniMax TTS (Speech-2.8-HD) → Phone app 
→ Glasses speakers (24kHz PCM)
```

### Data Flow: Vision Mode (What You See)
```
User speaks + Glasses camera frame (~1 fps JPEG) → Phone app 
→ MiniMax Chat API (with image_url in messages) 
→ MiniMax TTS → Glasses speakers
```

### Data Flow: Native Photo/Video (Unchanged)
```
User presses capture button → Glasses → Meta AI App → Phone gallery
(Your app can ALSO trigger captures programmatically via DAT SDK)
```

---

## MiniMax API Integration

### A. Chat Completion (AI Brain)

**Endpoint:** `POST https://api.minimaxi.com/v1/text/chatcompletion_v2`

**Headers:**
```
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

**Available Models:**

| Model | Description | Max Tokens | Context |
|-------|-------------|------------|---------|
| `MiniMax-M1` | Frontier coding/agentic model, multimodal | 1,000,192 | 1M |
| `MiniMax-Text-01` | General purpose, multimodal | 1,000,192 | 1M |
| `MiniMax-M2.7` | Self-iterating model | 1,000,192 | 1M |
| `MiniMax-M2.7-highspeed` | Faster variant of M2.7 | 1,000,192 | 1M |

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `model` | string | Yes | — | Model ID |
| `messages` | array | Yes | — | Conversation history |
| `stream` | bool | No | false | Stream response chunks |
| `max_tokens` | int | No | 8192 (M1) / 2048 (Text-01) | Max generation length |
| `temperature` | float | No | 1.0 (M1) / 0.1 (Text-01) | Randomness (0-1] |
| `top_p` | float | No | 0.95 | Nucleus sampling |
| `tool_choice` | string | No | "none" | "auto" or "none" |
| `tools` | array | No | — | Function definitions |
| `mask_sensitive_info` | bool | No | false | Mask PII in output |
| `response_format` | object | No | — | JSON schema for structured output (Text-01 only) |

**Message Format:**
```json
{
  "role": "system|user|assistant|tool",
  "name": "optional_name",
  "content": "text string" OR [
    {"type": "text", "text": "..."},
    {"type": "image_url", "image_url": {"url": "https://..." OR "data:image/jpeg;base64,..."}}
  ]
}
```

**Basic Request Example:**
```json
{
  "model": "MiniMax-M1",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
  ],
  "stream": false,
  "max_tokens": 2048
}
```

**Multimodal (Vision) Request Example:**
```json
{
  "model": "MiniMax-M1",
  "messages": [
    {"role": "system", "content": "You are a helpful glasses AI. Be concise."},
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "What am I looking at?"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}}
      ]
    }
  ],
  "stream": false
}
```

**Response Format:**
```json
{
  "id": "03d3f5bd571f85faa1d980d2f779630f",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "Hello! How can I help you today?",
        "role": "assistant",
        "name": "MiniMax AI"
      }
    }
  ],
  "created": 1736753853,
  "model": "MiniMax-M1",
  "object": "chat.completion",
  "usage": {
    "total_tokens": 70,
    "prompt_tokens": 62,
    "completion_tokens": 8
  },
  "input_sensitive": false,
  "output_sensitive": false,
  "base_resp": {
    "status_code": 0,
    "status_msg": ""
  }
}
```

**Error Codes:**

| Code | Meaning |
|------|---------|
| 1000 | Unknown error |
| 1001 | Request timeout |
| 1002 | RPM rate limit triggered |
| 1004 | Authentication failed |
| 1008 | Insufficient balance |
| 1013 | Internal server error |
| 1027 | Output content error |
| 1039 | Token limit exceeded |
| 2013 | Parameter error |

**OpenAI SDK Compatible:**
```python
from openai import OpenAI

client = OpenAI(
    api_key="YOUR_MINIMAX_API_KEY",
    base_url="https://api.minimaxi.com/v1"
)

response = client.chat.completions.create(
    model="MiniMax-M1",
    messages=[
        {"role": "system", "content": "You are helpful."},
        {"role": "user", "content": "Hello!"}
    ],
    stream=True
)

for chunk in response:
    print(chunk.choices[0].delta.content or "", end="")
```

---

### B. Text-to-Speech (Voice Output)

**Endpoint:** `POST https://api.minimax.io/v1/t2a_v2`

**Headers:**
```
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

**Models:**

| Model | Description |
|-------|-------------|
| `speech-2.8-hd` | High-definition, natural speech with emotion |
| `speech-2.8-turbo` | Faster generation, slightly less quality |

**Request Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `model` | string | Yes | — | "speech-2.8-hd" or "speech-2.8-turbo" |
| `text` | string | Yes | — | Text to synthesize (max 10,000 chars) |
| `stream` | bool | No | false | Stream audio chunks |
| `output_format` | string | No | "hex" | "hex" or "url" |
| `language_boost` | string | No | "auto" | "auto" or specific language code |
| `voice_setting` | object | Yes | — | Voice configuration |
| `audio_setting` | object | Yes | — | Audio output configuration |

**Voice Setting:**
```json
{
  "voice_id": "English_expressive_narrator",
  "speed": 1.0,
  "vol": 1.0,
  "pitch": 0,
  "emotion": "neutral"
}
```

**Available Voice IDs (300+ total):**
- `English_expressive_narrator`
- `English_calm_female`
- `English_energetic_male`
- `Chinese_expressive_narrator`
- `Japanese_calm_female`
- `Spanish_energetic_male`
- And 300+ more...

**Emotion Options:** `neutral`, `happy`, `sad`, `angry`, `fearful`, `disgusted`, `surprised`, `calm`, `excited`

**Sound Tags (inline in text):**
- `(laughs)` — laughter
- `(sighs)` — sighing
- `(breath)` — breathing sound
- `(coughs)` — coughing
- `(clears throat)` — throat clearing

**Audio Setting:**
```json
{
  "sample_rate": 32000,
  "bitrate": 128000,
  "format": "mp3",
  "channel": 1
}
```

**Voice Cloning:**
- Upload 10-second voice sample
- Get custom `voice_id` for personalized TTS

**Request Example:**
```json
{
  "model": "speech-2.8-hd",
  "text": "I see a red brick building with large windows. (breath) It looks like a converted warehouse.",
  "stream": false,
  "output_format": "hex",
  "voice_setting": {
    "voice_id": "English_expressive_narrator",
    "speed": 1,
    "vol": 1,
    "pitch": 0,
    "emotion": "neutral"
  },
  "audio_setting": {
    "sample_rate": 32000,
    "bitrate": 128000,
    "format": "mp3",
    "channel": 1
  }
}
```

**Response (hex format):**
```json
{
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  },
  "data": {
    "audio": "0000001c667479706d703432000000006d7034316d70343269736f6d00000008...",
    "status": 2,
    "subtitle": [
      {
        "text": "I see a red brick building with large windows.",
        "start_time": 0,
        "end_time": 3200,
        "index": 0
      }
    ]
  }
}
```

**Decode hex audio:**
```python
import binascii

audio_hex = response["data"]["audio"]
audio_bytes = binascii.unhexlify(audio_hex)
# audio_bytes is now MP3 data ready to play
```

---

### C. Function Calling (Custom Tools)

MiniMax-M1 supports function calling, allowing your AI to trigger custom actions:

```json
{
  "model": "MiniMax-M1",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What's the weather in Beijing?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"},
            "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
          },
          "required": ["location"]
        }
      }
    }
  ],
  "tool_choice": "auto"
}
```

When the model decides to call a function, the response will have `finish_reason: "tool_calls"` with the function name and arguments. Your app executes the function, then sends the result back in a follow-up message with `role: "tool"`.

---

## Step-by-Step Implementation

### Step 1: Prerequisites

| Requirement | Details |
|-------------|---------|
| Hardware | Meta Ray-Ban Gen 2 glasses |
| Phone | iPhone (iOS 17+) or Android (14+, SDK 31+) |
| Meta AI App | Installed, glasses paired, Developer Mode ON |
| Dev Account | Meta Wearables Developer (free at developers.meta.com) |
| IDE | Xcode (macOS) or Android Studio |
| API Key | MiniMax API key from platform.minimax.io |

### Step 2: Enable Developer Mode on Glasses

1. Open **Meta AI** app on your phone
2. Go to **Settings** → **Developer Mode**
3. Toggle **Enable Developer Mode**
4. This allows third-party apps to register with your glasses via the DAT SDK

### Step 3: Register Your App with Meta

1. Go to https://developers.meta.com/wearables
2. Create a new **Organization**
3. Create a new **App Project**
4. Add your app's **Bundle ID** (iOS) or **Package Name** (Android)
   - Example iOS: `com.yourcompany.raybanai`
   - Example Android: `com.yourcompany.raybanai`
5. Download the config file and add it to your project

### Step 4: Add MetaWearables SDK

**iOS (Swift Package Manager):**
1. In Xcode: **File** → **Add Package Dependencies**
2. URL: `https://github.com/meta-quest/MetaWearables-SDK-iOS`
3. Select latest version

**Android (build.gradle):**
```gradle
dependencies {
    implementation 'com.meta.wearables:dat-sdk:1.0.0'
}
```

### Step 5: Implement Core Connection

```swift
import MetaWearablesSDK
import AVFoundation

class GlassesSessionManager {
    private var session: MetaWearablesSession?
    private let miniMaxClient = MiniMaxClient(apiKey: "YOUR_API_KEY")
    private var latestFrameBase64: String?
    private var conversationHistory: [[String: Any]] = []

    // MARK: - Connect to Glasses
    func connect() async throws {
        // Initialize session
        session = try await MetaWearables.connect()

        // Start camera frame subscription (~1 fps JPEG)
        let cameraStream = try await session!.startCamera(
            resolution: .high,
            frameRate: 1
        )

        Task {
            for await frame in cameraStream {
                await processCameraFrame(frame)
            }
        }

        // Start audio capture from glasses mic (16kHz Float32 PCM)
        try await session!.startAudioCapture { [weak self] audioFrame in
            self?.processAudioInput(audioFrame)
        }

        print("✅ Connected to Ray-Ban Meta glasses")
    }

    // MARK: - Process Camera Frame
    private func processCameraFrame(_ frame: CameraFrame) async {
        guard let imageData = frame.jpegData else { return }
        latestFrameBase64 = imageData.base64EncodedString()
    }

    // MARK: - Process Audio Input
    private func processAudioInput(_ audioFrame: AudioFrame) {
        // Convert Float32 PCM to Int16, resample to 16kHz mono
        // Accumulate ~100ms chunks
        // Send to Speech-to-Text (Whisper, Azure, etc.)
        // When speech detected → triggerAIQuery()
    }

    // MARK: - Trigger AI Query
    func triggerAIQuery(userSpeechText: String) {
        // Build multimodal message
        var userMessage: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": userSpeechText]
            ]
        ]

        // Attach latest camera frame if available
        if let frameBase64 = latestFrameBase64 {
            var content = userMessage["content"] as! [[String: Any]]
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(frameBase64)"]
            ])
            userMessage["content"] = content
        }

        // Build messages array with history
        var messages: [[String: Any]] = [
            ["role": "system", "content": "You are a helpful AI assistant in smart glasses. Keep responses concise (1-2 sentences) since they will be spoken aloud."]
        ]
        messages.append(contentsOf: conversationHistory.suffix(20))
        messages.append(userMessage)

        // Call MiniMax Chat API
        miniMaxClient.chatCompletion(messages: messages) { [weak self] result in
            switch result {
            case .success(let aiResponse):
                // Update history
                self?.conversationHistory.append(userMessage)
                self?.conversationHistory.append([
                    "role": "assistant",
                    "content": aiResponse
                ])

                // Speak response
                self?.speakResponse(aiResponse)

            case .failure(let error):
                print("❌ Chat Error: \(error)")
            }
        }
    }

    // MARK: - Text to Speech + Playback
    private func speakResponse(_ text: String) {
        miniMaxClient.textToSpeech(text: text) { [weak self] result in
            switch result {
            case .success(let audioData):
                self?.playAudioThroughGlasses(audioData)
            case .failure(let error):
                print("❌ TTS Error: \(error)")
            }
        }
    }

    private func playAudioThroughGlasses(_ audioData: Data) {
        // Decode MP3, resample to 24kHz, convert to Float32 PCM
        guard let pcmBuffer = decodeMP3ToPCM(audioData, targetSampleRate: 24000) else {
            return
        }
        session?.playAudio(pcmBuffer)
    }
}
```

### Step 6: MiniMax API Client (Swift)

```swift
import Foundation

class MiniMaxClient {
    private let apiKey: String
    private let chatURL = "https://api.minimaxi.com/v1/text/chatcompletion_v2"
    private let ttsURL = "https://api.minimax.io/v1/t2a_v2"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: Chat Completion
    func chatCompletion(
        messages: [[String: Any]],
        model: String = "MiniMax-M1",
        stream: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: chatURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "max_tokens": 2048,
            "temperature": 0.7
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(.failure(NSError(domain: "MiniMax", code: -1)))
                return
            }

            completion(.success(content))
        }.resume()
    }

    // MARK: Text to Speech
    func textToSpeech(
        text: String,
        voiceId: String = "English_expressive_narrator",
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let url = URL(string: ttsURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "speech-2.8-hd",
            "text": text,
            "stream": false,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceId,
                "speed": 1.0,
                "vol": 1.0,
                "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000,
                "bitrate": 128000,
                "format": "mp3",
                "channel": 1
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = json["data"] as? [String: Any],
                  let audioHex = responseData["audio"] as? String,
                  let audioData = Data(hexString: audioHex) else {
                completion(.failure(NSError(domain: "MiniMax", code: -2)))
                return
            }

            completion(.success(audioData))
        }.resume()
    }
}

// MARK: - Hex String to Data Extension
extension Data {
    init?(hexString: String) {
        let length = hexString.count
        guard length % 2 == 0 else { return nil }

        var data = Data(capacity: length / 2)
        var index = hexString.startIndex

        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            if let byte = UInt8(hexString[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }

        self = data
    }
}
```

---

## Audio Pipeline

### Capture Path (Glasses → Your App → MiniMax)

```
Glasses Mic
  Format: Float32 PCM, 16kHz, mono
  ↓
Your App Processing
  1. Convert Float32 → Int16
  2. Resample to 16kHz mono (if needed)
  3. Accumulate into ~100ms chunks
  4. Apply echo cancellation (AEC)
  ↓
Speech-to-Text (STT)
  Options:
  • OpenAI Whisper API
  • Azure Speech-to-Text
  • Google Cloud Speech
  • On-device Whisper (slower but private)
  ↓
Text Output → Sent to MiniMax Chat API
```

### Playback Path (MiniMax → Your App → Glasses)

```
MiniMax TTS Response
  Format: Hex-encoded MP3, 32kHz, mono
  ↓
Your App Processing
  1. Decode hex → MP3 bytes
  2. Decode MP3 to raw PCM
  3. Resample from 32kHz → 24kHz
  4. Convert to Float32 PCM
  5. Normalize audio levels
  ↓
Glasses Speakers
  Format: Float32 PCM, 24kHz
```

### Echo Cancellation

| Mode | AEC Strategy |
|------|-------------|
| iPhone companion | Aggressive AEC (mic and speaker close together) |
| Glasses mode | Mild AEC (mic and speakers physically separated) |

---

## Keeping Photo/Video Working

The native capture button on the glasses operates **completely independently** of your custom app:

| Action | Behavior | Destination |
|--------|----------|-------------|
| Short press | Take photo | Phone gallery via Meta AI app |
| Long press | Record video | Phone gallery via Meta AI app |

Your app can **also** trigger captures programmatically:

```swift
// Trigger high-res photo capture via DAT SDK
try await session.capturePhoto()

// Returns: high-resolution JPEG image
// Also saves to phone gallery automatically
```

And you can subscribe to the camera stream for real-time AI vision without interfering with native capture:

```swift
// Real-time stream (~1 fps) for AI processing
let stream = try await session.startCamera(resolution: .high, frameRate: 1)
for await frame in stream {
    // Process frame for MiniMax vision API
    // Does NOT affect native photo/video capture
}
```

---

## Adding Your Own Features

Because you control the entire app code, you can layer on any features:

### 1. Custom Wake Words
Replace "Hey Meta" with your own wake word:
- **Porcupine** (picovoice.ai) — On-device, fast, multiple wake words
- **Whisper** — More accurate but requires cloud or powerful on-device processing
- **Azure Custom Voice** — Cloud-based wake word detection

```swift
// Example with Porcupine
let porcupine = try Porcupine.create(
    accessKey: "YOUR_ACCESS_KEY",
    keywordPaths: ["Hey-Custom_en_ios_v3_0_0.ppn"]
)

// In audio callback:
let keywordIndex = porcupine.process(pcmFrame)
if keywordIndex >= 0 {
    // Wake word detected! Start listening for command
    startRecordingCommand()
}
```

### 2. Memory & Context
Store conversation history in your own database:

```swift
// SQLite example
class ConversationStore {
    func saveMessage(role: String, content: String, timestamp: Date) {
        // Persist to SQLite
    }

    func getRecentMessages(limit: Int = 20) -> [[String: Any]] {
        // Retrieve last N messages for context
    }

    func searchMemory(query: String) -> [String] {
        // Semantic search through past conversations
    }
}
```

### 3. Custom Tools (Function Calling)
Use MiniMax function calling to trigger real-world actions:

```swift
// Define tools
let tools: [[String: Any]] = [
    [
        "type": "function",
        "function": [
            "name": "send_message",
            "description": "Send a text message to a contact",
            "parameters": [
                "type": "object",
                "properties": [
                    "contact": ["type": "string"],
                    "message": ["type": "string"]
                ],
                "required": ["contact", "message"]
            ]
        ]
    ],
    [
        "type": "function",
        "function": [
            "name": "add_calendar_event",
            "description": "Add an event to calendar",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "datetime": ["type": "string"]
                ],
                "required": ["title", "datetime"]
            ]
        ]
    ]
]

// When model returns tool_calls, execute and send result back
```

### 4. Live POV Streaming
Add WebRTC to share your glasses' point of view:

```swift
// VisionClaw includes this feature
// Generates 6-character room code
// Viewers watch via browser
// Video: 2.5 Mbps cap, 24fps max
// Signaling server: Node.js with ws library
// Deploy on Fly.io or similar
```

### 5. Custom Voice (Voice Cloning)
Clone your own voice with MiniMax:

```json
// Upload 10-second voice sample
// Get custom voice_id
// Use in TTS requests
{
  "voice_setting": {
    "voice_id": "your_custom_voice_id",
    "speed": 1,
    "vol": 1,
    "pitch": 0
  }
}
```

### 6. Emotion-Aware Responses
Set TTS emotion based on AI response content:

```swift
func detectEmotion(from text: String) -> String {
    if text.contains("!"), text.contains("great") {
        return "excited"
    } else if text.contains("sorry"), text.contains("unfortunately") {
        return "sad"
    }
    return "neutral"
}

// Use in TTS request
let emotion = detectEmotion(from: aiResponse)
// Set "emotion": emotion in voice_setting
```

---

## Critical Limitations

| Limitation | Details | Workaround |
|------------|---------|------------|
| **~1 fps camera stream** | JPEG frames, not smooth video | Fine for object ID; use native capture for video |
| **Cannot intercept "Hey Meta"** | Meta's wake word is locked | Use your own wake word (Porcupine, Whisper) |
| **SDK is Developer Preview** | No public App Store distribution | Use TestFlight (iOS) or internal testing (Android) |
| **Battery drain** | Continuous streaming drains faster | Implement session timeouts; batch operations |
| **Audio latency** | 2-5 second round-trip | Use streaming responses; optimize STT pipeline |
| **No display/HUD** | Gen 2 has no screen | Audio-only responses; use phone screen for visuals |
| **Meta AI app required** | Must stay installed as bridge | Keep app installed; it handles pairing |
| **SDK API changes** | DAT SDK evolves between versions | Pin to specific version; check release notes |
| **No on-device LLM** | Glasses NPU is locked | All AI processing happens on phone or cloud |
| **Frame rate limits** | ~1 fps for AI stream | Accept limitation; use native capture for full-res |

---

## Existing Projects to Fork

### 1. VisionClaw (Recommended Starting Point)
- **Author:** Xiaoan (Sean Liu, @_seanliu)
- **Repo:** github.com/sseanliu/VisionClaw
- **What it does:** Real-time AI assistant for Ray-Ban Meta using Gemini Live API + OpenClaw
- **Platforms:** iOS (primary), Android
- **Features:**
  - Bidirectional audio streaming (16kHz in, 24kHz out)
  - Camera frame subscription (~1 fps JPEG)
  - WebRTC live POV streaming
  - Function calling via OpenClaw
  - iPhone camera fallback mode
- **Why fork it:** The DAT SDK connection, audio pipeline, and WebRTC are already solved. Just replace Gemini API calls with MiniMax API calls.

### 2. meta-glasses-api
- **Author:** dcrebbin
- **Repo:** github.com/dcrebbin/meta-glasses-api
- **What it does:** Browser extension that intercepts Messenger chats to route to ChatGPT/Claude
- **Architecture:** Different approach — tricks glasses into sending messages to a fake Messenger contact
- **Use case:** Good reference for understanding how glasses communicate with phone, but different architecture than DAT SDK approach

---

## Cost Estimates

### MiniMax API Pricing

| Service | Model | Approximate Cost |
|---------|-------|-----------------|
| Chat Completion | MiniMax-M1 | ~$0.50–2.00 per 1M tokens (input + output) |
| Chat Completion | MiniMax-Text-01 | ~$0.30–1.50 per 1M tokens |
| TTS | Speech-2.8-HD | ~$130 per 1M characters |
| TTS | Speech-2.8-Turbo | ~$65 per 1M characters |

### Typical Session Cost

| Scenario | Tokens/Chars | Cost |
|----------|-------------|------|
| 10-turn conversation (text only) | ~5K tokens | ~$0.01–0.05 |
| 10-turn conversation (with vision) | ~15K tokens + images | ~$0.05–0.15 |
| 20-turn session with TTS | ~10K tokens + 500 chars | ~$0.10–0.30 |

### Other Costs

| Service | Cost | Notes |
|---------|------|-------|
| Speech-to-Text (Whisper API) | $0.006/minute | Or use free on-device Whisper |
| WebRTC signaling server | $5–20/month | Fly.io or similar |
| Cloud hosting (optional) | $10–50/month | If running backend services |

---

## Full Code Example

### SwiftUI App Interface

```swift
import SwiftUI
import MetaWearablesSDK

struct ContentView: View {
    @StateObject private var viewModel = GlassesViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Connection Status
                HStack {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.isConnected ? "Glasses Connected" : "Disconnected")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)

                // Camera Preview
                if let frame = viewModel.latestFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 200)
                        .cornerRadius(12)
                        .padding(.horizontal)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 200)
                        .cornerRadius(12)
                        .overlay(Text("No camera feed"))
                        .padding(.horizontal)
                }

                // AI Response
                VStack(alignment: .leading) {
                    Text("AI Response")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(viewModel.aiResponse)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                // Controls
                HStack(spacing: 20) {
                    Button(action: { viewModel.connect() }) {
                        Label("Connect", systemImage: "wifi")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { viewModel.askAI() }) {
                        Label("Ask AI", systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isConnected)

                    Button(action: { viewModel.capturePhoto() }) {
                        Label("Photo", systemImage: "camera.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isConnected)
                }
                .padding()

                Spacer()
            }
            .navigationTitle("Ray-Ban AI")
        }
    }
}

class GlassesViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var latestFrame: UIImage?
    @Published var aiResponse = "Tap 'Connect' to start..."

    private let manager = GlassesAIManager(miniMaxApiKey: "YOUR_MINIMAX_API_KEY")

    func connect() {
        Task {
            do {
                try await manager.connectToGlasses()
                await MainActor.run { 
                    isConnected = true
                    aiResponse = "Connected! Tap 'Ask AI' to start."
                }
            } catch {
                await MainActor.run {
                    aiResponse = "Connection failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func askAI() {
        // In real app, this would come from STT
        manager.triggerAIQuery(userSpeechText: "What do you see?")
        aiResponse = "Processing..."

        // Update UI when response arrives (simplified)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.aiResponse = "I see a room with natural light coming through windows. There's a desk with a laptop and some books on it."
        }
    }

    func capturePhoto() {
        Task {
            // Trigger high-res capture
            // Photo saves to gallery automatically
        }
    }
}
```

---

## Troubleshooting

### Connection Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| "Cannot find glasses" | Bluetooth off or glasses not paired | Enable Bluetooth; re-pair in Meta AI app |
| "Developer Mode required" | Glasses not in dev mode | Open Meta AI app → Settings → Developer Mode → ON |
| "Invalid app registration" | Bundle ID mismatch | Check Bundle ID matches Meta Developer Console |
| "SDK version mismatch" | DAT SDK updated | Update to latest SDK version; check release notes |

### Audio Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| No audio from glasses | Audio session not configured | Set AVAudioSession category to .playAndRecord |
| Choppy audio | Buffer underrun | Increase audio buffer size; check network latency |
| Echo/feedback | No AEC applied | Implement echo cancellation; check mic/speaker routing |
| Low volume | Audio not normalized | Normalize Float32 PCM before playback |

### API Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| "Authentication failed" (1004) | Invalid API key | Check API key in MiniMax console |
| "Rate limited" (1002) | Too many requests | Implement request throttling; check RPM limits |
| "Token limit" (1039) | Context too long | Reduce conversation history; increase max_tokens |
| "Output content error" (1027) | Content flagged | Check for sensitive content; adjust mask_sensitive_info |

### Performance Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Slow response (5+ sec) | Network latency + API round-trip | Use streaming responses; optimize STT pipeline |
| Battery drains quickly | Continuous streaming | Implement session timeouts; reduce frame rate |
| App crashes | Memory pressure | Optimize image handling; use lazy loading |
| High data usage | Large images + audio | Compress images before sending; cache responses |

---

## Resources & Links

### Meta Developer Resources
- Meta Wearables Developer Portal: https://developers.meta.com/wearables
- MetaWearables SDK iOS: https://github.com/meta-quest/MetaWearables-SDK-iOS
- Meta AI App: App Store / Google Play

### MiniMax API Resources
- MiniMax Platform: https://platform.minimax.io
- Chat Completion Docs: https://platform.minimaxi.com/document/ChatCompletion%20v2
- TTS Docs: https://platform.minimaxi.com/document/Speech
- API Status: Check platform.minimax.io for service status

### Open Source Projects
- VisionClaw: https://github.com/sseanliu/VisionClaw
- meta-glasses-api: https://github.com/dcrebbin/meta-glasses-api
- OpenClaw: https://github.com/openclaw (for agentic actions)

### Speech-to-Text Options
- OpenAI Whisper API: https://platform.openai.com
- Azure Speech Services: https://azure.microsoft.com/services/cognitive-services/speech-to-text
- Google Cloud Speech-to-Text: https://cloud.google.com/speech-to-text
- On-device Whisper: https://github.com/openai/whisper

### Wake Word Detection
- Porcupine by Picovoice: https://picovoice.ai/platform/porcupine
- Snowboy (discontinued but functional): https://github.com/Kitt-AI/snowboy
- Custom wake word with TensorFlow Lite

### Audio Processing
- AVAudioEngine (iOS): Apple Developer Docs
- Oboe (Android): https://github.com/google/oboe
- WebRTC Audio Processing: https://webrtc.org

### Deployment
- Fly.io: https://fly.io (for signaling servers)
- Firebase: https://firebase.google.com (for backend services)
- Supabase: https://supabase.com (for database + auth)

---

## Summary

**You cannot build a new OS for Ray-Ban Gen 2.** But you **can** build a custom phone app using Meta's official DAT SDK that:

✅ Streams camera + audio from the glasses  
✅ Routes everything to MiniMax API (chat + TTS)  
✅ Plays responses back through the glasses speakers  
✅ Keeps native photo/video capture fully functional  
✅ Lets you add any custom features you want  

**The recommended path:**
1. Fork **VisionClaw** (github.com/sseanliu/VisionClaw)
2. Replace Gemini Live API with MiniMax Chat Completion + TTS
3. Add your custom features (wake words, tools, memory, etc.)
4. Test on your glasses
5. Iterate

**Key files to modify in VisionClaw:**
- `GeminiLiveAPI.swift` → Replace with `MiniMaxClient.swift`
- `AudioPipeline.swift` → Adjust for MiniMax TTS output format
- `SessionManager.swift` → Update orchestration logic
- `SettingsView.swift` → Add MiniMax API key input

---

*This guide was compiled from official Meta Wearables documentation, MiniMax API documentation, VisionClaw source code, and community research as of July 2026. SDK APIs and pricing may change — always check official documentation for the latest information.*
