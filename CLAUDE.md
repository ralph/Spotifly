# Spotifly

Spotify client for macOS (and maybe later iPad and iOS).

## Tech Stack

- **Language**: Swift 6.2 with strict concurrency enabled
- **Target Platforms**: Latest Apple OSes only (macOS, iOS, iPadOS)
- **UI Framework**: SwiftUI

## Development Guidelines

- Use Swift 6.2 strict concurrency features (`Sendable`, `@MainActor`, async/await)
- No backwards compatibility needed - target only the latest OS versions
