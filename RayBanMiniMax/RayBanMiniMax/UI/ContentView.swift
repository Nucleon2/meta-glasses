//
//  ContentView.swift
//  RayBanMiniMax
//
//  Main SwiftUI interface. Shows the glasses connection status, the latest
//  camera frame, the AI response area, and the primary actions: connect,
//  push-to-talk, ask a typed question, and stop playback.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: SessionManager
    @State private var showSettings: Bool = false
    @State private var manualText: String = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    headerBar
                    ConnectionStatusView(state: session.connection)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    CameraPreviewView(
                        frame: session.camera.latestFrame,
                        isStreaming: session.camera.isStreaming
                    )
                    .padding(.horizontal, 4)

                    responseCard

                    inputRow

                    actionRow

                    if let error = session.lastError {
                        errorBanner(error)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(session)
        }
    }

    // MARK: - Sections

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.02, green: 0.03, blue: 0.07),
                Color(red: 0.04, green: 0.06, blue: 0.12)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("RayBan AI")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Powered by MiniMax-M3")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .accessibilityLabel("Open settings")
        }
    }

    private var responseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI Response", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if session.isThinking {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            }
            ScrollView {
                Text(displayedResponse)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 80, maxHeight: 180)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Type a question…", text: $manualText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .focused($textFieldFocused)
                    .submitLabel(.send)
                    .onSubmit { sendManual() }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            Button(action: sendManual) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle().fill(manualText.isEmpty ? Color.gray.opacity(0.4) : Color.accentColor)
                    )
            }
            .disabled(manualText.isEmpty || session.isThinking)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(
                title: session.connection.isActive ? "Reconnect" : "Connect",
                systemImage: session.connection.isActive ? "arrow.triangle.2.circlepath" : "wifi",
                tint: session.connection.isActive ? .orange : .green
            ) {
                session.reconnect()
            }

            actionButton(
                title: session.stt.isListening ? "Listening…" : "Speak",
                systemImage: session.stt.isListening ? "waveform" : "mic.fill",
                tint: .accentColor
            ) {
                Task { await session.listenAndAsk() }
            }
            .disabled(!session.connection.isActive)

            actionButton(
                title: "Stop",
                systemImage: "stop.fill",
                tint: .red
            ) {
                session.stopSpeaking()
            }
            .disabled(!session.audio.isPlaying)

            actionButton(
                title: "Photo",
                systemImage: "camera.fill",
                tint: .blue
            ) {
                Task {
                    do {
                        _ = try await session.capturePhoto()
                    } catch {
                        Logger.warn("Manual capture failed: \(error.localizedDescription)",
                                    category: .camera)
                    }
                }
            }
        }
    }

    private func actionButton(title: String,
                              systemImage: String,
                              tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var displayedResponse: String {
        if !session.lastAssistantMessage.isEmpty {
            return session.lastAssistantMessage
        }
        switch session.connection {
        case .idle:
            return "Tap Connect to pair your Ray-Ban Gen 2 glasses."
        case .configuring:
            return "Configuring Meta Wearables SDK…"
        case .registering:
            return "Registering with Meta…"
        case .ready:
            return "Connected! Tap Speak to ask a question."
        case .streaming:
            return "Live video streaming from glasses."
        case .permissionDenied:
            return "Camera permission denied. Open Settings to enable it."
        case .failed(let m):
            return "Couldn't connect: \(m)"
        }
    }

    private func sendManual() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manualText = ""
        textFieldFocused = false
        Task { await session.ask(transcript: text, attachLatestFrame: session.settings.attachLatestFrame) }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SessionManager())
            .preferredColorScheme(.dark)
    }
}
#endif
