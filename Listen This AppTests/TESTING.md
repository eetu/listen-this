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

### Simulator Optimization

**To speed up test runs, keep a simulator running between test sessions:**

```bash
# Launch and boot the simulator once
xcrun simctl boot "iPhone 17" && open -a Simulator

# Or just open Simulator app (it will use the default device)
open -a Simulator
```

Once the simulator is running, subsequent `xcodebuild test` commands will reuse it instead of launching a new instance, saving 10-30 seconds per run.

**Useful simulator commands:**

```bash
# List available simulators
xcrun simctl list devices

# Boot a specific device
xcrun simctl boot "iPhone 17"

# Shutdown when done (optional - can leave running)
xcrun simctl shutdown "iPhone 17"

# Shutdown all simulators
xcrun simctl shutdown all
```

### Command Line

```bash
# Run all tests (iPhone)
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Run all tests (iPad)
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPad Pro (13-inch) (M4)'

# Run specific test file
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/PlaybackStateSyncTests"

# Run specific test
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/CloudKitTransferTests/uploadChunkCount"

# Run tests on both iPhone and iPad
xcodebuild test -scheme "Listen This" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -destination 'platform=iOS Simulator,name=iPad Pro (13-inch) (M4)'
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

## iPad-Specific Testing

### UI Adaptation Tests

Tests for iPad-specific layouts and features:

```swift
@Suite("iPad Layout Tests")
@MainActor
struct iPadLayoutTests {
    
    @Test("Library shows 4 columns on iPad")
    func iPadLibraryColumns() async throws {
        // Test that iPad uses 4-column grid
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        // Create test audiobooks
        for i in 0..<8 {
            let book = createTestAudiobook(title: "Book \(i)")
            context.insert(book)
        }
        
        // Verify grid column count based on size class
        // Note: Size class testing requires UI testing framework
    }
    
    @Test("Split view layout on iPad")
    func iPadSplitView() async throws {
        // Verify NavigationSplitView is used on iPad
        // Test sidebar and detail pane behavior
    }
    
    @Test("Multitasking support")
    func multitaskingLayout() async throws {
        // Test that app adapts to Split View sizes
        // Verify readable content at various widths
    }
}
```

### Size Class Testing

```swift
@Suite("Size Class Adaptation")
@MainActor
struct SizeClassTests {
    
    @Test("Regular horizontal size class uses iPad layout")
    func regularSizeClassLayout() async throws {
        // Test layout switches based on horizontalSizeClass
    }
    
    @Test("Compact size class uses iPhone layout")
    func compactSizeClassLayout() async throws {
        // Test iPhone layout on iPad in Split View
    }
}
```

### Input Method Tests

```swift
@Suite("iPad Input Methods")
@MainActor
struct InputMethodTests {
    
    @Test("Keyboard shortcuts work")
    func keyboardShortcuts() async throws {
        // Test spacebar for play/pause
        // Test arrow keys for navigation
        // Test Cmd+N for add book
    }
    
    @Test("Drag and drop audiobook import")
    func dragDropImport() async throws {
        // Test dropping M4B file into app
    }
    
    @Test("External pointer hover effects")
    func pointerHoverEffects() async throws {
        // Test hover effects on buttons
    }
}
```

### Running iPad Tests

```bash
# Run iPad-specific tests
xcodebuild test -scheme "Listen This" \
  -destination 'platform=iOS Simulator,name=iPad Pro (13-inch) (M4)' \
  -only-testing:"Listen This AppTests/iPadLayoutTests"

# Test multiple iPad sizes
xcodebuild test -scheme "Listen This" \
  -destination 'platform=iOS Simulator,name=iPad Pro (13-inch) (M4)' \
  -destination 'platform=iOS Simulator,name=iPad mini (6th generation)'
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
- **Test on both iPhone and iPad simulators**
- **Test different size classes (regular/compact)**
- **Verify iPad-specific layouts and features**

### DON'T
- Test Apple's APIs
- Make tests dependent on each other
- Use real network calls
- Leave test data in production directories
- Skip error cases
- Write tests that take minutes to run
- **Assume iPhone layout works on iPad without testing**

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
