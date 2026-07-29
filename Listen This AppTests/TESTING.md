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
| **AudiobookshelfDownloadTests.swift** | Server address classification, error mapping, byte-based progress, download bookkeeping |
| **PartialDownloadTests.swift** | A partial transfer must never present itself as a download |
| **CancelAndResumeTests.swift** | Chunk resume offsets, partial visibility, staged-chunk reclamation, resume-data expiry |
| **TransferMethodSelectorTests.swift** | Transfer method selection thresholds and display names |
| **DominantColorTests.swift** | Artwork colour extraction |

### Mock Implementations

Located in **Shared/Mocks.swift** (main target):
- `MockCloudKitTransferManager`
- `MockCacheManager`
- `MockiOSWatchConnectivity`
- `MockAudioPlayerService`

Available in both tests (via `@testable import`) and SwiftUI previews. Wrapped in `#if DEBUG` to exclude from production builds.

## Testing Framework

We use **Swift Testing** (the modern Swift testing framework with macros) instead of XCTest.

### Key Features

- `@Suite` for grouping related tests
- `@Test` for individual test cases
- `#expect()` for assertions
- `#require()` for optional unwrapping
- `@MainActor` for main thread tests
- Async/await support built-in

## Test Categories

### Transfer Tests
Tests for file transfers between devices and CloudKit:
- Upload/download progress tracking
- Chunk calculations
- Cancel operations
- Error handling
- Integration workflows
- Background URLSession delegate callbacks
- Long-lived CloudKit operations
- Resume capability for interrupted uploads

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

Use `createTestContainer()` for standard in-memory SwiftData container, or `createTestContainerWithPlayback()` for containers that include PlaybackSession support.

### Creating Test Data

Helper functions in `TestHelpers.swift` provide factory methods for:
- Test audiobooks with default or custom properties
- Temporary test files with specified sizes
- Test chapters and playback sessions

All test data uses in-memory storage and doesn't persist between test runs.

## Mock Configuration

### MockCloudKitTransferManager

Mock implementation supports:
- Configurable upload/download failures
- Network delay simulation
- Partial upload simulation for resume testing
- Reset between tests for isolation

See `Shared/Mocks.swift` for full API.

## iPad-Specific Testing

### UI Adaptation Tests

Tests for iPad-specific layouts and features:
- Library grid column count (4 columns on iPad)
- NavigationSplitView behavior
- Multitasking and Split View adaptation
- Size class switching between regular and compact layouts

### Input Method Tests

Tests for iPad input methods:
- Keyboard shortcuts (spacebar, arrow keys, Cmd+N)
- Drag and drop audiobook import
- External pointer hover effects

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
- Use `async throws` for test functions
- Use `try await` for async operations
- Use `#expect()` for assertions

### Testing Errors
- Use `#expect(throws:)` for expected errors
- Specify error type for type-safe error checking

### Testing Concurrent Operations
- Use `withTaskGroup` for parallel operations
- Test atomicity and thread safety
- Verify progress updates under concurrency

## Resources

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [SwiftData Testing Guide](https://developer.apple.com/documentation/swiftdata/testing)
- [Concurrency Testing](https://developer.apple.com/documentation/swift/concurrency)

## Background Transfer Testing

### Background URLSession Testing

Tests for background download/upload functionality:
- Background URLSession continues after app termination
- URLSession delegate receives completion callbacks
- Cellular data setting is respected (WiFi-only vs cellular)
- Background session configuration is correct

### Long-Lived Operation Testing

Tests for CloudKit background operations:
- CKModifyRecordsOperation configured with long-lived flag
- Operations continue after app backgrounding
- Upload resumes after interruption (only missing chunks uploaded)
- Progress tracking during resume operations

### watchOS Background Task Testing

Tests for watchOS background tasks:
- WKURLSessionRefreshBackgroundTask handling
- URLSession reconnection with matching identifier
- Background downloads continue when app is suspended
- Delegate callbacks on task completion

---

*Last Updated: January 5, 2026*
