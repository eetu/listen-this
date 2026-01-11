# Claude Code Instructions

## Project Overview

Listen This is a cross-platform M4B audiobook player for iOS, iPadOS, and watchOS with CloudKit sync.

## Key Documentation

- `README.md` - Project status and features
- `Listen This/Docs/Architechture.md` - System architecture
- `Listen This AppTests/TESTING.md` - Testing guide

## Code Guidelines

- Ensure proper folder structure instead of creating flattened files
- Scan existing file structure and avoid creating duplicates in different directories
- Limit emoji usage in documentation and debug output
- Only update README and Architechture.md with relevant information
- Never add actual code into architecture docs, only pseudo code if applicable
- Try to share as much code between iOS and watchOS targets in Shared directory
- **Do not create separate instruction/setup files** - Add all instructions to CLAUDE.md instead
- When code requires manual Xcode configuration (like adding files to targets), mention it directly in conversation rather than creating files

## Project Structure

```
Listen This/
├── Shared/           # Shared code between iOS and watchOS
│   ├── Models/       # SwiftData models (Audiobook, Chapter, PlaybackSession)
│   ├── Services/     # Business logic (AudioPlayerService, CacheManager)
│   ├── Managers/     # CloudKit, WatchConnectivity managers
│   └── Mocks.swift   # Mock implementations for tests and previews
├── iOS/              # iOS-specific code
│   ├── Views/        # SwiftUI views
│   └── Managers/     # iOS-specific managers
├── Docs/             # Architecture documentation
└── Preview/          # SwiftUI preview helpers

Listen This Watch App/
└── Watch/            # watchOS-specific code

Listen This AppTests/
├── TestHelpers.swift      # Shared test utilities
├── TransferTests.swift    # CloudKit & Watch transfer tests
├── CacheTests.swift       # Cache manager tests
├── ModelTests.swift       # SwiftData model tests
├── ConcurrencyTests.swift # Thread safety tests
├── PlaybackSyncTests.swift # Cross-device sync tests
└── TESTING.md             # Testing documentation
```

## Key Patterns

### Playback State Sync
Cross-device sync uses timestamp comparison in `AudioPlayerService.savePlaybackState()`:
- Tracks `lastKnownPlayedTimestamp` when loading audiobook
- Before saving, checks if CloudKit synced newer data
- If remote is newer, adopts remote state instead of overwriting

### Testing
- Use Swift Testing framework (not XCTest)
- Tests organized by feature in separate files
- Run with: `xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'`

### SwiftData + CloudKit
- All models sync via CloudKit Private Database
- `PlaybackSession.lastPlayed` is key field for sync conflict resolution
- Cache state is device-local (not synced)

## Xcode & Build Configuration

### Project Files
- **Xcode Project**: `Listen This.xcodeproj`
- **Main Scheme**: `Listen This`
- **Test Target**: `Listen This AppTests`
- **Watch Target**: `Listen This Watch App`

### Build Commands
```bash
# Build project (iOS)
xcodebuild build -project "Listen This.xcodeproj" -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Build Watch app
xcodebuild build -project "Listen This.xcodeproj" -scheme "Listen This Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'

# Run tests
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Clean build
xcodebuild clean -project "Listen This.xcodeproj" -scheme "Listen This"
```

### Finding Available Simulators
```bash
# List all iOS simulators
xcrun simctl list devices available | grep iPhone

# List all watchOS simulators
xcrun simctl list devices available | grep "Apple Watch"

# List all iPad simulators
xcrun simctl list devices available | grep iPad
```

### Common Build Destinations
- **iPhone**: `'platform=iOS Simulator,name=iPhone 17'`
- **iPad**: `'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`
- **Apple Watch**: `'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'`

Note: Simulator names change with Xcode/iOS versions. Use the commands above to find the latest available devices on your system.

### LSP Setup (for non-Xcode editors)
- Requires `xcode-build-server` (install via Homebrew)
- Generate config: `xcode-build-server config -project "Listen This.xcodeproj" -scheme "Listen This"`
- Creates `buildServer.json` (not committed to git - contains machine-specific paths)
- Enables SourceKit LSP in editors like Zed, VS Code, Neovim
