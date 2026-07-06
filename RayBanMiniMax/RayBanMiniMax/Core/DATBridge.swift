//
//  DATBridge.swift
//  RayBanMiniMax
//
//  Thin wrapper around Meta's official Wearables Device Access Toolkit
//  (https://github.com/facebook/meta-wearables-dat-ios, modules MWDATCore +
//  MWDATCamera).
//
//  What the SDK actually exposes (verified from the upstream CameraAccess
//  sample, tag 0.8.0):
//
//    * `Wearables.shared` singleton (`WearablesInterface`)
//    * `try Wearables.configure()` once at launch
//    * `wearables.devicesStream()` -> `AsyncStream<[DeviceIdentifier]>`
//    * `wearables.registrationStateStream()` -> `AsyncStream<RegistrationState>`
//    * `wearables.checkPermissionStatus(.camera)` / `requestPermission(.camera)`
//    * `AutoDeviceSelector(wearables:)` picks the first connected device
//    * `deviceSession = try await sessionManager.getSession()`
//    * `let config = StreamConfiguration(videoCodec: .raw,
//                                        resolution: .low,
//                                        frameRate: 24)`
//    * `let stream = try deviceSession.addStream(config: config)`
//    * `stream.statePublisher.listen { state in ... }` -> `AnyListenerToken`
//    * `stream.videoFramePublisher.listen { frame in ... }` -> `UIImage`
//    * `stream.photoDataPublisher.listen { data in ... }` -> `Data`
//    * `stream.capturePhoto(format: .jpeg)` to trigger a high-res still
//
//  What the SDK does NOT expose (and our integration guide claimed it did):
//    * No microphone capture from the glasses
//    * No speaker/PCM playback to the glasses
//    * No "1 fps JPEG" mode — video is 24 fps raw by default
//
//  The AI voice loop therefore uses the *iPhone's* mic + speaker, not the
//  glasses'. The glasses contribute only vision and the physical capture
//  button. This is documented honestly in the README.
//

import Foundation
import AVFoundation
import UIKit

#if canImport(MWDATCore)
import MWDATCore
#endif

#if canImport(MWDATCamera)
import MWDATCamera
#endif

// MARK: - Public types

enum DATConnectionState: Equatable {
    case idle
    case configuring
    case registering
    case ready
    case streaming
    case failed(String)
    case permissionDenied
}

/// A JPEG still returned by the glasses' capture button or programmatic
/// `stream.capturePhoto()` call.
struct DATCapturedPhoto: Equatable {
    let jpegData: Data
    let capturedAt: Date
    let width: Int
    let height: Int
}

/// A single video frame delivered by the live stream. We keep the JPEG
/// bytes so the AI pipeline can re-encode at a different quality.
struct DATVideoFrame: Equatable {
    let jpegData: Data
    let capturedAt: Date
    let width: Int
    let height: Int
    let uiImage: UIImage?
}

// MARK: - Protocol

@MainActor
protocol DATBridgeProtocol: AnyObject {
    /// Configure the SDK (call once at app launch).
    func bootstrap() async

    /// Current connection/registration state.
    var state: DATConnectionState { get }

    /// Request the camera permission required to stream.
    func requestCameraPermission() async -> Bool

    /// Start a 1 fps (or as fast as the SDK allows) video stream from the
    /// first available device. Frames arrive via the `frameHandler`.
    func startVideoStream(onFrame: @escaping (DATVideoFrame) -> Void) async throws

    /// Stop the active video stream.
    func stopVideoStream()

    /// Programmatically trigger a high-res still capture. Result is delivered
    /// to the `photoHandler` registered alongside `startVideoStream`, or
    /// returned synchronously when the stream isn't running.
    func capturePhoto() async throws -> DATCapturedPhoto

    /// Tear everything down. Safe to call multiple times.
    func shutdown()
}

// MARK: - Real SDK bridge

#if canImport(MWDATCore) && canImport(MWDATCamera)

@MainActor
final class RealDATBridge: DATBridgeProtocol {

    // MARK: - State

    private(set) var state: DATConnectionState = .idle

    private let wearables: WearablesInterface
    private var sessionManager: DeviceSessionManager?
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var frameHandler: ((DATVideoFrame) -> Void)?

    // Listener tokens — strong refs so the publishers stay alive.
    private var stateToken: AnyListenerToken?
    private var videoToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var photoToken: AnyListenerToken?
    private var lastPhoto: DATCapturedPhoto?

    // AsyncStream tasks
    private var deviceStreamTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        self.wearables = Wearables.shared
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard state == .idle else { return }
        state = .configuring
        do {
            try Wearables.configure()
        } catch {
            Logger.error("Wearables.configure() failed: \(error.localizedDescription)",
                          category: .session)
            state = .failed(error.localizedDescription)
            return
        }

        // Build the device session manager and monitor devices.
        sessionManager = DeviceSessionManager(wearables: wearables)

        registrationTask = Task { [weak self] in
            guard let self else { return }
            for await registration in self.wearables.registrationStateStream() {
                switch registration {
                case .registering:
                    self.state = .registering
                case .registered:
                    self.state = .ready
                case .unregistered:
                    self.state = .idle
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Permissions

    func requestCameraPermission() async -> Bool {
        let permission = Permission.camera
        do {
            var status = try await wearables.checkPermissionStatus(permission)
            if status != .granted {
                status = try await wearables.requestPermission(permission)
            }
            if status != .granted {
                state = .permissionDenied
                return false
            }
            return true
        } catch {
            Logger.error("Permission check failed: \(error.localizedDescription)",
                         category: .session)
            return false
        }
    }

    // MARK: - Streaming

    func startVideoStream(onFrame handler: @escaping (DATVideoFrame) -> Void) async throws {
        guard let sessionManager else {
            throw NSError(domain: "DATBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not bootstrapped. Call bootstrap() first."])
        }
        guard await requestCameraPermission() else {
            throw NSError(domain: "DATBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied."])
        }
        self.frameHandler = handler

        // Get (or create) the device session.
        let deviceSession: DeviceSession
        do {
            deviceSession = try await sessionManager.getSession()
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            state = .failed("Glasses firmware is out of date. Please update the Meta AI app on the glasses.")
            throw DeviceSessionError.datAppOnTheGlassesUpdateRequired
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        guard deviceSession.state == .started else {
            state = .failed("Device session is not ready. Please try again.")
            throw NSError(domain: "DATBridge", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Device session not started."])
        }

        // Configure the stream. The DAT SDK streams 24 fps raw video at the
        // chosen resolution. We down-throttle to ~1 fps in the handler.
        let config = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )

        guard let newStream = try deviceSession.addStream(config: config) else {
            state = .failed("Unable to create stream.")
            throw NSError(domain: "DATBridge", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create video stream."])
        }
        self.stream = newStream
        self.deviceSession = deviceSession
        attachListeners(to: newStream)
        newStream.start()
        state = .streaming
        Logger.info("DAT video stream started", category: .camera)
    }

    func stopVideoStream() {
        clearListeners()
        stream?.stop()
        stream = nil
        if state == .streaming { state = .ready }
        Logger.info("DAT video stream stopped", category: .camera)
    }

    // MARK: - Photo capture

    func capturePhoto() async throws -> DATCapturedPhoto {
        // If a stream is running, the photo will arrive via the
        // photoDataPublisher listener we attached in `attachListeners`.
        // We poll `lastPhoto` for a short window.
        guard let stream else {
            throw NSError(domain: "DATBridge", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "No active stream. Start a video stream first."])
        }

        lastPhoto = nil
        let success = stream.capturePhoto(format: PhotoFormat.jpeg)
        if !success {
            throw NSError(domain: "DATBridge", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Photo capture rejected by SDK."])
        }

        // Wait up to 3 seconds for the photoDataPublisher to deliver.
        let deadline = Date().addingTimeInterval(3.0)
        while lastPhoto == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let photo = lastPhoto else {
            throw NSError(domain: "DATBridge", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Photo capture timed out."])
        }
        return photo
    }

    // MARK: - Listeners

    private func attachListeners(to stream: MWDATCamera.Stream) {
        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.handleStreamState(state)
            }
        }
        videoToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.handleVideoFrame(frame)
            }
        }
        errorToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }
        photoToken = stream.photoDataPublisher.listen { [weak self] data in
            Task { @MainActor in
                self?.handlePhotoData(data)
            }
        }
    }

    private func clearListeners() {
        stateToken = nil
        videoToken = nil
        errorToken = nil
        photoToken = nil
    }

    private func handleStreamState(_ state: StreamState) {
        switch state {
        case .stopped:
            if self.state == .streaming { self.state = .ready }
            Logger.info("Stream state: stopped", category: .camera)
        case .streaming:
            self.state = .streaming
        case .waitingForDevice, .starting, .stopping, .paused:
            // Keep the existing connection-level state; the stream is just warming up.
            break
        @unknown default:
            break
        }
    }

    private func handleVideoFrame(_ frame: VideoFrame) {
        // Down-throttle to ~1 fps by only forwarding the first frame in each
        // 1-second window. The SDK streams at 24 fps.
        let now = Date()
        if let last = lastFrameAt, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastFrameAt = now

        // `VideoFrame` exposes a `uiImage` and `imageBuffer`; we re-encode
        // to JPEG at a moderate quality so the bytes are stable for base64.
        let image = frame.uiImage
        let jpeg: Data
        if let image, let encoded = image.jpegData(compressionQuality: 0.7) {
            jpeg = encoded
        } else if let data = frame.jpegData {
            jpeg = data
        } else {
            return
        }

        let model = DATVideoFrame(
            jpegData: jpeg,
            capturedAt: now,
            width: Int(image?.size.width ?? 0),
            height: Int(image?.size.height ?? 0),
            uiImage: image
        )
        frameHandler?(model)
    }

    private func handleError(_ error: Error) {
        Logger.error("DAT stream error: \(error.localizedDescription)", category: .camera)
        state = .failed(error.localizedDescription)
    }

    private func handlePhotoData(_ data: Data) {
        let image = UIImage(data: data)
        let photo = DATCapturedPhoto(
            jpegData: data,
            capturedAt: Date(),
            width: Int(image?.size.width ?? 0),
            height: Int(image?.size.height ?? 0)
        )
        lastPhoto = photo
    }

    private var lastFrameAt: Date?

    // MARK: - Shutdown

    func shutdown() {
        stopVideoStream()
        deviceStreamTask?.cancel()
        deviceStreamTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        deviceSession = nil
        sessionManager?.cleanup()
        sessionManager = nil
        state = .idle
        Logger.info("DAT bridge shut down", category: .session)
    }

    deinit {
        // We can't safely touch MainActor-isolated state from a non-isolated
        // deinit, so just cancel the task handles — listeners are dropped
        // when `self` is released.
        deviceStreamTask?.cancel()
        registrationTask?.cancel()
    }
}

#else

// MARK: - Stub (SDK not linked — e.g. unit tests on macOS)

@MainActor
final class RealDATBridge: DATBridgeProtocol {
    private(set) var state: DATConnectionState = .idle
    func bootstrap() async { state = .failed("MWDATCore not linked") }
    func requestCameraPermission() async -> Bool { false }
    func startVideoStream(onFrame: @escaping (DATVideoFrame) -> Void) async throws {
        throw NSError(domain: "DATBridge", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "MWDATCore/MWDATCamera not linked"])
    }
    func stopVideoStream() {}
    func capturePhoto() async throws -> DATCapturedPhoto {
        throw NSError(domain: "DATBridge", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "MWDATCore/MWDATCamera not linked"])
    }
    func shutdown() { state = .idle }
}

#endif

// MARK: - Facade

/// Singleton facade. The rest of the app talks to this without knowing
/// whether the real SDK or a simulator is underneath.
@MainActor
final class DATBridge: DATBridgeProtocol {
    private let impl: DATBridgeProtocol

    init() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        self.impl = RealDATBridge()
        Logger.info("Using real MWDATCore + MWDATCamera", category: .session)
        #else
        self.impl = RealDATBridge() // stub variant above
        Logger.warn("MWDAT modules not linked — using stub bridge", category: .session)
        #endif
    }

    var state: DATConnectionState { impl.state }
    func bootstrap() async { await impl.bootstrap() }
    func requestCameraPermission() async -> Bool { await impl.requestCameraPermission() }
    func startVideoStream(onFrame handler: @escaping (DATVideoFrame) -> Void) async throws {
        try await impl.startVideoStream(onFrame: handler)
    }
    func stopVideoStream() { impl.stopVideoStream() }
    func capturePhoto() async throws -> DATCapturedPhoto {
        try await impl.capturePhoto()
    }
    func shutdown() { impl.shutdown() }
}
