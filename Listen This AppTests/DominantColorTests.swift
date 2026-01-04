//
//  DominantColorTests.swift
//  Listen This AppTests
//

import OSLog
import SwiftUI
import Testing
import UIKit

@testable import Listen_This

/// Tests for UIImage+DominantColor extension
/// Validates color extraction accuracy across different:
/// - Color spaces (RGB, BGR)
/// - Image layouts (solid, gradient, with badges/banners)
/// - Edge cases (low saturation, transparent pixels)
@Suite("Dominant Color Extraction")
struct DominantColorTests {

    // MARK: - Test Helpers

    /// Converts SwiftUI Color to RGB components for comparison
    private func rgbComponents(of color: Color) -> (red: Double, green: Double, blue: Double)? {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return (Double(red), Double(green), Double(blue))
    }

    /// Checks if two colors are approximately equal (within tolerance)
    private func colorsMatch(_ color1: Color, _ color2: Color, tolerance: Double = 0.15) -> Bool {
        guard let rgb1 = rgbComponents(of: color1),
            let rgb2 = rgbComponents(of: color2)
        else {
            return false
        }

        let redMatch = abs(rgb1.red - rgb2.red) <= tolerance
        let greenMatch = abs(rgb1.green - rgb2.green) <= tolerance
        let blueMatch = abs(rgb1.blue - rgb2.blue) <= tolerance

        return redMatch && greenMatch && blueMatch
    }

    /// Loads test image from bundle
    private func loadTestImage(_ filename: String) -> UIImage? {
        // Try multiple approaches to find the test bundle
        var bundle: Bundle?

        // Approach 1: Try to find bundle by identifier
        if let testBundle = Bundle(identifier: "com.anarkisti.Listen-This.Listen-This-AppTests") {
            bundle = testBundle
        }

        // Approach 2: Try Bundle.allBundles
        if bundle == nil {
            bundle = Bundle.allBundles.first { $0.bundlePath.contains("Listen This AppTests") }
        }

        // Approach 3: Fall back to main bundle (for test execution)
        if bundle == nil {
            bundle = Bundle.main
        }

        guard let testBundle = bundle else {
            AppLogger.general.error("Could not find test bundle for image: \(filename)")
            return nil
        }

        // Try multiple path variations
        // 1. With TestImages directory
        if let path = testBundle.path(
            forResource: filename, ofType: "png", inDirectory: "TestImages")
        {
            return UIImage(contentsOfFile: path)
        }

        // 2. With TestImages as part of resource name
        if let path = testBundle.path(forResource: "TestImages/\(filename)", ofType: "png") {
            return UIImage(contentsOfFile: path)
        }

        // 3. Just the filename in bundle root (images might be copied flat)
        if let path = testBundle.path(forResource: filename, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }

        // 4. Try url(forResource:) with subdirectory
        if let url = testBundle.url(
            forResource: filename, withExtension: "png", subdirectory: "TestImages")
        {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }

        // 5. Try url without subdirectory
        if let url = testBundle.url(forResource: filename, withExtension: "png") {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }

        // Log error - image not found after all attempts
        AppLogger.general.error("Test image not found: \(filename, privacy: .public)")
        AppLogger.general.debug("Bundle path: \(testBundle.bundlePath, privacy: .public)")

        if let resourcePath = testBundle.resourcePath {
            // List contents for debugging
            let testImagesPath = (resourcePath as NSString).appendingPathComponent("TestImages")
            if FileManager.default.fileExists(atPath: testImagesPath) {
                if let contents = try? FileManager.default.contentsOfDirectory(
                    atPath: testImagesPath)
                {
                    AppLogger.general.debug(
                        "TestImages directory contents: \(contents, privacy: .public)")
                }
            } else {
                AppLogger.general.debug(
                    "TestImages directory does not exist at: \(testImagesPath, privacy: .public)")
            }
        }

        return nil
    }

    // MARK: - RGB Color Space Tests

    @Test("Extract red from RGB image")
    func testRGBRed() async throws {
        guard let image = loadTestImage("test_rgb_red") else {
            Issue.record("Failed to load test_rgb_red.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Expected: RGB(220, 50, 50) -> approximately (0.86, 0.20, 0.20)
            let expectedRed = Color(red: 220 / 255.0, green: 50 / 255.0, blue: 50 / 255.0)
            #expect(
                colorsMatch(color, expectedRed, tolerance: 0.2),
                "Should extract red color from RGB image")
        }
    }

    // MARK: - BGR Color Space Tests

    @Test("Extract blue from BGR image")
    func testBGRBlue() async throws {
        guard let image = loadTestImage("test_bgr_blue") else {
            Issue.record("Failed to load test_bgr_blue.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Expected: RGB(50, 100, 230) -> approximately (0.20, 0.39, 0.90)
            let expectedBlue = Color(red: 50 / 255.0, green: 100 / 255.0, blue: 230 / 255.0)
            #expect(
                colorsMatch(color, expectedBlue, tolerance: 0.2),
                "Should correctly handle BGR byte order")
        }
    }

    // MARK: - Banner/Badge Exclusion Tests

    @Test("Ignore yellow Audible-style banner, extract green center")
    func testGreenWithYellowBanner() async throws {
        guard let image = loadTestImage("test_green_yellow_banner") else {
            Issue.record("Failed to load test_green_yellow_banner.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Expected: Green from center (RGB: 40, 200, 80)
            // Should NOT be yellow from banner
            let expectedGreen = Color(red: 40 / 255.0, green: 200 / 255.0, blue: 80 / 255.0)
            let yellowBanner = Color(red: 1.0, green: 200 / 255.0, blue: 0.0)

            #expect(
                colorsMatch(color, expectedGreen, tolerance: 0.25),
                "Should extract green from center, not yellow banner")
            #expect(
                !colorsMatch(color, yellowBanner, tolerance: 0.3),
                "Should ignore edge banner")
        }
    }

    @Test("Ignore white badge at top, extract purple center")
    func testPurpleWithWhiteBadge() async throws {
        guard let image = loadTestImage("test_purple_white_badge") else {
            Issue.record("Failed to load test_purple_white_badge.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Expected: Purple from center (RGB: 180, 60, 200)
            let expectedPurple = Color(red: 180 / 255.0, green: 60 / 255.0, blue: 200 / 255.0)

            #expect(
                colorsMatch(color, expectedPurple, tolerance: 0.25),
                "Should extract purple from center, not white badge")

            // Verify it's not white
            if let rgb = rgbComponents(of: color) {
                #expect(
                    rgb.red < 0.95 || rgb.green < 0.95 || rgb.blue < 0.95,
                    "Should not extract white/bright badge color")
            }
        }
    }

    @Test("Ignore edge badges, extract orange center")
    func testOrangeWithEdgeBadges() async throws {
        guard let image = loadTestImage("test_orange_edge_badges") else {
            Issue.record("Failed to load test_orange_edge_badges.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Expected: Orange from center (RGB: 240, 120, 40)
            let expectedOrange = Color(red: 240 / 255.0, green: 120 / 255.0, blue: 40 / 255.0)

            #expect(
                colorsMatch(color, expectedOrange, tolerance: 0.25),
                "Should extract orange from center despite multiple edge badges")
        }
    }

    // MARK: - Complex Layout Tests

    @Test("Extract from gradient with banner")
    func testGradientWithBanner() async throws {
        guard let image = loadTestImage("test_gradient_yellow_banner") else {
            Issue.record("Failed to load test_gradient_yellow_banner.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a dominant color")

        if let color = dominantColor {
            // Should extract teal/blue from gradient, not yellow banner
            let yellowBanner = Color(red: 1.0, green: 0.85, blue: 0.0)

            #expect(
                !colorsMatch(color, yellowBanner, tolerance: 0.3),
                "Should not extract yellow banner from gradient image")

            // Verify it extracted a blue-ish color (from gradient)
            if let rgb = rgbComponents(of: color) {
                #expect(rgb.blue > 0.5, "Should extract blue-ish color from gradient")
            }
        }
    }

    // MARK: - Edge Case Tests

    @Test("Return fallback for low saturation image")
    func testLowSaturation() async throws {
        guard let image = loadTestImage("test_low_saturation") else {
            Issue.record("Failed to load test_low_saturation.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should return fallback color")

        if let color = dominantColor {
            // Should return blue fallback for gray image
            let fallbackBlue = Color.blue
            #expect(
                colorsMatch(color, fallbackBlue, tolerance: 0.2),
                "Should return blue fallback for low saturation image")
        }
    }

    @Test("Handle nil CGImage gracefully")
    func testNilCGImage() async throws {
        // Create empty UIImage
        let emptyImage = UIImage()
        let dominantColor = emptyImage.dominantColor(quality: ColorExtractionQuality.medium)

        #expect(dominantColor == nil, "Should return nil for invalid image")
    }

    // MARK: - Quality Parameter Tests

    @Test("Different quality settings produce consistent results")
    func testQualityConsistency() async throws {
        guard let image = loadTestImage("test_rgb_red") else {
            Issue.record("Failed to load test_rgb_red.png")
            return
        }

        let lowQuality = image.dominantColor(quality: ColorExtractionQuality.low)
        let mediumQuality = image.dominantColor(quality: ColorExtractionQuality.medium)
        let highQuality = image.dominantColor(quality: ColorExtractionQuality.high)

        #expect(
            lowQuality != nil && mediumQuality != nil && highQuality != nil,
            "All quality levels should extract colors")

        if let low = lowQuality, let medium = mediumQuality, let high = highQuality {
            // All should extract similar red colors
            #expect(
                colorsMatch(low, medium, tolerance: 0.15),
                "Low and medium quality should produce similar results")
            #expect(
                colorsMatch(medium, high, tolerance: 0.15),
                "Medium and high quality should produce similar results")
        }
    }

    // MARK: - Performance Tests

    @Test("Extract color efficiently at different quality levels")
    func testPerformance() async throws {
        guard let image = loadTestImage("test_gradient_yellow_banner") else {
            Issue.record("Failed to load test_gradient_yellow_banner.png")
            return
        }

        // Test that extraction completes in reasonable time
        // Low quality should be fastest
        let start = Date()
        _ = image.dominantColor(quality: ColorExtractionQuality.low)
        let duration = Date().timeIntervalSince(start)

        #expect(duration < 0.1, "Low quality extraction should complete quickly (<100ms)")
    }

    // MARK: - Realistic Edge Case Tests

    @Test("Handles competing vibrant colors (50/50 split)")
    func testSplitRedBlue() async throws {
        guard let image = loadTestImage("test_split_red_blue") else {
            Issue.record("Failed to load test_split_red_blue.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a color from split image")

        if let color = dominantColor {
            // Should pick either red or blue (both are vibrant)
            // The algorithm should be deterministic and pick one based on vibrancy score
            let expectedRed = Color(red: 220 / 255.0, green: 40 / 255.0, blue: 40 / 255.0)
            let expectedBlue = Color(red: 40 / 255.0, green: 100 / 255.0, blue: 230 / 255.0)

            let matchesRed = colorsMatch(color, expectedRed, tolerance: 0.2)
            let matchesBlue = colorsMatch(color, expectedBlue, tolerance: 0.2)

            #expect(matchesRed || matchesBlue, "Should extract either red or blue consistently")
        }
    }

    @Test("Extracts bright accent from dark cover")
    func testDarkWithBrightAccent() async throws {
        guard let image = loadTestImage("test_dark_bright_accent") else {
            Issue.record("Failed to load test_dark_bright_accent.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a color")

        if let color = dominantColor {
            // Should extract the bright yellow accent, not the dark background
            let expectedYellow = Color(red: 255 / 255.0, green: 220 / 255.0, blue: 0 / 255.0)

            #expect(
                colorsMatch(color, expectedYellow, tolerance: 0.25),
                "Should extract bright yellow accent over dark background")

            // Verify it's not the dark background
            if let rgb = rgbComponents(of: color) {
                #expect(
                    rgb.red > 0.3 || rgb.green > 0.3 || rgb.blue > 0.3,
                    "Should extract bright color, not dark background")
            }
        }
    }

    @Test("Excludes text overlay, extracts background color")
    func testGreenWithBlackText() async throws {
        guard let image = loadTestImage("test_green_black_text") else {
            Issue.record("Failed to load test_green_black_text.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a color")

        if let color = dominantColor {
            // Should extract green background, not black text
            let expectedGreen = Color(red: 40 / 255.0, green: 180 / 255.0, blue: 70 / 255.0)

            #expect(
                colorsMatch(color, expectedGreen, tolerance: 0.25),
                "Should extract green background, not black text overlay")

            // Verify it's not black/dark text color
            if let rgb = rgbComponents(of: color) {
                #expect(
                    rgb.green > rgb.red && rgb.green > rgb.blue,
                    "Should be greenish, not black text")
            }
        }
    }

    @Test("Handles pastel colors correctly")
    func testPastelPink() async throws {
        guard let image = loadTestImage("test_pastel_pink") else {
            Issue.record("Failed to load test_pastel_pink.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)

        // Pastel pink might be below saturation threshold (0.4)
        // It could either extract the pastel or return fallback
        // This tests the boundary case
        if let color = dominantColor {
            let pastelPink = Color(red: 255 / 255.0, green: 200 / 255.0, blue: 220 / 255.0)
            let fallbackBlue = Color.blue

            let matchesPastel = colorsMatch(color, pastelPink, tolerance: 0.2)
            let matchesFallback = colorsMatch(color, fallbackBlue, tolerance: 0.2)

            #expect(
                matchesPastel || matchesFallback,
                "Should extract pastel pink or use fallback for low saturation")
        }
    }

    @Test("Extracts color from gold gradient")
    func testGoldGradient() async throws {
        guard let image = loadTestImage("test_gold_gradient") else {
            Issue.record("Failed to load test_gold_gradient.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a color from gradient")

        if let color = dominantColor {
            // Should extract a goldish/yellow color from the gradient
            // Verify it's in the gold/yellow range
            if let rgb = rgbComponents(of: color) {
                #expect(
                    rgb.red > 0.5 && rgb.green > 0.4,
                    "Should extract goldish color (high red and green)")
                #expect(
                    rgb.blue < rgb.red && rgb.blue < rgb.green,
                    "Blue should be lower than red/green for gold")
            }
        }
    }

    @Test("Handles rainbow (multiple vibrant colors)")
    func testRainbow() async throws {
        guard let image = loadTestImage("test_rainbow") else {
            Issue.record("Failed to load test_rainbow.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should extract a color from rainbow")

        if let color = dominantColor {
            // Should pick one of the vibrant colors based on vibrancy score
            // All colors are equally represented, so it should be deterministic
            // We just verify it extracted a vibrant color (not gray/muddy)
            if let rgb = rgbComponents(of: color) {
                let maxChannel = max(rgb.red, rgb.green, rgb.blue)
                let minChannel = min(rgb.red, rgb.green, rgb.blue)
                let saturation = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0

                #expect(
                    saturation > 0.3,
                    "Should extract a vibrant color from rainbow, not muddy average")
            }
        }
    }

    @Test("Handles very dark image gracefully")
    func testVeryDarkPurple() async throws {
        guard let image = loadTestImage("test_very_dark_purple") else {
            Issue.record("Failed to load test_very_dark_purple.png")
            return
        }

        let dominantColor = image.dominantColor(quality: ColorExtractionQuality.medium)
        #expect(dominantColor != nil, "Should return a color or fallback")

        if let color = dominantColor {
            // Very dark purple likely won't meet brightness threshold (>0.4)
            // Should probably return fallback blue
            let fallbackBlue = Color.blue

            // Either extracted the subtle purple or used fallback
            let matchesFallback = colorsMatch(color, fallbackBlue, tolerance: 0.2)

            // If it's not fallback, it should at least have some color
            if !matchesFallback, let rgb = rgbComponents(of: color) {
                #expect(
                    rgb.blue >= rgb.red && rgb.blue >= rgb.green,
                    "If not fallback, should have purple-ish tint (blue dominant)")
            }
        }
    }
}
