//
//  SleepTimerSheet.swift
//  Listen This
//
//  Sheet for configuring sleep timer with presets and custom duration
//

import SwiftUI

struct SleepTimerSheet<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player

    @Environment(\.dismiss) private var dismiss

    @State private var selectedMinutes: Double

    private let presets: [Int] = [5, 10, 15, 30, 45, 60]

    init(player: Player) {
        self.player = player
        // Initialize with current timer, user's default, or fallback to 15 minutes
        let current = player.sleepTimerRemaining
        if current > 0 {
            _selectedMinutes = State(initialValue: Double(Int(current / 60)))
        } else {
            let defaultMinutes = PlaybackSettings.shared.defaultSleepTimerMinutes
            // Use default if set and positive (not "None" or "End of Chapter")
            if defaultMinutes > 0 {
                _selectedMinutes = State(initialValue: Double(defaultMinutes))
            } else {
                _selectedMinutes = State(initialValue: 15.0)
            }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            if player.isSleepTimerActive {
                activeTimerView
            } else {
                timerSelectionView
            }

            if !player.isSleepTimerActive {
                actionButtons
            } else {
                cancelButton
            }

            Spacer()
        }
        .padding(.top)
    }

    // MARK: - Timer Selection View

    private var timerSelectionView: some View {
        Group {
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
        }
    }

    // MARK: - Active Timer View

    private var activeTimerView: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Sleep Timer Active")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                if player.sleepAtEndOfChapter {
                    Image(systemName: "text.bookmark")
                        .font(.system(size: 60))
                        .foregroundStyle(.tint)
                    Text("End of Chapter")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else {
                    Text(formattedRemaining)
                        .font(.system(size: 72, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                    Text("remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
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
    }

    // MARK: - Cancel Button

    private var cancelButton: some View {
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

    // MARK: - Helpers

    private var formattedRemaining: String {
        let remaining = Int(player.sleepTimerRemaining)
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
