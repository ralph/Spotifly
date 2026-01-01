#!/bin/bash

# Build script for the Spotifly Rust library
# This script builds the Rust library for macOS, iOS, and iOS Simulator (arm64 only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/../build/rust"

# Use rustup-installed cargo if available, otherwise use system cargo
if [ -f "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Determine what platforms to build for based on PLATFORM_NAME environment variable (set by Xcode)
# If not set, build for current platform (macOS)
PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
SDK_NAME="${SDK_NAME:-$PLATFORM_NAME}"

echo "Building Spotifly Rust library for platform: $PLATFORM_NAME"

# Create output directory
mkdir -p "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/include"

cd "$RUST_DIR"

# Build for the appropriate target based on platform
case "$PLATFORM_NAME" in
    macosx*)
        echo "Building for macOS (aarch64)..."
        cargo build --release --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/release/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphoneos*)
        echo "Building for iOS device (aarch64)..."
        cargo build --release --target aarch64-apple-ios
        cp "$RUST_DIR/target/aarch64-apple-ios/release/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphonesimulator*)
        echo "Building for iOS Simulator (aarch64)..."
        cargo build --release --target aarch64-apple-ios-sim
        cp "$RUST_DIR/target/aarch64-apple-ios-sim/release/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    *)
        echo "Unknown platform: $PLATFORM_NAME, defaulting to macOS"
        cargo build --release --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/release/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
esac

# Copy the header file
cp "$RUST_DIR/include/spotifly_rust.h" "$OUTPUT_DIR/include/"

echo "Build complete!"
echo "Static library: $OUTPUT_DIR/lib/libspotifly_rust.a"
echo "Header: $OUTPUT_DIR/include/spotifly_rust.h"
