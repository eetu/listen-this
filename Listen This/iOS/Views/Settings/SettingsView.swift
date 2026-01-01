//
//  SettingsView.swift
//  Listen This
//
//  Main settings navigation hub
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Playback
                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("Playback", systemImage: "play.circle")
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Playback speed, skip intervals, and sleep timer defaults")
                }

                // MARK: - Storage
                Section {
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        Label("Local Storage", systemImage: "internaldrive")
                    }

                    NavigationLink {
                        CloudKitStorageView()
                    } label: {
                        Label("CloudKit Storage", systemImage: "icloud")
                    }
                } header: {
                    Text("Storage")
                }

                // MARK: - Sync
                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        Label("iCloud Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }

                    NavigationLink {
                        TransferMethodSettingsView(modelContext: modelContext)
                    } label: {
                        Label("Watch Transfer", systemImage: "applewatch")
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Manage how your library and audiobooks sync across devices")
                }

                // MARK: - Sources
                Section {
                    NavigationLink {
                        Text("Content Sources - Coming Soon")
                    } label: {
                        Label("Content Sources", systemImage: "folder")
                    }
                } header: {
                    Text("Sources")
                }

                // MARK: - App
                Section {
                    NavigationLink {
                        Text("About - Coming Soon")
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                } header: {
                    Text("App")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
