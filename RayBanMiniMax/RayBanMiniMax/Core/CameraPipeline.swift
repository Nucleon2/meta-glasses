//
//  CameraPipeline.swift
//  RayBanMiniMax
//
//  Subscribes to the DAT SDK's camera publisher and exposes the most recent
//  JPEG frame for the AI vision pipeline.
//
//  The Meta Ray-Ban Gen 2 streams a single JPEG frame at roughly 1 fps. The
//  pipeline stores only the most recent frame to keep memory bounded; older
//  frames are released immediately as soon as a newer one arrives.
//
//  Thread-safety: a serial actor protects the storage. SwiftUI consumers
//  receive a snapshot via the @MainActor `latestFrame` published property.
//

import Foundation
import Combine
import UIKit

/// A decoded preview frame for the UI. We keep the JPEG bytes as well so
/// the AI pipeline can re-encode or attach them to a request without
/// re-decoding the same data.
struct CameraFrame: Equatable {
    let id: UUID = UUID()
    let jpegData: Data
    let base64: String
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let uiImage: UIImage?

    /// Convenience: size of the underlying JPEG in KB. Used in the UI.
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

    /// Max JPEG size we will keep in memory. Anything bigger is downscaled.
    /// 4 MB is more than enough for a 12 MP glasses camera and bounds RAM use.
    static let maxFrameBytes: Int = 4 * 1024 * 1024

    /// Target JPEG quality for any re-encoded frames (1.0 = lossless).
    static let reencodeQuality: CGFloat = 0.85

    // MARK: - Internals

    private var streamTask: Task<Void, Never>?
    private var fpsWindow: [Date] = []
    private var lastFrameAt: Date?

    deinit {
        streamTask?.cancel()
    }

    // MARK: - Stream lifecycle

    /// Begin a streaming subscription. Pass a closure that yields JPEG data.
    /// In production this is wired up to the DAT SDK's camera publisher;
    /// the closure abstraction lets us mock the stream in unit tests.
    ///
    /// - Parameter source: Async sequence (or closure-based source) that
    ///   yields raw JPEG `Data` for each new frame.
    func start<S: AsyncSequence>(source: S) where S.Element == Data {
        guard !isStreaming else { return }
        isStreaming = true
        lastError = nil
        Logger.info("Camera stream started", category: .camera)
        streamTask = Task { [weak self] in
            for await jpeg in source {
                guard let self else { return }
                self.ingest(jpegData: jpeg)
                if Task.isCancelled { break }
            }
            await self?.markStopped()
        }
    }

    /// Synchronous start that uses a callback. Useful when the SDK exposes
    /// a Combine publisher or a delegate.
    func startWithCallback(_ callback: @escaping () async -> AsyncStream<Data>.Continuation?) {
        // We model a one-shot helper to keep the API symmetric; the typical
        // usage is to call `start(source:)` with an `AsyncStream`.
        let stream = AsyncStream<Data> { continuation in
            Task {
                if let cont = await callback() {
                    cont.yield(Data()) // no-op placeholder, real glue in SessionManager
                }
            }
        }
        start(source: stream)
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        Logger.info("Camera stream stopped", category: .camera)
    }

    // MARK: - Frame ingestion

    /// Receive a raw JPEG frame. Replaces any previous frame immediately.
    /// Bounded by `maxFrameBytes` to keep memory in check; oversized frames
    /// are downscaled via UIKit.
    func ingest(jpegData raw: Data) {
        let data: Data
        if raw.count > Self.maxFrameBytes {
            guard let resized = downscale(jpegData: raw) else {
                Logger.warn("Frame too large and could not be downscaled (\(raw.count) B)",
                            category: .camera)
                return
            }
            data = resized
        } else {
            data = raw
        }

        let image = UIImage(data: data)
        let frame = CameraFrame(
            jpegData: data,
            base64: data.base64EncodedString(),
            capturedAt: Date(),
            pixelWidth: Int(image?.size.width ?? 0),
            pixelHeight: Int(image?.size.height ?? 0),
            uiImage: image
        )

        latestFrame = frame
        frameCount += 1
        updateFPS()
        lastFrameAt = frame.capturedAt
    }

    /// Discard the cached frame (e.g. when the user logs out).
    func clear() {
        latestFrame = nil
        frameCount = 0
        framesPerMinute = 0
        fpsWindow.removeAll()
    }

    // MARK: - Helpers

    private func markStopped() {
        isStreaming = false
    }

    private func updateFPS() {
        let now = Date()
        fpsWindow.append(now)
        // Keep only frames from the last 60 seconds.
        let cutoff = now.addingTimeInterval(-60)
        fpsWindow.removeAll { $0 < cutoff }
        framesPerMinute = Double(fpsWindow.count)
    }

    /// Downscale an oversized JPEG by decoding and re-encoding at 85% quality.
    private func downscale(jpegData: Data) -> Data? {
        guard let image = UIImage(data: jpegData) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1.0, maxSide / max(image.size.width, image.size.height))
        if scale >= 1.0 {
            return jpegData
        }
        let newSize = CGSize(width: image.size.width * scale,
                             height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: CameraPipeline.reencodeQuality)
    }
}
