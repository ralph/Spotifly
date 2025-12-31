# Spotifly Release Process

This document describes how to create and publish a new release of Spotifly.

## Prerequisites

- Xcode installed and working
- GitHub CLI (`gh`) installed and authenticated
- Write access to the `ralph/homebrew-spotifly` repository

## Release Steps

### 1. Update Version Number

In Xcode:
1. Open the project in Xcode
2. Select the **Spotifly** project in the navigator
3. Select the **Spotifly** target
4. Go to the **General** tab
5. Update the **Version** field (e.g., `1.0`, `1.1`, `2.0`)
6. The **Build** number can stay the same or be incremented

### 2. Commit Your Changes

Make sure all your changes are committed to git:

```bash
git status
git add -A
git commit -m "Prepare for v1.0 release"
```

### 3. Run the Release Script

```bash
./release.sh
```

The script will:
1. Check the current version from your Xcode project
2. Verify that this version hasn't been released yet
3. **Pause and ask you to create an Archive in Xcode**

### 4. Create Archive in Xcode

When the script prompts you:

1. Switch to Xcode
2. Go to **Product → Archive**
3. Wait for the archive to complete (this builds an optimized Release configuration)
4. When the Organizer window opens, just **close it** (do NOT export)
5. Switch back to Terminal and press **Enter**

The script will then:
- Find your archived app
- Create a ZIP file
- Upload to GitHub Releases in the `ralph/homebrew-spotifly` repository
- Tag as both `v{VERSION}` and `latest`
- Calculate SHA256 hash for Homebrew formula
- **Automatically update the Homebrew Cask formula** with the new version and SHA256
- Commit and push the formula changes to the homebrew-spotifly repository

### 5. Done!

The release is complete and published. The Homebrew formula is automatically updated, so users can install immediately:

```bash
brew upgrade ralph/spotifly/spotifly
```

## What Gets Released?

- **Archived app**: Optimized for Release (Product → Archive uses Release configuration)
- **Code signing**: Disabled for maximum compatibility
- **Optimizations**: Full compiler optimizations enabled
- **ZIP file**: Contains `Spotifly.app` bundle
- **Location**: `ralph/homebrew-spotifly` releases (NOT the source code repo)

## Verification

The Homebrew formula is automatically updated by the release script. You can verify the release:

```bash
brew upgrade ralph/spotifly/spotifly
```

Or for new installations:

```bash
brew install ralph/spotifly/spotifly
```

## Troubleshooting

**"Release v1.0 already exists"**
- Update the version number in Xcode before releasing

**"No archives found"**
- Make sure you completed the Archive step in Xcode
- Check ~/Library/Developer/Xcode/Archives for recent archives

**"Built app not found"**
- The archive may have failed
- Check Xcode for build errors
- Ensure all dependencies (Rust library) are built

## Build Configuration Details

### Archive Settings

Xcode Archive automatically uses:
- **Configuration**: Release
- **Optimization Level**: `-O` (Optimize for Speed)
- **Debug Info**: Included (for crash reports)
- **Assertions**: Disabled
- **Whole Module Optimization**: Enabled

### Code Signing

The script disables code signing (`CODE_SIGN_IDENTITY=""`) to:
- Avoid signing certificate requirements for users
- Allow installation without notarization
- Maximum compatibility across systems

Note: Users may need to allow the app in System Settings → Privacy & Security on first launch.
