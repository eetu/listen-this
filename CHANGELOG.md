# Changelog

User-facing changes, newest first. Each heading is an App Store version. Git
tags mark Xcode Cloud builds and don't map one-to-one: several tags can share a
version (see the tags listed under each release).

Each version's lists are written to paste straight into App Store Connect's
"What's New in This Version" field.

## Unreleased

## 1.3.1 — 2026-09-29

Tags: `v1.3.1` (build 6)

### Changed
- Audiobookshelf setup tests the connection automatically as you type — no button and no Enable switch; it turns on once the connection works
- The server address no longer needs `http://` or `https://`; it's added for you
- Editing the server address or API key keeps the working setup until the new one connects
- A Remove Server button clears the Audiobookshelf setup from all your devices
- Opening Audiobookshelf settings checks that the server is reachable, without switching anything off when you're away from it
- The API key is only sent once an Audiobookshelf server answers at the address, so a mistyped address never receives it
- A note shows when a local http:// server receives the API key unencrypted

### Fixed
- The first connection to a home-network server failed until tested again after allowing Local Network access
- iOS offered to save the Audiobookshelf API key as a password

## 1.3.0 — 2026-09-27

Tags: `v1.3.0` (build 5)

### Added
- Sort your Audiobookshelf library by recently added, title, author or duration — tap again to reverse the order
- A paused iPhone, iPad or Watch now follows along while you listen on another device

### Fixed
- Playback position could jump back to an older spot when switching between iPhone, iPad and Watch
- Pausing could save another device's position instead of where you stopped
- Play and pause could briefly freeze the app

## 1.2.0 — 2026-07-29

Tags: `v1.2.0`, `v1.2.1`, `v1.2.2` (all build 4)

### Added
- Apple Watch can download books directly from your Audiobookshelf server over WiFi, without the iPhone
- Download progress now appears on Watch library rows
- Partly downloaded books are marked and resume where they stopped instead of starting over

### Fixed
- Audiobookshelf servers on a local network using http:// couldn't be reached at all — on iPhone or Watch
- A download interrupted partway could show as complete and play silence past a certain point
- Cancelling a download to Watch didn't stop it — the book finished downloading and was saved anyway
- Removing a download on Watch left the iPhone showing it as sent, with no way to send it again
- The Transfer to Watch screen had no way to close it while a transfer was running
- Temporary iCloud files were left behind when a book reached the Watch by another route
- The Watch player's artwork background stopped short of the bottom of the screen (`v1.2.1`)
- The iPhone speed slider went up to 2.5x although playback tops out at 2.0x (`v1.2.2`)

## 1.1.1 — 2026-06-28

Tags: `v1.1.1` (build 3)

### Fixed
- Player controls scale properly with larger text sizes
- The Watch progress bar could overflow its track
- Artwork could shift the Watch player layout
- Sleep timer buttons could be pushed off screen at large text sizes

## 1.1.0 — 2026-06-27

Tags: `v1.1.0` (build 2)

### Added
- Transfer progress on the Watch: percentage, speed and time remaining
- "Transfer While Charging Only" option to save Watch battery
- The current chapter is highlighted in the chapter list

### Fixed
- Watch transfers showed a frozen 0% until they finished
- The Digital Crown kept jumping back to volume, so the chapter list couldn't be scrolled
- The send-to-Watch button could offer a book that was already uploaded
- Audiobookshelf cover art didn't load
- Missing accessibility labels and Dynamic Type support on playback controls

## 1.0.1 — 2026-05-25

Tags: `v1.0.5` (build 1)

### Changed
- Audiobookshelf setup opens directly from Import, and failed connections explain what to check

### Fixed
- Audiobookshelf streaming used an endpoint that could fail for some books
- The first connection test to a home-network server failed while iOS asked for Local Network access

## 1.0 — 2026-05-14

Tags: `v1.0.0`–`v1.0.4` (all build 1; `v1.0.1`–`v1.0.4` were App Store review fixes)

### Added
- Import M4B audiobooks from Files or iCloud Drive, or with Open With from other apps
- Chapter navigation, skip controls and adjustable playback speed
- Sleep timer with presets or end of chapter
- Background playback with Now Playing controls
- Home Screen and Watch widgets showing the current book
- Apple Watch app with offline playback; send books from iPhone
- Audiobookshelf server support for streaming and downloading
- Library and playback position sync across devices via iCloud

### Fixed
- Deleting an audiobook could crash the app (`v1.0.1`)
