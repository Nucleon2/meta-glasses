//
//  DATBridge.swift
//  RayBanMiniMax
//
//  Thin wrapper around Meta's official Wearables Device Access Toolkit
//  (https://github.com/facebook/meta-wearables-dat-ios, modules MWDATCore +
//  MWDATCamera). Types verified against the actual SDK 0.8.0
//  .swiftinterface files on disk.
//
//  Verified public surface (from MWDATCore/MWDATCamera swiftinterface):
//
//    Wearables.configure() throws
//    Wearables.shared : any WearablesInterface
//
//    protocol WearablesInterface : Sendable {
//      var registrationState: RegistrationState { get }
//      func addRegistrationStateListener(_:) -> AnyListenerToken
//      func registrationStateStream() -> AsyncStream<RegistrationState>
//      func startRegistration() async throws
//      func handleUrl(_:) async throws -> Bool
//      func startUnregistration() async throws
//      func openFirmwareUpdate() async throws
//      func openDATGlassesAppUpdate() async throws
//      var devices: [DeviceIdentifier] { get }
//      func addDevicesListener(_:) -> AnyListenerToken
//      func devicesStream() -> AsyncStream<[DeviceIdentifier]>
//      func deviceForIdentifier(_:) -> Device?
//      func checkPermissionStatus(_:) async throws -> PermissionStatus
//      func requestPermission(_:) async throws -> PermissionStatus
//      func createSession(deviceSelector:) throws -> DeviceSession
//      func deviceStateStream(for:) -> AsyncStream<DeviceState>
//    }
//
//    class AppManager : Sendable { ... }       // provided by AppManager.start()
//    class DeviceSession : Sendable {
//      func start() throws
//      func stop()
//      var state: DeviceSessionState
//      var statePublisher, errorPublisher: Announcer<...>
//      func addStream(config:) throws -> Stream?
//    }
//
//    class Stream : Sendable {
//      let streamConfiguration: StreamConfiguration
//      var state: StreamState
//      var statePublisher:  Announcer<StreamState>
//      var videoFramePublisher: Announcer<VideoFrame>
//      var photoDataPublisher:  Announcer<PhotoData>
//      var errorPublisher:    Announcer<StreamError>
//      func start()
//      func stop()
//      func capturePhoto(format:) -> Bool
//    }
//
//    struct VideoFrame : Sendable {
//      var sampleBuffer: CMSampleBuffer
//      func makeUIImage() -> sending UIImage?
//    }
//
//    struct PhotoData : Sendable {
//      let data: Data
//      let format: PhotoCaptureFormat
//    }
//
//    enum StreamState : Sendable { stopping, stopped, waitingForDevice,
//                                  starting, streaming, paused }
//
//    enum PhotoCaptureFormat : Sendable { heic, jpeg }
//    enum VideoCodec         : Sendable { raw, hvc1 }
//    enum StreamingResolution: Sendable { high, medium, low }
//

import Foundation
import AVFoundation
import UIKit
import CoreMedia

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

struct DATCapturedPhoto: Equatable {
    let jpegData: Data
    let capturedAt: Date
    let width: Int
    let height: Int
}

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
    func bootstrap() async
    var state: DATConnectionState { get }
    func requestCameraPermission() async -> Bool
    func startVideoStream(onFrame: @escaping (DATVideoFrame) -> Void) async throws
    func stopVideoStream()
    func capturePhoto() async throws -> DATCapturedPhoto
    func shutdown()
}

// MARK: - Real SDK bridge

#if canImport(MWDATCore) && canImport(MWDATCamera)

@MainActor
final class RealDATBridge: DATBridgeProtocol {

    // MARK: - State

    private(set) var state: DATConnectionState = .idle

    private let wearables: any WearablesInterface
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var frameHandler: ((DATVideoFrame) -> Void)?

    // Listener tokens — strong refs so the publishers stay alive.
    private var stateToken: (any AnyListenerToken)?
    private var videoToken: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?
    private var photoToken: (any AnyListenerToken)?
    private var lastPhoto: DATCapturedPhoto?

    // AsyncStream tasks for registration + device monitoring
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?

    private var lastFrameAt: Date?

    // MARK: - Init

    init() {
        // `Wearables.shared` returns `any WearablesInterface`
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

        // Monitor registration state.
        registrationTask = Task { [weak self] in
            guard let self else { return }
            for await registration in self.wearables.registrationStateStream() {
                await MainActor.run {
                    self.handleRegistration(registration)
                }
            }
        }

        // Monitor device list.
        devicesTask = Task { [weak self] in
            guard let self else { return }
            for await devices in self.wearables.devicesStream() {
                Logger.info("Devices: \(devices)", category: .session)
            }
        }

        state = .ready
    }

    private func handleRegistration(_ registration: RegistrationState) {
        switch registration {
        case .registering:
            state = .registering
        case .registered:
            state = .ready
        case .unavailable:
            state = .idle
        @unknown default:
            break
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
        self.frameHandler = handler

        guard await requestCameraPermission() else {
            throw NSError(domain: "DATBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied."])
        }

        // Create a device session using the auto device selector (picks
        // the first connected/registered device).
        let session: DeviceSession
        do {
            session = try wearables.createSession(
                deviceSelector: AutoDeviceSelector(wearables: wearables)
            )
        } catch {
            let desc = String(describing: error)
            state = .failed(desc)
            throw error
        }
        self.deviceSession = session

        // Start the session (synchronous, throws on failure).
        do {
            try session.start()
        } catch {
            let desc = String(describing: error)
            state = .failed("Session start failed: \(desc)")
            throw error
        }

        // Attach a stream. 24 fps raw video at low resolution; we
        // down-throttle to ~1 fps in the handler.
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        guard let newStream = try session.addStream(config: config) else {
            state = .failed("Failed to add stream")
            throw NSError(domain: "DATBridge", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "addStream returned nil"])
        }
        self.stream = newStream
        attachListeners(to: newStream)
        newStream.start()
        state = .streaming
        Logger.info("DAT video stream started", category: .camera)
    }

    func stopVideoStream() {
        clearListeners()
        stream?.stop()
        stream = nil
        deviceSession?.stop()
        deviceSession = nil
        if state == .streaming { state = .ready }
        Logger.info("DAT video stream stopped", category: .camera)
    }

    // MARK: - Photo capture

    func capturePhoto() async throws -> DATCapturedPhoto {
        guard let stream else {
            throw NSError(domain: "DATBridge", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "No active stream."])
        }
        lastPhoto = nil
        let success = stream.capturePhoto(format: .jpeg)
        if !success {
            throw NSError(domain: "DATBridge", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Photo capture rejected by SDK."])
        }
        // Wait up to 3 seconds for the photoData listener to deliver.
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
            Task { @MainActor in self?.handleStreamState(state) }
        }
        videoToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in self?.handleVideoFrame(frame) }
        }
        errorToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handleError(error) }
        }
        photoToken = stream.photoDataPublisher.listen { [weak self] data in
            Task { @MainActor in self?.handlePhotoData(data) }
        }
    }

    private func clearListeners() {
        // AnyListenerToken is Sendable; cancelling stops the listener.
        Task {
            await stateToken?.cancel()
            await videoToken?.cancel()
            await errorToken?.cancel()
            await photoToken?.cancel()
        }
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

        // VideoFrame.makeUIImage() returns an optional UIImage.
        guard let image = frame.makeUIImage() else { return }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else { return }

        let model = DATVideoFrame(
            jpegData: jpeg,
            capturedAt: now,
            width: Int(image.size.width),
            height: Int(image.size.height),
            uiImage: image
        )
        frameHandler?(model)
    }

    private func handleError(_ error: StreamError) {
        Logger.error("DAT stream error: \(error.localizedDescription)", category: .camera)
        state = .failed(error.localizedDescription)
    }

    private func handlePhotoData(_ data: PhotoData) {
        let bytes = data.data
        let image = UIImage(data: bytes)
        let photo = DATCapturedPhoto(
            jpegData: bytes,
            capturedAt: Date(),
            width: Int(image?.size.width ?? 0),
            height: Int(image?.size.height ?? 0)
        )
        lastPhoto = photo
    }

    // MARK: - Shutdown

    func shutdown() {
        stopVideoStream()
        registrationTask?.cancel()
        registrationTask = nil
        devicesTask?.cancel()
        devicesTask = nil
        state = .idle
        Logger.info("DAT bridge shut down", category: .session)
    }

    deinit {
        registrationTask?.cancel()
        devicesTask?.cancel()
    }
}

#else

// MARK: - Stub (SDK not linked — e.g. unit tests on macOS)

@MainActor
final class RealDATBridge: DATBridgeProtocol {
    private(set) var state: DATConnectionState = .idle
    func bootstrap() async { state = .failed("MWDATCore/MWDATCamera not linked") }
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

@MainActor
final class DATBridge: DATBridgeProtocol {
    private let impl: DATBridgeProtocol

    init() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        self.impl = RealDATBridge()
        Logger.info("Using real MWDATCore + MWDATCamera", category: .session)
        #else
        self.impl = RealDATBridge()
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
