#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates test images for DominantColor testing
/// Run with: swift GenerateTestImages.swift

let outputDir = "TestImages"

// Create output directory if needed
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// MARK: - Image Generation Helpers

func createContext(width: Int, height: Int, colorSpace: CGColorSpace, bitmapInfo: UInt32)
    -> CGContext?
{
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )
}

func saveImage(context: CGContext, filename: String) {
    guard let image = context.makeImage() else {
        print("Failed to create image from context")
        return
    }

    let url = URL(fileURLWithPath: "\(outputDir)/\(filename)")
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        print("Failed to create destination for \(filename)")
        return
    }

    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) {
        print("Created: \(filename)")
    } else {
        print("Failed to save: \(filename)")
    }
}

// MARK: - Test Image 1: Pure RGB Red (should extract red)

func createPureRGBRed() {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // RGB byte order
    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Fill with red (RGB: 220, 50, 50)
    context.setFillColor(red: 220 / 255.0, green: 50 / 255.0, blue: 50 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    saveImage(context: context, filename: "test_rgb_red.png")
}

// MARK: - Test Image 2: Pure BGR Blue (should extract blue)

func createPureBGRBlue() {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // BGR byte order (little endian)
    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    else { return }

    // Fill with blue (RGB: 50, 100, 230)
    context.setFillColor(red: 50 / 255.0, green: 100 / 255.0, blue: 230 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    saveImage(context: context, filename: "test_bgr_blue.png")
}

// MARK: - Test Image 3: Green center with yellow Audible-style banner

func createGreenWithYellowBanner() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Fill center with vibrant green (RGB: 40, 200, 80)
    context.setFillColor(red: 40 / 255.0, green: 200 / 255.0, blue: 80 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Add diagonal yellow banner at bottom right (like Audible)
    context.saveGState()

    // Create diagonal stripe from bottom-right
    context.setFillColor(red: 255 / 255.0, green: 200 / 255.0, blue: 0 / 255.0, alpha: 1.0)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: width, y: height))
    path.addLine(to: CGPoint(x: Int(Double(width) * 0.6), y: height))
    path.addLine(to: CGPoint(x: width, y: Int(Double(height) * 0.6)))
    path.closeSubpath()

    context.addPath(path)
    context.fillPath()

    context.restoreGState()

    saveImage(context: context, filename: "test_green_yellow_banner.png")
}

// MARK: - Test Image 4: Purple center with white badge at top

func createPurpleWithWhiteBadge() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Fill with vibrant purple (RGB: 180, 60, 200)
    context.setFillColor(red: 180 / 255.0, green: 60 / 255.0, blue: 200 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Add white circular badge at top-left (like "New" or "Sale" badges)
    context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    let badgeRect = CGRect(x: 10, y: 10, width: 60, height: 60)
    context.fillEllipse(in: badgeRect)

    saveImage(context: context, filename: "test_purple_white_badge.png")
}

// MARK: - Test Image 5: Orange with multiple edge badges

func createOrangeWithEdgeBadges() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Fill with vibrant orange (RGB: 240, 120, 40)
    context.setFillColor(red: 240 / 255.0, green: 120 / 255.0, blue: 40 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Add black badge at top-left corner
    context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))

    // Add blue badge at top-right corner
    context.setFillColor(red: 0.3, green: 0.4, blue: 0.9, alpha: 1.0)
    context.fill(CGRect(x: width - 50, y: 0, width: 50, height: 50))

    // Add green badge at bottom-left corner
    context.setFillColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)
    context.fill(CGRect(x: 0, y: height - 50, width: 50, height: 50))

    // Add red badge at bottom-right corner
    context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)
    context.fill(CGRect(x: width - 50, y: height - 50, width: 50, height: 50))

    saveImage(context: context, filename: "test_orange_edge_badges.png")
}

// MARK: - Test Image 6: Gradient with banner (complex case)

func createGradientWithBanner() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Create gradient from teal to blue
    let colors =
        [
            CGColor(red: 0.2, green: 0.8, blue: 0.8, alpha: 1.0),
            CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0),
        ] as CFArray

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: height),
            options: []
        )
    }

    // Add yellow diagonal banner
    context.setFillColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: width, y: height))
    path.addLine(to: CGPoint(x: Int(Double(width) * 0.65), y: height))
    path.addLine(to: CGPoint(x: width, y: Int(Double(height) * 0.65)))
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()

    saveImage(context: context, filename: "test_gradient_yellow_banner.png")
}

// MARK: - Test Image 7: Low saturation (should use fallback)

func createLowSaturationGray() {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Fill with low saturation gray (RGB: 140, 145, 150)
    context.setFillColor(red: 140 / 255.0, green: 145 / 255.0, blue: 150 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    saveImage(context: context, filename: "test_low_saturation.png")
}

// MARK: - Test Image 8: Split red/blue (50/50 competing colors)

func createSplitRedBlue() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Left half: vibrant red (RGB: 220, 40, 40)
    context.setFillColor(red: 220 / 255.0, green: 40 / 255.0, blue: 40 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))

    // Right half: vibrant blue (RGB: 40, 100, 230)
    context.setFillColor(red: 40 / 255.0, green: 100 / 255.0, blue: 230 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))

    saveImage(context: context, filename: "test_split_red_blue.png")
}

// MARK: - Test Image 9: Dark cover with bright accent

func createDarkWithBrightAccent() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Dark navy background (RGB: 20, 25, 45) - 80% of image
    context.setFillColor(red: 20 / 255.0, green: 25 / 255.0, blue: 45 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Bright yellow circle in center (RGB: 255, 220, 0)
    context.setFillColor(red: 255 / 255.0, green: 220 / 255.0, blue: 0 / 255.0, alpha: 1.0)
    let centerX = width / 2
    let centerY = height / 2
    let radius = 60.0
    let circleBounds = CGRect(
        x: centerX - Int(radius),
        y: centerY - Int(radius),
        width: Int(radius * 2),
        height: Int(radius * 2)
    )
    context.fillEllipse(in: circleBounds)

    saveImage(context: context, filename: "test_dark_bright_accent.png")
}

// MARK: - Test Image 10: Green with simulated text overlay

func createGreenWithBlackText() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Vibrant green background (RGB: 40, 180, 70)
    context.setFillColor(red: 40 / 255.0, green: 180 / 255.0, blue: 70 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Simulate text with thick black rectangles (like book title)
    context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

    // Top "text" - 3 horizontal bars
    context.fill(CGRect(x: 40, y: 50, width: 220, height: 25))
    context.fill(CGRect(x: 60, y: 85, width: 180, height: 25))
    context.fill(CGRect(x: 50, y: 120, width: 200, height: 25))

    // Bottom "text" - author name simulation
    context.fill(CGRect(x: 70, y: 220, width: 160, height: 18))
    context.fill(CGRect(x: 80, y: 245, width: 140, height: 18))

    saveImage(context: context, filename: "test_green_black_text.png")
}

// MARK: - Test Image 11: Pastel pink (low saturation but valid color)

func createPastelPink() {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Pastel pink (RGB: 255, 200, 220) - lower saturation
    context.setFillColor(red: 255 / 255.0, green: 200 / 255.0, blue: 220 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    saveImage(context: context, filename: "test_pastel_pink.png")
}

// MARK: - Test Image 12: Gold gradient (metallic effect)

func createGoldGradient() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Gold gradient from bright gold to bronze
    let colors =
        [
            CGColor(red: 255 / 255.0, green: 215 / 255.0, blue: 0 / 255.0, alpha: 1.0),  // Gold
            CGColor(red: 218 / 255.0, green: 165 / 255.0, blue: 32 / 255.0, alpha: 1.0),  // Goldenrod
            CGColor(red: 184 / 255.0, green: 134 / 255.0, blue: 11 / 255.0, alpha: 1.0),  // Dark goldenrod
        ] as CFArray

    if let gradient = CGGradient(
        colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0])
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )
    }

    saveImage(context: context, filename: "test_gold_gradient.png")
}

// MARK: - Test Image 13: Rainbow (multiple vibrant colors)

func createRainbow() {
    let width = 300
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Horizontal bands of rainbow colors
    let bandHeight = height / 6

    // Red
    context.setFillColor(red: 230 / 255.0, green: 40 / 255.0, blue: 40 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: bandHeight))

    // Orange
    context.setFillColor(red: 255 / 255.0, green: 140 / 255.0, blue: 0 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: bandHeight, width: width, height: bandHeight))

    // Yellow
    context.setFillColor(red: 255 / 255.0, green: 220 / 255.0, blue: 0 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: bandHeight * 2, width: width, height: bandHeight))

    // Green
    context.setFillColor(red: 40 / 255.0, green: 200 / 255.0, blue: 60 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: bandHeight * 3, width: width, height: bandHeight))

    // Blue
    context.setFillColor(red: 40 / 255.0, green: 100 / 255.0, blue: 230 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: bandHeight * 4, width: width, height: bandHeight))

    // Purple
    context.setFillColor(red: 180 / 255.0, green: 50 / 255.0, blue: 200 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: bandHeight * 5, width: width, height: bandHeight))

    saveImage(context: context, filename: "test_rainbow.png")
}

// MARK: - Test Image 14: Very dark image with subtle color

func createVeryDarkPurple() {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
        let context = createContext(
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }

    // Very dark purple (RGB: 25, 15, 35) - almost black with purple tint
    context.setFillColor(red: 25 / 255.0, green: 15 / 255.0, blue: 35 / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    saveImage(context: context, filename: "test_very_dark_purple.png")
}

// MARK: - Generate all images

print("Generating test images...")
print("\n=== Basic Color Space Tests ===")
createPureRGBRed()
createPureBGRBlue()

print("\n=== Badge/Banner Exclusion Tests ===")
createGreenWithYellowBanner()
createPurpleWithWhiteBadge()
createOrangeWithEdgeBadges()

print("\n=== Complex Layout Tests ===")
createGradientWithBanner()
createLowSaturationGray()

print("\n=== Realistic Edge Case Tests ===")
createSplitRedBlue()
createDarkWithBrightAccent()
createGreenWithBlackText()
createPastelPink()
createGoldGradient()
createRainbow()
createVeryDarkPurple()

print("\n✅ All test images generated in \(outputDir)/")
