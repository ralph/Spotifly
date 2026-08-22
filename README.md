# Spotifly

A lightweight Spotify player for macOS.

**[Website](https://ralph.github.io/Spotifly/)** · **[Download](https://github.com/ralph/Spotifly/releases/latest)**

## Screenshots

### Album View
![Album View](images/screenshot-album-view.png)

### Miniplayer
![Miniplayer](images/screenshot-miniplayer.png)

## Installation

### Direct Download

1. Download the [latest release](https://github.com/ralph/spotifly/releases/latest)
2. Extract the ZIP file
3. Move `Spotifly.app` to your Applications folder
4. Open Spotifly from Applications

### Homebrew

```bash
brew install ralph/spotifly/spotifly
```

## Requirements

- macOS 26.2 or later
- Spotify Premium account

## Features

- Lightweight and fast
- Native macOS app built with SwiftUI
- A real Spotify Connect device — play here, or drive your phone and speakers from here
- Your library: playlists, albums, followed artists and liked songs
- Queue management with drag-and-drop reordering
- Playback controls
- Search functionality
- Favorites management

## Signing In

1. Open Spotifly
2. Click **Connect with Spotify**
3. Authorize Spotifly in the browser tab that opens

That is the whole setup. There is no Client ID to create and nothing to register: Spotifly authorizes with Spotify's own desktop client id, and the one authorization both signs you in and makes this Mac available as a Spotify Connect device.

Earlier versions did ask for a Client ID, because they talked to the Spotify Web API and it will not answer without an app registered in the developer dashboard. Spotifly now uses the same APIs Spotify's own clients do, so that requirement is gone. If you created an app just for Spotifly, you can delete it.

## Keyboard Shortcuts

### Playback

| Shortcut | Action |
|----------|--------|
| Space | Play / Pause |
| ⌘ → | Next track |
| ⌘ ← | Previous track |
| ⌘ L | Like / Unlike current track |

### Navigation

| Shortcut | Action |
|----------|--------|
| ⌘ 1 | Go to Favorites |
| ⌘ 2 | Go to Playlists |
| ⌘ 3 | Go to Albums |
| ⌘ 4 | Go to Artists |
| ⌘ F | Focus search field |
| ⌘ R | Refresh (on startpage) |

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for build instructions and architecture documentation.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
