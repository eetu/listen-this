//
//  CacheSettingsView.swift
//  Listen This
//
//  Settings view for local cache management
//

import SwiftUI
import SwiftData

struct CacheSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = CacheSettings.shared
    @State private var currentCacheSize: Int64 = 0
    @State private var cachedAudiobooks: [CachedAudiobookInfo] = []
    @State private var isLoading = true
    @State private var isCleaningUp = false
    @State private var showClearAllConfirmation = false

    var body: some View {
        Form {
            // MARK: - Current Usage
            Section {
                HStack {
                    Text("Used")
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(CacheSettings.formatBytes(currentCacheSize))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Limit")
                    Spacer()
                    Text(CacheSettings.formatCacheSize(settings.maxCacheSizeGB))
                        .foregroundStyle(.secondary)
                }

                if !isLoading {
                    ProgressView(value: usagePercentage)
                        .tint(usageColor)
                }
            } header: {
                Text("Storage Usage")
            } footer: {
                if !isLoading {
                    if cachedAudiobooks.isEmpty {
                        Text("No audiobooks cached locally. Play an audiobook to download it for offline listening.")
                    } else {
                        Text("\(cachedAudiobooks.count) audiobook\(cachedAudiobooks.count == 1 ? "" : "s") cached locally for offline playback.")
                    }
                }
            }

            // MARK: - Cache Settings
            Section {
                Picker("Maximum Cache Size", selection: Binding(
                    get: { settings.maxCacheSizeGB },
                    set: { settings.maxCacheSizeGB = $0 }
                )) {
                    ForEach(CacheSettings.cacheSizePresets, id: \.self) { size in
                        Text(CacheSettings.formatCacheSize(size))
                            .tag(size)
                    }
                }

                Picker("Keep Recent Audiobooks", selection: Binding(
                    get: { settings.keepRecentCount },
                    set: { settings.keepRecentCount = $0 }
                )) {
                    ForEach(CacheSettings.keepRecentPresets, id: \.self) { count in
                        Text("\(count)")
                            .tag(count)
                    }
                }

                Toggle("Auto Cleanup", isOn: Binding(
                    get: { settings.autoCleanupEnabled },
                    set: { settings.autoCleanupEnabled = $0 }
                ))
            } header: {
                Text("Cache Settings")
            } footer: {
                Text("When auto cleanup is enabled, older cached audiobooks will be automatically removed when the cache exceeds the limit, keeping the most recently played ones.")
            }

            // MARK: - Cached Audiobooks
            if !cachedAudiobooks.isEmpty {
                Section {
                    ForEach(cachedAudiobooks) { audiobook in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(audiobook.title)
                                    .lineLimit(1)
                                Text(audiobook.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(CacheSettings.formatBytes(audiobook.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteCachedAudiobooks)
                } header: {
                    Text("Cached Audiobooks")
                } footer: {
                    Text("Swipe to delete individual cached files. The audiobook will remain in your library.")
                }
            }

            // MARK: - Actions
            Section {
                Button {
                    Task {
                        await runCleanup()
                    }
                } label: {
                    HStack {
                        Text("Clean Up Now")
                        Spacer()
                        if isCleaningUp {
                            ProgressView()
                        }
                    }
                }
                .disabled(isCleaningUp || cachedAudiobooks.isEmpty)

                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Text("Clear All Cache")
                }
                .disabled(cachedAudiobooks.isEmpty)
            } header: {
                Text("Actions")
            } footer: {
                Text("Clean Up removes orphaned files and evicts old audiobooks based on your settings. Clear All removes all cached files.")
            }
        }
        .navigationTitle("Local Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCacheInfo()
        }
        .refreshable {
            await loadCacheInfo()
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task {
                    await clearAllCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached audiobook files. Your library and playback progress will not be affected.")
        }
    }

    // MARK: - Computed Properties

    private var usagePercentage: Double {
        guard settings.maxCacheSizeBytes > 0 else { return 0 }
        return min(Double(currentCacheSize) / Double(settings.maxCacheSizeBytes), 1.0)
    }

    private var usageColor: Color {
        if usagePercentage > 0.9 {
            return .red
        } else if usagePercentage > 0.7 {
            return .orange
        } else {
            return .blue
        }
    }

    // MARK: - Methods

    @MainActor
    private func loadCacheInfo() async {
        isLoading = true

        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        currentCacheSize = cacheManager.getCacheSize()

        // Get cached audiobooks from database
        let descriptor = FetchDescriptor<Audiobook>(
            sortBy: [SortDescriptor(\.lastAccessedDate, order: .reverse)]
        )

        if let audiobooks = try? modelContext.fetch(descriptor) {
            cachedAudiobooks = audiobooks
                .filter { $0.isFileCached }
                .compactMap { audiobook -> CachedAudiobookInfo? in
                    guard let cachePath = audiobook.expectedCachePath else { return nil }
                    let cacheURL = URL(fileURLWithPath: cachePath)

                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                          let size = attrs[.size] as? Int64 else {
                        return nil
                    }

                    return CachedAudiobookInfo(
                        id: audiobook.id,
                        title: audiobook.title,
                        author: audiobook.author,
                        size: size,
                        cachePath: cachePath
                    )
                }
        }

        isLoading = false
    }

    private func deleteCachedAudiobooks(at offsets: IndexSet) {
        for index in offsets {
            let info = cachedAudiobooks[index]
            let cacheURL = URL(fileURLWithPath: info.cachePath)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        cachedAudiobooks.remove(atOffsets: offsets)

        // Recalculate cache size
        Task {
            let cacheManager = AudiobookCacheManager(modelContext: modelContext)
            currentCacheSize = cacheManager.getCacheSize()
        }
    }

    @MainActor
    private func runCleanup() async {
        isCleaningUp = true

        let cacheManager = AudiobookCacheManager(modelContext: modelContext)

        do {
            try await cacheManager.cleanupOrphanedCaches()
            try await cacheManager.evictOldCaches(keepingCount: settings.keepRecentCount)
            try await cacheManager.cleanupIfNeeded(maxSize: settings.maxCacheSizeBytes)
        } catch {
            print("[CacheSettings] Cleanup error: \(error)")
        }

        await loadCacheInfo()
        isCleaningUp = false
    }

    @MainActor
    private func clearAllCache() async {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        let cachedFiles = cacheManager.getAllCachedFiles()

        for fileURL in cachedFiles {
            try? FileManager.default.removeItem(at: fileURL)
        }

        await loadCacheInfo()
    }
}

// MARK: - Supporting Types

private struct CachedAudiobookInfo: Identifiable {
    let id: UUID
    let title: String
    let author: String
    let size: Int64
    let cachePath: String
}

#Preview {
    NavigationStack {
        CacheSettingsView()
            .modelContainer(for: Audiobook.self)
    }
}
