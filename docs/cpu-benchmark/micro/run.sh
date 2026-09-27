#!/bin/bash
# Decode speed of the vendored libvorbis under several sets of compiler flags,
# and CommonCrypto's AES-CTR throughput. Needs ffmpeg for the test file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$HERE/../../../Spotifly/Vendor"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Four minutes of stereo pink noise with a tone, through ffmpeg's own Vorbis
# encoder at its highest quality (about 250 kbps).
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anoisesrc=color=pink:sample_rate=44100:duration=240:amplitude=0.3" \
    -f lavfi -i "sine=frequency=330:sample_rate=44100:duration=240" \
    -filter_complex "[0][1]amerge=inputs=2,pan=stereo|c0=c0+0.5*c1|c1=c0-0.3*c1" \
    -c:a vorbis -strict -2 -q:a 10 "$WORK/test.ogg"

SOURCES=("$VENDOR/libogg/src/bitwise.c" "$VENDOR/libogg/src/framing.c" "$VENDOR"/libvorbis/lib/*.c)
INCLUDES=(-I"$VENDOR/libogg/include" -I"$VENDOR/libvorbis/include" -I"$VENDOR/config" -I"$VENDOR/libvorbis/lib")
for flags in "-Os" "-O2" "-O3" "-O3 -mcpu=apple-m1" "-Ofast -mcpu=apple-m1" "-O3 -flto -mcpu=apple-m1"; do
    # shellcheck disable=SC2086 # the flags are meant to split
    clang $flags -w "${INCLUDES[@]}" "$HERE/vorbis_decode.c" "${SOURCES[@]}" -o "$WORK/vorbis_decode"
    printf "%-28s" "$flags"
    "$WORK/vorbis_decode" "$WORK/test.ogg"
done

clang -O2 "$HERE/aes_ctr.c" -o "$WORK/aes_ctr"
"$WORK/aes_ctr"
