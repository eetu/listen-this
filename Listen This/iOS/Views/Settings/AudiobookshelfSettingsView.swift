//
//  AudiobookshelfSettingsView.swift
//  Listen This
//
//  Settings for Audiobookshelf server integration
//

import OSLog
import SwiftUI

struct AudiobookshelfSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsManager = SettingsManager.shared

    // Local state for editing. Saved to settings only after a successful test,
    // so a half-typed change never breaks the working configuration.
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var playbackMode: AudiobookshelfPlaybackMode = .manualDownload

    // Connection test state
    @State private var isTestingConnection: Bool = false
    @State private var testFailure: String?
    @State private var testTask: Task<Void, Never>?

    /// Whether the saved server answers right now. Display only: a LAN-only
    /// server is unreachable away from home, which must not switch anything off.
    @State private var savedServerStatus: SavedServerStatus?

    private enum SavedServerStatus: Equatable {
        case checking
        case reachable
        case unreachable(String)
    }

    @State private var showingRemoveConfirmation: Bool = false

    @State private var isAPIKeyVisible: Bool = false
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        Form {
            // MARK: - Server Configuration
            Section {
                TextField("Server Address", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: serverURL) {
                        // Longer than the key's delay so a pause mid-address
                        // (e.g. "192.168.1.1" of "…1.12") is less likely tested.
                        scheduleConnectionTest(after: .milliseconds(1500))
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
                } else if usesLocalCleartext {
                    Label {
                        Text(
                            "Your API key is sent unencrypted on your network. Use https:// if your server supports it."
                        )
                        .font(.caption)
                    } icon: {
                        Image(systemName: "lock.open")
                            .foregroundStyle(.secondary)
                    }
                }

                apiKeyField
                    .onChange(of: apiKey) {
                        scheduleConnectionTest(after: .milliseconds(800))
                    }

                connectionStatus

            } header: {
                Text("Server")
            } footer: {
                // Verbatim: a literal is parsed as Markdown, which would turn the
                // example address into a tappable link.
                Text(
                    verbatim:
                        "Generate an API key in your Audiobookshelf web interface (Settings → Users → [Your User] → API Tokens → Create). Enter your server address (e.g., 192.168.1.123:13378 or https://abs.example.com) and the API key. The connection is tested automatically."
                )
            }

            // MARK: - Playback Options
            if isConnected {
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

            // MARK: - Remove
            if hasSavedServer {
                Section {
                    Button("Remove Server", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove Server?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) {
                removeServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The server address and API key will be removed from all your devices. Books already in your library stay."
            )
        }
        .onAppear {
            loadSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            // The first request to a local server triggers the system's Local
            // Network prompt and fails while it is showing. Answering the prompt
            // makes the app active again, so retry a failed test then.
            guard phase == .active else { return }
            if testFailure != nil {
                scheduleConnectionTest(after: .milliseconds(300))
            } else if isConnected && !hasUnsavedEdits {
                checkSavedServer()
            }
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - API Key Field

    /// A plain text field masked while not being edited. Not a SecureField: iOS
    /// offers to save any secure field's contents to Passwords, and an API key
    /// isn't a login.
    private var apiKeyField: some View {
        HStack {
            if isAPIKeyVisible || isAPIKeyFocused || apiKey.isEmpty {
                TextField("API Key", text: $apiKey)
                    .focused($isAPIKeyFocused)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .fontDesign(.monospaced)
            } else {
                Text(String(repeating: "•", count: min(apiKey.count, 16)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Show the field first; focus can only land once it exists.
                        isAPIKeyVisible = true
                        Task { isAPIKeyFocused = true }
                    }
                    .accessibilityLabel("API key, hidden")
                    .accessibilityHint("Double-tap to edit")
                    .accessibilityAddTraits(.isButton)
            }

            if !apiKey.isEmpty {
                Button {
                    isAPIKeyVisible.toggle()
                } label: {
                    Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isAPIKeyVisible ? "Hide API key" : "Show API key")
            }
        }
        .onChange(of: isAPIKeyFocused) { _, focused in
            // Mask again once editing ends.
            if !focused { isAPIKeyVisible = false }
        }
    }

    // MARK: - Connection Status

    @ViewBuilder
    private var connectionStatus: some View {
        if isTestingConnection {
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing connection…")
                    .foregroundStyle(.secondary)
            }
        } else if let testFailure {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(testFailure)
                    if isConnected {
                        Text("Your previous server settings are still in use.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            } icon: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Button("Test Again") {
                scheduleConnectionTest(after: .zero)
            }
        } else if isConnected && !hasUnsavedEdits {
            switch savedServerStatus {
            case .checking, nil:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking connection…")
                        .foregroundStyle(.secondary)
                }
            case .reachable:
                Label {
                    Text("Connected")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .unreachable(let message):
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server not reachable right now")
                        Text(message)
                            .foregroundStyle(.secondary)
                        Text(
                            "Audiobookshelf stays set up and works again once the server is reachable, for example back on your home network."
                        )
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Button("Check Again") {
                    checkSavedServer()
                }
            }
        }
    }

    // MARK: - Computed Properties

    /// Audiobookshelf features are on once a configuration has tested successfully.
    private var isConnected: Bool {
        settingsManager.audiobookshelfEnabled
    }

    private var hasSavedServer: Bool {
        !settingsManager.audiobookshelfServerURL.isEmpty || isConnected
    }

    /// The typed address with a scheme filled in when missing.
    private var normalizedURL: URL? {
        ABSServerAddress.normalizedURL(from: serverURL)
    }

    /// Whether the fields differ from the saved, working configuration.
    private var hasUnsavedEdits: Bool {
        normalizedURL?.absoluteString != settingsManager.audiobookshelfServerURL
            || apiKey != settingsManager.audiobookshelfAPIKey
    }

    /// App Transport Security only permits cleartext to local addresses, so warn
    /// about an http:// server on a public host before the user hits a failure.
    private var showsCleartextWarning: Bool {
        guard let normalizedURL else { return false }
        return !ABSServerAddress.isCleartextPermitted(normalizedURL)
    }

    /// A permitted http:// address still carries the API key in the clear.
    private var usesLocalCleartext: Bool {
        normalizedURL?.scheme?.lowercased() == "http" && !showsCleartextWarning
    }

    // MARK: - Actions

    private func loadSettings() {
        serverURL = settingsManager.audiobookshelfServerURL
        apiKey = settingsManager.audiobookshelfAPIKey
        playbackMode = settingsManager.audiobookshelfPlaybackMode

        AppLogger.settings.info(
            "Loaded settings - API key: \(apiKey.isEmpty ? "empty" : "\(apiKey.count) chars")")
    }

    /// Starts a connection test once input settles, replacing any pending one.
    /// Only untested input needs it: edits, or a saved configuration that isn't
    /// on yet (e.g. switched off with the old Enable toggle).
    private func scheduleConnectionTest(after delay: Duration) {
        testTask?.cancel()
        guard let url = normalizedURL, !apiKey.isEmpty, hasUnsavedEdits || !isConnected
        else {
            isTestingConnection = false
            testFailure = nil
            // Fields match the saved setup (opening the screen, or an edit
            // undone): check that one is still reachable instead.
            if isConnected && !hasUnsavedEdits {
                checkSavedServer()
            }
            return
        }

        testTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await testConnection(url: url, apiKey: apiKey)
        }
    }

    /// Re-checks the saved configuration. Only updates what this screen shows;
    /// never disables the integration or writes (CloudKit-synced) settings.
    private func checkSavedServer() {
        guard let url = URL(string: settingsManager.audiobookshelfServerURL) else { return }
        let key = settingsManager.audiobookshelfAPIKey

        testTask?.cancel()
        savedServerStatus = .checking
        testTask = Task {
            do {
                let provider = AudiobookshelfProvider()
                try await provider.verifyServer(at: url)
                guard !Task.isCancelled else { return }
                try await provider.authenticateWithAPIKey(serverURL: url, apiKey: key)
                guard !Task.isCancelled else { return }
                savedServerStatus = .reachable
            } catch {
                guard !Task.isCancelled else { return }
                savedServerStatus = .unreachable(failureMessage(for: error, url: url))
            }
        }
    }

    private func testConnection(url: URL, apiKey: String) async {
        isTestingConnection = true

        do {
            let provider = AudiobookshelfProvider()
            // Only send the key once an Audiobookshelf server has answered.
            try await provider.verifyServer(at: url)
            guard !Task.isCancelled else { return }
            try await provider.authenticateWithAPIKey(serverURL: url, apiKey: apiKey)
            guard !Task.isCancelled else { return }

            // Save the address and key together, and only now that they work.
            settingsManager.audiobookshelfServerURL = url.absoluteString
            settingsManager.audiobookshelfAPIKey = apiKey
            settingsManager.audiobookshelfLastConnectionTest = Date()
            settingsManager.audiobookshelfLastConnectionSuccess = true
            settingsManager.audiobookshelfEnabled = true
            testFailure = nil
            savedServerStatus = .reachable
        } catch {
            // A newer test replaced this one; let it report instead.
            guard !Task.isCancelled else { return }

            // Keep any previously working configuration active.
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

    private func removeServer() {
        testTask?.cancel()
        isTestingConnection = false
        testFailure = nil
        savedServerStatus = nil

        settingsManager.audiobookshelfEnabled = false
        settingsManager.audiobookshelfServerURL = ""
        settingsManager.audiobookshelfAPIKey = ""
        settingsManager.audiobookshelfLastConnectionTest = nil
        settingsManager.audiobookshelfLastConnectionSuccess = false

        serverURL = ""
        apiKey = ""
    }
}

#Preview {
    NavigationStack {
        AudiobookshelfSettingsView()
    }
}
