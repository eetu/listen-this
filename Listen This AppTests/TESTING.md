# Testing Guide for Listen This App

## Overview

This document outlines the testing strategy for the Listen This audiobook app, covering unit tests, integration tests, and best practices.

## Test Architecture

### Test Files

| File | Purpose |
|------|---------|
| **TestHelpers.swift** | Shared test utilities (container creation, test data factories) |
| **TransferTests.swift** | CloudKit and WatchConnectivity file transfer tests |
| **CacheTests.swift** | AudiobookCacheManager and file system tests |
| **ModelTests.swift** | SwiftData model relationships and queries |
| **ConcurrencyTests.swift** | Thread safety, error recovery, and performance |
| **PlaybackSyncTests.swift** | Cross-device playback state synchronization |

### Mock Implementations

Located in **Shared/Mocks.swift** (main target):
- `MockCloudKitTransferManager`
- `MockCacheManager`
- `MockiOSWatchConnectivity`
- `MockAudioPlayerService`

Available in both tests (via `@testable import`) and SwiftUI previews. Wrapped in `#if DEBUG` to exclude from production builds.

## Testing Framework

We use **Swift Testing** (the modern Swift testing framework with macros) instead of XCTest.

### Key Syntax

```swift
import Testing

@Suite("Feature Name Tests")
@MainActor
struct FeatureTests {

    @Test("Descriptive test name")
    func testSomething() async throws {
        #expect(value == expected)
        #require(optionalValue != nil)
    }
}
```

## Test Categories

### Transfer Tests
Tests for file transfers between devices and CloudKit:
- Upload/download progress tracking
- Chunk calculations
- Cancel operations
- Error handling
- Integration workflows

### Cache Tests
Tests for local file caching:
- Cache directory management
- File copy/delete operations
- Cache size calculations
- Orphaned file cleanup

### Model Tests
Tests for SwiftData models:
- Relationship cascade delete
- Computed properties
- Query predicates
- Boundary cases (unicode, long strings)

### Concurrency Tests
Tests for thread safety and resilience:
- Concurrent uploads
- Cancel during operations
- Atomic progress updates
- Error recovery
- Performance benchmarks

### Playback Sync Tests
Tests for cross-device synchronization:
- Timestamp comparison
- Conflict resolution (Watch vs iPhone)
- Progress preservation
- Session field persistence

## Running Tests

### Command Line

```bash
# Run all tests
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Run specific test file
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/PlaybackStateSyncTests"

# Run specific test
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/CloudKitTransferTests/uploadChunkCount"
```

### Xcode

1. Open Test Navigator (Cmd+6)
2. Click the diamond icon next to a test/suite
3. Or use Product -> Test (Cmd+U)

## Test Helpers

### Creating Test Containers

```swift
// Standard container
let container = try createTestContainer()
let context = ModelContext(container)

// Container with PlaybackSession support
let container = try createTestContainerWithPlayback()
```

### Creating Test Data

```swift
// Default audiobook
let audiobook = createTestAudiobook()

// Custom properties
let audiobook = createTestAudiobook(
    title: "The Hobbit",
    fileSize: 250_000_000
)

// Temporary test file
let fileURL = try createTestFile(size: 1_000_000)
defer { try? FileManager.default.removeItem(at: fileURL) }
```

## Mock Configuration

### MockCloudKitTransferManager

```swift
let manager = MockCloudKitTransferManager()

// Configure behavior
manager.shouldFailUpload = true
manager.simulateNetworkDelay = false
manager.networkDelayNanoseconds = 50_000_000

// Simulate partial upload
manager.simulatePartialUpload(audiobook, uploadedChunks: Set([0, 1, 2]))

// Reset between tests
manager.reset()
```

## Best Practices

### DO
- Write tests for new features
- Use descriptive test names
- Keep tests independent
- Clean up test files with `defer`
- Test edge cases
- Use mocks for external dependencies
- Group related tests in suites

### DON'T
- Test Apple's APIs
- Make tests dependent on each other
- Use real network calls
- Leave test data in production directories
- Skip error cases
- Write tests that take minutes to run

## Common Patterns

### Testing Async Functions

```swift
@Test("Async operation completes")
func asyncTest() async throws {
    try await someAsyncFunction()
    #expect(result == expected)
}
```

### Testing Errors

```swift
@Test("Function throws error")
func errorTest() async throws {
    await #expect(throws: SomeError.self) {
        try await functionThatThrows()
    }
}
```

### Testing Concurrent Operations

```swift
@Test("Concurrent operations complete")
func concurrencyTest() async throws {
    await withTaskGroup(of: Void.self) { group in
        for item in items {
            group.addTask {
                try? await processItem(item)
            }
        }
    }
    #expect(allCompleted)
}
```

## Resources

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [SwiftData Testing Guide](https://developer.apple.com/documentation/swiftdata/testing)
- [Concurrency Testing](https://developer.apple.com/documentation/swift/concurrency)

---

*Last Updated: December 27, 2025*
