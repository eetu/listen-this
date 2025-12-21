import SwiftUI

struct PlaybackSpeedPickerView: View {
    let playerService: AudioPlayerService?

    @State private var selectedSpeed: Double

    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(playerService: AudioPlayerService?) {
        self.playerService = playerService
        _selectedSpeed = State(initialValue: playerService?.playbackRate ?? 1.0)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Playback Speed")
                    .font(.headline)
                Spacer()
                Text("\(selectedSpeed, specifier: "%.2f")x")
                    .monospacedDigit()
            }
            .padding(.horizontal)

            Slider(
                value: $selectedSpeed,
                in: 0.5...2.5,
                step: 0.05
            )
            .onChange(of: selectedSpeed) { _, newValue in
                playerService?.setPlaybackRate(newValue)
            }
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 5), spacing: 12) {
                ForEach(presets, id: \.self) { speed in
                    Button {
                        selectedSpeed = speed
                        playerService?.setPlaybackRate(speed)
                    } label: {
                        Text("\(speed, specifier: "%.2f")")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(abs(selectedSpeed - speed) < 0.01 ? Color.accentColor : Color(.systemGray5))
                            )
                            .foregroundStyle(abs(selectedSpeed - speed) < 0.01 ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
    }
}
