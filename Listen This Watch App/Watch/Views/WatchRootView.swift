//
//  WatchRootView.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData

struct WatchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) 
    private var audiobooks: [Audiobook]
    
    @State private var showingDownloads = false
    
    var body: some View {
        NavigationStack {
            if audiobooks.isEmpty {
                emptyStateView
            } else {
                libraryView
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("No Audiobooks")
                .font(.headline)
            
            Text("Add books from your iPhone or download via WiFi")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
    
    private var libraryView: some View {
        List {
            ForEach(audiobooks) { audiobook in
                NavigationLink {
                    WatchAudiobookDetailView(audiobook: audiobook)
                } label: {
                    WatchAudiobookRow(audiobook: audiobook)
                }
            }
            
            Section {
                NavigationLink {
                    WatchDownloadView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            }
        }
        .navigationTitle("Library")
    }
}

#Preview {
    WatchRootView()
        .modelContainer(for: [Audiobook.self], inMemory: true)
}
