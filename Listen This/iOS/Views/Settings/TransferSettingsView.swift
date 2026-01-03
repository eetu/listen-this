//
//  TransferSettingsView.swift
//  Listen This
//
//  Settings view for configuring iPhone → Apple Watch transfer methods
//

import Foundation
import SwiftData
import SwiftUI

struct TransferSettingsView: View {
    @State private var selector: TransferMethodSelector
    @State private var selectedMethod: TransferMethod
    @State private var showAdvancedOptions = false

    init(modelContext: ModelContext) {
        let selector = TransferMethodSelector(modelContext: modelContext)
        _selector = State(initialValue: selector)
        _selectedMethod = State(initialValue: selector.preferredMethod)
    }

    var body: some View {
        Form {
            Section {
                Picker("Transfer Method", selection: $selectedMethod) {
                    ForEach(TransferMethod.allCases.filter { $0 != .iCloudDirect }) { method in
                        Text(method.displayName)
                            .tag(method)
                    }
                }
                .pickerStyle(.menu)

                // Description of selected method
                Text(selectedMethod.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

            } header: {
                Text("iPhone → Apple Watch Transfer")
            } footer: {
                Text(
                    "Choose how audiobooks are transferred from your iPhone to Apple Watch. Automatic mode selects the best method based on file size and network conditions."
                )
            }

            // Automatic mode explanation
            if selectedMethod == .automatic {
                Section {
                    Text(
                        "Automatic mode intelligently selects the transfer method based on file size and network conditions:"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Large files (>50MB)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Uses CloudKit when WiFi is available")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Small files (<50MB)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Uses WatchConnectivity when Watch is nearby")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("How Automatic Works")
                }
            }

            Section {
                Button {
                    showAdvancedOptions.toggle()
                } label: {
                    HStack {
                        Text(showAdvancedOptions ? "Hide Details" : "Show Details")
                        Spacer()
                        Image(systemName: showAdvancedOptions ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }

            if showAdvancedOptions {
                Section("Method Details") {
                    VStack(alignment: .leading, spacing: 12) {
                        // CloudKit Method
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CloudKit Chunks")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("iPhone uploads to cloud, Watch downloads")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Best for: Large files (>50MB)")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        } icon: {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                        }

                        Divider()

                        // WatchConnectivity Method
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("WatchConnectivity")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("Direct Bluetooth transfer to Watch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Best for: Small files (<50MB)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        } icon: {
                            Image(systemName: "applewatch")
                                .foregroundStyle(.orange)
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ComparisonRow(
                            fileSize: "100 MB file",
                            cloudKit: "2-5 min",
                            watchConnectivity: "8-15 min"
                        )

                        Divider()

                        ComparisonRow(
                            fileSize: "500 MB file",
                            cloudKit: "5-15 min",
                            watchConnectivity: "25-45 min"
                        )
                    }
                    .font(.caption)
                } header: {
                    Text("Transfer Time to Watch")
                }

                Section("Requirements") {
                    VStack(alignment: .leading, spacing: 8) {
                        RequirementRow(
                            method: "CloudKit",
                            requirements: [
                                ("WiFi connection", true),
                                ("iCloud storage", true),
                                ("Device proximity", false),
                            ]
                        )

                        Divider()

                        RequirementRow(
                            method: "WatchConnectivity",
                            requirements: [
                                ("WiFi connection", false),
                                ("iCloud storage", false),
                                ("Device proximity", true),
                            ]
                        )
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Watch Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedMethod) { oldValue, newValue in
            selector.preferredMethod = newValue
        }
    }
}

// MARK: - Supporting Views

struct ComparisonRow: View {
    let fileSize: String
    let cloudKit: String
    let watchConnectivity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fileSize)
                .fontWeight(.semibold)

            HStack {
                Text("CloudKit:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cloudKit)
                    .foregroundStyle(.blue)
                    .fontWeight(.medium)
            }

            HStack {
                Text("Bluetooth:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(watchConnectivity)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RequirementRow: View {
    let method: String
    let requirements: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(method)
                .fontWeight(.semibold)

            ForEach(requirements, id: \.0) { requirement in
                HStack {
                    Image(systemName: requirement.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(requirement.1 ? .green : .red)
                    Text(requirement.0)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        TransferSettingsView(
            modelContext: ModelContext(
                try! ModelContainer(
                    for: Audiobook.self
                )
            )
        )
    }
}
