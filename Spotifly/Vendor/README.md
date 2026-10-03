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

The sources stay as released, so the three warnings they raise under the project's
settings are turned off for them alone, per file in the synced folder's exceptions
(`additionalCompilerFlagsByRelativePath` in the project):

- `-Wno-shorten-64-to-32` on every `.c` file. Both libraries use `long` as their
  general integer and store it in `int` fields: a bit read of at most 32 bits, a
  block size, an error code. On a 64-bit Mac each such store is a narrowing, 211 in
  all. Xiph's own builds don't enable this warning; Xcode does.
- `-Wno-unused-variable -Wno-strict-prototypes` on `vorbisfile.c`, for an `fpu`
  variable used only on x86 and a function declared `()` rather than `(void)`.

Every other warning still shows for these files. A file added here needs the same
flag.

Swift access goes through `Spotifly/SwiftLibrespot/Audio/VorbisDecoder.swift`,
which wraps `libvorbisfile`'s streaming API.
