//
//  AudioPipeline.swift
//  RayBanMiniMax
//
//  Bidirectional audio for the AI voice loop.
//
//  IMPORTANT — honest architecture note:
//  The Meta Wearables DAT SDK (0.8.0) does NOT expose the glasses' mic
//  or speakers. There is no `MWDATAudio` module. Until Meta adds that,
//  the voice loop runs through the *iPhone's* built-in mic and speaker.
//
//  Capture  : iPhone mic (Float32 PCM, 16 kHz mono) → Int16 chunks
//  Playback : MiniMax TTS MP3 (32 kHz) → Float32 PCM @ 24 kHz → speaker
//
//  This is still useful and reliable: the user speaks, the iPhone hears
//  them, the iPhone speaks back through its loudspeaker or connected
//  AirPods. The glasses only contribute the camera + capture button.
//
//  When Meta ships audio APIs, the only files that need to change are
//  this one and `STT/SpeechRecognizer.swift` — swap the input node for
//  the glasses' mic node the SDK hands us.
//

import Foundation
import AVFoundation
import Combine

/// Lightweight event the rest of the app (STT, VAD) can subscribe to.
struct AudioChunkEvent {
    let sampleRate: Double
    let int16Data: Data
    let floatSamples: [Float]
    let rms: Float
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

    /// Mic sample rate (iPhone hardware).
    static let captureSampleRate: Double = 16_000

    /// Speaker sample rate we render into. MiniMax TTS is 32 kHz, we
    /// resample to 24 kHz to keep buffer sizes small.
    static let playbackSampleRate: Double = 24_000

    /// MiniMax TTS source rate.
    static let ttsSourceSampleRate: Double = 32_000

    /// ~100 ms chunks for STT.
    static let chunkDurationSeconds: Double = 0.1

    // MARK: - Outputs

    let chunkPublisher = PassthroughSubject<AudioChunkEvent, Never>()

    // MARK: - Internals

    private let session = AVAudioSession.sharedInstance()
    private let captureEngine = AVAudioEngine()
    private let playerEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var captureBufferAccumulator: [Float] = []
    private var captureBufferLock = NSLock()
    private var captureTapInstalled = false
    private var playerStarted = false

    // MARK: - Init

    init() {}

    // MARK: - Session configuration

    /// Configure AVAudioSession. Idempotent.
    func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(AudioPipeline.captureSampleRate)
        try session.setPreferredIOBufferDuration(AudioPipeline.chunkDurationSeconds)
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
        Logger.info("AVAudioSession configured: .playAndRecord @ \(session.sampleRate) Hz",
                    category: .audio)
    }

    // MARK: - Capture (iPhone mic -> chunks)

    /// Start capturing audio from the iPhone's built-in microphone.
    /// We install a tap on `captureEngine.inputNode` that accumulates
    /// Float32 samples and emits ~100 ms Int16 chunks.
    func startCapture() throws {
        guard !isCapturing else { return }
        let inputNode = captureEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
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

        if !captureEngine.isRunning {
            try captureEngine.start()
        }
        isCapturing = true
        lastError = nil
        Logger.info("Mic capture started at \(hardwareRate) Hz", category: .audio)
    }

    func stopCapture() {
        guard isCapturing else { return }
        if captureTapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
        }
        if captureEngine.isRunning {
            captureEngine.stop()
        }
        isCapturing = false
        captureBufferLock.lock()
        captureBufferAccumulator.removeAll(keepingCapacity: false)
        captureBufferLock.unlock()
        Logger.info("Mic capture stopped", category: .audio)
    }

    private func accumulate(samples: [Float], sampleRate: Double) {
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

    // MARK: - Playback (TTS -> iPhone speaker)

    func preparePlayback() throws {
        guard !playerStarted else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioPipeline.playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
        playerEngine.attach(playerNode)
        playerEngine.connect(playerNode, to: playerEngine.mainMixerNode, format: format)
        playerEngine.mainMixerNode.outputVolume = 1.0
        try playerEngine.start()
        playerStarted = true
        Logger.info("Playback engine started @ \(AudioPipeline.playbackSampleRate) Hz",
                    category: .audio)
    }

    /// Decode MP3 data, resample to 24 kHz, and play through the iPhone
    /// speaker (or connected AirPods / Bluetooth, per AVAudioSession).
    func playMP3(_ data: Data) async throws {
        try preparePlayback()
        let pcm = try decodeMP3(data: data)
        try play(pcmBuffer: pcm)
    }

    private func decodeMP3(data: Data) throws -> AVAudioPCMBuffer {
        guard let sourceBuffer = decodeToFloatBuffer(data: data) else {
            throw NSError(
                domain: "AudioPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode MP3."]
            )
        }
        let sourceRate = sourceBuffer.format.sampleRate
        let monoSamples = PCMConverter.readMonoFloat32Samples(from: sourceBuffer)
        let resampled = PCMConverter.resample(
            monoSamples,
            from: sourceRate,
            to: AudioPipeline.playbackSampleRate
        )
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

    private func play(pcmBuffer buffer: AVAudioPCMBuffer) throws {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
        lastError = nil
        let rms = PCMConverter.rms(PCMConverter.readMonoFloat32Samples(from: buffer))
        Task { @MainActor in
            self.lastOutputLevel = rms
        }
    }

    func stopPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        isPlaying = false
    }

    // MARK: - MP3 decoding helper

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

    // MARK: - VU meter helpers

    var inputLevelSmoothed: Float { min(1.0, lastInputLevel * 4.0) }
    var outputLevelSmoothed: Float { min(1.0, lastOutputLevel * 4.0) }
}
