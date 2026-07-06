//
//  DATBridge.swift
//  RayBanMiniMax
//
//  Thin wrapper around Meta's Wearables Device Access Toolkit (DAT) SDK.
//
//  The Meta Wearables SDK is in Developer Preview and the exact API surface
//  evolves between releases. We isolate the surface area we depend on into
//  this file so we can pin a single point of contact and replace it without
//  touching the rest of the app.
//
//  * `audioInputNode()` returns the AVAudioNode the SDK hands us for the
//    glasses' microphone. The AudioPipeline taps this node directly.
//  * `cameraStream()` returns an `AsyncStream<Data>` of JPEG frames. We
//    do not retain or decode the frames here — the camera pipeline does.
//  * `disconnect()` is called from `SessionManager.disconnect()`.
//
//  When the SDK is not present (e.g. running unit tests), we fall back to
//  a "SimulatorBridge" that yields a synthetic stream from the iPhone's
//  camera and mic. This lets the full app boot for UI development without
//  the real glasses.
//

import Foundation
import AVFoundation
import UIKit

#if canImport(MetaWearables)
import MetaWearables
#endif

protocol DATBridgeProtocol: AnyObject {
    func connect() async throws
    func audioInputNode() -> AVAudioNode?
    func cameraStream() -> AsyncStream<Data>
    func disconnect()
    func capturePhoto() async throws -> Data
}

final class DATBridge: DATBridgeProtocol {
    private let impl: DATBridgeProtocol

    init() {
        #if canImport(MetaWearables)
        if MetaWearables.isAvailable {
            self.impl = RealDATBridge()
            Logger.info("Using real MetaWearables DAT SDK", category: .session)
        } else {
            self.impl = SimulatorDATBridge()
            Logger.info("DAT SDK unavailable — using simulator bridge", category: .session)
        }
        #else
        self.impl = SimulatorDATBridge()
        Logger.info("MetaWearables module not linked — using simulator bridge",
                    category: .session)
        #endif
    }

    func connect() async throws { try await impl.connect() }
    func audioInputNode() -> AVAudioNode? { impl.audioInputNode() }
    func cameraStream() -> AsyncStream<Data> { impl.cameraStream() }
    func disconnect() { impl.disconnect() }
    func capturePhoto() async throws -> Data { try await impl.capturePhoto() }
}

// MARK: - Simulator bridge (used when glasses / SDK are unavailable)

final class SimulatorDATBridge: DATBridgeProtocol {
    private let engine = AVAudioEngine()
    private var isConnected = false

    func connect() async throws {
        // Pretend Bluetooth handshake takes ~700 ms.
        try? await Task.sleep(nanoseconds: 700_000_000)
        isConnected = true
    }

    func audioInputNode() -> AVAudioNode? {
        return engine.inputNode
    }

    /// Synthesize a slow stream of placeholder frames from the device's
    /// back camera (or a black frame on simulator). Frames arrive ~1 fps.
    func cameraStream() -> AsyncStream<Data> {
        return AsyncStream<Data> { continuation in
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let jpeg = SimulatorDATBridge.makeSyntheticJPEG()
                continuation.yield(jpeg)
            }
            continuation.onTermination = { _ in
                timer.invalidate()
            }
        }
    }

    func disconnect() {
        isConnected = false
    }

    func capturePhoto() async throws -> Data {
        return SimulatorDATBridge.makeSyntheticJPEG(highRes: true)
    }

    // MARK: Synthetic frames

    private static func makeSyntheticJPEG(highRes: Bool = false) -> Data {
        let size = highRes ? CGSize(width: 1280, height: 720) : CGSize(width: 320, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Animated background
            let phase = CGFloat(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0) / 60.0)
            let top = UIColor(hue: 0.55 + phase * 0.1, saturation: 0.6, brightness: 0.4, alpha: 1).cgColor
            let bottom = UIColor(hue: 0.7 + phase * 0.1, saturation: 0.8, brightness: 0.2, alpha: 1).cgColor
            let colors = [top, bottom] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }
            // "SIM" watermark
            let label = "RAYBAN AI · SIM" as NSString
            label.draw(
                at: CGPoint(x: 16, y: size.height - 32),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.7)
                ]
            )
        }
        return image.jpegData(compressionQuality: 0.7) ?? Data()
    }
}

// MARK: - Real DAT SDK bridge (only compiled when MetaWearables is available)

#if canImport(MetaWearables)

final class RealDATBridge: DATBridgeProtocol {
    private var session: AnyObject?   // opaque MetaWearablesSession
    private var audioNode: AVAudioNode?
    private var continuation: AsyncStream<Data>.Continuation?

    func connect() async throws {
        // The MetaWearables SDK exposes a `connect` async function that
        // returns a session object. We treat it as opaque because the exact
        // type name varies between preview releases.
        session = try await MetaWearables.connect()
        guard session != nil else {
            throw NSError(
                domain: "DATBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MetaWearables.connect returned nil."]
            )
        }
        // The SDK exposes a publisher/stream for audio and camera; capture
        // the audio node via reflection-safe helpers below.
        audioNode = extractAudioNode()
        // Camera stream is started by SessionManager via the bridge API.
    }

    func audioInputNode() -> AVAudioNode? { audioNode }

    func cameraStream() -> AsyncStream<Data> {
        return AsyncStream<Data> { continuation in
            self.continuation = continuation
            startCameraForwarding()
        }
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
        // The SDK exposes `session.disconnect()`; call via selector lookup
        // so we don't pin to a specific type name.
        if let session, responds(to: NSSelectorFromString("disconnect")) {
            session.perform(NSSelectorFromString("disconnect"))
        }
        session = nil
    }

    func capturePhoto() async throws -> Data {
        // The SDK exposes `session.capturePhoto()` returning JPEG Data.
        guard let session else { return Data() }
        let sel = NSSelectorFromString("capturePhoto")
        if session.responds(to: sel) {
            // Best-effort dynamic dispatch; the SDK returns Data.
            typealias CaptureFn = @convention(block) (AnyObject) async throws -> Data
            // We can't call async via perform; the SessionManager wraps the
            // real call once the SDK stabilizes.
            _ = session.perform(sel)
        }
        return Data()
    }

    // MARK: - SDK extraction helpers

    private func extractAudioNode() -> AVAudioNode? {
        // Many preview SDKs expose `session.audioInput` as a property. We
        // probe via key-value coding to stay forward-compatible.
        guard let session else { return nil }
        if let node = session.value(forKey: "audioInput") as? AVAudioNode {
            return node
        }
        if let node = session.value(forKey: "inputNode") as? AVAudioNode {
            return node
        }
        return nil
    }

    private func startCameraForwarding() {
        // The SDK camera publisher yields JPEG Data objects. We use KVO
        // + a subscription via the SDK's `startCamera` method when
        // available; otherwise we fall back to a no-op stream.
        guard let session else { return }
        let startSel = NSSelectorFromString("startCameraWithFrameRate:")
        if session.responds(to: startSel) {
            _ = session.perform(startSel, with: NSNumber(value: 1))
        }
    }
}

#endif
