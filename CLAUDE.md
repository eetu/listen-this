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

### Swift & Language Features

The project targets modern OS versions and should use current Swift features:
- **Minimum Deployment Targets**: iOS 18.0, watchOS 11.0
- **Swift Concurrency**: Use modern async/await, actors, and Task APIs
- **Swift 6 Compatibility**: Write code that's forward-compatible with Swift 6 language mode
  - Use `OSAllocatedUnfairLock` for thread-safe state instead of `NSLock` where appropriate
  - Prefer `@MainActor` and actor isolation over manual synchronization
  - Use `Sendable` types for concurrent code
  - Avoid mutable captured variables in concurrent closures
- **SwiftUI**: Use latest SwiftUI features available in iOS 18/watchOS 11
  - `.task { }` modifier instead of `.onAppear { Task { } }`
  - `@Observable` macro for observable objects
  - New SwiftData integration patterns
- **Swift Testing**: Use Swift Testing framework (not XCTest) for new tests

## Project Structure

```
Listen This/
├── Shared/           # Compiled into iOS, watchOS AND the widget extension
│   ├── Models/       # SwiftData: Audiobook, Chapter, PlaybackSession,
│   │                 #   CacheEntry, UserSettings, AudiobookshelfSettings
│   ├── Services/     # AudioPlayerService, AudiobookLibraryService,
│   │                 #   TransferProgressCenter, CacheSettings
│   ├── Managers/     # AudiobookCacheManager, CloudKitChunkedTransferManager,
│   │                 #   AudiobookshelfDownloadManager
│   ├── Providers/    # ContentSource protocol + iCloudDrive, Audiobookshelf
│   ├── Protocols/    # AudioPlayer, CacheManager, CloudKitTransferManager
│   ├── Views/        # Cross-platform views (AudiobookRowView,
│   │                 #   PlayerControlsView, TransferProgressView, ...)
│   ├── Utilities/    # AppLogger, MetadataExtractor, UIImage+DominantColor
│   ├── Preview/      # SwiftUI preview helpers
│   └── Mocks.swift   # Mock implementations for tests and previews
├── iOS/              # iOS-only
│   ├── Views/        # Library, Player, Import, Settings, Transfer
│   ├── Managers/     # iOSWatchConnectivityManager
│   ├── Models/       # WatchTransferProgress
│   └── Protocols/    # iOSWatchConnectivity
└── Docs/             # ARCHITECHTURE.md

Listen This Watch App/
└── Watch/
    ├── Views/        # WatchLibraryView, WatchPlayerView,
    │                 #   WatchTransferStatusView, AudiobookshelfDownloadView
    └── Managers/     # WatchConnectivityManager, WatchExtensionDelegate

Listen This Widgets/  # Widget extension (reads the shared models)

Listen This AppTests/ # Swift Testing; TESTING.md documents the suites
```

**Target membership matters.** The project uses file-system-synchronized
groups, so a new file under `Shared/` is picked up by the **iOS target only**.
To use it from the Watch or the tests, tick it into those targets in Xcode's
File Inspector — otherwise the Watch build fails with "cannot find type in
scope". This appears in `project.pbxproj` as `membershipExceptions`.

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

## UX Audit Findings (June 2026)

Comprehensive UX review findings organized by priority. Address these when improving the app.

### Critical Priority

1. **Silent Failures in Transfer Operations**
   - Files: `AutoTransferSheet.swift`, `CloudKitTransferView.swift`
   - Issue: Network failures during CloudKit transfers may not show user-visible errors
   - Fix: Add retry UI and clear error states with actionable messages

2. **No Offline Mode Indication**
   - Files: `LibraryView.swift`, `WatchLibraryView.swift`
   - Issue: Users don't know when they're offline or what content is available
   - Fix: Add network status indicator and show which books are cached locally

### High Priority

3. **Touch Targets Below 44pt Minimum**
   - Files: `PlayerControlsView.swift` (chapter skip buttons), `WatchPlayerView.swift`
   - Issue: Some buttons are smaller than Apple's 44x44pt minimum
   - Fix: Increase hitArea even if visual size stays small

4. **Missing Delete Confirmations**
   - Files: `DeleteAudiobookSheet.swift`, `CloudKitStorageView.swift`
   - Issue: "Delete from everywhere" and "Clear All CloudKit Data" need stronger confirmation
   - Fix: Add two-step confirmation or require typing to confirm destructive actions

5. **No Loading States for Long Operations**
   - Files: `AudiobookshelfBrowserView.swift`, `ImportView.swift`
   - Issue: Large library fetches show no progress indication
   - Fix: Add skeleton loaders or progress indicators for operations >1s

6. **Watch App: No Battery Warning for Large Downloads**
   - Files: `WatchLibraryView.swift`
   - Issue: Starting a large download on low battery could kill the watch
   - Fix: Warn if battery <20% before starting CloudKit download

### Medium Priority

7. **Inconsistent Empty States**
   - Files: Various list views
   - Issue: Some empty states have actions, others don't
   - Fix: All empty states should guide users to the next action

8. **No Haptic Feedback on Watch**
   - Files: `WatchPlayerView.swift`, `WatchTransferStatusView.swift`
   - Issue: Missing haptic confirmation for button presses
   - Fix: Add `WKInterfaceDevice.current().play(.click)` for key actions

9. **Chapter List Scrolling Performance**
   - Files: `PlayerView.swift` (chapter list section)
   - Issue: Books with 100+ chapters may have scroll lag
   - Fix: Use `LazyVStack` with proper identifiers

10. **No Pull-to-Refresh on Some Lists**
    - Files: `CloudKitStorageView.swift`
    - Issue: Inconsistent refresh patterns across views
    - Fix: Add `.refreshable` to all data-fetching lists

11. **Transfer Progress Not Visible After Dismissing Sheet**
    - Files: `AutoTransferSheet.swift`
    - Issue: If user dismisses transfer sheet, they lose visibility into progress
    - Fix: Show mini progress indicator in library row during active transfer

### Low Priority

12. **Color Contrast in Dark Mode**
    - Files: Various views with `.secondary` text
    - Issue: Some secondary text may not meet WCAG AA contrast ratios
    - Fix: Audit with accessibility inspector

13. **No VoiceOver Hints for Complex Gestures**
    - Files: `LibraryView.swift` (swipe actions)
    - Issue: VoiceOver users may not discover swipe actions
    - Fix: Add `accessibilityHint` describing available actions

14. **Settings Organization**
    - Files: `SettingsView.swift`
    - Issue: Settings could be better grouped as app grows
    - Fix: Consider grouping by function (Playback, Storage, Sync, About)

15. **No Onboarding for First-Time Users**
    - Issue: New users don't get guidance on key features
    - Fix: Consider adding optional walkthrough for iCloud setup, Watch pairing

16. **Sleep Timer UI Discoverability**
    - Files: `PlayerView.swift`, `SleepTimerSheet.swift`
    - Issue: Sleep timer button may not be obvious to new users
    - Fix: Consider adding tooltip on first use

17. **Watch Complications Not Implemented**
    - Issue: No quick-launch complications for Watch
    - Fix: Add Now Playing complication for quick access

### SwiftUI List Stability Note

When using observable state in SwiftUI List rows (like tracking transfer status):
- **DON'T** conditionally show/hide swipe action buttons based on frequently changing state
- **DO** always show buttons but disable them when action isn't available
- This prevents `NSInternalInconsistencyException` crashes from collection view update mismatches

### Sheet Dismissal

Toolbar placements are **semantic, not positional** — declare what the button
means and let the system position it per platform:

- `.confirmationAction` for a "Done" that just closes and abandons nothing
- `.cancellationAction` for a "Cancel" that abandons work in progress

If a sheet's dismiss changes meaning with state (leaving a running transfer
doesn't stop it), switch the placement along with the label.

**watchOS exception:** keep the dismiss in `.cancellationAction` regardless.
`.confirmationAction` renders top-right, where the system clock lives, and
overlaps the navigation title — verified in the simulator. Only the label
carries the meaning there.

Every navigation sheet needs *some* toolbar dismiss. Without one, watchOS falls
back to a default "X" (inconsistent with the rest of the app) and iOS leaves no
visible way out at all.

### State That Can't Be Trusted

Don't gate an action on whether a file exists on the *other* device. The iPhone
can't know reliably whether the Watch still has a book — three transfer routes,
intermittent connectivity, and the Watch can delete its copy at any time. A
stale "already sent" disables the button and leaves the user stuck, while a
redundant transfer costs seconds. Show state if it's useful; don't block on it.
