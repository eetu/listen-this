//
//  AutoTransferSheet.swift
//  Listen This
//
//  Sheet for automatically selecting and initiating audiobook transfer to Watch
//

import SwiftData
import SwiftUI

struct AutoTransferSheet: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selector: TransferMethodSelector?
    @State private var selectedMethod: SelectedMethod?
    @State private var isTransferring = false
    @State private var transferError: Error?
    @State private var showError = false
    @State private var cloudKitManager: CloudKitChunkedTransferManager?

    var body: some View {
        VStack(spacing: 20) {
            if let selectedMethod {
                // Show selected method
                VStack(spacing: 12) {
                    Image(systemName: methodIcon(selectedMethod))
                        .font(.system(size: 48))
                        .foregroundStyle(methodColor(selectedMethod))

                    Text(methodTitle(selectedMethod))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(methodDescription(selectedMethod))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()

                if isTransferring {
                    transferProgressView
                } else {
                    // Show appropriate buttons based on method
                    if case .alreadyUploaded = selectedMethod {
                        Button("OK") {
                            dismiss()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    } else if case .error = selectedMethod {
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task {
                                await performTransfer()
                            }
                        } label: {
                            Text("Start Transfer")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(methodColor(selectedMethod))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)

                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Selecting best method...")
            }
        }
        .navigationTitle("Transfer to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Transfer Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {
                transferError = nil
            }
        } message: {
            if let error = transferError {
                Text(error.localizedDescription)
            }
        }
        .task {
            if selector == nil {
                let newSelector = TransferMethodSelector(modelContext: modelContext)
                selector = newSelector
                selectedMethod = await newSelector.selectMethod(for: audiobook)

                // Initialize CloudKit manager for progress tracking
                cloudKitManager = CloudKitChunkedTransferManager(modelContext: modelContext)
            }
        }
        .interactiveDismissDisabled(isTransferring)
    }

    private func performTransfer() async {
        guard let selectedMethod, let manager = cloudKitManager else { return }

        isTransferring = true
        do {
            // Execute transfer based on selected method
            switch selectedMethod {
            case .cloudKit:
                #if os(iOS)
                    // iPhone: Upload to CloudKit with progress tracking
                    try await manager.uploadAudiobook(audiobook)
                #else
                    // Watch: Download from CloudKit with progress tracking
                    _ = try await manager.downloadAudiobook(audiobook)
                #endif

            case .watchConnectivity:
                #if os(iOS)
                    // Direct transfer via WatchConnectivity
                    // Ensure file is cached first
                    if !audiobook.isFileCached {
                        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                        _ = try await audiobook.downloadAndCache(using: cacheManager)
                    }

                    let watchConnectivityManager = iOSWatchConnectivityManager.shared
                    try await watchConnectivityManager.transferAudiobook(audiobook)
                #else
                    throw TransferError.methodUnavailable
                #endif

            case .iCloudDirect:
                // Direct iCloud download
                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                _ = try await audiobook.downloadAndCache(using: cacheManager)

            case .alreadyUploaded:
                // Nothing to do - already uploaded
                break

            case .error(let reason):
                throw TransferError.noMethodAvailable(reason)
            }

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                transferError = error
                showError = true
                isTransferring = false
            }
        }
    }

    private func methodIcon(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit:
            return "icloud.and.arrow.up"
        case .watchConnectivity:
            return "applewatch"
        case .iCloudDirect:
            return "icloud.and.arrow.down"
        case .alreadyUploaded:
            return "checkmark.icloud"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private func methodColor(_ method: SelectedMethod) -> Color {
        switch method {
        case .cloudKit:
            return .blue
        case .watchConnectivity:
            return .purple
        case .iCloudDirect:
            return .green
        case .alreadyUploaded:
            return .blue
        case .error:
            return .red
        }
    }

    private func methodTitle(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit:
            return "CloudKit Transfer"
        case .watchConnectivity:
            return "Direct Transfer"
        case .iCloudDirect:
            return "iCloud Download"
        case .alreadyUploaded:
            return "Already Uploaded"
        case .error:
            return "Transfer Error"
        }
    }

    private func methodDescription(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit(let reason):
            return reason
        case .watchConnectivity(let reason):
            return reason
        case .iCloudDirect(let reason):
            return reason
        case .alreadyUploaded(let reason):
            return reason
        case .error(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var transferProgressView: some View {
        VStack(spacing: 16) {
            // Check for CloudKit upload progress
            if let manager = cloudKitManager,
                let progress = manager.activeUploads[audiobook.id]
            {
                VStack(spacing: 12) {
                    // Progress bar
                    ProgressView(value: progress.progress) {
                        Text(progress.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        HStack {
                            Text("\(progress.progressPercentage)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(progress.progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .progressViewStyle(.linear)
                }
                .padding(.horizontal)
            } else if let manager = cloudKitManager,
                let progress = manager.activeDownloads[audiobook.id]
            {
                // Download progress (for Watch)
                VStack(spacing: 12) {
                    ProgressView(value: progress.progress) {
                        Text(progress.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        HStack {
                            Text("\(progress.progressPercentage)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(progress.progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .progressViewStyle(.linear)
                }
                .padding(.horizontal)
            } else {
                // Generic progress spinner for non-CloudKit transfers
                ProgressView("Transferring...")
                    .padding()
            }
        }
        .padding()
    }
}
