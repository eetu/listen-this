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
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        Text("Content Sources - Coming Soon")
                    } label: {
                        Label("Content Sources", systemImage: "folder")
                    }
                    
                    NavigationLink {
                        Text("Storage Management - Coming Soon")
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                } header: {
                    Text("Library")
                }
                
                Section {
                    NavigationLink {
                        Text("iCloud Sync - Coming Soon")
                    } label: {
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                } header: {
                    Text("Sync")
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
