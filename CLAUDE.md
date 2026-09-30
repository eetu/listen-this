# Claude Code Instructions

## Project Overview

Listen This is an M4B audiobook player for iPhone, iPad and Apple Watch, with
iCloud (CloudKit) sync and optional Audiobookshelf server support.

## Key Documentation

- `README.md` - Project status and features
- `Listen This/Docs/Architechture.md` - System architecture, roadmap, known issues
- `Listen This AppTests/TESTING.md` - Testing guide
- `CHANGELOG.md` - User-facing changes per App Store version
- `Listen This/Docs/AppStoreListing.md` - App Store name, description, keywords

## Working Rules

- Keep the folder structure; don't create flattened files or duplicates in
  other directories — scan the existing structure first
- Share code between iOS and watchOS through `Shared/` wherever possible
- Keep README and Architechture.md to relevant information; architecture docs
  get pseudo code at most, never real code
- Don't create separate instruction or setup files — instructions belong here
- When a change needs manual Xcode configuration (such as target membership),
  say so in the conversation instead of writing a file about it
- Limit emoji in documentation and debug output
- **Zero warnings**: builds of both schemes stay at 0 compiler warnings. Ignore
  DerivedData "Could not read priors" noise; mention Xcode's "Update to
  recommended settings" prompt rather than accepting it silently
- **Commits**: conventional prefixes (`feat:`, `fix:`, `docs:`, `chore:`,
  `test:`), and no `Co-Authored-By` or other AI attribution lines in commits or
  PRs

### Swift & Language Features

- **Deployment targets**: iOS 26.2 and watchOS 26.2, set at the project level
  (the targets don't override them). APIs newer than that need `#available`
- **Isolation**: Swift 5 language mode with approachable concurrency, and types
  default to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Mark pure helpers
  that run off the main thread `nonisolated` (see `ABSServerAddress`)
- **Concurrency**: async/await, actors and `Task`; prefer actor isolation over
  locks, `OSAllocatedUnfairLock` over `NSLock` when a lock is needed; `Sendable`
  types and no mutable captures in concurrent closures
- **SwiftUI**: `.task { }` instead of `.onAppear { Task { } }`, `@Observable`
  for observable objects
- **Tests**: Swift Testing, not XCTest

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
│   ├── Widgets/      # Widget timeline data + accessory views (both widget targets)
│   ├── Preview/      # SwiftUI preview helpers
│   └── Mocks.swift   # Mock implementations for tests and previews
├── iOS/              # iOS-only
│   ├── Views/        # Library, Player, Import, Settings, Transfer
│   ├── Managers/     # iOSWatchConnectivityManager
│   ├── Models/       # WatchTransferProgress
│   └── Protocols/    # iOSWatchConnectivity
└── Docs/             # Architechture.md, AppStoreListing.md

Listen This Watch App/
└── Watch/
    ├── Views/        # WatchLibraryView, WatchPlayerView,
    │                 #   WatchTransferStatusView, AudiobookshelfDownloadView
    └── Managers/     # WatchConnectivityManager, WatchExtensionDelegate

Listen This Widgets/  # watchOS widget extension: complications
Listen This iPhone Widgets/  # iOS widget extension: Home Screen + Lock Screen
                      # Both read the shared models; every target must share one
                      # build number and version (app extensions must match the app)

Listen This AppTests/ # Swift Testing; TESTING.md documents the suites
```

**Target membership matters.** The project uses file-system-synchronized
groups, so a new file under `Shared/` is picked up by the **iOS target only**.
To use it from the Watch or the tests, tick it into those targets in Xcode's
File Inspector — otherwise the Watch build fails with "cannot find type in
scope". This appears in `project.pbxproj` as `membershipExceptions`.

The test target compiles selected `Shared/` files directly (e.g.
`AudioPlayerService.swift`), so code in those files must not reference types
that only the app or a widget target includes — expose a hook the app fills in
at launch instead (see `AudioPlayerService.playbackStateDidChange`). After
touching such files, build for testing, not just the app.

## Key Patterns

### Playback Position Sync

Positions sync through `PlaybackSession` in CloudKit; `lastPlayed` decides which
position is newest. The rules, in `AudioPlayerService`:

- The device actually playing owns the position and is never moved by a sync
- A paused device adopts newer remote progress: live on a CloudKit remote
  change, and again in `play()` before resuming
- Applying a stored position (restore, adopt) must never save — saving stamps a
  fresh `lastPlayed`, which would let a stale position win
- `pause()` saves before clearing `isPlaying`, so the listening device's
  position isn't swapped for another device's
- Newest wins, not furthest: going back to re-listen is legitimate

Playing on two devices at once is a documented known issue (Architechture.md).

### SwiftData + CloudKit

- All models sync via the CloudKit private database; cache state is
  device-local
- A new or changed model field needs the CloudKit schema deployed to production
  (CloudKit Console) before release, or it won't sync
- In-memory test containers must pass `cloudKitDatabase: .none`: the default
  `.automatic` starts mirroring in the host app and crashes parallel tests

### Audiobookshelf

- The server may be stock Audiobookshelf or a compatible server (the
  maintainer runs one); rely only on the documented API (`/ping`, `/api/...`)
- Settings save the address and API key together, and only after a
  successful test. Never disable the integration because a check fails — a
  LAN-only server is unreachable away from home
- Send the API key only after `verifyServer` (unauthenticated `/ping`) succeeds

## Building & Testing

- **Project**: `Listen This.xcodeproj`; schemes `Listen This` (iOS, includes the
  Watch app) and `Listen This Watch App`; tests in `Listen This AppTests`
- **During changes**: incremental build, per-file diagnostics, and only the
  relevant tests. A command-line `clean` also wipes Xcode's DerivedData, so the
  next Xcode build starts from scratch
- **Before tagging**: clean build of both schemes (check for `warning:`) and
  the full test suite
- **Run tests on a simulator**, not a connected device: a device run makes
  Xcode copy several GB of debug symbols for a new OS version

```bash
xcodebuild build -project "Listen This.xcodeproj" -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'
xcodebuild build -project "Listen This.xcodeproj" -scheme "Listen This Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)'
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'
xcrun simctl list devices available   # simulator names change with each Xcode
```

**LSP for other editors**: install `xcode-build-server` (Homebrew), then
`xcode-build-server config -project "Listen This.xcodeproj" -scheme "Listen This"`.
It writes `buildServer.json`, which isn't committed (machine-specific paths).

## Releasing

**Pushing a tag triggers the app build** in Xcode Cloud, which is configured in
Xcode / App Store Connect, not in this repo. GitHub Actions only runs the tests
(`tests.yml`) and publishes the marketing site (`pages.yml`).

Tags mark builds and App Store versions mark submissions, so they don't map
one-to-one: `v1.2.0`–`v1.2.2` all shipped as version 1.2.0. A fix that must
reach a build needs a tag even when the version doesn't change.

Release checklist:

1. **Bump the build number** (`CURRENT_PROJECT_VERSION`). Xcode Cloud doesn't
   set it, and App Store Connect rejects a build number it already has. For a
   new App Store version, also bump `MARKETING_VERSION`
2. **Changelog**: user-facing changes go under the next version's heading in
   `CHANGELOG.md` (`## X.Y.Z — Unreleased`) as they land. At release, replace
   "Unreleased" with the date, list the tag, and add a one-line **App Store**
   summary — that line is the "What's New" text; users skim it, so the detail
   stays in the lists. A tag that never reaches the App Store gets no section
   or GitHub release; its changes roll into the next version
3. **Verify**: clean build of both schemes with 0 warnings, and the full test
   suite
4. **Tag and push** (`vX.Y.Z`), which starts the Xcode Cloud build
5. **GitHub release**: one per App Store version, on its first tag. Title
   `X.Y.Z — short summary` (the App Store version, not the tag), body = that
   CHANGELOG section plus a closing italic line with the App Store version and
   build. A later tag for the same version edits the existing release instead

## UI Conventions

### SwiftUI List Stability

When List rows observe frequently changing state (like transfer status):
- **DON'T** conditionally show/hide swipe action buttons based on that state
- **DO** always show them and disable them when the action isn't available
- This prevents `NSInternalInconsistencyException` crashes from collection view
  update mismatches

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

## Open UX Items

From a June 2026 audit, re-checked against the code in September 2026; fixed
items were removed. Address these when working nearby.

**High**
- **Destructive actions confirm too little**: "Delete Everywhere"
  (`DeleteAudiobookSheet.swift`) deletes on one tap inside the sheet, and "Clear
  All CloudKit Data" (`CloudKitStorageView.swift`) has no confirmation at all
- **Touch targets under 44pt**: iOS chapter skip buttons
  (`PlayerControlsView.swift`, 30pt icons, no hit area) and the Watch chapters
  button (`WatchPlayerView.swift`, 32×32)
- **Transfer errors can't be retried**: `AutoTransferSheet` and
  `CloudKitTransferView` show the error in an OK-only alert, with no Retry
- **No low-battery warning for Watch CloudKit downloads**: the Audiobookshelf
  download path warns below 20%, the CloudKit path (`CloudKitTransferView`)
  doesn't

**Medium**
- **No offline indicator**: rows show whether a book is on the device, but
  nothing says the device is offline (`LibraryView`, `WatchLibraryView`)
- **No haptics on Watch** for key actions (`WatchPlayerView`,
  `WatchTransferStatusView`)
- **No pull-to-refresh** in `CloudKitStorageView`, unlike the other data lists
- **CloudKit storage empty state** has no next step

**Low**
- **No VoiceOver hint for library swipe actions** (a context menu offers the
  same actions)
- **No first-run onboarding** beyond the Watch transfer hint banner
- **Dark mode contrast** of secondary text is unverified — check with the
  Accessibility Inspector
