#!/bin/bash

# Spotifly Release Script
# Creates a notarized build and publishes it to GitHub Releases
#
# USAGE:
#   1. Update version in Xcode project settings (MARKETING_VERSION)
#   2. Run: ./release.sh
#   3. Follow the interactive prompts for Archive, Notarization, and Export
#
# REQUIREMENTS:
#   - Xcode installed with Apple Developer account configured
#   - GitHub CLI (gh) installed and authenticated
#   - Write access to ralph/homebrew-spotifly repository
#
# The build is signed with Developer ID and notarized by Apple.

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Spotifly Release Script${NC}"
echo "======================="

# Get current version from Xcode project
MARKETING_VERSION=$(xcodebuild -showBuildSettings -scheme Spotifly 2>/dev/null | grep "MARKETING_VERSION" | head -1 | awk '{print $3}')
BUILD_NUMBER=$(xcodebuild -showBuildSettings -scheme Spotifly 2>/dev/null | grep "CURRENT_PROJECT_VERSION" | head -1 | awk '{print $3}')
VERSION="${MARKETING_VERSION}"

echo -e "\n${YELLOW}Current version: ${VERSION}${NC}"

# Check if this version already exists as a release
REPLACE_EXISTING=false
if gh release view "v${VERSION}" --repo ralph/homebrew-spotifly &> /dev/null; then
    echo -e "${YELLOW}Warning: Release v${VERSION} already exists!${NC}"
    read -p "Do you want to replace it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        REPLACE_EXISTING=true
        echo -e "${YELLOW}Will replace existing release v${VERSION}${NC}"
    else
        echo -e "${RED}Aborted. Please update the version in Xcode before releasing.${NC}"
        exit 1
    fi
fi

# Export location for the notarized app
EXPORT_DIR="$HOME/Desktop/Spotifly-Export"

echo -e "\n${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  STEP 1: CREATE ARCHIVE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "Please follow these steps in Xcode:"
echo -e "  1. Open Xcode if not already open"
echo -e "  2. Go to ${GREEN}Product → Archive${NC}"
echo -e "  3. Wait for the archive to complete"
echo -e "  4. The ${GREEN}Organizer${NC} window will open - ${YELLOW}keep it open${NC}"
echo -e "  5. Press ${GREEN}Enter${NC} here to continue\n"

read -p "Press Enter when Archive is complete and Organizer is open..."

echo -e "\n${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  STEP 2: VALIDATE ARCHIVE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "In the Xcode Organizer window:"
echo -e "  1. Select your latest archive (should be at the top)"
echo -e "  2. Click ${GREEN}Validate App${NC}"
echo -e "  3. Choose ${GREEN}Developer ID${NC}"
echo -e "  4. Click ${GREEN}Next${NC} through the dialogs"
echo -e "  5. Wait for validation to complete"
echo -e "  6. Ensure you see ${GREEN}'Your app successfully passed all validation checks'${NC}"
echo -e "  7. Press ${GREEN}Enter${NC} here to continue\n"

read -p "Press Enter when validation is complete..."

echo -e "\n${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  STEP 3: DISTRIBUTE AND NOTARIZE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "In the Xcode Organizer window:"
echo -e "  1. Click ${GREEN}Distribute App${NC}"
echo -e "  2. Choose ${GREEN}Developer ID${NC}"
echo -e "  3. Choose ${GREEN}Upload${NC} (this sends your app to Apple for notarization)"
echo -e "  4. Click ${GREEN}Next${NC} through the dialogs"
echo -e "  5. Wait for the upload to complete"
echo -e "  6. ${YELLOW}Wait for notarization${NC} - this usually takes 2-5 minutes"
echo -e "     (You'll see a progress indicator, then a success message)"
echo -e "  7. Press ${GREEN}Enter${NC} here when you see the notarization success message\n"

read -p "Press Enter when notarization is complete..."

echo -e "\n${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  STEP 4: EXPORT NOTARIZED APP${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "In the Xcode Organizer window:"
echo -e "  1. Click ${GREEN}Distribute App${NC} again"
echo -e "  2. Choose ${GREEN}Developer ID${NC}"
echo -e "  3. Choose ${GREEN}Export${NC} (NOT Upload this time)"
echo -e "  4. Click ${GREEN}Next${NC} through the dialogs"
echo -e "  5. When asked where to export, choose: ${GREEN}${EXPORT_DIR}${NC}"
echo -e "     (Create this folder if it doesn't exist)"
echo -e "  6. Click ${GREEN}Export${NC}"
echo -e "  7. Press ${GREEN}Enter${NC} here when export is complete\n"

read -p "Press Enter when export is complete..."

# Find the exported app
APP_PATH="${EXPORT_DIR}/Spotifly.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: Exported app not found at ${APP_PATH}${NC}"
    echo "Please make sure you exported to the correct location."
    exit 1
fi

echo -e "\n${GREEN}Found exported app!${NC}"

# Verify it's notarized
echo -e "\n${YELLOW}Verifying notarization...${NC}"
if spctl -a -vv "$APP_PATH" 2>&1 | grep -q "accepted"; then
    echo -e "${GREEN}✓ App is properly signed and notarized${NC}"
else
    echo -e "${YELLOW}Warning: Could not verify notarization${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Create zip archive
ZIP_NAME="Spotifly-${VERSION}.zip"
echo -e "\n${YELLOW}Creating archive: ${ZIP_NAME}${NC}"

cd "$EXPORT_DIR"
zip -r -q "${OLDPWD}/${ZIP_NAME}" Spotifly.app
cd "${OLDPWD}"

# Calculate SHA256 for Homebrew formula
SHA256=$(shasum -a 256 "${ZIP_NAME}" | awk '{print $1}')
echo -e "${GREEN}SHA256: ${SHA256}${NC}"

# Delete existing release if replacing
if [ "$REPLACE_EXISTING" = true ]; then
    echo -e "\n${YELLOW}Deleting existing release v${VERSION}...${NC}"
    gh release delete "v${VERSION}" --yes --repo ralph/homebrew-spotifly 2>/dev/null || true
    # Also delete the tag
    git push --delete origin "v${VERSION}" --repo ralph/homebrew-spotifly 2>/dev/null || true
fi

# Create GitHub release
echo -e "\n${YELLOW}Creating GitHub release v${VERSION}...${NC}"

gh release create "v${VERSION}" \
    "${ZIP_NAME}" \
    --title "Spotifly ${VERSION}" \
    --notes "Release ${VERSION}

Download and install:
- **Homebrew (recommended)**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-${VERSION}.zip, extract, and move to Applications

**Note:** This version is signed and notarized with Apple Developer ID. No Gatekeeper warnings!

Built with [Claude Code](https://claude.com/claude-code)" \
    --repo ralph/homebrew-spotifly

# Also tag as latest
echo -e "${YELLOW}Updating 'latest' tag...${NC}"
gh release delete latest --yes --repo ralph/homebrew-spotifly 2>/dev/null || true
gh release create latest \
    "${ZIP_NAME}" \
    --title "Spotifly (Latest)" \
    --notes "Latest stable release of Spotifly

This is a rolling release that always points to the latest version.

Download and install:
- **Homebrew (recommended)**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-latest.zip, extract, and move to Applications

Current version: ${VERSION}

For specific versions, see: https://github.com/ralph/homebrew-spotifly/releases" \
    --repo ralph/homebrew-spotifly

# Copy zip as latest.zip
cp "${ZIP_NAME}" "Spotifly-latest.zip"
gh release upload latest "Spotifly-latest.zip" --clobber --repo ralph/homebrew-spotifly

echo -e "\n${GREEN}Release v${VERSION} created successfully!${NC}"
echo -e "${GREEN}Latest release updated${NC}"
echo ""
echo -e "Download URL: https://github.com/ralph/homebrew-spotifly/releases/download/v${VERSION}/${ZIP_NAME}"
echo -e "Latest URL: https://github.com/ralph/homebrew-spotifly/releases/download/latest/Spotifly-latest.zip"

# Update Homebrew Cask formula
echo -e "\n${YELLOW}Updating Homebrew Cask formula...${NC}"

HOMEBREW_TAP_DIR="$HOME/code/spotifly/homebrew-spotifly"
CASK_FILE="${HOMEBREW_TAP_DIR}/Casks/spotifly.rb"

if [ -d "$HOMEBREW_TAP_DIR" ] && [ -f "$CASK_FILE" ]; then
    # Update version and SHA256 in the Cask formula
    sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$CASK_FILE"
    sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "$CASK_FILE"

    # Commit and push changes
    cd "$HOMEBREW_TAP_DIR"
    git add Casks/spotifly.rb
    git commit -m "Update Spotifly to version ${VERSION}"
    git push

    echo -e "${GREEN}Homebrew formula updated and pushed!${NC}"
    cd "$OLDPWD"
else
    echo -e "${YELLOW}Homebrew tap directory not found at ${HOMEBREW_TAP_DIR}${NC}"
    echo -e "${YELLOW}Manual update required:${NC}"
    echo "1. Update the Homebrew Cask formula in homebrew-spotifly repository"
    echo "2. Update the SHA256 hash to: ${SHA256}"
    echo "3. Update the version to: ${VERSION}"
fi

# Clean up
rm -f "${ZIP_NAME}" "Spotifly-latest.zip"

echo -e "\n${GREEN}✓ Release complete!${NC}"
echo -e "\nUsers can now install with:"
echo -e "  ${GREEN}brew upgrade ralph/spotifly/spotifly${NC}"
echo ""
echo -e "Or for new installations:"
echo -e "  ${GREEN}brew install ralph/spotifly/spotifly${NC}"
echo ""
