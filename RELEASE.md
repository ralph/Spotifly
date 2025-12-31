# Spotifly Release Process

This document describes how to create and publish a new release of Spotifly.

## Prerequisites

- Xcode installed and working
- **Apple Developer account** (paid, $99/year) configured in Xcode
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

The script will guide you through the entire process with interactive prompts.

### 4. Follow the Interactive Steps

The script will pause at each step and provide clear instructions:

#### Step 1: Create Archive
- In Xcode, go to **Product → Archive**
- Wait for the archive to complete
- Keep the Organizer window open

#### Step 2: Validate Archive
- In the Organizer, click **Validate App**
- Choose **Developer ID**
- Wait for validation to complete
- Ensure validation passes

#### Step 3: Distribute and Notarize
- Click **Distribute App**
- Choose **Developer ID**
- Choose **Upload** (sends to Apple for notarization)
- Wait 2-5 minutes for notarization to complete

#### Step 4: Export Notarized App
- Click **Distribute App** again
- Choose **Developer ID**
- Choose **Export** (NOT Upload this time)
- Export to `~/Desktop/Spotifly-Export`

### 5. Automatic Completion

After you export the notarized app, the script automatically:
- Verifies the app is properly signed and notarized
- Creates a ZIP file
- Uploads to GitHub Releases in the `ralph/homebrew-spotifly` repository
- Tags as both `v{VERSION}` and `latest`
- Updates the Homebrew Cask formula with the new version and SHA256
- Commits and pushes the formula changes

### 6. Done!

The release is complete and published. Users can install immediately:

```bash
brew upgrade ralph/spotifly/spotifly
```

Or for new installations:

```bash
brew install ralph/spotifly/spotifly
```

## What Gets Released?

- **Archived app**: Optimized for Release (Product → Archive uses Release configuration)
- **Code signing**: Signed with Developer ID Application certificate
- **Notarization**: Notarized by Apple (no Gatekeeper warnings!)
- **Optimizations**: Full compiler optimizations enabled
- **Architecture**: arm64 only (Apple Silicon)
- **ZIP file**: Contains notarized `Spotifly.app` bundle
- **Location**: `ralph/homebrew-spotifly` releases (NOT the source code repo)

## Replacing an Existing Release

If you need to replace an existing release (e.g., to fix signing issues):

1. Run `./release.sh` as normal
2. When prompted that the release already exists, type `y` to replace it
3. The script will delete the old release and create a new one with the same version

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
- The script will ask if you want to replace it
- Type `y` to replace, or `n` to abort and update the version number

**Validation failed: "LSApplicationCategoryType"**
- This is already configured in the project (set to `public.app-category.music`)
- If you see this error, the Xcode project may need to be updated

**Notarization takes too long**
- Notarization usually takes 2-5 minutes
- You can check status at https://developer.apple.com/account
- If it fails, check the email associated with your Apple Developer account for details

**"Exported app not found"**
- Make sure you exported to `~/Desktop/Spotifly-Export`
- The script looks for `Spotifly.app` in this exact location

**Verification failed**
- The script verifies the app is properly notarized using `spctl`
- If verification fails, you can choose to continue anyway
- Check that your Developer ID certificate is valid in Xcode preferences

## Build Configuration Details

### Release Settings

The Release configuration includes:
- **Optimization Level**: `-O` (Optimize for Speed)
- **Whole Module Optimization**: Enabled
- **Architecture**: arm64 only (Apple Silicon)
- **Code Signing**: Automatic with Developer ID
- **Hardened Runtime**: Enabled
- **App Sandbox**: Enabled

### Code Signing and Notarization

The app is:
1. **Signed** with your Developer ID Application certificate
2. **Notarized** by Apple's notary service
3. **Verified** with `spctl` before upload

This ensures users don't see Gatekeeper warnings when opening the app.

### Rust Library Integration

The app links against a Rust library (`libspotifly_rust.a`) that must be:
- Compiled for arm64 architecture
- Located at `build/rust/lib/libspotifly_rust.a`
- Built before creating the Archive

## Notes

- The release script expects the homebrew-spotifly repository at `~/code/spotifly/homebrew-spotifly`
- Exported apps are saved to `~/Desktop/Spotifly-Export` and cleaned up after upload
- Both the source repo and homebrew-spotifly repo must have clean working directories
