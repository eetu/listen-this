//
//  AudiobookshelfSettingsView.swift
//  Listen This
//
//  Settings for Audiobookshelf server integration
//

import OSLog
import SwiftUI

struct AudiobookshelfSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsManager = SettingsManager.shared

    // Local state for editing
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isEnabled: Bool = false
    @State private var playbackMode: AudiobookshelfPlaybackMode = .manualDownload

    // Connection test state
    @State private var isTestingConnection: Bool = false
    @State private var testFailure: String?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        Form {
            // MARK: - Server Configuration
            Section {
                TextField("Server Address", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(isEnabled)
                    .onChange(of: serverURL) {
                        scheduleConnectionTest(after: .milliseconds(800))
                    }

                if showsCleartextWarning {
                    Label {
                        Text(
                            "This address uses http:// and isn't on your local network, so the system will block it. Use https:// or a local address."
                        )
                        .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .disabled(isEnabled)
                    .onChange(of: apiKey) { _, newValue in
                        settingsManager.audiobookshelfAPIKey = newValue
                        scheduleConnectionTest(after: .milliseconds(800))
                    }

                if !isEnabled {
                    connectionTestStatus
                }

            } header: {
                Text("Server")
            } footer: {
                Text(
                    "Generate an API key in your Audiobookshelf web interface (Settings → Users → [Your User] → API Tokens → Create). Enter your server address (e.g., 192.168.1.123:13378 or https://abs.example.com) and the API key. The connection is tested automatically."
                )
            }

            // MARK: - Status
            Section {
                Toggle("Enable Audiobookshelf", isOn: $isEnabled)
                    .disabled(isEnabled ? false : !canEnable)  // Always allow disabling, only validate when enabling
                    .onChange(of: isEnabled) { oldValue, newValue in
                        settingsManager.audiobookshelfEnabled = newValue
                    }

                if isEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                if !canEnable && !isEnabled {
                    Text("Available once the connection test succeeds.")
                }
            }

            // MARK: - Playback Options
            if isEnabled {
                Section {
                    Picker("Playback Mode", selection: $playbackMode) {
                        Text("Stream Always").tag(AudiobookshelfPlaybackMode.streamAlways)
                        Text("Download Manually").tag(AudiobookshelfPlaybackMode.manualDownload)
                        Text("Auto-Download on WiFi").tag(AudiobookshelfPlaybackMode.autoDownload)
                    }
                    .onChange(of: playbackMode) { _, newValue in
                        settingsManager.audiobookshelfPlaybackMode = newValue
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    switch playbackMode {
                    case .streamAlways:
                        Text(
                            "Always stream from server. Books are never cached locally. Best for saving storage space."
                        )
                    case .manualDownload:
                        Text(
                            "Stream by default. You can manually download specific books for offline playback."
                        )
                    case .autoDownload:
                        Text(
                            "Automatically download books on WiFi for offline playback. Streaming is used as fallback if download fails."
                        )
                    }
                }
            }

            // MARK: - Reset
            if isEnabled {
                Section {
                    Button(role: .destructive) {
                        resetConfiguration()
                    } label: {
                        Text("Reset Configuration")
                    }
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            // The first request to a local server triggers the system's Local
            // Network prompt and fails while it is showing. Answering the prompt
            // makes the app active again, so retry a failed test then.
            if phase == .active, testFailure != nil {
                scheduleConnectionTest(after: .milliseconds(300))
            }
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - Connection Test Status

    @ViewBuilder
    private var connectionTestStatus: some View {
        if isTestingConnection {
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing connection…")
                    .foregroundStyle(.secondary)
            }
        } else if let testFailure {
            Label {
                Text(testFailure)
                    .font(.caption)
            } icon: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Button("Test Again") {
                scheduleConnectionTest(after: .zero)
            }
        } else if canEnable {
            Label {
                Text("Connection successful")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Computed Properties

    /// The typed address with a scheme filled in when missing.
    private var normalizedURL: URL? {
        ABSServerAddress.normalizedURL(from: serverURL)
    }

    /// Enabling needs a successful test of the address currently in the field,
    /// not of whatever was tested before the user edited it.
    private var canEnable: Bool {
        guard let normalizedURL else { return false }
        return settingsManager.audiobookshelfLastConnectionSuccess
            && settingsManager.audiobookshelfServerURL == normalizedURL.absoluteString
            && !apiKey.isEmpty
    }

    /// App Transport Security only permits cleartext to local addresses, so warn
    /// about an http:// server on a public host before the user hits a failure.
    private var showsCleartextWarning: Bool {
        guard let normalizedURL else { return false }
        return !ABSServerAddress.isCleartextPermitted(normalizedURL)
    }

    // MARK: - Actions

    private func loadSettings() {
        serverURL = settingsManager.audiobookshelfServerURL
        apiKey = settingsManager.audiobookshelfAPIKey
        isEnabled = settingsManager.audiobookshelfEnabled
        playbackMode = settingsManager.audiobookshelfPlaybackMode

        AppLogger.settings.info(
            "Loaded settings - API key: \(apiKey.isEmpty ? "empty" : "\(apiKey.count) chars")")
    }

    /// Starts a connection test once input settles, replacing any pending one.
    private func scheduleConnectionTest(after delay: Duration) {
        testTask?.cancel()
        guard !isEnabled, let url = normalizedURL, !apiKey.isEmpty else {
            isTestingConnection = false
            testFailure = nil
            return
        }

        testTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await testConnection(url: url)
        }
    }

    private func testConnection(url: URL) async {
        isTestingConnection = true

        do {
            let provider = AudiobookshelfProvider()
            try await provider.authenticateWithAPIKey(serverURL: url, apiKey: apiKey)
            guard !Task.isCancelled else { return }

            settingsManager.audiobookshelfServerURL = url.absoluteString
            settingsManager.audiobookshelfLastConnectionTest = Date()
            settingsManager.audiobookshelfLastConnectionSuccess = true
            testFailure = nil
        } catch {
            // A newer test replaced this one; let it report instead.
            guard !Task.isCancelled else { return }

            settingsManager.audiobookshelfLastConnectionTest = Date()
            settingsManager.audiobookshelfLastConnectionSuccess = false
            testFailure = failureMessage(for: error, url: url)
        }

        isTestingConnection = false
    }

    private func failureMessage(for error: Error, url: URL) -> String {
        if case .cleartextBlocked = AudiobookshelfError.from(error) {
            return AudiobookshelfError.cleartextBlocked.localizedDescription
        }

        let isLocalNetwork = url.host.map(ABSServerAddress.isLocalHost) ?? false
        guard isLocalNetwork, let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return
                "Can't reach the server. Check that Local Network access is allowed (Settings → Listen This → Local Network), that the server is running, and that the address and port are correct."
        case .notConnectedToInternet:
            return "No network connection. Check your WiFi settings."
        default:
            return error.localizedDescription
        }
    }

    private func resetConfiguration() {
        testTask?.cancel()
        isEnabled = false
        serverURL = ""
        apiKey = ""
        testFailure = nil

        settingsManager.audiobookshelfEnabled = false
        settingsManager.audiobookshelfServerURL = ""
        settingsManager.audiobookshelfAPIKey = ""
        settingsManager.audiobookshelfLastConnectionTest = nil
        settingsManager.audiobookshelfLastConnectionSuccess = false
    }
}

#Preview {
    NavigationStack {
        AudiobookshelfSettingsView()
    }
}
