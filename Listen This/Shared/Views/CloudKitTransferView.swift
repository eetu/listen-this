//
//  CloudKitTransferView.swift
//  Listen This
//
//  Refactored SwiftUI view for CloudKit chunked transfers
//  Optimized for watchOS and iOS with shared logic
//

import OSLog
import Observation
import SwiftData
import SwiftUI

// MARK: - View Model

@Observable
final class CloudKitTransferViewModel {

    enum TransferMode {
        case upload
        case download
    }

    enum TransferState: Equatable {
        case idle
        case preparing
        case transferring(ChunkTransferProgress)
        case complete
        case error(String)
    }

    let audiobook: Audiobook
    let mode: TransferMode

    private let modelContext: ModelContext
    private let transferManager: CloudKitChunkedTransferManager
    private let cacheManager: AudiobookCacheManager

    var state: TransferState = .idle
    var actionButtonTitle: String
    var isActionDisabled: Bool = false

    init(
        audiobook: Audiobook,
        mode: TransferMode,
        modelContext: ModelContext
    ) {
        self.audiobook = audiobook
        self.mode = mode
        self.modelContext = modelContext
        self.transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
        self.cacheManager = AudiobookCacheManager(modelContext: modelContext)

        // Initialize button title based on mode
        self.actionButtonTitle = mode == .upload ? "Upload" : "Download"
    }

    var activeProgress: ChunkTransferProgress? {
        switch mode {
        case .upload:
            return transferManager.activeUploads[audiobook.id]
        case .download:
            return transferManager.activeDownloads[audiobook.id]
        }
    }

    /// Check CloudKit chunk availability for both upload (iPhone) and download (Watch)
    func checkChunkAvailability() async {
        let availability = await transferManager.checkCloudKitChunks(for: audiobook)

        AppLogger.cloudKit.debug(
            "Chunk availability for \(self.mode == .upload ? "upload" : "download"): \(String(describing: availability))"
        )

        switch mode {
        case .upload:
            // iPhone: Check if already uploaded
            switch availability {
            case .fullyUploaded:
                isActionDisabled = true
                actionButtonTitle = "Already Uploaded"

            case .partiallyUploaded:
                actionButtonTitle = "Resume Upload"
                isActionDisabled = false

            case .notUploaded:
                actionButtonTitle = "Upload"
                isActionDisabled = false
            }

        case .download:
            // Watch: Check if chunks exist before allowing download
            switch availability {
            case .fullyUploaded:
                actionButtonTitle = "Download"
                isActionDisabled = false

            case .partiallyUploaded:
                // Partial upload - not safe to download
                actionButtonTitle = "Upload Incomplete"
                isActionDisabled = true
                state = .error(
                    "Audiobook upload is incomplete. Please complete upload from iPhone first.")

            case .notUploaded:
                // No chunks available
                actionButtonTitle = "Not Available"
                isActionDisabled = true
                state = .error(
                    "Audiobook not uploaded to CloudKit. Please upload from iPhone first.")
            }
        }
    }

    func start() {
        Task {
            switch mode {
            case .upload:
                await upload()
            case .download:
                await download()
            }
        }
    }

    func cancel() {
        transferManager.cancelTransfer(audiobookId: audiobook.id)
    }

    // MARK: - Upload

    private func upload() async {
        state = .preparing

        do {
            if !audiobook.isFileCached {
                guard let iCloudURL = audiobook.iCloudFileURL else {
                    throw ChunkTransferError.fileNotAvailable
                }
                _ = try cacheManager.cacheAudiobook(audiobook, from: iCloudURL)
            }

            try await transferManager.uploadAudiobook(audiobook)
            state = .complete

        } catch {
            state = .error("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Download

    private func download() async {
        state = .preparing

        do {
            let outputURL = try await transferManager.downloadAudiobook(audiobook)

            let cacheEntry = CacheEntry(
                filePath: outputURL.path,
                fileSize: audiobook.fileSize
            )
            modelContext.insert(cacheEntry)
            audiobook.cacheEntry = cacheEntry
            try modelContext.save()

            state = .complete

        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - View

struct CloudKitTransferView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let audiobook: Audiobook

    @State private var viewModel: CloudKitTransferViewModel?

    #if os(iOS)
        private let mode: CloudKitTransferViewModel.TransferMode = .upload
    #else
        private let mode: CloudKitTransferViewModel.TransferMode = .download
    #endif

    var body: some View {
        Group {
            if let viewModel {
                #if os(watchOS)
                    // Compact single-screen layout for Watch
                    VStack(spacing: 8) {
                        content(viewModel)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                #else
                    // Scrollable layout for iOS with more spacing
                    ScrollView {
                        VStack(spacing: 24) {
                            content(viewModel)
                        }
                        .padding()
                    }
                #endif
            } else {
                ProgressView()
            }
        }
        .navigationTitle(mode == .upload ? "Upload" : "Download")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(viewModel?.state == .complete ? "Done" : "Cancel") {
                    dismiss()
                }
            }
        }
        .alert("Transfer Error", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if viewModel == nil {
                let vm = CloudKitTransferViewModel(
                    audiobook: audiobook,
                    mode: mode,
                    modelContext: modelContext
                )
                viewModel = vm

                // Check chunk availability for both upload and download modes
                Task {
                    await vm.checkChunkAvailability()
                }
            }
        }
        .onChange(of: viewModel?.activeProgress) { _, newValue in
            if let progress = newValue {
                viewModel?.state = .transferring(progress)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ viewModel: CloudKitTransferViewModel) -> some View {
        #if os(iOS)
            // iOS: Structured layout with sections
            iOSContent(viewModel)
        #else
            // Watch: Compact vertical stack
            header(viewModel)

            switch viewModel.state {
            case .idle:
                actionCard(viewModel)

            case .preparing:
                ProgressView("Preparing...")
                    .font(.caption)

            case .transferring(let progress):
                watchProgressView(viewModel, progress)

            case .complete:
                completionCard

            case .error:
                EmptyView()
            }
        #endif
    }

    // MARK: - iOS Content

    @ViewBuilder
    private func iOSContent(_ viewModel: CloudKitTransferViewModel) -> some View {
        header(viewModel)

        // Explanation section
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "wifi")
                        .foregroundStyle(.blue)
                    Text(
                        viewModel.mode == .upload ? "Fast WiFi Transfer" : "Download from iCloud"
                    )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                }

                Text(
                    viewModel.mode == .upload
                        ? "Transfers your audiobook to Apple Watch over WiFi. Much faster than Bluetooth."
                        : "Download audiobook that was uploaded from your iPhone."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if viewModel.mode == .upload {
                    Label {
                        Text("Uses temporary iCloud storage (\(ByteCountFormatter.string(fromByteCount: viewModel.audiobook.fileSize, countStyle: .file)))")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "icloud")
                            .foregroundStyle(.blue)
                    }
                    .foregroundStyle(.secondary)
                }
            }.padding()
        }
        #if os(iOS)
            .background(Color(.secondarySystemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))

        // Main action/status section
        switch viewModel.state {
        case .idle:
            actionSection(viewModel)

        case .preparing:
            ProgressView("Preparing...")
                .padding()

        case .transferring(let progress):
            progressCard(viewModel, progress)

        case .complete:
            completionCard

        case .error:
            EmptyView()
        }

        // Info section
        if viewModel.state == .idle {
            infoSection(viewModel)
        }
    }

    @ViewBuilder
    private func actionSection(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(spacing: 16) {
            Button {
                viewModel.start()
            } label: {
                Label(
                    viewModel.actionButtonTitle,
                    systemImage: viewModel.mode == .upload
                        ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isActionDisabled)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func infoSection(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            if viewModel.mode == .upload {
                Label {
                    Text("Upload via WiFi to your iCloud")
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.blue)
                }
                Label {
                    Text("Open Watch app and download")
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.blue)
                }
                Label {
                    Text("Temporary files auto-delete after download")
                } icon: {
                    Image(systemName: "3.circle.fill")
                        .foregroundStyle(.blue)
                }

                Divider()
                    .padding(.vertical, 4)

                Label {
                    Text("Not enough iCloud space? Use Direct Transfer instead")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.orange)
                }
            } else {
                Label {
                    Text("Download via WiFi from your iCloud")
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.blue)
                }
                Label {
                    Text("Temporary files auto-delete after download")
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .font(.caption)
        .padding()
        #if os(iOS)
            .background(Color(.secondarySystemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ viewModel: CloudKitTransferViewModel) -> some View {
        #if os(iOS)
            iOSHeader(viewModel)
        #else
            watchHeader(viewModel)
        #endif
    }

    private func iOSHeader(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(spacing: 12) {
            if let data = viewModel.audiobook.artworkData,
                let image = UIImage(data: data)
            {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text(viewModel.audiobook.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(viewModel.audiobook.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func watchHeader(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(spacing: 2) {
            Text(viewModel.audiobook.title)
                .font(.footnote)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(
                ByteCountFormatter.string(
                    fromByteCount: viewModel.audiobook.fileSize,
                    countStyle: .file
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action Card (Watch only)

    private func actionCard(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(spacing: 8) {
            Image(
                systemName: viewModel.mode == .upload
                    ? "icloud.and.arrow.up"
                    : "icloud.and.arrow.down"
            )
            .font(.system(size: 28))
            .foregroundStyle(viewModel.isActionDisabled ? .gray : .blue)

            Button {
                viewModel.start()
            } label: {
                Text(viewModel.actionButtonTitle)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isActionDisabled)
        }
    }

    // MARK: - Progress

    private func progressCard(
        _ viewModel: CloudKitTransferViewModel,
        _ progress: ChunkTransferProgress
    ) -> some View {
        VStack(spacing: 16) {
            // Progress percentage and bar
            VStack(spacing: 8) {
                Text("\(progress.progressPercentage)%")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.blue)

                ProgressView(value: progress.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            // Transfer details (simplified)
            VStack(spacing: 8) {
                HStack {
                    Text("Chunks")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(progress.completedChunks) / \(progress.totalChunks)")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.subheadline)

                HStack {
                    Text("Transferred")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.progressText)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
            }

            Button("Cancel Transfer", role: .destructive) {
                viewModel.cancel()
                dismiss()
            }
            .controlSize(.large)
        }
        .padding(20)
        #if os(iOS)
            .background(Color(.systemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        #endif
    }

    private func watchProgressView(
        _ viewModel: CloudKitTransferViewModel,
        _ progress: ChunkTransferProgress
    ) -> some View {
        VStack(spacing: 8) {
            Text("\(progress.progressPercentage)%")
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()

            ProgressView(value: progress.progress)
                .progressViewStyle(.linear)

            Text("\(progress.completedChunks)/\(progress.totalChunks) chunks")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Cancel", role: .destructive) {
                viewModel.cancel()
                dismiss()
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    // MARK: - Completion

    private var completionCard: some View {
        #if os(watchOS)
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)

                Text("Complete")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
        #else
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: true)

                VStack(spacing: 8) {
                    Text("Transfer Complete")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(
                        "Audiobook is now available on your \(mode == .upload ? "Apple Watch" : "device")"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #endif
    }

    // MARK: - Error Handling

    private var errorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .error = viewModel?.state { return true }
                return false
            },
            set: { _ in }
        )
    }

    private var errorMessage: String {
        if case .error(let message) = viewModel?.state {
            return message
        }
        return ""
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CloudKitTransferView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 500_000_000
            )
        )
    }
    .modelContainer(for: [Audiobook.self])
}
