//
//  CloudKitTransferView.swift
//  Listen This
//
//  Refactored SwiftUI view for CloudKit chunked transfers
//  Optimized for watchOS and iOS with shared logic
//

import SwiftUI
import SwiftData
import Observation

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
    var uploadButtonTitle: String = "Upload"
    var isUploadDisabled: Bool = false

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
    }

    var activeProgress: ChunkTransferProgress? {
        switch mode {
        case .upload:
            return transferManager.activeUploads[audiobook.id.uuidString]
        case .download:
            return transferManager.activeDownloads[audiobook.id.uuidString]
        }
    }
    
    func checkUploadAvailability() async {
        guard mode == .upload else { return }
        
        let availability = await transferManager.uploadAvailability(for: audiobook)
        
        print("[CloudKitTransferView] Upload availability: \(availability)")
        switch availability {
        case .fullyUploaded:
            isUploadDisabled = true
            uploadButtonTitle = "Already Uploaded"
            
        case .partiallyUploaded:
            uploadButtonTitle = "Resume Upload"
            isUploadDisabled = false
            
        case .notUploaded:
            uploadButtonTitle = "Upload"
            isUploadDisabled = false
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
        transferManager.cancelTransfer(audiobookId: audiobook.id.uuidString)
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
                VStack(spacing: 12) {
                    content(viewModel)
                }
                .padding()
                #else
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(viewModel?.state == .complete ? "Done" : "Cancel") {
                    dismiss()
                }
            }
        }
        .alert("Transfer Error", isPresented: errorBinding) {
            Button("OK") { }
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
                
                // Check upload availability for upload mode
                if mode == .upload {
                    Task {
                        await vm.checkUploadAvailability()
                    }
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
        header(viewModel)

        switch viewModel.state {
        case .idle:
            actionCard(viewModel)

        case .preparing:
            ProgressView("Preparing...")
                .font(.caption)

        case .transferring(let progress):
            #if os(watchOS)
            watchProgressView(viewModel, progress)
            #else
            progressCard(viewModel, progress)
            #endif

        case .complete:
            completionCard

        case .error:
            EmptyView()
        }
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
               let image = UIImage(data: data) {
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
        VStack(spacing: 4) {
            Text(viewModel.audiobook.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(1)

            Text(ByteCountFormatter.string(
                fromByteCount: viewModel.audiobook.fileSize,
                countStyle: .file
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action Card

    private func actionCard(_ viewModel: CloudKitTransferViewModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.mode == .upload
                  ? "icloud.and.arrow.up"
                  : "icloud.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(viewModel.isUploadDisabled ? .gray : .blue)

            Text(viewModel.mode == .upload
                 ? "Upload to CloudKit"
                 : "Download from CloudKit")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Button {
                viewModel.start()
            } label: {
                Text(viewModel.uploadButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isUploadDisabled)
        }
    }

    // MARK: - Progress

    private func progressCard(
        _ viewModel: CloudKitTransferViewModel,
        _ progress: ChunkTransferProgress
    ) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.progress)

            Text(progress.statusText)
                .font(.subheadline)

            Text("\(progress.completedChunks) / \(progress.totalChunks) chunks")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Cancel Transfer", role: .destructive) {
                viewModel.cancel()
                dismiss()
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func watchProgressView(
        _ viewModel: CloudKitTransferViewModel,
        _ progress: ChunkTransferProgress
    ) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: progress.progress)

            Text("\(progress.progressPercentage)%")
                .font(.caption2)

            Button("Cancel", role: .destructive) {
                viewModel.cancel()
                dismiss()
            }
            .font(.caption2)
        }
    }

    // MARK: - Completion

    private var completionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("Transfer Complete")
                .font(.headline)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
