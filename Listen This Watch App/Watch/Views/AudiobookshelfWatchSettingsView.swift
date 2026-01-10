//
//  AudiobookshelfWatchSettingsView.swift
//  Listen This Watch App
//
//  Read-only Audiobookshelf settings view for Apple Watch
//  Settings are managed on iPhone and synced via iCloud
//

import OSLog
import SwiftData
import SwiftUI

struct AudiobookshelfWatchSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings: AudiobookshelfSettings?
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if let settings = settings {
                if settings.isEnabled && settings.isConfigured {
                    // Show active configuration (read-only)
                    List {
                        Section("Server Configuration") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server URL")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(settings.serverURL)
                                    .font(.footnote)
                                    .lineLimit(3)
                            }
                        }

                        Section("Playback Mode") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playbackModeText(settings.playbackMode))
                                    .font(.footnote)
                                Text(playbackModeDescription(settings.playbackMode))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "Configure settings on iPhone. Watch can stream Audiobookshelf books independently over WiFi."
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Section {
                            Button {
                                isRefreshing = true
                                Task {
                                    try? await Task.sleep(for: .seconds(0.5))
                                    loadSettings()
                                    isRefreshing = false
                                }
                            } label: {
                                HStack {
                                    Text("Refresh from iCloud")
                                    Spacer()
                                    if isRefreshing {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(isRefreshing)
                        }
                    }
                } else {
                    // Not configured
                    VStack {
                        ContentUnavailableView {
                            Label("Not Configured", systemImage: "iphone.and.arrow.forward")
                        } description: {
                            Text(
                                "Configure Audiobookshelf on your iPhone in Settings.\n\nSettings will sync automatically via iCloud."
                            )
                        }

                        List {
                            Section {
                                Button {
                                    isRefreshing = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(0.5))
                                        loadSettings()
                                        isRefreshing = false
                                    }
                                } label: {
                                    HStack {
                                        Text("Check for Sync")
                                        Spacer()
                                        if isRefreshing {
                                            ProgressView()
                                        }
                                    }
                                }
                                .disabled(isRefreshing)
                            }
                        }
                    }
                }
            } else {
                // Loading
                ProgressView("Checking iCloud...")
            }
        }
        .navigationTitle("Audiobookshelf")
        .onAppear {
            loadSettings()
        }
    }

    private func loadSettings() {
        AppLogger.settings.info("[Watch] Loading Audiobookshelf settings from SwiftData/iCloud")
        let descriptor = FetchDescriptor<AudiobookshelfSettings>()

        // Debug: Check all records
        if let allSettings = try? modelContext.fetch(descriptor) {
            AppLogger.settings.info(
                "[Watch] Found \(allSettings.count) AudiobookshelfSettings record(s)")
            for (index, setting) in allSettings.enumerated() {
                AppLogger.settings.info(
                    "[Watch] Record \(index): id='\(setting.id)', serverURL='\(setting.serverURL)', enabled=\(setting.isEnabled)"
                )
            }
        }

        // Load the one with the correct ID (synced from iPhone)
        let specificDescriptor = FetchDescriptor<AudiobookshelfSettings>(
            predicate: #Predicate { $0.id == "audiobookshelf_settings" }
        )

        if let fetchedSettings = try? modelContext.fetch(specificDescriptor).first {
            AppLogger.settings.info(
                "[Watch] Found settings - serverURL: '\(fetchedSettings.serverURL)', enabled: \(fetchedSettings.isEnabled)"
            )
            settings = fetchedSettings
        } else {
            AppLogger.settings.warning(
                "[Watch] No Audiobookshelf settings synced from iPhone yet")
            settings = nil
        }
    }

    private func playbackModeText(_ mode: AudiobookshelfPlaybackMode) -> String {
        switch mode {
        case .streamAlways:
            return "Stream Always"
        case .manualDownload:
            return "Download Manually"
        case .autoDownload:
            return "Auto-Download on WiFi"
        }
    }

    private func playbackModeDescription(_ mode: AudiobookshelfPlaybackMode) -> String {
        switch mode {
        case .streamAlways:
            return "Always stream, never cache"
        case .manualDownload:
            return "Stream or download on demand"
        case .autoDownload:
            return "Auto-download when on WiFi"
        }
    }

}

#Preview {
    NavigationStack {
        AudiobookshelfWatchSettingsView()
            .modelContainer(for: [AudiobookshelfSettings.self], inMemory: true)
    }
}
