//
//  RayBanMiniMaxApp.swift
//  RayBanMiniMax
//
//  Turn your Meta Ray-Ban Gen 2 smart glasses into a MiniMax-M3-powered AI assistant.
//

import SwiftUI

@main
struct RayBanMiniMaxApp: App {
    // The SessionManager is the single source of truth for glasses connection,
    // audio capture, camera frames, conversation state, and AI orchestration.
    @StateObject private var session = SessionManager()

    init() {
        // Configure logging early so all subsystems (API, audio, camera) inherit it.
        Logger.configure()
        Logger.info("RayBan AI launching", category: .app)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Best-effort auto-connect; failures are non-fatal and surfaced in UI.
                    session.bootstrap()
                }
        }
    }
}
