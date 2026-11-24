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
    @State private var importProgress: (done: Int, total: Int) = (0, 0)
    @State private var importErrors: [String] = []
    @State private var showingFilePicker = false
    @State private var showingAudiobookshelf = false
    @State private var showingAudiobookshelfSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import M4B Files", systemImage: "doc.badge.plus")
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

                if !importErrors.isEmpty {
                    Section {
                        ForEach(importErrors, id: \.self) { message in
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(message)
                                    .font(.caption)
                            }
                        }
                    } header: {
                        Text("Not Imported")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // iCloud Drive instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Label("From iCloud Drive", systemImage: "icloud")
                                .font(.subheadline.weight(.medium))
                            
                            Text("Place M4B files in iCloud Drive, then tap 'Import M4B Files' to select one or more.")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.audiobook, .mpeg4Audio],
                allowsMultipleSelection: true
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
                    ProgressView(
                        importProgress.total > 1
                            ? "Importing \(importProgress.done + 1) of \(importProgress.total)..."
                            : "Importing..."
                    )
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

    /// Imports each picked file in turn. Closes when all succeed; otherwise
    /// stays open listing the ones that didn't.
    private func handleFileImport(_ result: Result<[URL], Error>) async {
        importErrors = []

        let urls: [URL]
        do {
            urls = try result.get()
        } catch {
            importErrors = [error.localizedDescription]
            return
        }

        guard !urls.isEmpty, let service = libraryService else { return }

        isImporting = true
        defer { isImporting = false }

        for (index, url) in urls.enumerated() {
            importProgress = (index, urls.count)
            do {
                _ = try await service.importFile(from: url)
            } catch {
                AppLogger.import.error(
                    "Import of \(url.lastPathComponent) failed: \(error.localizedDescription)")
                importErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if importErrors.isEmpty {
            dismiss()
        }
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
