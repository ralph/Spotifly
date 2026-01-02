#!/bin/bash

# Script to inject environment variables into Info.plist during build
# This ensures sensitive values aren't checked into git

set -e

INFO_PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"

# Only proceed if building for Release or if Info.plist exists
if [ ! -f "$INFO_PLIST" ]; then
    echo "Info.plist not found at: $INFO_PLIST"
    echo "Skipping environment variable injection (this is expected during initial build phases)"
    exit 0
fi

# Inject Spotify Client ID from environment
if [ -n "$SPOTIFY_CLIENT_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :SpotifyClientID string $SPOTIFY_CLIENT_ID" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SpotifyClientID $SPOTIFY_CLIENT_ID" "$INFO_PLIST"
    echo "✓ Injected SPOTIFY_CLIENT_ID into Info.plist"
else
    echo "⚠️  Warning: SPOTIFY_CLIENT_ID not set"
    echo "   The app will crash on login without this value."
    echo "   Set it in .envrc or as an environment variable."
fi
