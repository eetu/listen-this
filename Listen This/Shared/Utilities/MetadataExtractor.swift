//
//  MetadataExtractor.swift
//  Listen This
//

import AVFoundation
import Foundation
import OSLog

/// Utility for extracting metadata and artwork from M4B audiobook files
enum MetadataExtractor {

    private static let logger = Logger(
        subsystem: "com.anarkisti.Listen-This", category: "MetadataExtractor")

    // MARK: - Metadata Extraction

    /// Extract complete metadata from an M4B file
    static func extractMetadata(from url: URL) async throws -> ExtractedMetadata {
        logger.info("Extracting metadata from: \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url)

        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Extract metadata items
        let metadata = try await asset.load(.metadata)

        var title: String?
        var author: String?
        var narrator: String?
        var artworkData: Data?

        for item in metadata {
            guard let commonKey = item.commonKey else { continue }

            switch commonKey {
            case .commonKeyTitle:
                if let value = try? await item.load(.value) as? String {
                    title = value
                }

            case .commonKeyArtist:
                if let value = try? await item.load(.value) as? String {
                    author = value
                }

            case .commonKeyCreator:
                if let value = try? await item.load(.value) as? String {
                    narrator = value
                }

            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue) {
                    artworkData = data
                }

            default:
                break
            }
        }

        // Count chapters
        let chapterCount = try await countChapters(in: asset)

        logger.info(
            "Extracted metadata - title: '\(title ?? "nil")', author: '\(author ?? "nil")', narrator: '\(narrator ?? "nil")', duration: \(durationSeconds)s, chapters: \(chapterCount), artwork: \(artworkData != nil ? "\(artworkData!.count) bytes" : "none")"
        )

        return ExtractedMetadata(
            title: title,
            author: author,
            narrator: narrator,
            duration: durationSeconds,
            chapterCount: chapterCount,
            artworkData: artworkData
        )
    }

    /// Extract only artwork data from an M4B file
    static func extractArtwork(from url: URL) async throws -> Data? {
        logger.info("Extracting artwork from: \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)

        for item in metadata {
            guard let commonKey = item.commonKey else { continue }

            if commonKey == .commonKeyArtwork {
                if let artworkData = try? await item.load(.dataValue) {
                    logger.info("Extracted artwork: \(artworkData.count) bytes")
                    return artworkData
                }
            }
        }

        logger.info("No artwork found")
        return nil
    }

    /// Extract chapter information from an M4B file
    static func extractChapters(from url: URL) async throws -> [ExtractedChapter] {
        logger.info("Extracting chapters from: \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url)
        let chapterGroups = try await loadChapterGroups(from: asset)

        var chapters: [ExtractedChapter] = []

        for (index, chapterGroup) in chapterGroups.enumerated() {
            let timeRange = chapterGroup.timeRange
            let startTime = CMTimeGetSeconds(timeRange.start)
            let duration = CMTimeGetSeconds(timeRange.duration)

            // Extract chapter title
            var chapterTitle = "Chapter \(index + 1)"

            for item in chapterGroup.items {
                if let commonKey = item.commonKey,
                    commonKey == .commonKeyTitle,
                    let title = try? await item.load(.stringValue)
                {
                    chapterTitle = title
                    break
                }
            }

            chapters.append(
                ExtractedChapter(
                    index: index,
                    title: chapterTitle,
                    startTime: startTime,
                    duration: duration
                )
            )
        }

        logger.info("Extracted \(chapters.count) chapters")
        return chapters
    }

    // MARK: - Private Helpers

    /// Count the number of chapters in an asset
    private static func countChapters(in asset: AVAsset) async throws -> Int {
        let chapterGroups = try await loadChapterGroups(from: asset)
        return chapterGroups.count
    }

    /// Extracts chapter metadata groups with the best matching language
    private static func loadChapterGroups(from asset: AVAsset) async throws
        -> [AVTimedMetadataGroup]
    {
        let languages = try await asset.load(.availableChapterLocales)

        guard let primaryLanguage = languages.first else {
            return []
        }

        let languageIdentifier = primaryLanguage.language.languageCode?.identifier ?? "en"
        return try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [
            languageIdentifier
        ])
    }
}

// MARK: - Supporting Types

/// Complete metadata extracted from an M4B file
struct ExtractedMetadata {
    let title: String?
    let author: String?
    let narrator: String?
    let duration: Double
    let chapterCount: Int
    let artworkData: Data?
}

/// Chapter information extracted from M4B file
struct ExtractedChapter {
    let index: Int
    let title: String
    let startTime: Double
    let duration: Double
}
