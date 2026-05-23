//
//  ImportView.swift
//  listen this
//

import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var libraryService: AudiobookLibraryService?
    @State private var isImporting = false
    @State private var importError: AudiobookError?
    @State private var showingFilePicker = false
    @State private var showingRefreshSheet = false
    @State private var showingAudiobookshelf = false
    @State private var showingAudiobookshelfSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import M4B File", systemImage: "doc.badge.plus")
                    }
                    .disabled(isImporting)

                    if SettingsManager.shared.audiobookshelfEnabled {
                        Button {
                            showingAudiobookshelf = true
                        } label: {
                            Label("Browse Audiobookshelf", systemImage: "server.rack")
                        }
                    } else {
                        Button {
                            showingAudiobookshelfSettings = true
                        } label: {
                            Label("Setup Audiobookshelf", systemImage: "server.rack")
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Import Sources")
                } footer: {
                    if SettingsManager.shared.audiobookshelfEnabled {
                        Text("Import M4B files from iCloud or browse your Audiobookshelf library.")
                    } else {
                        Text(
                            "Import M4B files from iCloud. Enable Audiobookshelf in Settings to access your server library."
                        )
                    }
                }

                if let error = importError {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error.userMessage)
                                .font(.caption)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // iCloud Drive instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Label("From iCloud Drive", systemImage: "icloud")
                                .font(.subheadline.weight(.medium))
                            
                            Text("Place M4B files in iCloud Drive, then tap 'Import M4B File' to select them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Audiobookshelf instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Label("From Audiobookshelf", systemImage: "server.rack")
                                .font(.subheadline.weight(.medium))
                            
                            if SettingsManager.shared.audiobookshelfEnabled {
                                Text("Tap 'Browse Audiobookshelf' to add books from your server library.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Tap 'Setup Audiobookshelf' to connect to your self-hosted server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("How to Add Audiobooks")
                }
            }
            .navigationTitle("Import Audiobooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.audiobook, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    await handleFileImport(result)
                }
            }
            .sheet(isPresented: $showingAudiobookshelf) {
                AudiobookshelfBrowserView()
            }
            .sheet(isPresented: $showingAudiobookshelfSettings) {
                NavigationStack {
                    AudiobookshelfSettingsView()
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(10)
                }
            }
            .onAppear {
                if libraryService == nil {
                    libraryService = AudiobookLibraryService(modelContext: modelContext)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        isImporting = true
        importError = nil

        defer { isImporting = false }

        do {
            let urls = try result.get()

            guard let url = urls.first else {
                AppLogger.import.error("No URL selected")
                return
            }

            guard let service = libraryService else {
                AppLogger.import.error("Library service is nil")
                return
            }

            _ = try await service.importFile(from: url)

            // Success - dismiss after brief delay
            try? await Task.sleep(for: .seconds(0.5))
            dismiss()

        } catch let error as AudiobookError {
            AppLogger.import.error("AudiobookError: \(error.userMessage)")
            importError = error
        } catch {
            AppLogger.import.error("Unknown error: \(error.localizedDescription)")
            importError = .unknown(error)
        }
    }
}

// MARK: - Supporting Views

struct RefreshProgressView: View {
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: 20) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.large)

                Text("Scanning iCloud Drive...")
                    .font(.headline)

                Text("Looking for M4B audiobook files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)

                Text("Scan Complete")
                    .font(.headline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - UTType Extension

extension UTType {
    static var audiobook: UTType {
        UTType(filenameExtension: "m4b") ?? .audio
    }
}

#Preview {
    ImportView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
}
