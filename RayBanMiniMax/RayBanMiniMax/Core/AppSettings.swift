//
//  AppSettings.swift
//  RayBanMiniMax
//
//  User-tweakable settings, persisted in UserDefaults. Loaded once at app
//  launch and saved on every mutation.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    // MARK: - Chat

    @Published var chatModel: MiniMaxModel = .m3 {
        didSet { save(\.chatModel, key: Keys.chatModel) }
    }
    @Published var temperature: Double = APIConfig.Defaults.temperature {
        didSet { save(\.temperature, key: Keys.temperature) }
    }
    @Published var maxTokens: Int = APIConfig.Defaults.maxTokens {
        didSet { save(\.maxTokens, key: Keys.maxTokens) }
    }
    @Published var attachLatestFrame: Bool = true {
        didSet { save(\.attachLatestFrame, key: Keys.attachLatestFrame) }
    }

    // MARK: - TTS

    @Published var ttsModel: TTSModel = .speech28HD {
        didSet { save(\.ttsModel, key: Keys.ttsModel) }
    }
    @Published var voiceId: String = APIConfig.Defaults.voiceId {
        didSet { save(\.voiceId, key: Keys.voiceId) }
    }
    @Published var ttsEmotion: TTSEmotion = .neutral {
        didSet { save(\.ttsEmotion, key: Keys.ttsEmotion) }
    }
    @Published var ttsSpeed: Double = 1.0 {
        didSet { save(\.ttsSpeed, key: Keys.ttsSpeed) }
    }
    @Published var ttsPitch: Int = 0 {
        didSet { save(\.ttsPitch, key: Keys.ttsPitch) }
    }
    @Published var ttsVolume: Double = 1.0 {
        didSet { save(\.ttsVolume, key: Keys.ttsVolume) }
    }

    // MARK: - Misc

    @Published var customVoiceId: String = "" {
        didSet { save(\.customVoiceId, key: Keys.customVoiceId) }
    }
    @Published var extraSystemPrompt: String = "" {
        didSet { save(\.extraSystemPrompt, key: Keys.extraSystemPrompt) }
    }

    // MARK: - Persistence

    private enum Keys {
        static let chatModel = "settings.chatModel"
        static let temperature = "settings.temperature"
        static let maxTokens = "settings.maxTokens"
        static let attachLatestFrame = "settings.attachLatestFrame"
        static let ttsModel = "settings.ttsModel"
        static let voiceId = "settings.voiceId"
        static let ttsEmotion = "settings.ttsEmotion"
        static let ttsSpeed = "settings.ttsSpeed"
        static let ttsPitch = "settings.ttsPitch"
        static let ttsVolume = "settings.ttsVolume"
        static let customVoiceId = "settings.customVoiceId"
        static let extraSystemPrompt = "settings.extraSystemPrompt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        let d = defaults

        if let raw = d.string(forKey: Keys.chatModel), let m = MiniMaxModel(rawValue: raw) {
            chatModel = m
        }
        if d.object(forKey: Keys.temperature) != nil {
            temperature = d.double(forKey: Keys.temperature)
        }
        if d.object(forKey: Keys.maxTokens) != nil {
            maxTokens = d.integer(forKey: Keys.maxTokens)
        }
        if d.object(forKey: Keys.attachLatestFrame) != nil {
            attachLatestFrame = d.bool(forKey: Keys.attachLatestFrame)
        }
        if let raw = d.string(forKey: Keys.ttsModel), let m = TTSModel(rawValue: raw) {
            ttsModel = m
        }
        if let raw = d.string(forKey: Keys.voiceId) {
            voiceId = raw
        }
        if let raw = d.string(forKey: Keys.ttsEmotion), let e = TTSEmotion(rawValue: raw) {
            ttsEmotion = e
        }
        if d.object(forKey: Keys.ttsSpeed) != nil {
            ttsSpeed = d.double(forKey: Keys.ttsSpeed)
        }
        if d.object(forKey: Keys.ttsPitch) != nil {
            ttsPitch = d.integer(forKey: Keys.ttsPitch)
        }
        if d.object(forKey: Keys.ttsVolume) != nil {
            ttsVolume = d.double(forKey: Keys.ttsVolume)
        }
        customVoiceId = d.string(forKey: Keys.customVoiceId) ?? ""
        extraSystemPrompt = d.string(forKey: Keys.extraSystemPrompt) ?? ""
    }

    /// Apply a custom voice id at runtime. Falls back to the built-in list
    /// if the user clears the field.
    var effectiveVoiceId: String {
        let trimmed = customVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? voiceId : trimmed
    }

    static func load() -> AppSettings {
        return AppSettings()
    }

    // MARK: - Save helpers

    private func save<Value>(_ kp: ReferenceWritableKeyPath<AppSettings, Value>,
                             key: String) {
        // Reference the key path so the compiler doesn't warn in release.
        _ = self[keyPath: kp]
        defaults.set(self[keyPath: kp], forKey: key)
    }
}
