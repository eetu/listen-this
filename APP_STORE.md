# App Store Submission

## App Name
Listen This

## Subtitle
M4B Audiobook Player

## Description

A simple, focused audiobook player for your M4B files. Listen on iPhone, iPad, or Apple Watch — your progress syncs automatically via iCloud.

**FEATURES**

• Import M4B audiobooks from Files or iCloud Drive
• Chapter navigation with skip controls
• Adjustable playback speed (0.5x - 2.0x)
• Sleep timer with presets or end of chapter
• Background playback with Now Playing controls
• Home Screen widget showing current book

**APPLE WATCH**

Listen without your iPhone. Download audiobooks to your Watch for offline playback during workouts, walks, or whenever you leave your phone behind — either sent across from your iPhone, or downloaded straight from your Audiobookshelf server over WiFi with no iPhone involved. Downloads continue in the background and pick up where they left off if interrupted.

**AUDIOBOOKSHELF**

Connect to your self-hosted Audiobookshelf server to stream your library or download books for offline listening, on iPhone and Apple Watch alike. Servers on your home network work over plain http, so there's nothing extra to set up.

**SYNC**

Your library and playback position sync automatically across all your devices via iCloud. Start listening on your iPhone, continue on your iPad, finish on your Watch.

## What's New (1.2.0)

Paste into the "What's New in This Version" field:

**New**
- Apple Watch can download books directly from your Audiobookshelf server over WiFi, without the iPhone
- Download progress now appears on Watch library rows
- Partly downloaded books are marked and resume where they stopped instead of starting over

**Fixed**
- Audiobookshelf servers on a local network using http:// couldn't be reached at all — on iPhone or Watch
- A download interrupted partway could show as complete and play silence past a certain point
- Cancelling a download to Watch didn't stop it — the book finished downloading and was saved anyway
- Removing a download on Watch left the iPhone showing it as sent, with no way to send it again
- The Transfer to Watch screen had no way to close it while a transfer was running
- Temporary iCloud files were left behind when a book reached the Watch by another route

## Keywords
audiobook, m4b, player, listen, books, audio, watch, offline, chapters, audiobookshelf

## Category
- Primary: Books
- Secondary: Entertainment

## Screenshots
See `Screenshots/` folder:
- iPhone: Library, Player, Import, Settings
- iPad: Player with split view
- Apple Watch: Library, Player
