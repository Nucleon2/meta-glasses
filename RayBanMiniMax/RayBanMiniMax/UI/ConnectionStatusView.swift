//
//  ConnectionStatusView.swift
//  RayBanMiniMax
//
//  Small green/red status pill + label that reflects the current
//  SessionManager.connection state.
//

import SwiftUI

struct ConnectionStatusView: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 6)
                        .scaleEffect(state == .connecting || state == .reconnecting ? 1.4 : 1.0)
                        .opacity(state == .connecting || state == .reconnecting ? 0 : 1)
                        .animation(
                            state == .connecting || state == .reconnecting
                                ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                                : .default,
                            value: state
                        )
                )
            Text(state.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(state.label)")
    }

    private var color: Color {
        switch state {
        case .idle:           return .gray
        case .connecting:     return .yellow
        case .connected:      return .green
        case .reconnecting:   return .orange
        case .failed:         return .red
        }
    }
}

#if DEBUG
struct ConnectionStatusView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            ConnectionStatusView(state: .idle)
            ConnectionStatusView(state: .connecting)
            ConnectionStatusView(state: .connected)
            ConnectionStatusView(state: .reconnecting)
            ConnectionStatusView(state: .failed("no SDK"))
        }
        .padding()
        .background(Color.black)
    }
}
#endif
