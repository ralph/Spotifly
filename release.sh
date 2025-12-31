#!/bin/bash

# Spotifly Release Script
# Creates an optimized build and publishes it to GitHub Releases
#
# USAGE:
#   1. Update version in Xcode project settings (MARKETING_VERSION)
#   2. Run: ./release.sh
#   3. When prompted, create an Archive in Xcode (Product → Archive)
#   4. Press Enter to continue - script will package and upload
#
# REQUIREMENTS:
#   - Xcode installed
#   - GitHub CLI (gh) installed and authenticated
#   - Write access to ralph/homebrew-spotifly repository
#
# The archived build is optimized (Release configuration) and ready for distribution.

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Spotifly Release Script${NC}"
echo "======================="

# Get current version from Xcode project
MARKETING_VERSION=$(xcodebuild -showBuildSettings -scheme Spotifly 2>/dev/null | grep "MARKETING_VERSION" | head -1 | awk '{print $3}')
BUILD_NUMBER=$(xcodebuild -showBuildSettings -scheme Spotifly 2>/dev/null | grep "CURRENT_PROJECT_VERSION" | head -1 | awk '{print $3}')
VERSION="${MARKETING_VERSION}"

echo -e "\n${YELLOW}Current version: ${VERSION}${NC}"

# Check if this version already exists as a release
if gh release view "v${VERSION}" &> /dev/null; then
    echo -e "${RED}Error: Release v${VERSION} already exists!${NC}"
    echo "Please update the version in your Xcode project before releasing."
    exit 1
fi

echo -e "\n${YELLOW}=== MANUAL BUILD REQUIRED ===${NC}"
echo -e "Please follow these steps in Xcode:"
echo -e "  1. Open Xcode if not already open"
echo -e "  2. Go to ${GREEN}Product → Archive${NC}"
echo -e "  3. Wait for the archive to complete"
echo -e "  4. ${GREEN}Do NOT export${NC} - just close the Organizer window"
echo -e "  5. Press ${GREEN}Enter${NC} here to continue\n"

read -p "Press Enter when Archive is complete..."

echo -e "\n${GREEN}Looking for archived app...${NC}"

# Find the most recent archive
ARCHIVES_PATH="$HOME/Library/Developer/Xcode/Archives"
LATEST_ARCHIVE=$(find "$ARCHIVES_PATH" -name "*.xcarchive" -type d -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)

if [ -z "$LATEST_ARCHIVE" ]; then
    echo -e "${RED}Error: No archives found${NC}"
    echo "Please make sure you archived the app in Xcode (Product → Archive)"
    exit 1
fi

echo -e "${GREEN}Found archive: $(basename "$LATEST_ARCHIVE")${NC}"

# Find the app in the archive
APP_PATH="${LATEST_ARCHIVE}/Products/Applications/Spotifly.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: Built app not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}Build successful!${NC}"

# Create zip archive
ZIP_NAME="Spotifly-${VERSION}.zip"
echo -e "\n${YELLOW}Creating archive: ${ZIP_NAME}${NC}"

# Create zip from the app location
ARCHIVE_DIR=$(dirname "${APP_PATH}")
cd "${ARCHIVE_DIR}"
zip -r -q "${OLDPWD}/${ZIP_NAME}" Spotifly.app
cd "${OLDPWD}"

# Calculate SHA256 for Homebrew formula
SHA256=$(shasum -a 256 "${ZIP_NAME}" | awk '{print $1}')
echo -e "${GREEN}SHA256: ${SHA256}${NC}"

# Create GitHub release
echo -e "\n${YELLOW}Creating GitHub release v${VERSION}...${NC}"

gh release create "v${VERSION}" \
    "${ZIP_NAME}" \
    --title "Spotifly ${VERSION}" \
    --notes "Release ${VERSION}

Download and install:
- **Homebrew (recommended)**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-${VERSION}.zip, extract, and move to Applications

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

echo -e "\n${GREEN}Done!${NC}"
