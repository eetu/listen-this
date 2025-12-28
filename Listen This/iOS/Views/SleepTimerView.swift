import SwiftUI

struct SleepTimerView<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player

    @Environment(\.dismiss) private var dismiss

    @State private var selectedMinutes: Double

    private let presets: [Int] = [5, 10, 15, 30, 45, 60]

    init(player: Player) {
        self.player = player
        // Initialize with current timer or default to 15 minutes
        let current = player.sleepTimerRemaining
        _selectedMinutes = State(initialValue: current > 0 ? Double(Int(current / 60)) : 15.0)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)

                Spacer()

                Text("\(Int(selectedMinutes)) min")
                    .monospacedDigit()
            }
            .padding(.horizontal)

            Slider(
                value: $selectedMinutes,
                in: 1...90,
                step: 1
            )
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                ForEach(presets, id: \.self) { minutes in
                    Button {
                        selectedMinutes = Double(minutes)
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
                                .fill(Int(selectedMinutes) == minutes ? Color.accentColor : Color(.systemGray5))
                        )
                        .foregroundStyle(Int(selectedMinutes) == minutes ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                // End of Chapter option
                Button {
                    player.setSleepTimerEndOfChapter()
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

                // Set Timer button
                Button {
                    player.setSleepTimer(minutes: Int(selectedMinutes))
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.title3)
                        Text("Set Timer")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            if player.isSleepTimerActive {
                Button(role: .destructive) {
                    player.cancelSleepTimer()
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
}
