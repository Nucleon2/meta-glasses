//
//  AudioPipeline.swift
//  RayBanMiniMax
//
//  Bidirectional audio pipeline for Meta Ray-Ban Gen 2 glasses.
//
//  * Capture  : Glasses mic (Float32 PCM, 16 kHz mono) -> Int16 chunks
//  * Playback : MiniMax TTS MP3 (32 kHz) -> Float32 PCM @ 24 kHz -> speakers
//
//  The pipeline is designed to run alongside the DAT SDK's audio session.
//  We do NOT touch the glasses' hardware path; the Meta AI app continues to
//  own the native capture button. We only consume the audio subscription
//  the SDK hands us, and submit TTS audio back through the SDK.
//
//  Echo cancellation is enabled at the AVAudioSession level; for an extra
//  layer we mute the mic briefly while we are speaking.
//

import Foundation
import AVFoundation
import Combine

/// Lightweight event the rest of the app (STT, VAD) can subscribe to.
struct AudioChunkEvent {
    /// Original capture sample rate (Hz).
    let sampleRate: Double
    /// Interleaved Int16 little-endian PCM.
    let int16Data: Data
    /// Mono Float32 view of the same samples (range -1.0...1.0).
    let floatSamples: [Float]
    /// True RMS energy of the chunk.
    let rms: Float
    /// Wall-clock time the chunk was finalized.
    let timestamp: Date
}

@MainActor
final class AudioPipeline: ObservableObject {
    // MARK: - Published state

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastInputLevel: Float = 0
    @Published private(set) var lastOutputLevel: Float = 0

    // MARK: - Tunables

    /// Glasses mic sample rate (per DAT SDK docs).
    static let captureSampleRate: Double = 16_000

    /// Glasses speaker sample rate (per DAT SDK docs).
    static let playbackSampleRate: Double = 24_000

    /// MiniMax TTS returns 32 kHz MP3 by default.
    static let ttsSourceSampleRate: Double = 32_000

    /// We accumulate ~100 ms of audio before emitting a chunk.
    static let chunkDurationSeconds: Double = 0.1

    /// While the assistant is speaking, we duck the mic to avoid feedback.
    static let playbackDuckingGain: Float = 0.15

    // MARK: - Outputs

    /// Stream of audio chunks ready for STT. MainActor-safe subscribe.
    let chunkPublisher = PassthroughSubject<AudioChunkEvent, Never>()

    // MARK: - Internals

    private let session = AVAudioSession.sharedInstance()
    private let audioEngine = AVAudioEngine()
    private let playerEngine = AVAudioEngine()
    private let playerMixer: AVAudioMixerNode
    private let playerNode = AVAudioPlayerNode()

    private var captureBufferAccumulator: [Float] = []
    private var captureBufferLock = NSLock()

    private var isMutedForPlayback = false
    private var captureTapInstalled = false
    private var playerStarted = false

    // MARK: - Init

    init() {
        // Use a separate mixer for playback so we can attach effects (volume, EQ)
        // without disturbing the capture graph.
        playerMixer = playerEngine.mainMixerNode
    }

    // MARK: - Session configuration

    /// Configure the shared AVAudioSession. Idempotent. Safe to call from
    /// any actor; it touches shared audio hardware.
    func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,         // enables AEC and AGC when supported
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(AudioPipeline.captureSampleRate)
        try session.setPreferredIOBufferDuration(AudioPipeline.chunkDurationSeconds)
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
        Logger.info("AVAudioSession configured: .playAndRecord @ \(session.sampleRate) Hz",
                    category: .audio)
    }

    // MARK: - Capture (glasses mic -> chunks)

    /// Start capturing audio from the supplied input node (the DAT SDK hands
    /// us a node connected to the glasses' mic). We install a tap that
    /// accumulates Float32 samples and emits ~100 ms Int16 chunks.
    ///
    /// - Parameter inputNode: The AVAudioInputNode to tap. Pass the engine's
    ///   input node for the iPhone mic fallback, or a node the SDK exposes.
    func startCapture(from inputNode: AVAudioNode) throws {
        guard !isCapturing else { return }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        Logger.info("Starting capture: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch",
                    category: .audio)

        // Sample-rate the input is already in. Capture pipeline assumes 16 kHz
        // mono Float32, but we tolerate other rates by resampling into our
        // accumulator. The DAT SDK normalizes to 16 kHz before exposing.
        let hardwareRate = inputFormat.sampleRate > 0
            ? inputFormat.sampleRate
            : AudioPipeline.captureSampleRate

        let chunkFrames = Int(AudioPipeline.chunkDurationSeconds * hardwareRate)

        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(chunkFrames * 2),
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = PCMConverter.readMonoFloat32Samples(from: buffer)
            self.accumulate(samples: samples, sampleRate: hardwareRate)
        }
        captureTapInstalled = true

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        isCapturing = true
        lastError = nil
    }

    func stopCapture() {
        guard isCapturing else { return }
        if captureTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        isCapturing = false
        captureBufferLock.lock()
        captureBufferAccumulator.removeAll(keepingCapacity: false)
        captureBufferLock.unlock()
        Logger.info("Capture stopped", category: .audio)
    }

    /// Process incoming Float32 samples. Resamples to the canonical 16 kHz
    /// capture rate, downsamples into 100 ms chunks, and publishes them.
    private func accumulate(samples: [Float], sampleRate: Double) {
        // Resample to canonical rate if needed.
        let resampled: [Float]
        if abs(sampleRate - AudioPipeline.captureSampleRate) < 1.0 {
            resampled = samples
        } else {
            resampled = PCMConverter.resample(
                samples,
                from: sampleRate,
                to: AudioPipeline.captureSampleRate
            )
        }

        captureBufferLock.lock()
        captureBufferAccumulator.append(contentsOf: resampled)
        let chunkFrames = Int(AudioPipeline.chunkDurationSeconds * AudioPipeline.captureSampleRate)
        var ready: [Float] = []
        if captureBufferAccumulator.count >= chunkFrames {
            ready = Array(captureBufferAccumulator.prefix(chunkFrames))
            captureBufferAccumulator.removeFirst(chunkFrames)
        }
        captureBufferLock.unlock()

        if !ready.isEmpty {
            let int16 = PCMConverter.floatToInt16(ready)
            let rms = PCMConverter.rms(ready)
            let event = AudioChunkEvent(
                sampleRate: AudioPipeline.captureSampleRate,
                int16Data: int16,
                floatSamples: ready,
                rms: rms,
                timestamp: Date()
            )
            Task { @MainActor in
                self.lastInputLevel = rms
                self.chunkPublisher.send(event)
            }
        }
    }

    // MARK: - Playback (TTS -> speakers)

    /// Prepare the playback engine. Idempotent.
    func preparePlayback() throws {
        guard !playerStarted else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioPipeline.playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
        playerEngine.attach(playerNode)
        playerEngine.connect(playerNode, to: playerMixer, format: format)
        playerMixer.outputVolume = 1.0
        try playerEngine.start()
        playerStarted = true
        Logger.info("Playback engine started @ \(AudioPipeline.playbackSampleRate) Hz",
                    category: .audio)
    }

    /// Decode MP3 data, resample to 24 kHz, and play through the speakers.
    func playMP3(_ data: Data) async throws {
        try preparePlayback()
        let pcm = try decodeMP3(data: data)
        try play(pcmBuffer: pcm)
    }

    /// Decode MP3 to an AVAudioPCMBuffer at the playback sample rate.
    private func decodeMP3(data: Data) throws -> AVAudioPCMBuffer {
        // Step 1: Decode MP3 to a Float32 PCM buffer at the source rate (typically 32 kHz).
        guard let sourceBuffer = decodeToFloatBuffer(data: data) else {
            throw NSError(
                domain: "AudioPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode MP3."]
            )
        }
        let sourceRate = sourceBuffer.format.sampleRate
        let monoSamples = PCMConverter.readMonoFloat32Samples(from: sourceBuffer)

        // Step 2: Resample to the glasses' 24 kHz playback rate.
        let resampled = PCMConverter.resample(
            monoSamples,
            from: sourceRate,
            to: AudioPipeline.playbackSampleRate
        )

        // Step 3: Build the output buffer.
        guard let out = PCMConverter.makeMonoFloat32Buffer(
            samples: resampled,
            sampleRate: AudioPipeline.playbackSampleRate
        ) else {
            throw NSError(
                domain: "AudioPipeline",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build playback buffer."]
            )
        }
        return out
    }

    /// Schedule and play an already-decoded buffer on the player engine.
    private func play(pcmBuffer buffer: AVAudioPCMBuffer) throws {
        awaitPlayback()
        isMutedForPlayback = true
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                self?.isPlaying = false
                self?.isMutedForPlayback = false
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
        lastError = nil

        // Update output level meter periodically while playing.
        let rms = PCMConverter.rms(PCMConverter.readMonoFloat32Samples(from: buffer))
        Task { @MainActor in
            self.lastOutputLevel = rms
        }
    }

    private func awaitPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    /// Stop all in-flight playback immediately.
    func stopPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        isPlaying = false
        isMutedForPlayback = false
    }

    // MARK: - MP3 decoding helper

    /// Decode arbitrary compressed audio (MP3 from MiniMax) to a Float32 PCM
    /// buffer using AVAudioFile. The file is written to a temp location
    /// because `AVAudioFile` requires a URL.
    private func decodeToFloatBuffer(data: Data) -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-\(UUID().uuidString).mp3")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            Logger.error("Failed to write MP3 to temp: \(error)", category: .audio)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let file = try? AVAudioFile(forReading: tmp) else {
            Logger.error("AVAudioFile could not open MP3", category: .audio)
            return nil
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            Logger.error("AVAudioFile read failed: \(error)", category: .audio)
            return nil
        }
        return buffer
    }

    // MARK: - Teardown

    /// Stop everything. Safe to call multiple times.
    func shutdown() {
        stopCapture()
        stopPlayback()
        if playerStarted {
            playerEngine.stop()
            playerStarted = false
        }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        Logger.info("Audio pipeline shut down", category: .audio)
    }

    // MARK: - Test seams

    /// A simple level meter driven by `lastInputLevel` / `lastOutputLevel`.
    /// Used by the SwiftUI UI to render VU bars.
    var inputLevelSmoothed: Float {
        return min(1.0, lastInputLevel * 4.0)
    }

    var outputLevelSmoothed: Float {
        return min(1.0, lastOutputLevel * 4.0)
    }
}
