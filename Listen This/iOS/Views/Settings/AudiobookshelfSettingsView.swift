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
    @State private var settingsManager = SettingsManager.shared

    // Local state for editing
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isEnabled: Bool = false
    @State private var playbackMode: AudiobookshelfPlaybackMode = .manualDownload

    // Connection test state
    @State private var isTestingConnection: Bool = false
    @State private var testResult: TestResult?
    @State private var showTestResult: Bool = false
    @State private var hasAttemptedLocalNetworkConnection: Bool = false

    enum TestResult {
        case failure(String)
    }

    var body: some View {
        Form {
            // MARK: - Server Configuration
            Section {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .disabled(isEnabled)
                    .onChange(of: serverURL) { _, newValue in
                        // Auto-fix http to https if needed (but allow http for local testing)
                        if newValue.hasPrefix("http://") || newValue.hasPrefix("https://") {
                            // URL looks good
                        } else if !newValue.isEmpty && !newValue.hasPrefix("http") {
                            serverURL = "http://" + newValue
                        }
                    }

                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .disabled(isEnabled)
                    .onChange(of: apiKey) { _, newValue in
                        settingsManager.audiobookshelfAPIKey = newValue
                    }

                if !isEnabled {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isTestingConnection ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(serverURL.isEmpty || apiKey.isEmpty || isTestingConnection)
                }

            } header: {
                Text("Server")
            } footer: {
                Text(
                    "Generate an API key in your Audiobookshelf web interface (Settings → Users → [Your User] → API Tokens → Create). Enter your server URL (e.g., http://192.168.1.123:13378) and the API key."
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
                } else if !canEnable && settingsManager.audiobookshelfLastConnectionTest != nil {
                    // Show last test result only when not enabled
                    HStack {
                        Image(
                            systemName: settingsManager.audiobookshelfLastConnectionSuccess
                                ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(
                            settingsManager.audiobookshelfLastConnectionSuccess ? .green : .red)

                        Text(
                            settingsManager.audiobookshelfLastConnectionSuccess
                                ? "Test successful" : "Test failed"
                        )
                        .foregroundStyle(.secondary)

                        Spacer()

                        if let lastTest = settingsManager.audiobookshelfLastConnectionTest {
                            Text(lastTest, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                if !canEnable && !isEnabled {
                    Text("Test connection successfully before enabling.")
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
        .alert("Connection Failed", isPresented: $showTestResult) {
            Button("OK") {
                showTestResult = false
            }
        } message: {
            if case .failure(let message) = testResult {
                Text(message)
            }
        }
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Computed Properties

    private var canEnable: Bool {
        settingsManager.audiobookshelfLastConnectionSuccess && !serverURL.isEmpty
            && !apiKey.isEmpty
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

    private func testConnection() {
        isTestingConnection = true

        let isLocalNetwork = serverURL.hasPrefix("http://192.168.")
            || serverURL.hasPrefix("http://10.")
            || serverURL.hasPrefix("http://172.")
            || serverURL.contains("localhost")

        Task {
            // For local network URLs on first attempt, we retry after failure
            // because iOS blocks the request while showing the permission dialog
            let maxAttempts = (isLocalNetwork && !hasAttemptedLocalNetworkConnection) ? 2 : 1

            for attempt in 1...maxAttempts {
                let startTime = Date()

                do {
                    guard let url = URL(string: serverURL) else {
                        throw AudiobookshelfError.invalidServerURL
                    }

                    let provider = AudiobookshelfProvider()
                    try await provider.authenticateWithAPIKey(serverURL: url, apiKey: apiKey)

                    // Save settings
                    settingsManager.audiobookshelfServerURL = serverURL
                    settingsManager.audiobookshelfLastConnectionTest = Date()
                    settingsManager.audiobookshelfLastConnectionSuccess = true

                    await MainActor.run {
                        hasAttemptedLocalNetworkConnection = true
                        // Success is shown via the UI status indicator - no alert needed
                        isTestingConnection = false
                    }
                    return // Success, exit the function

                } catch {
                    let elapsed = Date().timeIntervalSince(startTime)

                    // If this is the first attempt on local network and it failed quickly with a network error,
                    // the permission dialog was likely shown. Retry automatically.
                    // A quick failure (< 2 seconds) suggests the request was blocked by the permission dialog.
                    if attempt < maxAttempts,
                       let urlError = error as? URLError,
                       [.timedOut, .cannotConnectToHost, .networkConnectionLost].contains(urlError.code),
                       elapsed < 2.0
                    {
                        // Wait a moment for the system to settle after permission grant, then retry
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }

                    settingsManager.audiobookshelfLastConnectionTest = Date()
                    settingsManager.audiobookshelfLastConnectionSuccess = false

                    let errorMessage: String
                    if isLocalNetwork {
                        if let urlError = error as? URLError {
                            switch urlError.code {
                            case .timedOut, .cannotConnectToHost, .networkConnectionLost:
                                errorMessage =
                                    "Cannot connect to server. Please check:\n\n1. Local Network permission is enabled in Settings → Listen This → Local Network\n\n2. The server is running and reachable\n\n3. The URL and port are correct"
                            case .notConnectedToInternet:
                                errorMessage = "No internet connection. Please check your WiFi settings."
                            default:
                                errorMessage = error.localizedDescription
                            }
                        } else {
                            errorMessage = error.localizedDescription
                        }
                    } else {
                        errorMessage = error.localizedDescription
                    }

                    await MainActor.run {
                        hasAttemptedLocalNetworkConnection = true
                        testResult = .failure(errorMessage)
                        showTestResult = true
                        isTestingConnection = false
                    }
                    return
                }
            }
        }
    }

    private func resetConfiguration() {
        isEnabled = false
        serverURL = ""
        apiKey = ""

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
