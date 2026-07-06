//
//  CameraPipeline.swift
//  RayBanMiniMax
//
//  Receives JPEG frames from the DATBridge (the real Meta Wearables SDK
//  video stream) and exposes the most recent frame for the AI vision
//  pipeline. We keep only the latest frame to bound memory; older frames
//  are released as soon as a newer one arrives.
//
//  Thread-safety: the @MainActor isolation guarantees serialized access
//  from any view or view model.
//

import Foundation
import Combine
import UIKit

/// A decoded preview frame for the UI. JPEG bytes are retained so the AI
/// pipeline can base64-encode them without re-decoding.
struct CameraFrame: Equatable {
    let id: UUID
    let jpegData: Data
    let base64: String
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let uiImage: UIImage?

    var sizeInBytes: Int { jpegData.count }
    var sizeInKB: Double { Double(jpegData.count) / 1024.0 }
}

@MainActor
final class CameraPipeline: ObservableObject {
    // MARK: - Published state

    @Published private(set) var latestFrame: CameraFrame?
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var framesPerMinute: Double = 0

    // MARK: - Tunables

    /// Max JPEG size we'll keep in memory. Larger frames are downscaled.
    static let maxFrameBytes: Int = 4 * 1024 * 1024

    /// Quality used when re-encoding oversized frames.
    static let reencodeQuality: CGFloat = 0.85

    /// Soft cap on frames in the rolling FPS window (last 60s).
    static let fpsWindowSeconds: Double = 60.0

    // MARK: - Internals

    private weak var bridge: DATBridge?
    private var fpsWindow: [Date] = []

    // MARK: - Lifecycle

    /// Attach a bridge and start streaming from it.
    func start(with bridge: DATBridge) async {
        guard !isStreaming else { return }
        self.bridge = bridge
        isStreaming = true
        lastError = nil
        do {
            try await bridge.startVideoStream { [weak self] datFrame in
                // Already on MainActor (the bridge dispatches here).
                self?.ingest(datFrame: datFrame)
            }
            Logger.info("Camera pipeline attached to DAT bridge stream", category: .camera)
        } catch {
            isStreaming = false
            lastError = error.localizedDescription
            Logger.error("Failed to start camera pipeline: \(error.localizedDescription)",
                         category: .camera)
        }
    }

    /// Stop streaming and clear cached frames.
    func stop() {
        bridge?.stopVideoStream()
        bridge = nil
        isStreaming = false
        clear()
        Logger.info("Camera pipeline stopped", category: .camera)
    }

    // MARK: - Frame ingestion

    /// Receive a raw frame from the DAT bridge. Bounded by `maxFrameBytes`.
    private func ingest(datFrame: DATVideoFrame) {
        let data: Data
        if datFrame.jpegData.count > Self.maxFrameBytes {
            guard let resized = downscale(jpegData: datFrame.jpegData) else {
                Logger.warn("Frame too large and could not be downscaled (\(datFrame.jpegData.count) B)",
                            category: .camera)
                return
            }
            data = resized
        } else {
            data = datFrame.jpegData
        }

        let image = datFrame.uiImage ?? UIImage(data: data)
        let frame = CameraFrame(
            id: UUID(),
            jpegData: data,
            base64: data.base64EncodedString(),
            capturedAt: datFrame.capturedAt,
            pixelWidth: datFrame.width > 0 ? datFrame.width : Int(image?.size.width ?? 0),
            pixelHeight: datFrame.height > 0 ? datFrame.height : Int(image?.size.height ?? 0),
            uiImage: image
        )

        latestFrame = frame
        frameCount += 1
        updateFPS()
    }

    /// Inject a frame that came from somewhere other than the live stream
    /// (e.g. a `DATCapturedPhoto` from a programmatic capture).
    func inject(jpegData: Data) {
        let image = UIImage(data: jpegData)
        let frame = CameraFrame(
            id: UUID(),
            jpegData: jpegData,
            base64: jpegData.base64EncodedString(),
            capturedAt: Date(),
            pixelWidth: Int(image?.size.width ?? 0),
            pixelHeight: Int(image?.size.height ?? 0),
            uiImage: image
        )
        latestFrame = frame
        frameCount += 1
        updateFPS()
    }

    /// Drop the cached frame.
    func clear() {
        latestFrame = nil
        frameCount = 0
        framesPerMinute = 0
        fpsWindow.removeAll()
    }

    // MARK: - Helpers

    private func updateFPS() {
        let now = Date()
        fpsWindow.append(now)
        let cutoff = now.addingTimeInterval(-Self.fpsWindowSeconds)
        fpsWindow.removeAll { $0 < cutoff }
        framesPerMinute = Double(fpsWindow.count) * (60.0 / Self.fpsWindowSeconds)
    }

    /// Downscale an oversized JPEG to keep memory bounded.
    private func downscale(jpegData: Data) -> Data? {
        guard let image = UIImage(data: jpegData) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1.0, maxSide / max(image.size.width, image.size.height))
        if scale >= 1.0 { return jpegData }
        let newSize = CGSize(width: image.size.width * scale,
                             height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: CameraPipeline.reencodeQuality)
    }
}
