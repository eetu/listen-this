# Listen This - M4B Audiobook Player

A cross-platform audiobook player for iOS, iPadOS, and watchOS with synchronized playback state and offline-first design.

## Features

- Play M4B audiobooks on iPhone, iPad, and Apple Watch
- Automatic playback position sync across all devices via CloudKit
- Offline playback with smart caching on Apple Watch
- Independent Watch operation without iPhone connection
- Display chapter information and artwork
- Support for multiple content sources (iCloud Drive, with Jellyfin and AudiobookShelf planned)
- WatchConnectivity integration for direct file transfers between iPhone and Watch

## Project Status

### Step 1: Project Foundation (COMPLETED)

**Completed Components:**

1. **Core Data Models** (SwiftData)
   - Audiobook entity with relationships
   - Chapter information
   - Playback state tracking
   - Cache management
   - CloudKit-compatible schema (all attributes have defaults or are optional)

2. **Architecture Foundation**
   - ContentSource protocol for provider abstraction
   - Error handling framework
   - CloudKit sync configuration

3. **iOS Application**
   - Library browser with search
   - Audio player with full controls
   - Settings interface
   - Tab-based navigation

### Step 2: iCloud Drive Provider (COMPLETED)

**Completed Components:**

1. **iCloudDriveProvider**
   - Browse iCloud Drive for M4B files
   - Extract metadata using AVFoundation
   - Parse chapters from M4B files
   - Import files into library
   - Artwork extraction
   - Automatic download management

2. **AudiobookLibraryService**
   - Coordinate between provider and SwiftData
   - Manage library refresh
   - Handle file imports
   - Search functionality

3. **Import UI**
   - File picker integration
   - iCloud Drive scanner
   - Progress indicators
   - Download status visualization
   - Error handling

### Step 3: AVPlayer Integration (COMPLETED)

**Completed Components:**

1. **AudioPlayerService**
   - AVFoundation-based playback engine
   - Audio session management
   - Time observation and progress tracking
   - Playback controls (play, pause, seek)
   - Chapter navigation (previous/next/jump to)
   - Variable playback speed (0.5x - 3.0x with 0.05 steps)
   - Automatic state saving
   - Interruption handling (calls, route changes)
   - Sleep timer (preset times + end of chapter)
   - iCloud file management and download

2. **PlayerView Integration**
   - Chapter-focused interface
   - Real-time progress updates per chapter
   - Interactive chapter selection sheet
   - Playback speed picker with slider and presets
   - Sleep timer interface
   - Bottom toolbar navigation
   - Clean, modern UI design
   - Error handling

3. **Supporting Types**
   - AudiobookError enum with user-friendly messages
   - ContentSource protocol
   - AudiobookMetadata struct
   - CacheEntry model

### Step 4: CloudKit Configuration (COMPLETED)

**Completed Components:**

1. **CloudKit Integration**
   - Private database configuration (`iCloud.com.anarkisti.Listen-This`)
   - SwiftData models compatible with CloudKit
   - Automatic schema creation
   - Cross-device sync ready

2. **iCloud Container Setup**
   - Ubiquity container configured
   - Documents directory management
   - File download status monitoring
   - Security-scoped resource access

### Step 5: WatchConnectivity Integration (COMPLETED)

**Completed Components:**

1. **WatchConnectivityManager**
   - Singleton service for managing Watch-iPhone communication
   - Direct file transfers from iPhone cache to Watch
   - Transfer progress tracking
   - NSFileCoordinator for safe iCloud file access
   - Transfer status monitoring

2. **iOS Integration**
   - "Send to Watch" context menu option
   - Transfer progress indicators
   - Automatic WatchConnectivity session activation
   - Transfer retry logic

3. **Watch Receiver**
   - Receive files via Bluetooth (WatchConnectivity) or WiFi (CloudKit)
   - Save to Watch cache directory
   - Update CacheEntry models
   - Download method selection UI

### Next Steps

6. **watchOS App** - Build Apple Watch companion with playback
7. **Enhanced Features** - Bookmarks, CarPlay integration
8. **Additional Sources** - Jellyfin, AudiobookShelf providers

## Project Structure

- **Shared/** - Cross-platform code (Models, Services, Managers, shared Views)
- **iOS/Views/** - iOS views organized by feature (Library, Player, Settings, Transfer, Import)
- **Watch/** - watchOS-specific views and services
- **Docs/** - Architecture documentation

Views use feature-based grouping with naming convention: `*View` for screens, `*Sheet` for modals.

See [Architechture.md](Listen%20This/Docs/Architechture.md) for complete structure and system architecture.

## Requirements

- **Xcode**: 15.0+
- **iOS**: 17.0+
- **iPadOS**: 17.0+
- **watchOS**: 10.0+ (planned)
- **Swift**: 5.9+

### Getting Started

**Quick Start**: 

1. Open project in Xcode 15.0+
2. Configure signing with your team
3. Enable iCloud capabilities (CloudKit + iCloud Documents)
4. Enable Background Modes (Audio, Background fetch)
5. Build and run on iOS 17.0+ device or simulator

### 1. Open Project

```bash
open "listen this.xcodeproj"
```

### 2. Configure Signing

1. Select your target in Xcode
2. Go to **Signing & Capabilities**
3. Choose your **Team**

### 3. Enable Capabilities

Add these capabilities in Xcode:

**iCloud**
- CloudKit
- iCloud Documents

**Background Modes**
- Audio, AirPlay, and Picture in Picture
- Background fetch

### 4. Build and Run

```bash
# Clean Build Folder: Cmd+Shift+K
# Build: Cmd+B
# Run: Cmd+R
xcodebuild build -project "Listen This.xcodeproj" -scheme "Listen This"
```

### 5. Editor Setup (Optional)

For LSP support in editors like Zed, VS Code, or Neovim:

**Install xcode-build-server:**
```bash
brew install xcode-build-server
```

**Generate buildServer.json:**
```bash
xcode-build-server config -project "Listen This.xcodeproj" -scheme "Listen This"
```

This creates a `buildServer.json` file that enables SourceKit LSP to provide code completion, type checking, and navigation in your editor. The file contains machine-specific paths and is not committed to git - each developer needs to generate it on their machine.

## Current Features

### Library Management
- Grid-based library view with high-quality artwork
- Search audiobooks by title/author
- Download progress indicators for iCloud files
- Empty state with add button
- Navigation to player
- Real-time library updates
- Circular progress overlay for downloading books

### Audio Playback
- Full AVPlayer integration with iCloud file support
- Play/Pause controls
- Chapter-based progress tracking
- Seek within current chapter
- Skip backward 15s / forward 30s
- Chapter navigation (previous/next/jump to chapter)
- Variable playback speed (0.5x - 3.0x in 0.05 steps)
- Resume from last position on app launch
- Audio session management
- Interruption handling (phone calls, route changes)
- Background audio support
- Automatic download of iCloud files

### Player Interface
- **Chapter-Focused Design**
  - Current chapter title as main heading
  - Chapter X of Y indicator
  - Progress slider per chapter (not whole book)
  - Chapter list sheet with current chapter indicator
  
- **Modern UI**
  - High-quality artwork display
  - Clean, minimal design
  - Bottom toolbar with key controls
  - Sheet-based overlays for settings

- **Playback Speed Control**
  - Slider for precise adjustment (0.5x - 3.0x)
  - 6 quick-select presets (0.5, 1.0, 1.2, 1.5, 1.7, 2.0)
  - Current speed highlighted
  - Badge on toolbar when not at 1.0x

- **Sleep Timer**
  - Preset times (5, 10, 15, 30, 45, 60 minutes)
  - End of chapter option
  - Live countdown display
  - Cancel option when active

- **Additional Features**
  - Time formatting (hours:minutes:seconds)
  - Real-time progress updates
  - Chapter selection with checkmark for current
  - Error handling with user-friendly messages

### Data Layer
- SwiftData models with CloudKit sync
- Automatic playback state persistence
- Progress tracking per chapter and overall
- CloudKit-compatible schema (no unique constraints)
- Cross-device sync with conflict resolution (newest timestamp wins)
- Error handling framework
- Content provider abstraction
- iCloud container management

## Documentation

- **Architecture** - Complete system architecture (see `Listen This/Docs/Architechture.md`)
- **Testing Guide** - See `Listen This AppTests/TESTING.md`

## Development Roadmap

### Phase 1: MVP (COMPLETED) ✅
- [x] Core data models with CloudKit support
- [x] UI foundation
- [x] iCloud Drive provider
- [x] Chapter parsing and navigation
- [x] AVFoundation playback
- [x] Playback controls integration
- [x] Real-time progress tracking (per chapter)
- [x] Chapter navigation (previous/next/jump)
- [x] CloudKit configuration and sync
- [x] Variable playback speed (0.5x - 3.0x)
- [x] Sleep timer with presets
- [x] Download progress indicators
- [x] Modern UI with sheets and toolbars

### Phase 2: Extended Sources (Planned)
- [ ] Jellyfin provider
- [ ] AudiobookShelf provider
- [ ] Advanced download management
- [ ] Offline mode improvements

### Phase 3: Apple Watch (COMPLETED) ✅
- [x] watchOS app
- [x] Independent playback
- [x] Download manager for Watch (Bluetooth + CloudKit WiFi)
- [x] Cache management

### Phase 4: Polish & Enhancement (Planned)
- [ ] Bookmarks
- [ ] Notes per chapter
- [ ] Watch complications
- [ ] CarPlay integration
- [ ] Widgets
- [ ] Siri shortcuts

## Architecture Highlights

### Data Flow
```
Content Source → SwiftData Models → CloudKit Sync → Other Devices
     ↓                                                      ↓
Local Cache ← Intelligent Management → Playback State Updates
```

### Key Design Decisions

1. **Offline-First**: All platforms cache content locally
2. **Independent Operation**: Each device functions without others
3. **Eventual Consistency**: CloudKit syncs when network available
4. **Source Agnostic**: Abstract content providers behind protocol
5. **Resource Aware**: Intelligent cache management for device constraints

## Testing

```bash
# Run all tests
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Run specific test suite
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/PlaybackStateSyncTests"
```

Test files are organized by feature:
- `TransferTests.swift` - CloudKit and WatchConnectivity transfers
- `CacheTests.swift` - Cache manager and file system
- `ModelTests.swift` - SwiftData models
- `ConcurrencyTests.swift` - Thread safety and performance
- `PlaybackSyncTests.swift` - Cross-device playback sync

See `Listen This AppTests/TESTING.md` for the complete testing guide.

## Contributing

This is a private project. For questions or suggestions, contact the project maintainer.

## License

Private project - All rights reserved

---

**Last Updated**: December 27, 2025
**Status**: Phase 1 MVP Complete, Phase 3 Apple Watch Complete
**Recent**: Cross-device playback sync with conflict resolution
**CloudKit**: Configured and Active
**WatchConnectivity**: Bluetooth and CloudKit WiFi transfers implemented
