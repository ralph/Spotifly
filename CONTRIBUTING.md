# Contributing to Spotifly

## Librespot Fork Requirement

This project uses a **modified fork of librespot**, not the official repository.

| Repository | URL | Status |
|------------|-----|--------|
| Official librespot | `github.com/librespot-org/librespot` | Will NOT work |
| Required fork | `github.com/ralph/librespot` | Required |

The fork adds `PlayerEvent::SetQueue` and `QueueTrack` types for queue state updates. Using the official librespot will cause build errors.

## Setup

Clone the fork as a sibling to this repository:

```bash
git clone -b spotifly-dev https://github.com/ralph/librespot.git
```

Expected directory structure:
```
YourProjects/
├── repos/          # This repo
└── librespot/      # Ralph's fork
```

Then build Rust (`cd rust && ./build.sh`) and open Xcode.

## Contributors

- [@vitbashy](https://github.com/vitbashy) — context-aware track playback (#15)
