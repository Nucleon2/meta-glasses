//
//  SpeechRecognizer.swift
//  RayBanMiniMax
//
//  Thin async/await wrapper around Apple's SFSpeechRecognizer. We default
//  to on-device recognition (`requiresOnDeviceRecognition = true`) whenever
//  the user's locale supports it, so audio never leaves the phone unless
//  the user explicitly opts in via Settings.
//
//  In production the audio source is the AudioPipeline's chunk stream. This
//  class also supports a "push to talk" mode that listens while a flag is
//  set, plus a placeholder wake-word hook for Porcupine.
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechRecognizer: ObservableObject {
    // MARK: - Published state

    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var isListening: Bool = false
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastError: String?
    @Published var localeIdentifier: String = Locale.current.identifier

    // MARK: - Internals

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Optional Porcupine wake-word hook. Set this from the SessionManager
    /// once the SDK is ready; leave nil to disable.
    var onWakeWord: (() -> Void)?

    init(localeIdentifier: String = Locale.current.identifier) {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        self.recognizer?.delegate = nil
    }

    // MARK: - Authorization

    /// Request speech + microphone permissions. Call once at app launch.
    func requestAuthorization() async {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        let micGranted: Bool = await withCheckedContinuation { cont in
            // The microphone permission must be requested via AVAudioApplication
            // on iOS 17+.
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        isAuthorized = (speechStatus == .authorized) && micGranted
        if !isAuthorized {
            Logger.warn("Speech/mic not authorized (speech=\(speechStatus.rawValue), mic=\(micGranted))",
                        category: .stt)
        }
    }

    // MARK: - One-shot recognition

    /// Listen for a single utterance. Stops automatically on silence.
    /// Returns the final transcript, or throws.
    func listenOnce(timeout: TimeInterval = 8.0) async throws -> String {
        guard isAuthorized else {
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech not authorized."])
        }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechRecognizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable for locale \(localeIdentifier)."])
        }

        // Cancel any in-flight task.
        task?.cancel()
        task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        lastTranscript = ""
        lastError = nil

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    Task { @MainActor in
                        self.lastTranscript = text
                    }
                    if result.isFinal {
                        self.cleanup()
                        cont.resume(returning: text)
                    }
                }
                if let error {
                    self.cleanup()
                    Logger.error("STT error: \(error.localizedDescription)", category: .stt)
                    cont.resume(throwing: error)
                }
            }

            // Timeout safety.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                if self.isListening {
                    self.cleanup()
                    cont.resume(returning: self.lastTranscript)
                }
            }
        }
    }

    /// Stop any active recognition immediately.
    func stop() {
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false
    }

    // MARK: - Feed mode (for AudioPipeline integration)

    /// Append raw audio samples from the AudioPipeline chunks. Useful when
    /// you want to feed glasses-mic audio into the recognizer rather than
    /// the iPhone mic. Use `startFeed` to begin and `endFeed` to finish.
    func startFeed() {
        guard isAuthorized, let recognizer, recognizer.isAvailable else { return }
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.lastTranscript = text
                }
                if result.isFinal {
                    self.endFeed()
                }
            }
            if let error != nil {
                self.endFeed()
            }
        }
        isListening = true
    }

    func appendFeed(samples: [Float], sampleRate: Double) {
        guard let request else { return }
        let buffer = PCMConverter.makeMonoFloat32Buffer(samples: samples, sampleRate: sampleRate)
        if let buffer {
            request.append(buffer)
        }
    }

    func endFeed() {
        request?.endAudio()
        request = nil
        isListening = false
    }
}
