//
//  LibraryView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var audiobooks: [Audiobook]
    
    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var showingSettings = false
    
    var filteredAudiobooks: [Audiobook] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText) ||
            book.author.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if audiobooks.isEmpty {
                    emptyStateView
                } else {
                    libraryGrid
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search audiobooks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddBook = true
                    } label: {
                        Label("Add Book", systemImage: "plus")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingAddBook) {
                ImportView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Audiobooks", systemImage: "book.closed")
        } description: {
            Text("Add audiobooks from iCloud Drive, Jellyfin, or AudiobookShelf")
        } actions: {
            Button("Add Audiobook") {
                showingAddBook = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Library Grid
    
    private var libraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160), spacing: 16)
            ], spacing: 16) {
                ForEach(filteredAudiobooks) { book in
                    NavigationLink(value: book) {
                        AudiobookCard(audiobook: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationDestination(for: Audiobook.self) { book in
            PlayerView(audiobook: book)
        }
    }
}

// MARK: - Audiobook Card

struct AudiobookCard: View {
    let audiobook: Audiobook
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            Group {
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.tertiary)
                        
                        Image(systemName: "book.closed")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
            
            // Title
            Text(audiobook.title)
                .font(.headline)
                .lineLimit(2)
            
            // Author
            Text(audiobook.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            // Progress indicator
            if let session = audiobook.playbackSession {
                ProgressView(value: session.progressPercentage, total: 100)
                    .tint(.accentColor)
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
}
