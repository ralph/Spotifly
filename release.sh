#!/bin/bash

# Spotifly Release Script
# Creates an optimized build and publishes it to GitHub Releases

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

echo -e "\n${GREEN}Building optimized release...${NC}"

# Clean build directory
rm -rf build/Release
xcodebuild clean -scheme Spotifly -configuration Release

# Build for release
xcodebuild \
    -scheme Spotifly \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    build

# Find the built app
APP_PATH="build/Build/Products/Release/Spotifly.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: Built app not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}Build successful!${NC}"

# Create zip archive
ZIP_NAME="Spotifly-${VERSION}.zip"
echo -e "\n${YELLOW}Creating archive: ${ZIP_NAME}${NC}"

cd build/Build/Products/Release
zip -r -q "../../../../${ZIP_NAME}" Spotifly.app
cd ../../../..

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
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update the Homebrew Cask formula in homebrew-spotifly repository"
echo "2. Update the SHA256 hash to: ${SHA256}"
echo "3. Update the version to: ${VERSION}"

# Clean up
rm -f "${ZIP_NAME}" "Spotifly-latest.zip"

echo -e "\n${GREEN}Done!${NC}"
