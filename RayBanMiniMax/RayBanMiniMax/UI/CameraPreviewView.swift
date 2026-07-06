//
//  CameraPreviewView.swift
//  RayBanMiniMax
//
//  Displays the latest frame streamed from the Meta Ray-Ban Gen 2 glasses
//  via the CameraPipeline. Shows frame metadata (size, KB) and renders a
//  tasteful gradient fallback when no frame is available yet.
//

import SwiftUI

struct CameraPreviewView: View {
    let frame: CameraFrame?
    let isStreaming: Bool

    var body: some View {
        ZStack {
            background
            content
            overlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 6)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var background: some View {
        if let image = frame?.uiImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if frame == nil {
            VStack(spacing: 10) {
                Image(systemName: isStreaming ? "antenna.radiowaves.left.and.right" : "eye.slash")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                Text(isStreaming ? "Waiting for first frame…" : "Camera idle")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                if isStreaming {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.6)))
                }
                Spacer()
                if let frame {
                    Text("\(Int(frame.pixelWidth))×\(Int(frame.pixelHeight)) · \(String(format: "%.0f KB", frame.sizeInKB))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
            }
            .padding(10)
            Spacer()
            if let frame {
                HStack {
                    Spacer()
                    Text(timeAgoString(from: frame.capturedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
                .padding(10)
            }
        }
    }

    // MARK: - Helpers

    private var accessibilityDescription: String {
        if let frame {
            return "Live camera frame, \(Int(frame.pixelWidth)) by \(Int(frame.pixelHeight)) pixels."
        } else {
            return isStreaming ? "Waiting for first camera frame." : "Camera not streaming."
        }
    }

    private func timeAgoString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 1 { return "now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        return "\(Int(interval / 60))m ago"
    }
}

#if DEBUG
struct CameraPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            CameraPreviewView(frame: nil, isStreaming: false)
            CameraPreviewView(frame: nil, isStreaming: true)
        }
        .padding()
        .background(Color.black)
    }
}
#endif
