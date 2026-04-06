# Changelog

All notable changes to Spotifly will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Favorites now resolve via batched `/me/tracks/contains` checks for the tracks actually shown in album, playlist, queue, search, and now-playing views instead of depending on a full favorites preload
- Saving and removing favorite tracks now uses Spotify's saved-tracks endpoint correctly, so heart toggles persist again across Spotify clients

## [1.2.5] - 2026-03-11

### Added
- French localization (merci [@statisticalyquiet](https://github.com/statisticalyquiet)! 🇫🇷🥐)
- Shuffle mode

### Fixed
- Fix silent failure (no audio) when playing a new album/playlist immediately after the previous one ends, if a network reconnect races the track load (audio key timeout left player in a broken state with no context)

## [1.2.4] - 2026-03-06

### Fixed
- Fix connecting to Spotify Connect enabled speakers
- Bug fixes and performance improvements

## [1.2.3] - 2026-02-27

### Changed
- AirPlay audio routing rewritten to use `AVAudioEngine` with a custom `AudioRenderer` for more reliable AirPlay device support
- Spotify Connect session stability improvements: better soft reconnect handling, reduced playback jolts during network recovery
- Use 300px album art instead of 640px across the app — reduces download size and eliminates OS-side JPEG transcode overhead in Now Playing (largest display size is 200pt)

### Fixed
- Mini player mode no longer breaks when a fullscreen notification triggers a window state change
- Significantly reduced CPU usage during playback: split Now Playing metadata updates into full vs position-only paths, lowered seek bar update frequency, stopped unnecessary drift-check writes, and removed redundant per-second `currentPositionMs` updates (~94% reduction in active CPU samples vs 1.2.2)

## [1.2.2] - 2026-02-08

### Added
- Context-aware track playback: double-tap a track in an album, playlist, or favorites to play from that position within the context (thanks [@vitbashy](https://github.com/vitbashy)!)

### Changed
- Adapt to [Spotify Web API breaking changes (February 2026)](https://developer.spotify.com/documentation/web-api/references/changes/february-2026): migrate removed endpoints, update playlist response structure, and replace batch fetches with parallel individual requests

### Fixed
- Double-tapping a queue track when playing radio (no context URI) no longer silently does nothing — falls back to single track playback
- Clicking a track card in search results before any playback has occurred now properly initializes the player first

### Removed
- Artist top tracks section (endpoint removed by Spotify with no alternative)
- New Releases section (endpoint removed by Spotify with no alternative)
- Artist follower counts, user email/country/follower display (fields removed from API responses)

## [1.2.1] - 2026-02-06

### Added
- 🎉 Spotify Connect support — Spotifly now shows up as a real Spotify Connect device
- Seamless playback transfer between Spotifly and other Spotify devices (phone, desktop, etc.)
- Automatic session reconnection with exponential backoff

### Changed
- All playback controls (play, pause, seek, volume, next, previous) now go through Spotify Connect for proper state sync across devices

### Fixed
- Remote playback state (queue, position, track) now shows immediately on launch
- Playback state updates correctly in the UI when controlled locally

## [1.2.0] - 2026-01-12

### Added
- User-facing README with screenshots, download links, and setup guide
- DEVELOPMENT.md with architecture and build documentation
- Images directory with screenshots for GitHub page

### Changed
- Releases now published to main repo (ralph/spotifly) instead of homebrew-spotifly
- Updated release process documentation in CLAUDE.md

## [1.1.7] - 2026-01-09

### Added
- Queue editing: Edit queue like playlists with drag-and-drop reordering and track removal
- Fixed queue header with song count, scroll-to-current button, clear queue button, and edit mode toggle
- Only unplayed tracks can be reordered or removed from the queue
- Real-time queue updates: when player advances during editing, track is automatically removed from edit list
- New Rust FFI functions for queue manipulation: `spotifly_remove_from_queue`, `spotifly_move_queue_item`, `spotifly_clear_upcoming_queue`

## [1.1.6] - 2026-01-07

### Changed
- Client ID is now mandatory: removed optional toggle, users must provide their own Spotify Client ID
- Added link to setup instructions on login screen
- Added note about using existing Spotify apps with the required redirect URI

## [1.1.5] - 2026-01-07

### Added
- Custom Client ID support: Users can now provide their own Spotify Client ID on the login screen via a checkbox and input field, useful for working around Spotify API restrictions

## [1.1.4] - 2026-01-05

### Added
- Streaming quality preferences (Normal, High, Very High) in Preferences window
- Sleep-proof token refresh: tokens are now validated lazily on-demand instead of background timers

### Fixed
- Fixed favorite indicator not updating correctly after toggling
- Fixed token expiration handling when Mac wakes from sleep

## [1.1.3] - 2026-01-05

### Changed
- Use market from OAuth token instead of hardcoded US for proper regional content
- Optimized album loading: reduced page size and prevented duplicate fetches
- Moved service state to centralized AppStore for consistent architecture
- Reduced artist pagination limit to 20 for better performance

### Fixed
- Fixed artist pagination issues
- Auto-select first item in library list views for better UX

## [1.1.2] - 2026-01-04

### Fixed
- Mini player bugfixes and performance improvements

## [1.1.1] - 2026-01-04

### Added
- Playlist management (edit, rename, delete, reorder tracks)

### Fixed
- Bug fixes and performance improvements

## [1.1.0] - 2026-01-03

### Added
- 3-dot context menu on tracks with actions:
  - Play Next
  - Add to Queue
  - Start Song Radio
  - Go to Artist
  - Go to Album
  - Share (copies link to clipboard)
- Like/Unlike current track with Cmd+L keyboard shortcut
- Menu bar entries for all keyboard shortcuts (Playback and Navigate menus)
- Heart indicator on tracks showing favorite status

### Fixed
- Bug fixes and performance improvements

## [1.0.1] - 2026-01-02

### Fixed
- Fixed crash on login in release builds by embedding Spotify client credentials in the app bundle

### Changed
- Updated build process to automatically inject credentials from environment variables

## [1.0.0] - 2026-01-01

### Added
- Lightweight Spotify player for macOS using librespot
- Recently played tracks, albums, artists, and playlists
- Queue management with drag-to-reorder
- Playback controls with progress bar
- Search functionality across tracks, albums, artists, playlists
- Favorites management
- Mini player mode
- AirPlay support
- Native macOS app with Spotify Web API integration
