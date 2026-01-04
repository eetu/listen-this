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

                            HStack {
                                Text("Sync Status")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Label("Synced from iPhone", systemImage: "checkmark.icloud.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .lineLimit(1)
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

                            Button(role: .destructive) {
                                deleteEmptySettings()
                            } label: {
                                Text("Delete Empty Settings")
                            }
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

                                Button(role: .destructive) {
                                    deleteEmptySettings()
                                } label: {
                                    Text("Delete Empty Settings")
                                }
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

    private func deleteEmptySettings() {
        AppLogger.settings.info("[Watch] Attempting to delete empty settings records")
        let descriptor = FetchDescriptor<AudiobookshelfSettings>()

        guard let allSettings = try? modelContext.fetch(descriptor) else {
            AppLogger.settings.error("[Watch] Failed to fetch settings for deletion")
            return
        }

        var deletedCount = 0
        for setting in allSettings {
            // Access all properties to resolve faults before checking/deleting
            let id = setting.id
            let url = setting.serverURL
            let enabled = setting.isEnabled
            let _ = setting.playbackMode  // Force fault resolution

            if url.isEmpty {
                AppLogger.settings.info(
                    "[Watch] Deleting empty settings record with id: '\(id)', enabled: \(enabled)")
                modelContext.delete(setting)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            do {
                try modelContext.save()
                AppLogger.settings.info("[Watch] Deleted \(deletedCount) empty settings record(s)")

                // Clear current settings and reload after deletion
                settings = nil
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    loadSettings()
                }
            } catch {
                AppLogger.settings.error(
                    "[Watch] Failed to save after deleting empty settings: \(error.localizedDescription)"
                )
            }
        } else {
            AppLogger.settings.info("[Watch] No empty settings found to delete")
        }
    }
}

#Preview {
    NavigationStack {
        AudiobookshelfWatchSettingsView()
            .modelContainer(for: [AudiobookshelfSettings.self], inMemory: true)
    }
}
