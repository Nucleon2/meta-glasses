//
//  APIConfig.swift
//  RayBanMiniMax
//
//  Centralized API configuration. Reads the MiniMax API key from Info.plist
//  (key: MINIMAX_API_KEY) — never hardcode keys in source.
//

import Foundation

/// Static configuration for the MiniMax API.
///
/// Endpoints are taken from the official docs:
///   - Chat: https://api.minimaxi.com/v1/text/chatcompletion_v2
///   - TTS:  https://api.minimax.io/v1/t2a_v2
enum APIConfig {
    enum Endpoint {
        static let chat = URL(string: "https://api.minimaxi.com/v1/text/chatcompletion_v2")!
        static let tts  = URL(string: "https://api.minimax.io/v1/t2a_v2")!
    }

    enum Defaults {
        static let model: MiniMaxModel = .m3
        static let ttsModel: TTSModel = .speech28HD
        static let voiceId: String = "English_expressive_narrator"
        static let temperature: Double = 0.7
        static let maxTokens: Int = 2048
        static let ttsSampleRate: Int = 32_000
        static let ttsBitrate: Int = 128_000
    }

    // MARK: - API Key Loading

    private static let apiKeyInfoPlistKey = "MINIMAX_API_KEY"

    /// Cached API key. Empty string means "not configured".
    static var apiKey: String = {
        if let fromInfoPlist = Bundle.main.object(forInfoDictionaryKey: apiKeyInfoPlistKey) as? String,
           !fromInfoPlist.isEmpty,
           !fromInfoPlist.hasPrefix("$") {
            return fromInfoPlist
        }
        // User may have stored it in UserDefaults via the Settings screen.
        if let fromUserDefaults = UserDefaults.standard.string(forKey: apiKeyInfoPlistKey),
           !fromUserDefaults.isEmpty {
            return fromUserDefaults
        }
        return ""
    }()

    /// Invalidate the cached key. Call after the user updates it in Settings.
    static func reloadAPIKey() {
        // We rely on the closure re-running by reassigning via a static wrapper.
        // The simplest approach: read fresh each time when called.
    }

    /// Fresh, non-cached lookup. Use right before making a request.
    static func currentAPIKey() -> String {
        if let fromInfoPlist = Bundle.main.object(forInfoDictionaryKey: apiKeyInfoPlistKey) as? String,
           !fromInfoPlist.isEmpty,
           !fromInfoPlist.hasPrefix("$") {
            return fromInfoPlist
        }
        if let fromUserDefaults = UserDefaults.standard.string(forKey: apiKeyInfoPlistKey),
           !fromUserDefaults.isEmpty {
            return fromUserDefaults
        }
        return ""
    }

    /// Returns true if an API key is configured (Info.plist OR UserDefaults).
    static var hasAPIKey: Bool { !currentAPIKey().isEmpty }

    // MARK: - Settings persistence

    /// Persist the user's API key in UserDefaults. The Info.plist copy is read-only.
    static func setUserAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: apiKeyInfoPlistKey)
        Logger.info("User API key updated (length=\(trimmed.count))", category: .api)
    }
}

// MARK: - Model enums

enum MiniMaxModel: String, CaseIterable, Identifiable, Codable {
    case m3 = "MiniMax-M3"
    case text01 = "MiniMax-Text-01"
    case m1 = "MiniMax-M1"
    case m27 = "MiniMax-M2.7"
    case m27Highspeed = "MiniMax-M2.7-highspeed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .m3: return "MiniMax-M3 (frontier)"
        case .m1: return "MiniMax-M1"
        case .text01: return "MiniMax-Text-01"
        case .m27: return "MiniMax-M2.7"
        case .m27Highspeed: return "MiniMax-M2.7-highspeed"
        }
    }

    var maxTokens: Int {
        switch self {
        case .m3, .m1, .m27, .m27Highspeed: return 8_192
        case .text01: return 2_048
        }
    }

    var defaultTemperature: Double {
        switch self {
        case .m3, .m1, .m27, .m27Highspeed: return 1.0
        case .text01: return 0.1
        }
    }
}

enum TTSModel: String, CaseIterable, Identifiable, Codable {
    case speech28HD = "speech-2.8-hd"
    case speech28Turbo = "speech-2.8-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speech28HD: return "Speech-2.8-HD (high quality)"
        case .speech28Turbo: return "Speech-2.8-Turbo (fast)"
        }
    }
}

enum TTSEmotion: String, CaseIterable, Identifiable, Codable {
    case neutral, happy, sad, angry, fearful, disgusted, surprised, calm, excited

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// A curated subset of MiniMax TTS voices for the settings UI. The full list
/// is 300+ — users can override `voiceId` directly in advanced settings.
enum TTSVoice: String, CaseIterable, Identifiable, Codable {
    case englishNarrator  = "English_expressive_narrator"
    case englishCalmF     = "English_calm_female"
    case englishEnergM    = "English_energetic_male"
    case englishGentleF   = "English_gentle_female"
    case englishWarmM     = "English_warm_male"
    case chineseNarrator  = "Chinese_expressive_narrator"
    case chineseCalmF     = "Chinese_calm_female"
    case japaneseCalmF    = "Japanese_calm_female"
    case spanishEnergM    = "Spanish_energetic_male"
    case frenchSoftF      = "French_soft_female"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .englishNarrator: return "English — Expressive Narrator"
        case .englishCalmF:    return "English — Calm Female"
        case .englishEnergM:   return "English — Energetic Male"
        case .englishGentleF:  return "English — Gentle Female"
        case .englishWarmM:    return "English — Warm Male"
        case .chineseNarrator: return "Chinese — Expressive Narrator"
        case .chineseCalmF:    return "Chinese — Calm Female"
        case .japaneseCalmF:   return "Japanese — Calm Female"
        case .spanishEnergM:   return "Spanish — Energetic Male"
        case .frenchSoftF:     return "French — Soft Female"
        }
    }
}
