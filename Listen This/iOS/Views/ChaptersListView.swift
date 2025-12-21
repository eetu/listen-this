import SwiftUI

struct ChaptersListView: View {
    let audiobook: Audiobook
    let playerService: AudioPlayerService?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                    }
                } else {
                    ContentUnavailableView(
                        "No Chapters",
                        systemImage: "list.bullet",
                        description: Text("This audiobook has no chapter metadata.")
                    )
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
