//
//  PreviewExamples.swift
//  Listen This
//
//  Examples of using mocks in SwiftUI previews
//

#if DEBUG

import SwiftUI
import SwiftData

// MARK: - CloudKit Transfer View Previews

#Preview("CloudKit Transfer - Idle") {
    let container = try! createPreviewContainer()
    let audiobook = Audiobook.preview()

    return CloudKitTransferView(audiobook: audiobook)
        .modelContainer(container)
        .environment(MockCloudKitTransferManager())
}

#Preview("CloudKit Transfer - Uploading") {
    let container = try! createPreviewContainer()
    let context = ModelContext(container)
    let audiobook = Audiobook.preview()
    context.insert(audiobook)

    let manager = MockCloudKitTransferManager()
    manager.simulateActiveUpload(audiobookId: audiobook.id, progress: 0.65)

    return CloudKitTransferView(audiobook: audiobook)
        .modelContainer(container)
        .environment(manager)
}

#Preview("CloudKit Transfer - Downloading") {
    let container = try! createPreviewContainer()
    let context = ModelContext(container)
    let audiobook = Audiobook.preview()
    context.insert(audiobook)

    let manager = MockCloudKitTransferManager()
    manager.simulateActiveDownload(audiobookId: audiobook.id, progress: 0.35)

    return CloudKitTransferView(audiobook: audiobook)
        .modelContainer(container)
        .environment(manager)
}

#Preview("CloudKit Transfer - Multiple Transfers") {
    let container = try! createPreviewContainer()
    let context = ModelContext(container)

    let audiobook1 = Audiobook.preview(title: "Book 1")
    let audiobook2 = Audiobook.preview(title: "Book 2")
    let audiobook3 = Audiobook.preview(title: "Book 3")

    context.insert(audiobook1)
    context.insert(audiobook2)
    context.insert(audiobook3)

    let manager = MockCloudKitTransferManager()
    manager.simulateActiveUpload(audiobookId: audiobook1.id, progress: 0.25)
    manager.simulateActiveDownload(audiobookId: audiobook2.id, progress: 0.75)
    manager.simulateActiveUpload(audiobookId: audiobook3.id, progress: 0.50)

    return CloudKitTransferView(audiobook: audiobook1)
        .modelContainer(container)
        .environment(manager)
}

#Preview("CloudKit Transfer - Error State") {
    let container = try! createPreviewContainer()
    let audiobook = Audiobook.preview()

    let manager = MockCloudKitTransferManager()
    manager.shouldFailUpload = true

    return CloudKitTransferView(audiobook: audiobook)
        .modelContainer(container)
        .environment(manager)
}

// MARK: - Library View Previews

#Preview("Library - Empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self,
        configurations: config
    )
    
    return LibraryView()
        .modelContainer(container)
}

#Preview("Library - Populated") {
    let container = try! createPreviewContainer()
    
    return LibraryView()
        .modelContainer(container)
}

#Preview("Library - With Cached Books") {
    let container = try! createPreviewContainer()
    let context = ModelContext(container)
    
    // Mark some books as cached
    let descriptor = FetchDescriptor<Audiobook>()
    if let audiobooks = try? context.fetch(descriptor),
       let firstBook = audiobooks.first {
        // In a real preview, you'd set cache state
        let cacheEntry = CacheEntry(
            filePath: "/mock/path/\(firstBook.id).m4b",
            fileSize: firstBook.fileSize
        )
        firstBook.cacheEntry = cacheEntry
        context.insert(cacheEntry)
        try? context.save()
    }
    
    return LibraryView()
        .modelContainer(container)
}

// MARK: - Progress View Previews

#Preview("Transfer Progress - 0%") {
    let progress = ChunkTransferProgress(
        audiobookId: UUID(),
        totalBytes: 100_000_000,
        totalChunks: 10,
        completedChunks: 0,
        bytesTransferred: 0,
        isUploading: true
    )
    
    VStack {
        Text(progress.statusText)
        ProgressView(value: progress.progress)
        Text("\(progress.progressPercentage)%")
    }
    .padding()
}

#Preview("Transfer Progress - 50%") {
    let progress = ChunkTransferProgress(
        audiobookId: UUID(),
        totalBytes: 100_000_000,
        totalChunks: 10,
        completedChunks: 5,
        bytesTransferred: 50_000_000,
        isUploading: true
    )
    
    VStack {
        Text(progress.statusText)
        ProgressView(value: progress.progress)
        Text("\(progress.progressPercentage)%")
        Text(progress.progressText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
}

#Preview("Transfer Progress - Complete") {
    let progress = ChunkTransferProgress(
        audiobookId: UUID(),
        totalBytes: 100_000_000,
        totalChunks: 10,
        completedChunks: 10,
        bytesTransferred: 100_000_000,
        isUploading: false
    )
    
    VStack {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.largeTitle)
        Text("Download Complete")
        Text(progress.progressText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
}

// MARK: - Watch Transfer Previews

#Preview("Watch Transfer - Uploading") {
    let progress = WatchTransferProgress(
        audiobookId: "test",
        audiobookTitle: "The Hobbit",
        totalBytes: 450_000_000,
        bytesTransferred: 225_000_000,
        isActive: true
    )
    
    return VStack(spacing: 16) {
        HStack {
            Image(systemName: "applewatch")
            Text("Transferring to Apple Watch")
        }
        .font(.headline)
        
        VStack(alignment: .leading) {
            Text(progress.audiobookTitle)
                .font(.subheadline)
            
            ProgressView(value: progress.progress)
            
            HStack {
                Text(progress.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(progress.progressPercentage)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding()
}

// MARK: - Audiobook Card Previews

#Preview("Audiobook Card - Single") {
    let audiobook = Audiobook.preview()
    
    return List {
        HStack {
            Image(systemName: "book.fill")
                .font(.largeTitle)
                .frame(width: 60, height: 60)
                .background(.blue.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading) {
                Text(audiobook.title)
                    .font(.headline)
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let narrator = audiobook.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview("Audiobook Card - List") {
    let audiobooks = Audiobook.previewLibrary()
    
    return List(audiobooks) { audiobook in
        HStack {
            Image(systemName: "book.fill")
                .font(.largeTitle)
                .frame(width: 60, height: 60)
                .background(.blue.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                HStack {
                    Image(systemName: "clock")
                    Text(formatDuration(audiobook.duration))
                    
                    Spacer()
                    
                    Image(systemName: "doc")
                    Text(formatFileSize(audiobook.fileSize))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helper Functions

private func formatDuration(_ seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    return "\(hours)h \(minutes)m"
}

private func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Mock Scenario Previews

#Preview("Scenario - Fresh Install") {
    // Empty library, no transfers, no cache
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self,
        configurations: config
    )
    
    return LibraryView()
        .modelContainer(container)
        .environment(MockCloudKitTransferManager())
}

#Preview("Scenario - Active User") {
    // Library with books, some cached, active transfer
    let container = try! createPreviewContainer()
    let context = ModelContext(container)

    let manager = MockCloudKitTransferManager()

    // Simulate some books already uploaded to CloudKit
    let descriptor = FetchDescriptor<Audiobook>()
    if let audiobooks = try? context.fetch(descriptor) {
        let uploadedIds = audiobooks.prefix(3).map { $0.id }
        manager.preloadUploadedBooks(uploadedIds)

        // Simulate active download for one book
        if let firstBook = audiobooks.first {
            manager.simulateActiveDownload(
                audiobookId: firstBook.id,
                progress: 0.42
            )
        }
    }

    return LibraryView()
        .modelContainer(container)
        .environment(manager)
}

#Preview("Scenario - Network Error") {
    let container = try! createPreviewContainer()

    let manager = MockCloudKitTransferManager()
    manager.shouldFailUpload = true
    manager.errorToThrow = .networkError

    let audiobook = Audiobook.preview()
    return CloudKitTransferView(audiobook: audiobook)
        .modelContainer(container)
        .environment(manager)
}

#Preview("Scenario - Large Library (100 books)") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self,
        configurations: config
    )
    
    let context = ModelContext(container)
    
    // Create 100 audiobooks
    for i in 1...100 {
        let audiobook = Audiobook.preview(
            title: "Book \(i)",
            author: "Author \(i % 10)",
            narrator: "Narrator \(i % 5)"
        )
        context.insert(audiobook)
    }
    
    try? context.save()
    
    return LibraryView()
        .modelContainer(container)
}

#endif
