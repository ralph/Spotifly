#!/bin/bash

# Build script for the Spotifly Rust library
# This script builds the Rust library for macOS, iOS, and iOS Simulator (arm64 only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/../build/rust"
LIBRESPOT_DIR="$SCRIPT_DIR/../../librespot"

# The integration currently depends on the patched librespot in the sibling checkout:
# next/previous must use local play intent rather than the deferred remote-facing
# ConnectState. Cargo resolves librespot through path dependencies, so the build silently
# follows whichever branch happens to be checked out there.
#
# Assert the patch is present rather than pinning a commit hash: the check then survives
# rebases of spotifly-dev onto newer upstream revisions. Once the migration to unmodified
# librespot is settled, this is replaced by a real git+rev pin.
#
# Set SPOTIFLY_ALLOW_UNPATCHED_LIBRESPOT=1 to build against official librespot on purpose.
# That is how the open question gets answered: whether the patch is still needed now that
# the Player no longer outlives its Session. The override is deliberately loud, so a build
# that skipped the check is never mistaken for a normal one.
if [ ! -d "$LIBRESPOT_DIR" ]; then
    echo "error: librespot checkout not found at $LIBRESPOT_DIR" >&2
    echo "       See CONTRIBUTING.md for the expected directory layout." >&2
    exit 1
fi
if [ "${SPOTIFLY_ALLOW_UNPATCHED_LIBRESPOT:-0}" = "1" ]; then
    echo "═══════════════════════════════════════════════════════════════════"
    echo " SPOTIFLY_ALLOW_UNPATCHED_LIBRESPOT=1 — patch check SKIPPED"
    echo " Building against whatever is checked out in:"
    echo "   $LIBRESPOT_DIR"
    if command -v git >/dev/null 2>&1; then
        echo "   branch: $(git -C "$LIBRESPOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        echo "   commit: $(git -C "$LIBRESPOT_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
    fi
    echo "═══════════════════════════════════════════════════════════════════"
elif ! grep -q "play_status.is_playing()" "$LIBRESPOT_DIR/connect/src/spirc.rs"; then
    echo "error: $LIBRESPOT_DIR is missing the required librespot patch." >&2
    echo "       Check out the spotifly-dev branch (see CONTRIBUTING.md)," >&2
    echo "       or set SPOTIFLY_ALLOW_UNPATCHED_LIBRESPOT=1 to build without it." >&2
    exit 1
fi

# Add cargo to PATH - check rustup first, then Homebrew
if [ -f "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
elif [ -f "/opt/homebrew/bin/cargo" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

# Determine what platforms to build for based on PLATFORM_NAME environment variable (set by Xcode)
# If not set, build for current platform (macOS)
PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
SDK_NAME="${SDK_NAME:-$PLATFORM_NAME}"

# Determine build configuration from Xcode's CONFIGURATION variable
# Default to Release if not set (e.g., when running build.sh manually)
CONFIGURATION="${CONFIGURATION:-Release}"

if [ "$CONFIGURATION" = "Debug" ]; then
    CARGO_FLAGS=""
    BUILD_TYPE="debug"
    echo "Building Spotifly Rust library (DEBUG) for platform: $PLATFORM_NAME"
else
    CARGO_FLAGS="--release"
    BUILD_TYPE="release"
    echo "Building Spotifly Rust library (RELEASE) for platform: $PLATFORM_NAME"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/include"

cd "$RUST_DIR"

# Enable hardware-accelerated AES, NEON, and SHA on Apple Silicon.
# - target-cpu=apple-m1: enables ARM crypto target features (aes, neon, sha2)
#   so cpufeatures can resolve at compile time instead of runtime detection.
#   Uses apple-m1 (baseline Apple Silicon) rather than "native" so
#   cross-compiled iOS builds also get hardware crypto.
# - --cfg aes_armv8: the `aes` crate 0.8 gates its ARMv8 intrinsics backend
#   behind this cfg flag. Without it, it falls back to software fixslice
#   which is ~10x slower than ARM crypto extensions.
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=apple-m1 --cfg aes_armv8"

# Build for the appropriate target based on platform
case "$PLATFORM_NAME" in
    macosx*)
        echo "Building for macOS (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphoneos*)
        echo "Building for iOS device (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-ios
        cp "$RUST_DIR/target/aarch64-apple-ios/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphonesimulator*)
        echo "Building for iOS Simulator (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-ios-sim
        cp "$RUST_DIR/target/aarch64-apple-ios-sim/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    *)
        echo "Unknown platform: $PLATFORM_NAME, defaulting to macOS"
        cargo build $CARGO_FLAGS --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
esac

# Copy the header file and modulemap
cp "$RUST_DIR/include/spotifly_rust.h" "$OUTPUT_DIR/include/"
cp "$RUST_DIR/include/module.modulemap" "$OUTPUT_DIR/include/"

echo "Build complete!"
echo "Static library: $OUTPUT_DIR/lib/libspotifly_rust.a"
echo "Header: $OUTPUT_DIR/include/spotifly_rust.h"
