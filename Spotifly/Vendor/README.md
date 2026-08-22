# Vendored C dependencies

Reference implementations of the Ogg Vorbis codec, vendored so the app can
decode Spotify audio natively without a package manager. Sources are
unmodified except for the removal of the standalone utility programs that
carry their own `main()` (`barkmel.c`, `psytune.c`, `tone.c`).

- `libogg/` — [libogg 1.3.5](https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz),
  only `src/bitwise.c`, `src/framing.c`, and `include/ogg/*.h`.
- `libvorbis/` — [libvorbis 1.3.7](https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz),
  the full `lib/` directory (minus the utilities above) and `include/vorbis/*.h`.
- `config/ogg/config_types.h` — hand-written replacement for the header
  autoconf normally generates, fixed to Apple LP64 targets.

Both libraries are BSD-style licensed; see the `COPYING-*.txt` file in each folder.
The Xcode target compiles everything under this directory through its synced
folder membership; the include paths are set in `HEADER_SEARCH_PATHS`.

Swift access goes through `Spotifly/SwiftLibrespot/Audio/VorbisDecoder.swift`,
which wraps `libvorbisfile`'s streaming API.
