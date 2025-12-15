//
//  ImportView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var libraryService: AudiobookLibraryService?
    @State private var isImporting = false
    @State private var importError: AudiobookError?
    @State private var showingFilePicker = false
    @State private var showingRefreshSheet = false
    
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
                    
                    Button {
                        Task {
                            await refreshFromiCloud()
                        }
                    } label: {
                        Label("Scan iCloud Drive", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(isImporting)
                } header: {
                    Text("Import Sources")
                } footer: {
                    Text("Import M4B audiobook files from your device or scan for files in your iCloud Drive Documents folder.")
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to Add Audiobooks")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Place M4B files in iCloud Drive/Documents", systemImage: "1.circle.fill")
                            Label("Use 'Scan iCloud Drive' to import them", systemImage: "2.circle.fill")
                            Label("Or use 'Import M4B File' to pick files", systemImage: "3.circle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Instructions")
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
            .sheet(isPresented: $showingRefreshSheet) {
                RefreshProgressView(
                    isRefreshing: libraryService?.isRefreshing ?? false
                )
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
    
    private func refreshFromiCloud() async {
        guard let service = libraryService else { return }
        
        isImporting = true
        importError = nil
        
        await service.refreshLibrary()
        
        if let error = service.lastError {
            importError = error
        }
        
        isImporting = false
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) async {
        isImporting = true
        importError = nil
        
        defer { isImporting = false }
        
        do {
            let urls = try result.get()
            
            guard let url = urls.first else {
                print("❌ No URL selected")
                return
            }
            
            print("✅ Selected file: \(url.lastPathComponent)")
            print("   Path: \(url.path)")
            
            guard let service = libraryService else {
                print("❌ Library service is nil")
                return
            }
            
            print("📚 Starting import...")
            let audiobook = try await service.importFile(from: url)
            print("✅ Import successful!")
            print("   Title: \(audiobook.title)")
            print("   Author: \(audiobook.author)")
            print("   Duration: \(audiobook.duration)s")
            
            // Success - dismiss after brief delay
            try? await Task.sleep(for: .seconds(0.5))
            dismiss()
            
        } catch let error as AudiobookError {
            print("❌ AudiobookError: \(error)")
            importError = error
        } catch {
            print("❌ Unknown error: \(error)")
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
