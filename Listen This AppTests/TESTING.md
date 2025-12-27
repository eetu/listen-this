# Testing Guide for Listen This App

## Overview

This document outlines the testing strategy for the Listen This audiobook app, covering unit tests, integration tests, and best practices.

## Test Architecture

### Test Files

1. **Listen_This_AppTests.swift** - Core functionality tests
   - CloudKit chunked transfer tests
   - WatchConnectivity transfer tests
   - AudiobookCacheManager tests
   - Integration tests
   - Edge case tests

2. **Listen_This_AdvancedTests.swift** - Advanced scenarios
   - Concurrency and thread safety
   - Error recovery and resilience
   - SwiftData model tests
   - File system operations
   - Performance tests
   - Boundary tests

3. **Shared/Mocks.swift** (in main target) - Shared mock implementations
   - MockCloudKitTransferManager
   - MockCacheManager
   - MockiOSWatchConnectivity
   - MockAudioPlayerService
   - Available in both tests (via @testable import) and previews
   - Wrapped in #if DEBUG to exclude from production builds

## Testing Framework

We use **Swift Testing** (the modern Swift testing framework with macros) instead of XCTest.

### Key Differences from XCTest

```swift
// Swift Testing
import Testing

@Test("Test description")
func myTest() async throws {
    #expect(value == expected)
    #require(optionalValue != nil)
}

// vs XCTest
import XCTest

func testMyFunction() throws {
    XCTAssertEqual(value, expected)
    XCTAssertNotNil(optionalValue)
}
```

## Test Categories

### 1. Unit Tests

**Purpose:** Test individual components in isolation

**Examples:**
- Progress calculation tests
- Error description tests
- Model property tests
- Utility function tests

**Best Practices:**
- Use mocks for dependencies
- Test one thing per test
- Keep tests fast (< 100ms each)

### 2. Integration Tests

**Purpose:** Test interactions between components

**Examples:**
- Complete upload/download workflows
- Cache-to-CloudKit pipelines
- iPhone-to-Watch transfers

**Best Practices:**
- Use in-memory storage
- Clean up after tests
- Mock network calls

### 3. Concurrency Tests

**Purpose:** Verify thread safety and race condition handling

**Examples:**
- Multiple concurrent uploads
- Cancel during operations
- Atomic progress updates

**Best Practices:**
- Use `withTaskGroup` for concurrent operations
- Test cancellation scenarios
- Verify no data corruption

### 4. Error Recovery Tests

**Purpose:** Ensure graceful error handling

**Examples:**
- Resume partial uploads
- Handle network interruptions
- Recover from corrupted files

**Best Practices:**
- Test both happy and sad paths
- Verify cleanup after errors
- Check error propagation

### 5. Performance Tests

**Purpose:** Catch performance regressions

**Examples:**
- Large library queries
- Progress update frequency
- File operations

**Best Practices:**
- Set reasonable thresholds
- Test with realistic data sizes
- Profile memory usage

## Running Tests

### Command Line

```bash
# Run all tests
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test suite
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Listen_This_AppTests/CloudKitTransferTests

# Run specific test
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Listen_This_AppTests/CloudKitTransferTests/uploadChunkCount
```

### Xcode

1. Open Test Navigator (⌘6)
2. Click the diamond icon next to a test/suite
3. Or use Product → Test (⌘U)

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

### MockCacheManager

```swift
let cacheManager = MockCacheManager()

// Simulate failures
cacheManager.shouldFailCaching = true

// Check cached audiobooks
print(cacheManager.cachedAudiobooks)

// Clean up
cacheManager.reset()
```

## Test Data Helpers

### Creating Test Containers

```swift
let container = try createTestContainer()
let context = ModelContext(container)
```

### Creating Test Audiobooks

```swift
// Default audiobook
let audiobook = createTestAudiobook()

// Custom properties
let audiobook = createTestAudiobook(
    title: "The Hobbit",
    fileSize: 250_000_000
)
```

### Creating Test Files

```swift
let fileURL = try createTestFile(size: 1_000_000)
defer {
    try? FileManager.default.removeItem(at: fileURL)
}
```

## Coverage Goals

| Component | Target Coverage | Current |
|-----------|----------------|---------|
| CloudKitChunkedTransferManager | 85% | 75% |
| WatchConnectivityManager | 80% | 45% |
| AudiobookCacheManager | 90% | 85% |
| Data Models | 95% | 90% |
| UI Components | 60% | 30% |

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

### Testing Progress Updates

```swift
@Test("Progress updates correctly")
func progressTest() async throws {
    let manager = MockCloudKitTransferManager()
    let audiobook = createTestAudiobook()
    
    Task {
        try await manager.uploadAudiobook(audiobook)
    }
    
    // Wait and verify progress
    try await Task.sleep(nanoseconds: 100_000_000)
    
    let progress = manager.activeUploads[audiobook.id.uuidString]
    #expect(progress != nil)
    #expect(progress!.progress > 0)
}
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: |
          xcodebuild test \
            -scheme "Listen This" \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -enableCodeCoverage YES
```

## Debugging Tests

### Print Statements

```swift
@Test("Debug test")
func debugTest() async throws {
    print("Current value: \(value)")
    #expect(value == expected)
}
```

### Breakpoints

Set breakpoints in test code just like regular code. Xcode will pause execution.

### Test Failure Messages

```swift
#expect(value == expected, "Values should match")

// Custom failure
Issue.record("Something unexpected happened")
```

## Future Improvements

### Not Yet Implemented

1. **UI Tests** - Test SwiftUI views and user interactions
2. **Snapshot Tests** - Verify UI appearance
3. **Network Mocking** - Mock URLSession responses
4. **CloudKit Mocking** - Better CloudKit operation testing
5. **Watch Simulator Tests** - Test watchOS app directly
6. **Accessibility Tests** - Verify VoiceOver support
7. **Localization Tests** - Test multiple languages

### Planned Test Suites

- **PlayerTests** - Test audio playback functionality
- **ChapterTests** - Test chapter navigation
- **LibraryTests** - Test library management
- **SyncTests** - Test CloudKit sync logic
- **UITests** - Test SwiftUI views

## Best Practices

### DO ✅

- Write tests for new features
- Use descriptive test names
- Keep tests independent
- Clean up after tests
- Test edge cases
- Use mocks for external dependencies
- Test async code properly
- Group related tests in suites

### DON'T ❌

- Don't test Apple's APIs
- Don't make tests dependent on each other
- Don't use real network calls
- Don't leave test data in production directories
- Don't skip error cases
- Don't test implementation details
- Don't write tests that take minutes to run

## Resources

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [SwiftData Testing Guide](https://developer.apple.com/documentation/swiftdata/testing)
- [Concurrency Testing](https://developer.apple.com/documentation/swift/concurrency)

## Questions?

If you have questions about testing:
1. Check this guide first
2. Look at existing tests for examples
3. Review Apple's testing documentation
4. Ask the team

---

*Last Updated: December 25, 2025*
