# Listen This - M4B Audiobook Player

A cross-platform audiobook player for iOS, iPadOS, and watchOS with synchronized playback state and offline-first design.

## Features

- Play M4B audiobooks on iPhone, iPad, and Apple Watch
- Automatic playback position sync across all devices via CloudKit
- Offline playback with smart caching on Apple Watch
- Independent Watch operation without iPhone connection
- Display chapter information and artwork
- Support for multiple content sources (iCloud Drive, Jellyfin, AudiobookShelf)

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

### Next Steps

5. **watchOS App** - Build Apple Watch companion
6. **Enhanced Features** - Bookmarks, CarPlay integration
7. **Additional Sources** - Jellyfin, AudiobookShelf providers

## Project Structure

```
listen this/
├── Shared/                  # Cross-platform code
│   ├── Models/             # SwiftData models
│   └── Providers/          # Content source abstractions
├── iOS/                    # iOS/iPadOS specific
│   └── Views/              # SwiftUI views
├── docs/                   # Documentation
├── ContentView.swift       # Main tab view
├── listen_thisApp.swift    # App entry point
└── README.md              # This file
```

**File Organization**: See `docs/File-Organization-Standards.md` for conventions and best practices when adding new files.

## Requirements

- **Xcode**: 15.0+
- **iOS**: 17.0+
- **iPadOS**: 17.0+
- **watchOS**: 10.0+ (planned)
- **Swift**: 5.9+

## Getting Started

**Quick Start**: See `QUICKSTART-ICLOUD.md` for 10-minute setup guide.

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

```
Clean Build Folder: Cmd+Shift+K
Build: Cmd+B
Run: Cmd+R
```

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
- Error handling framework
- Content provider abstraction
- iCloud container management

## Documentation

- **Architecture** - Complete system architecture (see `architechture.md`)
- **iCloud Drive Setup** - Configure and use iCloud Drive provider (see `docs/iCloud-Drive-Setup.md`)
- **Xcode Configuration** - Quick setup checklist (see `docs/Xcode-Configuration.md`)
- **Testing Guide** - Comprehensive test plan (see `docs/Testing-Guide.md`)
- **Implementation Summary** - Technical details and design decisions (see `docs/Implementation-Summary.md`)

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

### Phase 3: Apple Watch (Planned)
- [ ] watchOS app
- [ ] Independent playback
- [ ] Download manager for Watch
- [ ] Cache management
- [ ] Complications

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
# Run tests (when available)
Cmd+U

# Test on simulator
Select simulator → Cmd+R

# Test on device
Connect device → Select device → Cmd+R
```

## Contributing

This is a private project. For questions or suggestions, contact the project maintainer.

## License

Private project - All rights reserved

---

**Last Updated**: December 15, 2025
**Status**: Phase 1 MVP Complete ✅
**Next**: watchOS App Development or Additional Content Sources
**CloudKit**: Configured and Active
