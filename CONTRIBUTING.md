# Contributing to Spotifly

## Setup

Clone this repository and open `Spotifly.xcodeproj`. That is all: there is nothing to
check out beside it and nothing to build first. Playback and Spotify Connect are
implemented in Swift under `Spotifly/SwiftLibrespot/`, and the Ogg Vorbis decoder is
vendored C under `Spotifly/Vendor/`. Earlier versions built against a sibling
[librespot](https://github.com/librespot-org/librespot) checkout through a Rust bridge;
neither is needed any more.

[DEVELOPMENT.md](DEVELOPMENT.md) covers building, testing and debugging, and
[AGENTS.md](AGENTS.md) the conventions the code follows.

## Before sending a change

- Build, and run the unit tests (`-only-testing:SpotiflyTests`; see DEVELOPMENT.md).
- Format with `swiftformat --swiftversion 6.3 .`
- Add a line to `CHANGELOG.md` under `[Unreleased]`.
- For anything touching playback or Spotify Connect, run the app. Connect can be broken
  while music still plays, and a second device (another instance, or Spotify's web
  player) is what shows it.

## Contributors

- [@vitbashy](https://github.com/vitbashy) — context-aware track playback (#15)
