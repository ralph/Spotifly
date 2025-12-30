#!/bin/bash

# Build script for the Spotifly Rust library
# This script builds the Rust library for macOS (both arm64 and x86_64)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/../build/rust"

echo "Building Spotifly Rust library..."

# Create output directory
mkdir -p "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/include"

# Build for the current architecture in release mode
echo "Building for current architecture..."
cd "$RUST_DIR"
cargo build --release

# Determine the target triple
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="aarch64-apple-darwin"
else
    TARGET="x86_64-apple-darwin"
fi

# Copy the static library
cp "$RUST_DIR/target/release/libspotifly_rust.a" "$OUTPUT_DIR/lib/"

# Copy the header file
cp "$RUST_DIR/include/spotifly_rust.h" "$OUTPUT_DIR/include/"

echo "Build complete!"
echo "Static library: $OUTPUT_DIR/lib/libspotifly_rust.a"
echo "Header: $OUTPUT_DIR/include/spotifly_rust.h"
