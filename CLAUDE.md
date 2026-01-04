# Spotifly

Spotify client for macOS (and maybe later iPad and iOS).

## Tech Stack

- **Language**: Swift 6.2 with strict concurrency enabled
- **Target Platforms**: Latest Apple OSes only (macOS, iOS, iPadOS)
- **UI Framework**: SwiftUI

## Development Guidelines

- Use Swift 6.2 strict concurrency features (`Sendable`, `@MainActor`, async/await)
- No backwards compatibility needed - target only the latest OS versions
- Format all Swift code with: `swiftformat --swiftversion 6.2 .`

## Network Request Logging

All Spotify API network requests must include debug logging. Add a log statement after constructing the URL string, wrapped in `#if DEBUG`:

```swift
let urlString = "\(baseURL)/endpoint"
#if DEBUG
    apiLogger.debug("[METHOD] \(urlString)")
#endif
```

- Use the appropriate HTTP method: `[GET]`, `[POST]`, `[PUT]`, `[DELETE]`
- The `apiLogger` is defined at the top of `SpotifyAPI.swift`
- Logs are only compiled in debug builds (zero overhead in release)
