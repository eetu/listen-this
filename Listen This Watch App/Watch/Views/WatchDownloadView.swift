//
//  WatchDownloadView.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData

struct WatchDownloadView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Audiobook> { !$0.isCached })
    private var availableBooks: [Audiobook]
    
    @State private var downloadManager: WatchDownloadManager?
    
    var body: some View {
        List {
            Section {
                storageInfoView
            }
            
            if availableBooks.isEmpty {
                Text("All books are downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Section("Available to Download") {
                    ForEach(availableBooks) { audiobook in
                        WatchDownloadRow(audiobook: audiobook, downloadManager: downloadManager)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .task {
            downloadManager = WatchDownloadManager(modelContext: modelContext)
        }
    }
    
    private var storageInfoView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let manager = downloadManager {
                let (used, available) = manager.getStorageInfo()
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(formatBytes(used)) used")
                            .font(.caption2)
                        Text("\(formatBytes(available)) available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    CircularProgressView(
                        progress: Double(used) / Double(used + available),
                        lineWidth: 4
                    )
                    .frame(width: 30, height: 30)
                }
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct WatchDownloadRow: View {
    let audiobook: Audiobook
    let downloadManager: WatchDownloadManager?
    
    @State private var isDownloading = false
    @State private var progress: Double = 0
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(audiobook.title)
                    .font(.caption)
                    .lineLimit(2)
                
                Text("\(formatBytes(audiobook.fileSize))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isDownloading {
                CircularProgressView(progress: progress, lineWidth: 2)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    startDownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func startDownload() {
        guard let manager = downloadManager else { return }
        
        isDownloading = true
        
        Task {
            do {
                try await manager.downloadBook(audiobook) { newProgress in
                    progress = newProgress
                }
                isDownloading = false
            } catch {
                isDownloading = false
                // Handle error
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct CircularProgressView: View {
    let progress: Double
    let lineWidth: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: lineWidth)
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    WatchDownloadView()
        .modelContainer(for: [Audiobook.self], inMemory: true)
}
