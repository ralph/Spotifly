# Contributing to Spotifly

## Setup

Clone this repository and open `Spotifly.xcodeproj`. That is all: there is nothing to
check out beside it and nothing to build first. The app is Swift throughout. Spotify's
Soloist plays: the app downloads it and runs it as a child process (`Spotifly/Soloist/`).
`Spotifly/SwiftLibrespot/` is the Spotify Connect controller. It plays nothing.

[DEVELOPMENT.md](DEVELOPMENT.md) covers building, testing and debugging, and
[AGENTS.md](AGENTS.md) the conventions the code follows.

## Before sending a change

- Build, and run the unit tests (`-only-testing:SpotiflyTests`; see DEVELOPMENT.md).
- Format with `swiftformat --swiftversion 6.4 .`
- Add a line to `CHANGELOG.md` under `[Unreleased]`.
- For anything touching playback or Spotify Connect, run the app. Connect can be broken
  while music still plays, and a second device (another instance, or Spotify's web
  player) is what shows it.

## Contributors

- [@vitbashy](https://github.com/vitbashy) — context-aware track playback (#15)
