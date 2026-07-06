//
//  Logger.swift
//  RayBanMiniMax
//
//  Unified logging facade over Apple's os.Logger with categories and a
//  console-friendly fallback. Use this for every `print()` replacement.
//

import Foundation
import os

/// Logical subsystem grouping. Keep the list small and meaningful.
enum LogCategory: String, CaseIterable {
    case app = "App"
    case session = "Session"
    case audio = "Audio"
    case camera = "Camera"
    case api = "API"
    case stt = "STT"
    case tts = "TTS"
    case tool = "Tool"
    case ui = "UI"
    case util = "Util"
}

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// Centralized logger. Use the static helpers — they are cheap and thread-safe.
final class Logger {
    /// Set true to mirror all log lines to the console (in addition to os_log).
    nonisolated(unsafe) static var echoToConsole: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    private static let subsystem = "com.minimax.rayban.RayBanMiniMax"
    nonisolated(unsafe) private static var osLoggers: [LogCategory: os.Logger] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    /// Call once at app launch. Safe to call multiple times.
    static func configure() {
        for category in LogCategory.allCases {
            osLoggers[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
    }

    static func debug(_ message: @autoclosure () -> String,
                      category: LogCategory,
                      file: String = #fileID,
                      line: Int = #line) {
        log(level: .debug, message: message(), category: category, file: file, line: line)
    }

    static func info(_ message: @autoclosure () -> String,
                     category: LogCategory,
                     file: String = #fileID,
                     line: Int = #line) {
        log(level: .info, message: message(), category: category, file: file, line: line)
    }

    static func warn(_ message: @autoclosure () -> String,
                     category: LogCategory,
                     file: String = #fileID,
                     line: Int = #line) {
        log(level: .warn, message: message(), category: category, file: file, line: line)
    }

    static func error(_ message: @autoclosure () -> String,
                      category: LogCategory,
                      file: String = #fileID,
                      line: Int = #line) {
        log(level: .error, message: message(), category: category, file: file, line: line)
    }

    // MARK: - Internal

    private static func log(level: LogLevel,
                            message: String,
                            category: LogCategory,
                            file: String,
                            line: Int) {
        let osLogger = osLogger(for: category)
        let formatted = "[\(category.rawValue)] \(message) (\(file):\(line))"

        switch level {
        case .debug:
            osLogger.debug("\(formatted, privacy: .public)")
        case .info:
            osLogger.info("\(formatted, privacy: .public)")
        case .warn:
            osLogger.warning("\(formatted, privacy: .public)")
        case .error:
            osLogger.error("\(formatted, privacy: .public)")
        }

        if echoToConsole {
            print("[\(level.rawValue)] \(formatted)")
        }
    }

    private static func osLogger(for category: LogCategory) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = osLoggers[category] { return existing }
        let new = os.Logger(subsystem: subsystem, category: category.rawValue)
        osLoggers[category] = new
        return new
    }
}
