import SwiftUI

struct SleepTimerView: View {
    let playerService: AudioPlayerService?

    @Environment(\.dismiss) private var dismiss

    private let presets: [Int] = [5, 10, 15, 30, 45, 60]

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)

                Spacer()

                if playerService?.isSleepTimerActive == true {
                    Text(statusText)
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                ForEach(presets, id: \.self) { minutes in
                    Button {
                        playerService?.setSleepTimer(minutes: minutes)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(minutes)")
                                .font(.title2.bold())
                            Text("minutes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            // End of Chapter option
            Button {
                playerService?.setSleepTimerEndOfChapter()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.bookmark")
                        .font(.title3)
                    Text("End of Chapter")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray5))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if playerService?.isSleepTimerActive == true {
                Button(role: .destructive) {
                    playerService?.cancelSleepTimer()
                    dismiss()
                } label: {
                    Text("Cancel Sleep Timer")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red.opacity(0.15))
                        )
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
    }

    private var statusText: String {
        if playerService?.sleepAtEndOfChapter == true {
            return "End of Chapter"
        }
        let remaining = Int(playerService?.sleepTimerRemaining ?? 0)
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
