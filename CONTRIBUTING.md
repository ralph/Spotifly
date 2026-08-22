# Contributing to Spotifly

## Librespot

Spotifly builds against **official librespot**. A patched fork is no longer required — the
queue APIs it once added (`PlayerEvent::SetQueue`, `QueueTrack`,
`ConnectConfig::emit_set_queue_events`, `Spirc::add_to_queue`, `Player::set_session`) have
all been upstreamed, and the two behavioral patches Spotifly carried turned out to be
artifacts of a reconnect strategy that no longer exists.

## Setup

Clone librespot as a sibling to this repository:

```bash
git clone https://github.com/librespot-org/librespot.git
```

Expected directory structure:
```
YourProjects/
├── spotifly-code/  # This repo
└── librespot/      # Official librespot
```

Then build Rust (`cd rust && ./build.sh`) and open Xcode.

### Which revision

`rust/Cargo.toml` uses **path** dependencies, so the build simply compiles whatever is
checked out in `../librespot`. There is no pin, deliberately: it makes trying a local
librespot patch a matter of checking it out and rebuilding.

The flip side is that the build follows that checkout silently, so when something behaves
oddly, check which revision is actually there:

```bash
git -C ../librespot log --oneline -1
```

Known-good: official `dev` @ `9c7d756`. When a new librespot release lands, move to that
release rather than tracking a branch.

## Contributors

- [@vitbashy](https://github.com/vitbashy) — context-aware track playback (#15)
