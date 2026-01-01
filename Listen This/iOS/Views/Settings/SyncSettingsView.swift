//
//  SyncSettingsView.swift
//  Listen This
//
//  Settings view for iCloud sync management
//

import SwiftUI
import SwiftData
import CloudKit

struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = SyncSettings.shared
    @State private var iCloudStatus: CKAccountStatus?
    @State private var isCheckingStatus = true
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var audiobookCount = 0
    @State private var sessionCount = 0

    var body: some View {
        Form {
            // MARK: - iCloud Status
            Section {
                HStack {
                    Label {
                        Text("iCloud Account")
                    } icon: {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                    }

                    Spacer()

                    if isCheckingStatus {
                        ProgressView()
                    } else {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Last Sync")
                    Spacer()
                    Text(settings.formattedLastSync())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            // MARK: - Sync Settings
            Section {
                Toggle("iCloud Sync", isOn: Binding(
                    get: { settings.iCloudSyncEnabled },
                    set: { settings.iCloudSyncEnabled = $0 }
                ))

                Toggle("Sync Playback Progress", isOn: Binding(
                    get: { settings.syncPlaybackProgress },
                    set: { settings.syncPlaybackProgress = $0 }
                ))
                .disabled(!settings.iCloudSyncEnabled)
            } header: {
                Text("Sync Options")
            } footer: {
                Text("When enabled, your library and playback progress will sync across all your devices signed into the same iCloud account.")
            }

            // MARK: - Sync Data
            Section {
                HStack {
                    Text("Audiobooks")
                    Spacer()
                    Text("\(audiobookCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Playback Sessions")
                    Spacer()
                    Text("\(sessionCount)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Synced Data")
            } footer: {
                Text("This data is stored in your private iCloud database and syncs automatically.")
            }

            // MARK: - Actions
            Section {
                Button {
                    Task {
                        await triggerSync()
                    }
                } label: {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        if isSyncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isSyncing || !isICloudAvailable || !settings.iCloudSyncEnabled)

                if let error = syncError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Actions")
            } footer: {
                if !isICloudAvailable {
                    Text("Sign in to iCloud in Settings to enable sync.")
                }
            }

            // MARK: - How Sync Works
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    SyncInfoRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Automatic Sync",
                        description: "Changes sync automatically when connected to the internet"
                    )

                    SyncInfoRow(
                        icon: "clock.arrow.circlepath",
                        title: "Conflict Resolution",
                        description: "Most recent playback position wins when syncing between devices"
                    )

                    SyncInfoRow(
                        icon: "lock.shield",
                        title: "Private & Secure",
                        description: "Data is stored in your private iCloud container"
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("How Sync Works")
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await checkICloudStatus()
            await loadSyncStats()
        }
        .refreshable {
            await checkICloudStatus()
            await loadSyncStats()
        }
    }

    // MARK: - Computed Properties

    private var isICloudAvailable: Bool {
        iCloudStatus == .available
    }

    private var statusIcon: String {
        switch iCloudStatus {
        case .available:
            return "checkmark.icloud.fill"
        case .noAccount:
            return "xmark.icloud.fill"
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            return "exclamationmark.icloud.fill"
        case .none:
            return "icloud"
        @unknown default:
            return "icloud"
        }
    }

    private var statusColor: Color {
        switch iCloudStatus {
        case .available:
            return .green
        case .noAccount:
            return .red
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            return .orange
        case .none:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var statusText: String {
        switch iCloudStatus {
        case .available:
            return "Connected"
        case .noAccount:
            return "Not Signed In"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Unknown"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        case .none:
            return "Checking..."
        @unknown default:
            return "Unknown"
        }
    }

    // MARK: - Methods

    private func checkICloudStatus() async {
        isCheckingStatus = true

        do {
            let container = CKContainer(identifier: "iCloud.com.anarkisti.Listen-This")
            iCloudStatus = try await container.accountStatus()
        } catch {
            iCloudStatus = .couldNotDetermine
        }

        isCheckingStatus = false
    }

    @MainActor
    private func loadSyncStats() async {
        let audiobookDescriptor = FetchDescriptor<Audiobook>()
        let sessionDescriptor = FetchDescriptor<PlaybackSession>()

        audiobookCount = (try? modelContext.fetchCount(audiobookDescriptor)) ?? 0
        sessionCount = (try? modelContext.fetchCount(sessionDescriptor)) ?? 0
    }

    @MainActor
    private func triggerSync() async {
        isSyncing = true
        syncError = nil

        do {
            // SwiftData with CloudKit syncs automatically, but we can trigger a save
            // to ensure pending changes are pushed
            try modelContext.save()

            // Mark sync as completed
            settings.markSyncCompleted()

            // Reload stats
            await loadSyncStats()
        } catch {
            syncError = error.localizedDescription
        }

        isSyncing = false
    }
}

// MARK: - Supporting Views

private struct SyncInfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SyncSettingsView()
            .modelContainer(for: Audiobook.self)
    }
}
