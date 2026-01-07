# Spotifly

A Swift/SwiftUI app that integrates with Spotify using the [librespot](https://github.com/librespot-org/librespot) Rust library for OAuth authentication.

## Installation

Install via Homebrew from [homebrew-spotifly](https://github.com/ralph/homebrew-spotifly):

```bash
brew tap ralph/spotifly
brew install spotifly
```

## Architecture

This project demonstrates Swift 6.2's C interoperability to call Rust code:

```
┌─────────────────────┐
│     SwiftUI App     │
│   (ContentView)     │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│   SpotifyAuth.swift │
│  (Swift wrapper)    │
└──────────┬──────────┘
           │ C FFI
┌──────────▼──────────┐
│   SpotiflyRust      │
│  (C module map)     │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│   libspotifly_rust  │
│  (Rust static lib)  │
│  + librespot-oauth  │
└─────────────────────┘
```

## Prerequisites

- Xcode 26.2+ (Swift 6.2)
- Rust toolchain (install via [rustup](https://rustup.rs/))
- macOS 26.2+ (or adjust deployment target)

## Building

### 1. Build the Rust library first

```bash
cd rust
./build.sh
```

This compiles the Rust code into a static library at `build/rust/lib/libspotifly_rust.a`.

### 2. Build the Swift app

Open `Spotifly.xcodeproj` in Xcode and build (⌘B), or:

```bash
xcodebuild -scheme Spotifly -destination 'platform=macOS' build
```

## Project Structure

```
Spotifly/
├── Spotifly/                    # Swift source files
│   ├── SpotiflyApp.swift        # App entry point
│   ├── ContentView.swift        # Main UI with OAuth button
│   └── SpotifyAuth.swift        # Swift wrapper for Rust FFI
├── rust/                        # Rust library source
│   ├── Cargo.toml               # Rust dependencies
│   ├── src/lib.rs               # Rust FFI implementation
│   ├── include/spotifly_rust.h  # C header for FFI
│   └── build.sh                 # Build script
├── build/rust/                  # Built Rust artifacts
│   ├── lib/libspotifly_rust.a   # Static library
│   └── include/                 # Headers + module map
└── Spotifly.xcodeproj           # Xcode project
```

## How it Works

1. **Rust Layer** (`rust/src/lib.rs`):
   - Uses `librespot-oauth` crate for Spotify OAuth with PKCE
   - Exposes C-compatible functions (`extern "C"`)
   - Manages async Tokio runtime internally

2. **C Header** (`rust/include/spotifly_rust.h`):
   - Declares the C function signatures
   - Used by Swift via a module map

3. **Swift Wrapper** (`Spotifly/SpotifyAuth.swift`):
   - Imports the `SpotiflyRust` C module
   - Provides a Swift-native async API using `@globalActor`
   - Follows Swift 6.2 concurrency best practices

4. **SwiftUI** (`Spotifly/ContentView.swift`):
   - Uses `@Observable` for state management
   - `@MainActor` isolated view model
   - Initiates OAuth flow on button press

## OAuth Flow

When you click "Connect with Spotify":

1. The Rust library starts a local HTTP server on `http://127.0.0.1:8888`
2. Opens Spotify's OAuth page in your browser
3. After authentication, Spotify redirects to the local server
4. The library captures the authorization code and exchanges it for tokens
5. Access token is returned to Swift and displayed in the UI

## Xcode Build Settings

The following settings are configured in the Xcode project:

- **Library Search Paths**: `$(PROJECT_DIR)/build/rust/lib`
- **Swift Include Paths**: `$(PROJECT_DIR)/build/rust/include`
- **Other Linker Flags**: 
  - `-lspotifly_rust`
  - `-framework SystemConfiguration`
  - `-framework Security`
  - `-framework CoreFoundation`

## Notes

- The app sandbox is enabled, but you may need to disable it or add network entitlements for the OAuth flow to work properly
- Currently builds for macOS only; iOS would require cross-compilation of the Rust library
- Uses Spotify's official client ID from librespot

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
