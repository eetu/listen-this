//
//  AudiobookshelfSettingsView.swift
//  Listen This
//
//  Settings for Audiobookshelf server integration
//

import Security
import SwiftUI

struct AudiobookshelfSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settingsManager = SettingsManager.shared

    // Local state for editing
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isEnabled: Bool = false
    @State private var preferOffline: Bool = true
    @State private var autoDownload: Bool = false

    // Connection test state
    @State private var isTestingConnection: Bool = false
    @State private var testResult: TestResult?
    @State private var showTestResult: Bool = false

    enum TestResult {
        case success
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
                    "Generate an API key in your Audiobookshelf web interface (Settings → Users → [Your User] → API Tokens → Create). Enter your server URL (e.g., http://192.168.1.69:13378) and the API key."
                )
            }

            // MARK: - Status
            Section {
                Toggle("Enable Audiobookshelf", isOn: $isEnabled)
                    .disabled(!canEnable)
                    .onChange(of: isEnabled) { oldValue, newValue in
                        if newValue && !oldValue {
                            // Enabling - save API key to keychain
                            saveAPIKey()
                        } else if !newValue && oldValue {
                            // Disabling - remove API key from keychain
                            deleteAPIKey()
                        }
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
                    Toggle("Prefer Offline Playback", isOn: $preferOffline)
                        .onChange(of: preferOffline) { _, newValue in
                            settingsManager.audiobookshelfPreferOffline = newValue
                        }

                    Toggle("Auto-Download on WiFi", isOn: $autoDownload)
                        .onChange(of: autoDownload) { _, newValue in
                            settingsManager.audiobookshelfAutoDownload = newValue
                        }
                } header: {
                    Text("Playback")
                } footer: {
                    if preferOffline {
                        Text(
                            "Books will be downloaded before playback. Streaming is used as fallback if download fails."
                        )
                    } else {
                        Text(
                            "Books will stream from the server. You can manually download books for offline playback."
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
        .alert("Connection Test", isPresented: $showTestResult) {
            Button("OK") {
                showTestResult = false
            }
        } message: {
            switch testResult {
            case .success:
                Text("Connection successful! You can now enable Audiobookshelf integration.")
            case .failure(let message):
                Text("Connection failed: \(message)")
            case .none:
                Text("Unknown result")
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
        isEnabled = settingsManager.audiobookshelfEnabled
        preferOffline = settingsManager.audiobookshelfPreferOffline
        autoDownload = settingsManager.audiobookshelfAutoDownload

        // Load API key from keychain if enabled
        if isEnabled {
            apiKey = loadAPIKeyFromKeychain() ?? ""
        }
    }

    private func testConnection() {
        isTestingConnection = true

        Task {
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
                    testResult = .success
                    showTestResult = true
                    isTestingConnection = false
                }

            } catch {
                settingsManager.audiobookshelfLastConnectionTest = Date()
                settingsManager.audiobookshelfLastConnectionSuccess = false

                // Check if this might be a local network permission issue
                let errorMessage: String
                if serverURL.hasPrefix("http://192.168.") || serverURL.hasPrefix("http://10.")
                    || serverURL.hasPrefix("http://172.") || serverURL.contains("localhost")
                {
                    // Local network - might be permission issue
                    if let urlError = error as? URLError,
                        urlError.code == .timedOut || urlError.code == .cannotConnectToHost
                    {
                        errorMessage =
                            "Connection timed out. If this is your first time connecting, iOS may have requested local network permission. Please try again."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }

                await MainActor.run {
                    testResult = .failure(errorMessage)
                    showTestResult = true
                    isTestingConnection = false
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
        settingsManager.audiobookshelfLastConnectionTest = nil
        settingsManager.audiobookshelfLastConnectionSuccess = false

        deleteAPIKey()
    }

    // MARK: - Keychain Management

    private func saveAPIKey() {
        let service = "com.anarkisti.Listen-This.audiobookshelf"
        let account = "api-key"

        guard let apiKeyData = apiKey.data(using: .utf8) else { return }

        // Delete existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: apiKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadAPIKeyFromKeychain() -> String? {
        let service = "com.anarkisti.Listen-This.audiobookshelf"
        let account = "api-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return apiKey
    }

    private func deleteAPIKey() {
        let service = "com.anarkisti.Listen-This.audiobookshelf"
        let account = "api-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

#Preview {
    NavigationStack {
        AudiobookshelfSettingsView()
    }
}
