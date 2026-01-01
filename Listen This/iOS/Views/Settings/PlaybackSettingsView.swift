//
//  PlaybackSettingsView.swift
//  Listen This
//
//  Settings view for playback preferences
//

import SwiftUI

struct PlaybackSettingsView: View {
    @State private var settings = PlaybackSettings.shared

    var body: some View {
        Form {
            // MARK: - Playback Speed
            Section {
                Toggle("Remember Speed Per Book", isOn: Binding(
                    get: { settings.rememberSpeedPerBook },
                    set: { settings.rememberSpeedPerBook = $0 }
                ))
            } header: {
                Text("Playback Speed")
            } footer: {
                Text("When enabled, each audiobook will remember its own playback speed. Otherwise, all books play at 1.0x speed.")
            }

            // MARK: - Skip Intervals
            Section {
                Picker("Skip Backward", selection: Binding(
                    get: { settings.skipBackwardInterval },
                    set: { settings.skipBackwardInterval = $0 }
                )) {
                    ForEach(PlaybackSettings.skipIntervalPresets, id: \.self) { interval in
                        Text(PlaybackSettings.formatInterval(interval))
                            .tag(interval)
                    }
                }

                Picker("Skip Forward", selection: Binding(
                    get: { settings.skipForwardInterval },
                    set: { settings.skipForwardInterval = $0 }
                )) {
                    ForEach(PlaybackSettings.skipIntervalPresets, id: \.self) { interval in
                        Text(PlaybackSettings.formatInterval(interval))
                            .tag(interval)
                    }
                }
            } header: {
                Text("Skip Intervals")
            } footer: {
                Text("Configure how far to skip when using the skip buttons or remote controls.")
            }

            // MARK: - Sleep Timer
            Section {
                Picker("Default Sleep Timer", selection: Binding(
                    get: { settings.defaultSleepTimerMinutes },
                    set: { settings.defaultSleepTimerMinutes = $0 }
                )) {
                    ForEach(PlaybackSettings.sleepTimerPresets, id: \.self) { minutes in
                        Text(PlaybackSettings.formatSleepTimer(minutes))
                            .tag(minutes)
                    }
                }
            } header: {
                Text("Sleep Timer")
            } footer: {
                Text("Set a default sleep timer that will be suggested when starting playback. Select \"None\" to disable.")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PlaybackSettingsView()
    }
}
