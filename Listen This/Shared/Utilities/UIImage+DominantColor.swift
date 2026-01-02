//
//  UIImage+DominantColor.swift
//  Listen This
//

import OSLog
import SwiftUI
import UIKit

extension UIImage {
    /// Extracts the most vibrant color from an image
    /// Takes average of the most saturated pixels
    func dominantColor(quality: ColorExtractionQuality = .medium) -> Color? {
        guard self.cgImage != nil else { return nil }

        // Resize image for performance
        let size = CGSize(width: quality.rawValue, height: quality.rawValue)
        guard let resizedImage = resize(to: size)?.cgImage else { return nil }

        // Get pixel data
        guard let pixelData = resizedImage.dataProvider?.data,
            let data = CFDataGetBytePtr(pixelData)
        else { return nil }

        let width = resizedImage.width
        let height = resizedImage.height
        let bytesPerPixel = 4
        let bytesPerRow = resizedImage.bytesPerRow

        struct ColorData {
            var r: CGFloat
            var g: CGFloat
            var b: CGFloat
            var saturation: CGFloat
            var brightness: CGFloat

            var vibrancyScore: CGFloat {
                // Favor both saturation and brightness for vibrant colors
                saturation * brightness
            }
        }

        var vibrantColors: [ColorData] = []

        // Define crop area to exclude edges (where branding/logos often appear)
        // Exclude outer 20% on each side (increased to avoid more branding)
        let cropMargin = 0.20
        let xStart = Int(CGFloat(width) * cropMargin)
        let xEnd = Int(CGFloat(width) * (1.0 - cropMargin))
        let yStart = Int(CGFloat(height) * cropMargin)
        let yEnd = Int(CGFloat(height) * (1.0 - cropMargin))

        // Collect saturated pixels from center area only
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let pixelIndex = (y * bytesPerRow) + (x * bytesPerPixel)

                // Note: Some images might be BGR instead of RGB
                // Check bitmapInfo to determine byte order
                let isBGR = resizedImage.bitmapInfo.contains(.byteOrder32Little)

                let r = CGFloat(data[pixelIndex + (isBGR ? 2 : 0)]) / 255.0
                let g = CGFloat(data[pixelIndex + 1]) / 255.0
                let b = CGFloat(data[pixelIndex + (isBGR ? 0 : 2)]) / 255.0
                let a = CGFloat(data[pixelIndex + 3]) / 255.0

                // Skip transparent pixels
                guard a > 0.5 else { continue }

                // Calculate HSB manually (more accurate than UIColor.getHue)
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let brightness = maxC
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC

                // Only keep vibrant, saturated colors - require higher brightness
                guard saturation > 0.4 && brightness > 0.4 && brightness < 0.95 else { continue }

                vibrantColors.append(
                    ColorData(r: r, g: g, b: b, saturation: saturation, brightness: brightness))
            }
        }

        guard !vibrantColors.isEmpty else {
            AppLogger.general.debug("No vibrant colors found in artwork - using fallback blue")
            return .blue
        }

        // Sort by vibrancy score (saturation × brightness - favors bright, saturated colors)
        vibrantColors.sort { $0.vibrancyScore > $1.vibrancyScore }

        // Take top 10% most vibrant pixels
        let topCount = max(5, vibrantColors.count / 10)
        let topColors = Array(vibrantColors.prefix(topCount))

        // Average the RGB of most saturated colors
        let avgR = topColors.map(\.r).reduce(0, +) / CGFloat(topColors.count)
        let avgG = topColors.map(\.g).reduce(0, +) / CGFloat(topColors.count)
        let avgB = topColors.map(\.b).reduce(0, +) / CGFloat(topColors.count)

        AppLogger.general.debug(
            "Extracted dominant color: RGB(\(Int(avgR * 255)), \(Int(avgG * 255)), \(Int(avgB * 255))) from \(vibrantColors.count) vibrant pixels"
        )

        return Color(red: Double(avgR), green: Double(avgG), blue: Double(avgB))
    }

    private func resize(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

enum ColorExtractionQuality: Int {
    case low = 20
    case medium = 40
    case high = 80
}
