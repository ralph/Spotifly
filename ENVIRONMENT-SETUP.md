# Environment Variables Setup

## Overview

Sensitive configuration values (like Spotify API credentials) are **NOT** checked into git. Instead, they are automatically injected during the build process from environment variables.

## How It Works

1. **Development**: Environment variables are set in `.envrc` (which is in `.gitignore`)
2. **Build Time**: A build script (`Scripts/inject-env-to-plist.sh`) reads these environment variables and injects them into the app's Info.plist
3. **Runtime**: The app reads the values from its Info.plist

## Required Environment Variables

The following environment variables must be set for the app to build and run:

- `SPOTIFY_CLIENT_ID` - Your Spotify app client ID
- (Optional) `SPOTIFY_CLIENT_SECRET` - If needed in the future

## Setup Instructions

### For Local Development

1. Copy `.envrc.example` to `.envrc` (or just use the existing `.envrc`)
2. Add your Spotify credentials to `.envrc`:
   ```bash
   export SPOTIFY_CLIENT_ID="your-client-id-here"
   export SPOTIFY_CLIENT_SECRET="your-client-secret-here"
   ```
3. If using direnv: `direnv allow .`
4. If not using direnv: `source .envrc` before building

### For CI/CD or Release Builds

Set the environment variables in your CI/CD system or shell before running the build:

```bash
export SPOTIFY_CLIENT_ID="your-client-id-here"
./release.sh
```

Or use the existing `.envrc`:
```bash
source .envrc
./release.sh
```

## Files Involved

- `.envrc` - Contains environment variables (in `.gitignore`)
- `Scripts/inject-env-to-plist.sh` - Build script that injects env vars into Info.plist
- `Spotifly/SpotifyConfig.swift` - Reads values from Info.plist at runtime
- `Spotifly/Info.plist` - Source file (no secrets), gets populated during build

## What Gets Committed to Git

✅ **Committed:**
- `Scripts/inject-env-to-plist.sh` - The injection script
- `Spotifly/Info.plist` - WITHOUT sensitive values
- `Spotifly/SpotifyConfig.swift` - Code that reads from Info.plist

❌ **NOT Committed:**
- `.envrc` - Contains actual credentials
- Built app bundles - Only source code is committed

## Verifying It Works

After building, check that the secret was injected but not in the source:

```bash
# Build the app
xcodebuild -scheme Spotifly -configuration Release build

# Verify built app HAS the client ID
/usr/libexec/PlistBuddy -c "Print :SpotifyClientID" \
  ~/Library/Developer/Xcode/DerivedData/Spotifly-*/Build/Products/Release/Spotifly.app/Contents/Info.plist

# Verify source Info.plist DOES NOT have the client ID
/usr/libexec/PlistBuddy -c "Print :SpotifyClientID" \
  Spotifly/Info.plist
# ^ Should fail with "Does Not Exist" - this is correct!
```

## Troubleshooting

**Problem:** App crashes on login with "Missing Spotify Client ID"

**Solution:** Make sure `SPOTIFY_CLIENT_ID` environment variable is set before building:
```bash
source .envrc  # or direnv allow .
xcodebuild -scheme Spotifly -configuration Release build
```

**Problem:** Build warning about "Run script build phase 'Inject Environment Variables' will be run during every build"

**Solution:** This is expected and harmless. The script needs to run on every build to ensure the Info.plist is updated.
