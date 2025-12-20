//
//  SettingsView.swift
//  listen this
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudKitStorageView()
                    } label: {
                        Label("CloudKit Storage", systemImage: "icloud")
                    }
                    
                    NavigationLink {
                        Text("Local Storage - Coming Soon")
                    } label: {
                        Label("Local Storage", systemImage: "internaldrive")
                    }
                } header: {
                    Text("Storage")
                }
                
                Section {
                    NavigationLink {
                        TransferMethodSettingsView(modelContext: modelContext)
                    } label: {
                        Label("Transfer Method", systemImage: "arrow.triangle.swap")
                    }
                } header: {
                    Text("Apple Watch Sync")
                } footer: {
                    Text("Choose how audiobooks are transferred to your Apple Watch")
                }
                
                Section {
                    NavigationLink {
                        Text("iCloud Sync - Coming Soon")
                    } label: {
                        Label("iCloud Sync", systemImage: "icloud.and.arrow.up")
                    }
                } header: {
                    Text("Sync")
                }
                
                Section {
                    NavigationLink {
                        Text("Content Sources - Coming Soon")
                    } label: {
                        Label("Content Sources", systemImage: "folder")
                    }
                } header: {
                    Text("Sources")
                }
                
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
