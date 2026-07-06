//
//  SettingsView.swift
//  RayBanMiniMax
//
//  User-facing preferences. Lets the user paste in a MiniMax API key, pick
//  a chat model, choose a TTS voice, and tweak temperature / max tokens.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var showKey: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                chatSection
                ttsSection
                advancedSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                apiKeyInput = UserDefaults.standard.string(forKey: "MINIMAX_API_KEY") ?? ""
            }
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            HStack {
                Group {
                    if showKey {
                        TextField("eyJ…", text: $apiKeyInput)
                    } else {
                        SecureField("eyJ…", text: $apiKeyInput)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                APIConfig.setUserAPIKey(apiKeyInput)
                session.objectWillChange.send()
            } label: {
                Label("Save API Key", systemImage: "key.fill")
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            if APIConfig.hasAPIKey {
                Label("API key configured", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No API key yet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("MiniMax API")
        } footer: {
            Text("Get an API key at platform.minimaxi.com. Keys are stored in UserDefaults and never leave your device except in the Authorization header of MiniMax API calls.")
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        Section {
            Picker("Model", selection: $session.settings.chatModel) {
                ForEach(MiniMaxModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", session.settings.temperature))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $session.settings.temperature, in: 0.0...1.5, step: 0.05)
            Stepper(value: $session.settings.maxTokens, in: 256...8192, step: 256) {
                HStack {
                    Text("Max tokens")
                    Spacer()
                    Text("\(session.settings.maxTokens)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Attach camera frame", isOn: $session.settings.attachLatestFrame)
        } header: {
            Text("Chat")
        } footer: {
            Text("MiniMax-M3 is the frontier multimodal model. Lower temperature = more focused; higher = more creative.")
        }
    }

    // MARK: - TTS

    private var ttsSection: some View {
        Section {
            Picker("TTS model", selection: $session.settings.ttsModel) {
                ForEach(TTSModel.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            Picker("Voice", selection: $session.settings.voiceId) {
                ForEach(TTSVoice.allCases) { v in
                    Text(v.displayName).tag(v.rawValue)
                }
            }
            Picker("Emotion", selection: $session.settings.ttsEmotion) {
                ForEach(TTSEmotion.allCases) { e in
                    Text(e.displayName).tag(e)
                }
            }
            HStack {
                Text("Speed")
                Spacer()
                Text(String(format: "%.2fx", session.settings.ttsSpeed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $session.settings.ttsSpeed, in: 0.5...2.0, step: 0.05)
            Stepper(value: $session.settings.ttsPitch, in: -12...12) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text("\(session.settings.ttsPitch) st")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Emotion tags work best with Speech-2.8-HD. Pitch shifts are in semitones.")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            TextField("Custom voice id", text: $session.settings.customVoiceId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Extra system prompt", text: $session.settings.extraSystemPrompt, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Use a custom voice id (e.g. from MiniMax voice cloning) or add an extra system prompt instruction.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://platform.minimaxi.com")!) {
                Label("MiniMax Platform", systemImage: "globe")
            }
            Link(destination: URL(string: "https://developers.meta.com/wearables")!) {
                Label("Meta Wearables Dev Portal", systemImage: "link")
            }
        } header: {
            Text("About")
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(SessionManager())
    }
}
#endif
