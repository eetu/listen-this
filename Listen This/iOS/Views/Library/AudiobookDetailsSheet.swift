//
//  AudiobookDetailsSheet.swift
//  Listen This
//
//  Detailed information about an audiobook
//

import SwiftUI

struct AudiobookDetailsSheet: View {
    let audiobook: Audiobook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Source Information
                Section {
                    LabeledContent("Source") {
                        HStack(spacing: 6) {
                            if audiobook.sourceType == "audiobookshelf" {
                                Image(systemName: "server.rack")
                                Text("Audiobookshelf")
                            } else if audiobook.sourceType == "jellyfin" {
                                Image(systemName: "server.rack")
                                Text("Jellyfin")
                            } else if audiobook.iCloudRelativePath != nil {
                                Image(systemName: "icloud")
                                Text("iCloud Drive")
                            } else {
                                Text("Local")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let serverURL = audiobook.sourceURL {
                        LabeledContent("Server") {
                            Text(serverURL)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if let iCloudPath = audiobook.iCloudRelativePath {
                        LabeledContent("Path") {
                            Text(iCloudPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Source")
                }

                // Availability
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if audiobook.isFileCached {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Downloaded")
                                    .foregroundStyle(.green)
                            } else if audiobook.requiresStreaming {
                                Image(systemName: "wifi")
                                    .foregroundStyle(.orange)
                                Text("Streaming")
                                    .foregroundStyle(.orange)
                            } else if audiobook.iCloudRelativePath != nil {
                                Image(systemName: "icloud")
                                    .foregroundStyle(.blue)
                                Text("iCloud")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    if let cachePath = audiobook.expectedCachePath {
                        LabeledContent("Cache Path") {
                            Text(cachePath)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    if audiobook.isFileCached {
                        Text("This audiobook is downloaded and available for offline playback.")
                    } else if audiobook.requiresStreaming {
                        Text(
                            "This audiobook will stream from the server. Download it for offline access."
                        )
                    } else if audiobook.iCloudRelativePath != nil {
                        Text(
                            "This audiobook is stored in iCloud Drive and will be downloaded on first play."
                        )
                    }
                }

                // File Information
                Section {
                    LabeledContent("Duration") {
                        Text(formatDuration(audiobook.duration))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("File Size") {
                        Text(formatFileSize(audiobook.fileSize))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Chapters") {
                        Text("\(audiobook.chapterCount)")
                            .foregroundStyle(.secondary)
                    }

                    if let narrator = audiobook.narrator {
                        LabeledContent("Narrator") {
                            Text(narrator)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Last Played") {
                        Text(audiobook.lastAccessedDate, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Information")
                }

                // Progress
                if let session = audiobook.playbackSession, session.currentPosition > 0 {
                    Section {
                        LabeledContent("Progress") {
                            Text(String(format: "%.1f%%", session.progressPercentage))
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Position") {
                            Text(formatDuration(session.currentPosition))
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Playback Speed") {
                            Text(String(format: "%.1fx", session.playbackRate))
                                .foregroundStyle(.secondary)
                        }

                        if session.isCompleted {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Completed")
                                    .foregroundStyle(.green)
                            }
                        }
                    } header: {
                        Text("Playback")
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    AudiobookDetailsSheet(
        audiobook: Audiobook(
            title: "Sample Book",
            author: "Author Name",
            narrator: "Narrator Name",
            duration: 36000,
            fileSize: 350_000_000,
            chapterCount: 15
        ))
}
