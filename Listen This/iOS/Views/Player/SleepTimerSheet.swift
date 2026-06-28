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

    @State private var selectedTimer: SleepTimerDefault = .minutes15
    @State private var customMinutes: Int = 15
    @State private var hasInitialized = false

    /// Countdown size that grows with Dynamic Type
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 72

    // Presets to show as quick-select buttons (excluding none and end of chapter)
    private let presets: [SleepTimerDefault] = [.minutes5, .minutes10, .minutes15, .minutes30, .minutes45, .minutes60]

    var body: some View {
        // ScrollView so the action buttons stay reachable within the fixed
        // presentation detent when content grows under large Dynamic Type.
        ScrollView {
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
            }
            .padding(.top)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true

            // Initialize with current timer or user's default
            let current = player.sleepTimerRemaining
            if current > 0 {
                let mins = Int(current / 60)
                customMinutes = mins
                // Try to match to a preset, otherwise keep as custom
                selectedTimer = SleepTimerDefault(rawValue: mins)
            } else if player.sleepAtEndOfChapter {
                selectedTimer = .endOfChapter
            } else {
                // Use user's default setting
                let defaultTimer = SettingsManager.shared.defaultSleepTimer
                selectedTimer = defaultTimer
                if let mins = defaultTimer.minutes {
                    customMinutes = mins
                }
            }
        }
    }

    // MARK: - Timer Selection View

    private var timerSelectionView: some View {
        Group {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)

                Spacer()

                if selectedTimer != .endOfChapter {
                    Text("\(customMinutes) min")
                        .monospacedDigit()
                }
            }
            .padding(.horizontal)

            Slider(
                value: Binding(
                    get: { Double(customMinutes) },
                    set: {
                        customMinutes = Int($0)
                        // Update selectedTimer to match if it's a preset, otherwise keep current
                        selectedTimer = SleepTimerDefault(rawValue: customMinutes)
                    }
                ),
                in: 1...120,
                step: 1
            )
            .disabled(selectedTimer == .endOfChapter)
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        selectedTimer = preset
                        if let mins = preset.minutes {
                            customMinutes = mins
                        }
                    } label: {
                        Text("\(preset.minutes ?? 0) min")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTimer == preset ? Color.accentColor : Color(.systemGray5))
                            )
                            .foregroundStyle(selectedTimer == preset ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            // End of Chapter button as a separate full-width option
            Button {
                selectedTimer = .endOfChapter
            } label: {
                Text("End of Chapter")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTimer == .endOfChapter ? Color.accentColor : Color(.systemGray5))
                    )
                    .foregroundStyle(selectedTimer == .endOfChapter ? .white : .primary)
            }
            .buttonStyle(.plain)
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
                        .foregroundStyle(.primary)
                    Text("End of Chapter")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else {
                    Text(formattedRemaining)
                        .font(.system(size: countdownSize, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
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
        Button {
            if selectedTimer == .endOfChapter {
                player.setSleepTimerEndOfChapter()
            } else {
                player.setSleepTimer(minutes: customMinutes)
            }
            dismiss()
        } label: {
            Text(selectedTimer == .endOfChapter ? "Set End of Chapter" : "Set \(customMinutes) min Timer")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
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
