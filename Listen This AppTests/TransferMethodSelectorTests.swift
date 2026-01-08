//
//  TransferMethodSelectorTests.swift
//  Listen This AppTests
//
//  Tests for TransferMethodSelector logic
//

import Foundation
import SwiftData
import Testing

@testable import Listen_This

@Suite("Transfer Method Selector Tests")
struct TransferMethodSelectorTests {

    // MARK: - File Size Threshold Tests

    @Test("CloudKit threshold is 50MB")
    func testCloudKitThreshold() {
        #expect(
            TransferMethodSelector.cloudKitThreshold == 50 * 1024 * 1024,
            "CloudKit threshold should be 50MB")
    }

    @Test("WatchConnectivity limit is 300MB")
    func testWatchConnectivityLimit() {
        #expect(
            TransferMethodSelector.watchConnectivityLimit == 300 * 1024 * 1024,
            "WatchConnectivity limit should be 300MB")
    }

    // MARK: - TransferMethod Enum Tests

    @Test("All TransferMethod cases have display names")
    func testTransferMethodDisplayNames() {
        let methods: [TransferMethod] = [.automatic, .cloudKit, .watchConnectivity, .iCloudDirect]

        for method in methods {
            #expect(
                !method.displayName.isEmpty,
                "\(method) should have display name")
            #expect(
                !method.description.isEmpty,
                "\(method) should have description")
        }
    }

    @Test("TransferMethod enum has all expected cases")
    func testTransferMethodEnumCompleteness() {
        let allCases = TransferMethod.allCases

        #expect(allCases.count == 4, "Should have exactly 4 transfer methods")
        #expect(allCases.contains(.automatic), "Should include automatic")
        #expect(allCases.contains(.cloudKit), "Should include cloudKit")
        #expect(allCases.contains(.watchConnectivity), "Should include watchConnectivity")
        #expect(allCases.contains(.iCloudDirect), "Should include iCloudDirect")
    }

    @Test("TransferMethod rawValue round-trip")
    func testTransferMethodRawValueRoundTrip() {
        for method in TransferMethod.allCases {
            let rawValue = method.rawValue
            let reconstructed = TransferMethod(rawValue: rawValue)

            #expect(
                reconstructed == method,
                "TransferMethod should round-trip through rawValue")
        }
    }

    @Test("TransferMethod is Identifiable")
    func testTransferMethodIdentifiable() {
        for method in TransferMethod.allCases {
            #expect(
                method.id == method.rawValue,
                "ID should equal rawValue")
        }
    }

    // MARK: - SelectedMethod Tests

    @Test("SelectedMethod descriptions include reasons")
    func testSelectedMethodDescriptions() {
        let testCases: [(SelectedMethod, String)] = [
            (.cloudKit(reason: "Test reason"), "CloudKit"),
            (.watchConnectivity(reason: "Test reason"), "WatchConnectivity"),
            (.iCloudDirect(reason: "Test reason"), "iCloud Direct"),
            (.error(reason: "Test error"), "Error"),
        ]

        for (method, expectedPrefix) in testCases {
            let description = method.description
            #expect(
                description.contains(expectedPrefix),
                "Description should contain '\(expectedPrefix)': \(description)")
            #expect(
                description.contains("Test"),
                "Description should include reason")
        }
    }

    // MARK: - Network Status Tests

    @Test("NetworkStatus enum has all cases")
    func testNetworkStatusCases() {
        // Ensure all enum cases are defined
        let wifi: NetworkStatus = .wifi
        let cellular: NetworkStatus = .cellular
        let none: NetworkStatus = .none
        let unknown: NetworkStatus = .unknown

        #expect(wifi != cellular)
        #expect(wifi != none)
        #expect(wifi != unknown)
    }

    // MARK: - TransferError Tests

    @Test("TransferError provides localized descriptions")
    func testTransferErrorDescriptions() {
        let methodUnavailable = TransferError.methodUnavailable
        let noMethod = TransferError.noMethodAvailable("No network")

        #expect(
            methodUnavailable.errorDescription != nil,
            "methodUnavailable should have error description")
        #expect(
            noMethod.errorDescription != nil,
            "noMethodAvailable should have error description")

        if let desc = noMethod.errorDescription {
            #expect(
                desc.contains("No network"),
                "Error description should include provided reason")
        }
    }

    // MARK: - User Preference Persistence Tests

    @Test("User preference persists in UserDefaults")
    @MainActor
    func testUserPreferencePersistence() async throws {
        // Clear any existing preference
        UserDefaults.standard.removeObject(forKey: "preferredTransferMethod")

        let container = try createTestContainer()
        let context = container.mainContext

        // Set preference
        let selector1 = TransferMethodSelector(modelContext: context)
        selector1.preferredMethod = .cloudKit

        // Create new instance - should load from UserDefaults
        let selector2 = TransferMethodSelector(modelContext: context)

        #expect(
            selector2.preferredMethod == .cloudKit,
            "Preference should persist in UserDefaults")

        // Cleanup
        selector2.preferredMethod = .automatic
    }

    @Test("Default preference is automatic")
    @MainActor
    func testDefaultPreference() async throws {
        // Clear any existing preference
        UserDefaults.standard.removeObject(forKey: "preferredTransferMethod")

        let container = try createTestContainer()
        let context = container.mainContext

        let selector = TransferMethodSelector(modelContext: context)

        #expect(
            selector.preferredMethod == .automatic,
            "Default preference should be automatic")
    }

    @Test("Can set all preference types")
    @MainActor
    func testAllPreferenceTypes() async throws {
        let container = try createTestContainer()
        let context = container.mainContext

        let selector = TransferMethodSelector(modelContext: context)

        // Test setting each preference
        for method in TransferMethod.allCases {
            selector.preferredMethod = method
            #expect(
                selector.preferredMethod == method,
                "Should be able to set preference to \(method)")
        }

        // Cleanup
        selector.preferredMethod = .automatic
    }

    // MARK: - Display String Tests

    @Test("TransferMethod display names are user-friendly")
    func testDisplayNamesAreUserFriendly() {
        let expectations: [TransferMethod: String] = [
            .automatic: "Automatic",
            .cloudKit: "CloudKit Chunks",
            .watchConnectivity: "WatchConnectivity",
            .iCloudDirect: "iCloud Direct",
        ]

        for (method, expectedName) in expectations {
            #expect(
                method.displayName == expectedName,
                "\(method) should have display name '\(expectedName)', got '\(method.displayName)'")
        }
    }

    @Test("TransferMethod descriptions are informative")
    func testDescriptionsAreInformative() {
        for method in TransferMethod.allCases {
            let description = method.description
            #expect(
                description.count > 10,
                "\(method) description should be informative: '\(description)'")
        }
    }
}

// MARK: - Integration Tests

@Suite("Transfer Method Selector Integration Tests")
@MainActor
struct TransferMethodSelectorIntegrationTests {

    @Test("TransferMethodSelector initializes successfully")
    func testInitialization() async throws {
        let container = try createTestContainer()
        let context = container.mainContext

        let selector = TransferMethodSelector(modelContext: context)

        #expect(
            selector.preferredMethod != nil,
            "Selector should have a preferred method after initialization")
    }

    @Test("Multiple selector instances share preferences via UserDefaults")
    func testMultipleInstancesSharePreferences() async throws {
        // Clear preferences
        UserDefaults.standard.removeObject(forKey: "preferredTransferMethod")

        let container = try createTestContainer()
        let context = container.mainContext

        let selector1 = TransferMethodSelector(modelContext: context)
        selector1.preferredMethod = .cloudKit

        let selector2 = TransferMethodSelector(modelContext: context)

        #expect(
            selector2.preferredMethod == .cloudKit,
            "Multiple instances should share the same UserDefaults preference")

        // Cleanup
        selector1.preferredMethod = .automatic
    }
}
