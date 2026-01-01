
# M4B Audiobook Player - Architecture Documentation

## Project Overview

Cross-platform audiobook player for iOS, iPadOS, and watchOS with synchronized playback state and offline-first design. Supports M4B audiobook files from multiple sources (iCloud Drive, Jellyfin, AudiobookShelf) with intelligent caching and independent device operation.

### Key Features
- Play M4B audiobooks on iPhone, iPad, and Apple Watch
- Automatic playback position sync across all devices via CloudKit
- Offline playback on all devices with device-independent caching
- Independent Watch operation without iPhone connection
- Display chapter information and artwork
- Support for multiple content sources
- Direct file transfers between iPhone and Watch via WatchConnectivity

---

## System Architecture

### High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                         iOS/iPadOS App                       │
├─────────────────────────────────────────────────────────────┤
│  Views                                                       │
│  ├─ LibraryView (grid, search, import)                     │
│  ├─ PlayerView (playback controls, chapters)               │
│  ├─ SettingsView                                           │
│  └─ ImportView (iCloud Drive picker)                       │
├─────────────────────────────────────────────────────────────┤
│  Services                                                    │
│  ├─ AudioPlayerService (AVPlayer integration)              │
│  ├─ AudiobookLibraryService (library management)           │
│  ├─ AudiobookCacheManager (local cache)                    │
│  ├─ iCloudDriveProvider (file import)                      │
│  └─ WatchConnectivityManager (file transfers)              │
├─────────────────────────────────────────────────────────────┤
│  Models (SwiftData)                                         │
│  ├─ Audiobook (metadata, iCloud path)                      │
│  ├─ Chapter (timing, metadata)                             │
│  ├─ PlaybackSession (position, state)                      │
│  └─ CacheEntry (cache metadata)                            │
└─────────────────────────────────────────────────────────────┘
                              ↕
                    CloudKit Private DB
                    (metadata sync)
                              ↕
                    WatchConnectivity
                    (file transfers)
                              ↕
┌─────────────────────────────────────────────────────────────┐
│                         watchOS App                          │
├─────────────────────────────────────────────────────────────┤
│  Views                                                       │
│  ├─ WatchLibraryView                                       │
│  ├─ WatchPlayerView                                        │
│  └─ DownloadView                                           │
├─────────────────────────────────────────────────────────────┤
│  Services                                                    │
│  ├─ WatchAudioPlayerService                                │
│  ├─ WatchDownloadManager                                   │
│  ├─ AudiobookCacheManager (shared logic)                   │
│  └─ WatchConnectivityManager                               │
├─────────────────────────────────────────────────────────────┤
│  Models (SwiftData - same schema)                           │
│  ├─ Audiobook                                              │
│  ├─ Chapter                                                │
│  ├─ PlaybackSession                                        │
│  └─ CacheEntry                                             │
└─────────────────────────────────────────────────────────────┘
```


### Architecture Principles

1. **Offline-First**: All platforms cache content locally for offline access
2. **Independent Operation**: Each device can function without others (especially Watch)
3. **Eventual Consistency**: CloudKit syncs playback state when network available
4. **Source Agnostic**: Abstract content providers behind common protocol
5. **Resource Aware**: Intelligent cache management respecting device constraints
6. **Device-Independent Caching**: Each device manages its own cache without sync conflicts

### Current Implementation Status

**Completed:**
- SwiftData models with CloudKit sync configuration
- Device-independent cache architecture
- iOS application with library and player views
- iCloud Drive file import and management
- WatchConnectivity file transfer (iPhone sender)
- AudioPlayerService with AVFoundation integration
- Chapter parsing and metadata extraction

**In Progress:**
- Full AVPlayer playback integration
- watchOS application enhancements

**Completed:**
- CloudKit chunked file transfer system
- iOS upload to CloudKit functionality
- watchOS download from CloudKit functionality
- CloudKit storage management UI

**Planned:**
- Transfer method auto-selection based on file size
- Background transfer support for large files
- Additional content sources (Jellyfin, AudiobookShelf)
- Enhanced playback features (bookmarks, sleep timer)
- CarPlay integration

---

## Technology Stack

### iOS/iPadOS Application
- **UI Framework**: SwiftUI
- **Audio Playback**: AVFoundation (AVPlayer, AVAudioSession)
- **Persistence**: SwiftData
- **Sync**: CloudKit Private Database
- **Networking**: URLSession
- **File Management**: FileManager

### watchOS Application
- **UI Framework**: SwiftUI
- **Audio Playback**: AVFoundation with Audio Playback background mode
- **Persistence**: SwiftData (shared schema with iOS)
- **Sync**: CloudKit Private Database
- **Downloads**: URLSession with background configuration
- **Communication**: WatchConnectivity (optional, for live commands)

### Shared Components
- Swift Package for business logic
- Common data models and protocols
- Content provider abstractions
- Sync manager
- Cache management utilities

---

## Apple Watch Architecture

### Watch Storage Strategy

#### Storage Constraints
- Apple Watch Series 4+: 8-64GB total storage
- Realistic audiobook cache: 2-8GB
- Target: 1-5 books cached simultaneously

#### Three-Layer Storage Architecture

The app uses three distinct storage layers, each serving a specific purpose:

**1. iCloud Drive (Source of Truth)**
- Original audiobook files imported by user
- Path stored in `Audiobook.iCloudRelativePath` (e.g., "Documents/Audiobooks/book.m4b")
- Synced across all user's devices via iCloud Drive
- Never deleted by app
- Primary use: iPhone can play directly from iCloud Drive, source for caching

**2. Local Device Cache (Per-Device)**
- Managed by `AudiobookCacheManager`
- Location: `~/Library/Caches/Audiobooks/` on each device
- Platform-specific: iPhone cache ≠ Watch cache (different file system, different storage constraints)
- Can be cleared and re-downloaded from iCloud Drive
- Primary use: Offline playback, faster access than iCloud Drive

**3. CloudKit Chunked Transfer (Temporary)**
- Managed by `CloudKitChunkedTransferManager`
- Files split into 100MB chunks stored in CloudKit Private Database
- Purpose: Fast audiobook transfers from iPhone → Watch over WiFi
- Lifecycle: iPhone uploads chunks → Watch downloads chunks → chunks auto-deleted after successful Watch download
- Not permanent storage: Multi-watch edge case requires re-upload
- Primary use: Overcome WatchConnectivity transfer speed limitations

**Storage Decision Matrix:**
```
iPhone: iCloud Drive (source) → Local Cache (playback) → CloudKit Chunks (upload for Watch)
Watch:  CloudKit Chunks (download) → Local Cache (playback)
```

**Why Three Layers?**
- iCloud Drive: User's permanent library, accessible from any Apple device
- Local Cache: Fast access, offline capability, respects device storage limits
- CloudKit Chunks: Solves Watch transfer problem (iCloud Drive not accessible on Watch, WatchConnectivity too slow)

#### Cleanup Policy (Priority Order)

Removal priority from lowest to highest:
1. Books not accessed > 90 days
2. Books not accessed > 30 days
3. Books with < 10% progress
4. Completed books (100% progress)
5. Books accessed in last 7 days
6. Currently playing book (never remove)

---

## Sync Architecture

### CloudKit Sync Strategy

**SwiftData CloudKit Configuration:**

All models sync via CloudKit Private Database in a single configuration:
  - `Audiobook` - metadata, artwork, paths
  - `Chapter` - chapter information
  - `PlaybackSession` - playback position and state
  - `CacheEntry` - cache metadata (syncs but is optional per-device)

**Cache Entry Sync Behavior:**

While `CacheEntry` syncs via CloudKit, each device manages its cache independently:
- The `cacheEntry` relationship is optional on `Audiobook`
- Each device can have different cache states (one device cached, another not)
- Deleting a cache entry on one device doesn't affect other devices' files
- CloudKit only syncs the metadata about what's cached, not the actual files

**Important:** Using multiple ModelConfigurations (one for CloudKit, one local-only) causes SwiftData to create duplicate entity instances, leading to "ID occurs multiple times" errors in ForEach loops.

#### Sync Triggers
- Playback position update (debounced, every 30 seconds)
- App enters background
- Book completion
- Manual sync request
- Periodic background refresh (every 15 minutes)

#### Conflict Resolution

The app uses timestamp-based conflict resolution to handle cross-device sync:

```swift
// In AudioPlayerService.savePlaybackState()
// Tracks the timestamp when playback state was last loaded
private var lastKnownPlayedTimestamp: Date?

func savePlaybackState() {
    // Check if CloudKit synced newer data from another device
    if let knownTimestamp = lastKnownPlayedTimestamp,
       session.lastPlayed > knownTimestamp {
        // Remote has newer data - adopt it instead of overwriting
        currentPosition = session.currentPosition
        lastKnownPlayedTimestamp = session.lastPlayed
        seek(to: currentPosition)
        return
    }

    // Save local state with new timestamp
    session.lastPlayed = Date()
    lastKnownPlayedTimestamp = session.lastPlayed
}
```

**How it works:**
1. When loading an audiobook, store the `lastPlayed` timestamp
2. Before saving, check if CloudKit synced newer data (from Watch/other device)
3. If remote `lastPlayed > knownTimestamp`, adopt remote state instead of overwriting
4. This prevents older local state from overwriting newer progress from another device

**Key field:** `PlaybackSession.lastPlayed: Date` - Updated on every position save

#### Sync Flow

**Typical Sync Sequence:**

1. **iPhone Updates Position**
   - User plays audiobook
   - Position updates every 30 seconds
   - iPhone pushes to CloudKit with timestamp

2. **CloudKit Storage**
   - Stores PlaybackSession update
   - Triggers push notification to other devices

3. **Watch Receives Update**
   - CloudKit sends push notification
   - Watch fetches latest state
   - Compares timestamps (local vs remote)
   - Updates position if remote is newer

4. **Offline Scenario**
   - Watch updates local state during offline playback
   - Queues sync operation
   - Pushes to CloudKit when network available
   - iPhone receives notification and merges state

### Watch-iPhone Communication

#### Communication Strategy

**CloudKit (Primary Sync & File Transfer)**
- Playback position and state
- Library metadata
- Cache manifests
- Works when devices not nearby
- Handles conflicts automatically
- Batch updates
- **NEW: Chunked file transfers** (100MB chunks)

**CloudKit Chunked File Transfer** (Recommended for large audiobooks)
- Files split into 100MB chunks (well under CloudKit's 250MB asset limit)
- iPhone uploads chunks to CloudKit Private Database
- Watch downloads chunks independently over WiFi
- Files reconstructed from chunks on destination device
- Much faster than WatchConnectivity for large files
- No device proximity required
- Can resume interrupted transfers
- Works while Watch is charging
- **Chunk lifecycle**: Auto-deleted after successful Watch download to free iCloud storage
- **Chunk verification**: Both iPhone and Watch use `checkCloudKitChunks()` to verify availability before upload/download

**WatchConnectivity (Direct Transfer - Alternative)**
- Direct device-to-device transfers via Bluetooth/WiFi Direct
- Slower for large files (100+ MB)
- Requires devices nearby and paired
- Real-time progress tracking via `WatchTransferProgress`
- Useful fallback when WiFi unavailable or CloudKit issues
- Implemented in `WatchConnectivityTransferView` (iOS) and `WatchTransferStatusView` (Watch)

**Transfer Views:**
- `CloudKitTransferView` (Shared) - Modern MVVM-based view for chunked CloudKit transfers
  - Works on both iOS and watchOS
  - Auto-detects upload vs download mode based on platform
  - Shows chunk-by-chunk progress
  - Handles availability checking and error states

- `WatchConnectivityTransferView` (iOS-only) - Direct device transfer via WatchConnectivity
  - Alternative to CloudKit when WiFi unavailable
  - Requires iPhone and Watch to be nearby
  - Handles download-then-transfer if file not cached
  - Uses WatchConnectivity framework for Bluetooth/WiFi Direct transfer

**Communication Decision Matrix:**
- Metadata updates → CloudKit sync (automatic)
- Playback state → CloudKit sync (automatic)
- Large file transfers (>50MB) → **CloudKit Chunked Transfer** (recommended)
- When WiFi unavailable → WatchConnectivity Bluetooth transfer (fallback)
- Direct downloads → Watch downloads from iCloud independently (if available)

---

## Playback Architecture

### AVFoundation Setup

```swift
class AudiobookPlayer {
    private var player: AVPlayer
    private var timeObserver: Any?
    private var audioSession: AVAudioSession
    
    // Initialize audio session
    func setupAudioSession() {
        audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: []
        )
        try? audioSession.setActive(true)
    }
    
    // Load audiobook
    func load(audiobook: Audiobook) async throws {
        let asset: AVAsset
        
        // Try cached file first, fallback to iCloud
        if let cachedURL = audiobook.cacheFileURL {
            // Play from cache
            asset = AVAsset(url: cachedURL)
        } else if let iCloudURL = audiobook.iCloudFileURL {
            // Play from iCloud Drive
            asset = AVAsset(url: iCloudURL)
        } else {
            throw AudiobookError.fileNotFound
        }
        
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        
        // Extract chapters
        try await loadChapters(from: asset, for: audiobook)
    }
    
    // Extract chapter metadata
    func loadChapters(from asset: AVAsset, for audiobook: Audiobook) async throws {
        let languages = try await asset.load(.availableChapterLocales)
        guard let locale = languages.first else { return }
        
        let chapterMetadata = try await asset.load(.chapterMetadataGroups(
            bestMatchingPreferredLanguages: [locale.languageCode ?? "en"]
        ))
        
        // Parse and store chapters
        for (index, group) in chapterMetadata.enumerated() {
            let chapter = Chapter()
            chapter.index = index
            chapter.startTime = group.timeRange.start.seconds
            chapter.duration = group.timeRange.duration.seconds
            chapter.title = extractChapterTitle(from: group)
            chapter.audiobook = audiobook
            
            modelContext.insert(chapter)
        }
    }
    
    // Playback position tracking
    func startPositionTracking() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.updatePlaybackPosition(time.seconds)
        }
    }
}
```

### Chapter Navigation

```swift
extension AudiobookPlayer {
    func skipToChapter(_ chapter: Chapter) {
        let time = CMTime(seconds: chapter.startTime, preferredTimescale: 600)
        player.seek(to: time)
    }
    
    func nextChapter() {
        guard let current = currentChapter,
              let next = audiobook.chapters.first(where: { $0.index == current.index + 1 })
        else { return }
        
        skipToChapter(next)
    }
    
    func previousChapter() {
        guard let current = currentChapter else { return }
        
        // If > 3 seconds into chapter, restart it
        if currentPosition - current.startTime > 3.0 {
            skipToChapter(current)
        } else if let previous = audiobook.chapters.first(where: { $0.index == current.index - 1 }) {
            skipToChapter(previous)
        }
    }
}
```

### Background Audio (Watch)

```swift
// Info.plist configuration required
// UIBackgroundModes: ["audio"]

// Watch-specific audio setup
func setupWatchAudioSession() {
    let session = AVAudioSession.sharedInstance()
    
    try? session.setCategory(
        .playback,
        mode: .spokenAudio,
        policy: .longFormAudio,  // Watch-specific
        options: []
    )
    
    try? session.setActive(true)
}
```

---

## Cache Architecture

### Device-Independent Cache Design

The current architecture implements a **device-independent caching system** where:

1. **Shared Metadata**: All audiobook metadata (title, author, duration, etc.) syncs via CloudKit
2. **Shared iCloud Reference**: `iCloudRelativePath` stores the canonical file location in iCloud Drive
3. **Device-Local Cache**: Each device maintains its own cache independently using computed properties

#### How It Works

```swift
// On iPhone
let audiobook = Audiobook(
    title: "My Book",
    iCloudRelativePath: "Documents/Audiobooks/mybook.m4b"
)

// expectedCachePath is computed per-device
// iPhone: /var/mobile/.../Caches/Audiobooks/{UUID}.m4b
// Watch:  /var/mobile/.../Caches/Audiobooks/{UUID}.m4b (different physical location)

// Check if cached locally (no database query needed)
if audiobook.isFileCached {
    // File exists on THIS device
    play(from: audiobook.cacheFileURL)
} else {
    // Download from iCloud to local cache
    download(from: audiobook.iCloudFileURL)
}
```

#### Key Benefits

1. **No Sync Conflicts**: Cache state is device-local, not synced
2. **Simple CloudKit Schema**: Only metadata syncs, not file paths
3. **Storage Flexibility**: Each device can cache different books based on available space
4. **Real-Time Status**: `isFileCached` checks file system directly, always accurate
5. **Easy Cleanup**: Deleting cache file automatically updates `isFileCached` status

## Storage & Caching

### File Organization

```
iOS/iPadOS (FileManager.default.cachesDirectory):
Caches/
└── Audiobooks/
    ├── {audiobook-uuid-1}.m4b
    ├── {audiobook-uuid-2}.m4b
    └── {audiobook-uuid-3}.m4b

iCloud Drive (Ubiquity Container):
iCloud.com.anarkisti.Listen-This/
└── Documents/
    └── Audiobooks/
        ├── book1.m4b
        └── book2.m4b

watchOS (FileManager.default.cachesDirectory):
Caches/
└── Audiobooks/
    ├── {audiobook-uuid-1}.m4b
    ├── {audiobook-uuid-2}.m4b
    └── {audiobook-uuid-3}.m4b

SwiftData (CloudKit synced):
- Audiobook metadata (title, author, duration)
- iCloudRelativePath (reference to iCloud file)
- Chapter metadata
- PlaybackSession (position, state)
- CacheEntry (optional cache metadata)
```

### Device-Independent Cache Architecture

Each device maintains its own local cache independently:

**Storage Strategy:**
- `iCloudRelativePath` (synced): Canonical reference to file in iCloud Drive
- `expectedCachePath` (computed): Device-specific local cache location
- `isFileCached` (computed): Real-time check of file existence
- `cacheFileURL` (computed): URL to local cache if exists

**Benefits:**
- No CloudKit sync conflicts for cache state
- Each device manages storage independently
- Real-time cache status without database queries
- Simple cleanup (delete file, status auto-updates)

---

## MVP Implementation Plan

### Phase 1: Core Foundation (MVP)

**Shared Components**
- [x] Define SwiftData schema (Audiobook, Chapter, PlaybackSession, CacheEntry)
- [x] Implement device-independent cache architecture
- [x] Create iCloudDriveProvider
- [x] Build AudiobookCacheManager
- [ ] Implement ContentSource protocol (for future providers)
- [ ] Build CloudKit sync manager

**iOS/iPadOS App**
- [x] SwiftUI app structure
- [x] Library view (browse audiobooks)
- [x] Player view with controls
- [x] Chapter navigation UI
- [x] Artwork display
- [x] File import from iCloud Drive/document picker
- [x] Context menu for audiobook management
- [x] Delete audiobook functionality (iPhone/Watch/CloudKit options)
- [x] WatchConnectivity integration for transferring audiobooks
- [ ] Full AVPlayer integration with playback
- [ ] CloudKit sync integration
- [ ] Background playback
- [ ] CarPlay integration

**watchOS App**
- [ ] SwiftUI app structure
- [ ] Library browsing
- [ ] Audiobook card UI with transfer status
- [ ] WatchConnectivity file receiver
- [ ] Cache entry management
- [ ] Download manager implementation (direct WiFi downloads)
- [ ] AVPlayer integration with background mode
- [ ] Playback controls
- [ ] CloudKit sync integration
- [ ] Cache cleanup automation

**Sync & State**
- [ ] CloudKit schema setup
- [ ] Playback position sync
- [ ] Library metadata sync
- [ ] Conflict resolution
- [ ] Offline queue

**Watch Transfer System**
- [x] WatchConnectivity manager setup
- [x] File transfer from iPhone to Watch
- [x] Transfer status badges in UI
- [x] Temporary file handling for transfers
- [x] NSFileCoordinator for iCloud file access
- [x] Transfer progress tracking
- [ ] Transfer retry on failure
- [ ] Background transfer support
- [ ] Watch receiver implementation

### Phase 2: Extended Sources

- [ ] Jellyfin provider implementation
- [ ] AudiobookShelf provider implementation
- [ ] Source selection UI
- [ ] Authentication flows
- [ ] Server configuration settings
- [ ] Download queue management
- [ ] Smart watch cache (predictive)
- [ ] Background downloads on charger
- [ ] Playback speed control
- [ ] Manual cache management UI

### Phase 3: Advanced Features

- [ ] Sleep timer
- [ ] Bookmarks and notes
- [ ] Watch complications
- [ ] Cellular downloads (Watch Series 7+)
- [ ] Advanced cache policies
- [ ] Listening statistics
- [ ] CarPlay integration
- [ ] Siri shortcuts
- [ ] Widget support

---

## Key Technical Decisions

### 1. Sync Strategy
**Decision**: CloudKit Private Database as primary sync
**Rationale**:
- Automatic Apple ID association
- Built-in conflict resolution
- No server infrastructure needed
- Works across all Apple platforms

**Alternatives Considered**:
- iCloud Key-Value Store (too limited for structured data)
- Custom server (unnecessary complexity for MVP)
- Server-only (requires constant connectivity)

### 2. Watch Architecture
**Decision**: Standalone with local caching
**Rationale**:
- True offline capability
- Better user experience
- Realistic for workout scenarios
- Reduces iPhone dependency

**Alternatives Considered**:
- Stream from iPhone (requires connection)
- Pure streaming (no offline)
- Hybrid stream/cache (too complex)

### 3. Audio Framework
**Decision**: AVFoundation (AVPlayer)
**Rationale**:
- Native chapter support
- Background playback built-in
- Streaming and local file support
- Remote command center integration
- Well-documented and stable

**Alternatives Considered**:
- AVAudioEngine (too low-level)
- Third-party frameworks (unnecessary dependency)

### 4. Persistence
**Decision**: SwiftData with CloudKit
**Rationale**:
- Modern Swift-first approach
- Native CloudKit sync support
- Type-safe model definitions with macros
- Simplified relationship management
- Query performance with predicates

**Alternatives Considered**:
- Core Data (older API, more verbose)
- Realm (external dependency)
- SQLite direct (too low-level)

### 5. Content Abstraction
**Decision**: Protocol-based providers
**Rationale**:
- Easy to add new sources
- Testable architecture
- Clear separation of concerns
- Allows different authentication methods

**Implementation Pattern**:
```swift
protocol ContentSource {
    func fetchLibrary() async throws -> [AudiobookMetadata]
    func getStreamURL(identifier: String) async throws -> URL
    func getDownloadURL(identifier: String) async throws -> URL
}
```

### 6. Cache Architecture (Updated)
**Decision**: Device-local cache with computed properties
**Rationale**:
- Eliminates CloudKit sync conflicts for cache state
- Each device manages its own storage independently
- Real-time cache status without database queries
- Simpler data model (no stored cache paths)
- Works seamlessly with @Observable macro

**Key Implementation:**
- `iCloudRelativePath`: Synced reference to canonical file location
- `expectedCachePath`: Computed per-device cache location
- `isFileCached`: Computed check of file existence
- `CacheEntry`: Optional relationship for cache metadata tracking

**Alternatives Considered**:
- Synced cache paths (conflicts when devices have different storage)
- Single source of truth approach (requires constant connectivity)
- Manual cache state management (error-prone, stale data)

### 7. Watch Connectivity & File Transfer
**Decision**: CloudKit chunked transfers for large files, optional WatchConnectivity for small files
**Rationale**:
- CloudKit chunked transfers are much faster for large audiobooks (200MB+ files)
- No device proximity required - Watch can download independently
- Chunking (200MB pieces) enables reliable transfers with resume capability
- CloudKit Private Database keeps transfers private and secure
- WatchConnectivity can be used as fallback for smaller files

**Implementation Benefits**:
- 5-10x faster than WatchConnectivity for large files
- Watch can download while charging overnight
- Works over WiFi without iPhone nearby
- Chunks can be downloaded in parallel for speed
- Reliable resume on network interruptions
- Progress tracking per chunk

**CloudKit Considerations**:
- Each user gets 1GB free CloudKit storage
- Chunks automatically deleted after successful download (or manual cleanup)
- 250MB asset limit per chunk (200MB gives headroom)
- Uses CloudKit Private Database (user-scoped, secure)

**Current Status**: CloudKit chunked transfer implementation ready. WatchConnectivity fallback available for edge cases.

### Watch Transfer Implementation Details

#### WatchConnectivityManager Architecture

The `WatchConnectivityManager` provides a centralized service for managing file transfers between iPhone and Apple Watch:

**Key Features:**
- Singleton pattern for global access
- Observable properties for UI binding
- Transfer progress tracking
- Error handling with user-friendly messages
- NSFileCoordinator integration for iCloud safety

**Transfer Process:**

```
1. User Action
   └─> Context menu "Send to Watch"

2. Pre-flight Checks
   ├─> Session activated?
   ├─> Watch paired?
   ├─> Watch app installed?
   └─> Watch reachable?

3. File Access
   ├─> Check iPhone cache first
   └─> If not cached, access iCloud with NSFileCoordinator

4. Transfer Initiation
   ├─> WCSession.transferFile()
   ├─> Set metadata (audiobook UUID, title, size)
   └─> Update transferProgress

5. Progress Monitoring
   ├─> Observable property updates
   └─> UI reflects current state

6. Completion (Watch side - planned)
   ├─> Receive file in delegate
   ├─> Save to Watch cache directory
   ├─> Update CacheEntry model
   └─> Notify completion
```

**Error Scenarios:**
- Watch not paired: "Apple Watch not paired"
- Watch app not installed: "Install app on Watch"
- File not found: "Audiobook file not available"
- Transfer failed: "Transfer failed, try again"

---

## Error Handling Strategy

### Error Categories

```swift
enum AudiobookError: Error {
    // Network errors
    case networkUnavailable
    case authenticationFailed
    case serverUnreachable
    
    // Storage errors
    case insufficientSpace
    case fileNotFound
    case downloadFailed
    
    // Playback errors
    case unsupportedFormat
    case corruptedFile
    case playbackFailed
    
    // Sync errors
    case syncConflict
    case cloudKitUnavailable
    case quotaExceeded
}
```

### User-Facing Messages

```swift
extension AudiobookError {
    var userMessage: String {
        switch self {
        case .networkUnavailable:
            return "No network connection. Content will download when WiFi is available."
        case .insufficientSpace:
            return "Not enough storage. Remove some books to free up space."
        case .syncConflict:
            return "Playback position updated on another device. Using latest position."
        // ... etc
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .networkUnavailable, .cloudKitUnavailable:
            return true  // Can retry later
        case .unsupportedFormat, .corruptedFile:
            return false  // Permanent failure
        default:
            return true
        }
    }
}
```

---

## Testing Strategy

Tests are organized by feature in `Listen This AppTests/`:

| File | Purpose |
|------|---------|
| `TestHelpers.swift` | Shared utilities (containers, factories) |
| `TransferTests.swift` | CloudKit & WatchConnectivity transfers |
| `CacheTests.swift` | Cache manager & file system |
| `ModelTests.swift` | SwiftData models & boundaries |
| `ConcurrencyTests.swift` | Thread safety, errors, performance |
| `PlaybackSyncTests.swift` | Cross-device playback sync |

### Test Categories

**Transfer Tests** - File transfers between devices and CloudKit
**Cache Tests** - Local file caching and cleanup
**Model Tests** - SwiftData relationships and queries
**Concurrency Tests** - Thread safety and error recovery
**Playback Sync Tests** - Cross-device timestamp conflict resolution

### Running Tests

```bash
# Run all tests
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17'

# Run specific suite
xcodebuild test -scheme "Listen This" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Listen This AppTests/PlaybackStateSyncTests"
```

See `Listen This AppTests/TESTING.md` for complete documentation.

---

## Performance Considerations

### Watch Constraints

| Constraint | Impact | Mitigation |
|------------|--------|------------|
| Limited storage | Can't cache many books | Max 3 books, aggressive cleanup |
| Battery drain | Downloads consume power | Only on charger, background config |
| Memory limits | Can't load large files | Stream from local file |
| Slow WiFi | Long download times | Show progress, allow cancellation |
| Processing power | Slow metadata parsing | Cache parsed data, lazy load |

### Optimization Strategies

**Artwork Handling**
```swift
// Compress artwork for Watch
func compressArtworkForWatch(_ imageData: Data) -> Data {
    guard let image = UIImage(data: imageData) else { return imageData }
    
    let targetSize = CGSize(width: 200, height: 200)  // Watch display size
    let scaledImage = image.scaled(to: targetSize)
    
    return scaledImage.jpegData(compressionQuality: 0.7) ?? imageData
}
```

**Metadata Lazy Loading**
```swift
// Don't load all metadata upfront
func fetchLibrary() async throws -> [AudiobookMetadata] {
    // Only fetch essential fields
    let books = try await provider.fetchLibrary()
    
    // Load artwork on-demand
    return books.map { book in
        var metadata = book
        metadata.artwork = nil  // Lazy load later
        return metadata
    }
}
```

**Background Sync Throttling**
```swift
// Debounce position updates
private var syncTimer: Timer?

func updatePosition(_ position: Double) {
    syncTimer?.invalidate()
    syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { _ in
        Task {
            await self.syncToCloud()
        }
    }
}
```

---

## Security & Privacy

### Authentication
- CloudKit: Automatic Apple ID authentication
- Jellyfin: API token stored in Keychain
- AudiobookShelf: API key stored in Keychain
- No passwords stored locally

### Data Privacy
- All playback data in CloudKit Private Database (user-scoped)
- Local files encrypted at rest (iOS/watchOS file system)
- No telemetry or analytics in MVP
- No data shared with third parties

### Network Security
- HTTPS required for all network providers
- Certificate pinning for custom servers (optional)
- Token refresh handling
- Secure credential storage

---

## Accessibility

### VoiceOver Support
- All UI elements labeled
- Playback position announcements
- Chapter navigation accessible
- Download progress spoken

### Dynamic Type
- All text respects user font size
- Layout adapts to larger text
- No fixed font sizes

### Reduced Motion
- Respect reduce motion preference
- Disable unnecessary animations
- Instant transitions option

---

## Localization

### Supported Languages (Phase 1)
- English (primary)

### Future Languages
- Spanish
- French
- German
- Japanese

### Localized Elements
- UI strings
- Error messages
- Time formatting
- Duration display

---

## Deployment

### Requirements
- Xcode 15.0+
- iOS 17.0+
- iPadOS 17.0+
- watchOS 10.0+
- Swift 5.9+

### App Store Metadata
- Category: Books & Reference
- Age Rating: 4+
- Privacy Nutrition Labels: Required
- App Privacy: File access, CloudKit usage

### Build Configuration
```swift
// Build settings
SWIFT_VERSION = 5.9
IPHONEOS_DEPLOYMENT_TARGET = 17.0
WATCHOS_DEPLOYMENT_TARGET = 10.0

// Capabilities required
- iCloud (CloudKit)
- Background Modes (Audio, Background Fetch)
- File Provider (iCloud Drive)
```

---

## Project Structure

```
Listen This/
├── Shared/                 # Cross-platform code (iOS + watchOS)
│   ├── Models/             # SwiftData entities synced via CloudKit
│   ├── Services/           # Business logic (playback, caching, providers)
│   ├── Managers/           # Platform managers (CloudKit, WatchConnectivity)
│   └── Views/              # Shared SwiftUI components
│
├── iOS/
│   ├── Views/              # iOS views, organized by feature (see below)
│   └── Managers/           # iOS-specific managers
│
├── Docs/                   # Architecture documentation
└── Preview/                # SwiftUI preview helpers

Listen This Watch App/
└── Watch/
    ├── Views/              # watchOS views
    └── Services/           # Watch-specific services
```

### View Organization

iOS views are grouped by **feature** rather than by type:

| Folder | Purpose |
|--------|---------|
| `Library/` | Audiobook browsing, search, deletion |
| `Player/` | Playback controls, sleep timer, chapters |
| `Settings/` | App preferences, storage, sync configuration |
| `Transfer/` | Watch file transfers and method selection |
| `Import/` | File import from iCloud Drive |

**Conventions:**
- `*View` suffix for full screens
- `*Sheet` suffix for modal presentations
- Shared components used across features go in `Shared/Views/`
- Root `ContentView.swift` stays at `iOS/Views/` level

---

## Next Steps for Implementation

### Immediate Priorities (Current Sprint)

1. **Complete AVPlayer Integration**
   - Full playback controls implementation
   - Background audio session management
   - Interruption handling (calls, route changes)
   - Remote command center integration

2. **Watch Receiver Implementation**
   - WCSession delegate on watchOS
   - File reception and cache storage
   - CacheEntry model updates
   - UI notifications on transfer completion

3. **watchOS App Foundation**
   - Basic library view
   - Audiobook card UI with transfer status
   - Cache management interface

### Short-term Goals

4. **Enhanced Playback Features**
   - Variable playback speed controls
   - Sleep timer functionality
   - Chapter navigation improvements
   - Progress persistence during interruptions

5. **CloudKit Sync Testing**
   - Multi-device sync validation
   - Conflict resolution testing
   - Offline queue implementation

### Long-term Goals

6. **Additional Content Sources**
   - Jellyfin provider implementation
   - AudiobookShelf provider implementation
   - Source selection UI

7. **Advanced Features**
   - Bookmarks and notes
   - Listening statistics
   - Watch complications
   - CarPlay integration
   - Siri shortcuts

---

## Reference Links

- [AVFoundation Programming Guide](https://developer.apple.com/documentation/avfoundation)
- [CloudKit Documentation](https://developer.apple.com/documentation/cloudkit)
- [Core Data Programming Guide](https://developer.apple.com/documentation/coredata)
- [WatchOS App Development](https://developer.apple.com/documentation/watchos-apps)
- [Background Execution](https://developer.apple.com/documentation/uikit/app_and_environment/scenes/preparing_your_ui_to_run_in_the_background)
