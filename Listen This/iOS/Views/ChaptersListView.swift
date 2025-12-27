import SwiftUI

struct ChaptersListView: View {
    let audiobook: Audiobook
    let playerService: AudioPlayerService?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let chapters = audiobook.chapters, !chapters.isEmpty {
                        ForEach(chapters.sorted(by: { $0.index < $1.index })) { chapter in
                            Button {
                                Task {
                                    await playerService?.seek(to: chapter.startTime)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chapter.title)
                                            .font(.headline)

                                        Text("Chapter \(chapter.index + 1)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if chapter.index == playerService?.currentChapterIndex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .id(chapter.id)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Chapters",
                            systemImage: "list.bullet",
                            description: Text("This audiobook has no chapter metadata.")
                        )
                    }
                }
                .task {
                    // Scroll to current chapter after a brief delay to ensure list is rendered
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

                    if let chapters = audiobook.chapters,
                       let currentChapterIndex = playerService?.currentChapterIndex,
                       currentChapterIndex >= 0,
                       currentChapterIndex < chapters.count {
                        let sortedChapters = chapters.sorted(by: { $0.index < $1.index })
                        if let currentChapter = sortedChapters.first(where: { $0.index == currentChapterIndex }) {
                            withAnimation {
                                proxy.scrollTo(currentChapter.id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
