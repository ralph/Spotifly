# Changelog

All notable changes to Spotifly will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
