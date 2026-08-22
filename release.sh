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
#   - Write access to ralph/spotifly and ralph/homebrew-spotifly repositories
#
# The build is signed with Developer ID and notarized by Apple.
# Releases are published to ralph/spotifly (main repo).
# The homebrew-spotifly formula is updated to point to the new release.

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
if gh release view "v${VERSION}" --repo ralph/spotifly &> /dev/null; then
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
echo -e "${BLUE}  XCODE NOTARIZATION WORKFLOW${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "\nComplete these steps in Xcode, then press Enter:\n"

echo -e "${YELLOW}1. ARCHIVE${NC}"
echo -e "   • Product → Archive"
echo -e "   • Wait for completion (Organizer window will open)\n"

echo -e "${YELLOW}2. VALIDATE${NC}"
echo -e "   • Select latest archive"
echo -e "   • Click ${GREEN}Validate App${NC} → ${GREEN}Developer ID${NC}"
echo -e "   • Click ${GREEN}Next${NC} through dialogs"
echo -e "   • Wait for: ${GREEN}'Successfully passed all validation checks'${NC}\n"

echo -e "${YELLOW}3. DISTRIBUTE (Upload for Notarization)${NC}"
echo -e "   • Click ${GREEN}Distribute App${NC} → ${GREEN}Developer ID${NC} → ${GREEN}Upload${NC}"
echo -e "   • Click ${GREEN}Next${NC} through dialogs"
echo -e "   • ${YELLOW}Wait for notarization (2-5 minutes)${NC}"
echo -e "   • Wait for notarization success message\n"

echo -e "${YELLOW}4. EXPORT${NC}"
echo -e "   • Click ${GREEN}Distribute App${NC} → ${GREEN}Developer ID${NC} → ${GREEN}Export${NC}"
echo -e "   • Export location: ${GREEN}${EXPORT_DIR}${NC}"
echo -e "   • Click ${GREEN}Export${NC}\n"

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}\n"

read -p "Press Enter when all steps are complete and app is exported..."

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
    gh release delete "v${VERSION}" --yes --repo ralph/spotifly 2>/dev/null || true
    gh release delete "v${VERSION}" --yes --repo ralph/homebrew-spotifly 2>/dev/null || true
    # Also delete the tags, on both repos: a release delete leaves its tag, and the recreate
    # below reuses it rather than moving it, so the replacement would point at the first
    # attempt's commit. Named per repo rather than pushed to `origin`, which from here is
    # only ever the app repo.
    gh api -X DELETE "repos/ralph/spotifly/git/refs/tags/v${VERSION}" &>/dev/null || true
    gh api -X DELETE "repos/ralph/homebrew-spotifly/git/refs/tags/v${VERSION}" &>/dev/null || true
    git tag -d "v${VERSION}" &>/dev/null || true
fi

# Extract changelog entry for this version
CHANGELOG_FILE="$HOME/code/spotifly/spotifly-code/CHANGELOG.md"
CHANGELOG_ENTRY=""
if [ -f "$CHANGELOG_FILE" ]; then
    # Extract the section for this version (from ## [VERSION] to next ## or end)
    CHANGELOG_ENTRY=$(awk "/^## \[${VERSION}\]/{flag=1; next} /^## \[/{flag=0} flag" "$CHANGELOG_FILE")
fi

# Create GitHub releases (both main repo and homebrew-spotifly for now)
echo -e "\n${YELLOW}Creating GitHub release v${VERSION} on ralph/spotifly...${NC}"

gh release create "v${VERSION}" \
    "${ZIP_NAME}" \
    --title "Spotifly ${VERSION}" \
    --notes "## What's New

${CHANGELOG_ENTRY}

## Download and Install

- **Homebrew**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-${VERSION}.zip, extract, and move to Applications

**Note:** This version is signed and notarized with Apple Developer ID. No Gatekeeper warnings!

[Full Changelog](https://github.com/ralph/spotifly/blob/main/CHANGELOG.md)" \
    --repo ralph/spotifly

# Also create on homebrew-spotifly (temporary, until app is in official Homebrew)
echo -e "${YELLOW}Creating GitHub release v${VERSION} on ralph/homebrew-spotifly...${NC}"
gh release delete "v${VERSION}" --yes --repo ralph/homebrew-spotifly 2>/dev/null || true

gh release create "v${VERSION}" \
    "${ZIP_NAME}" \
    --title "Spotifly ${VERSION}" \
    --notes "## What's New

${CHANGELOG_ENTRY}

## Download and Install

- **Homebrew**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-${VERSION}.zip, extract, and move to Applications

**Note:** This version is signed and notarized with Apple Developer ID. No Gatekeeper warnings!

[Full Changelog](https://github.com/ralph/spotifly/blob/main/CHANGELOG.md)" \
    --repo ralph/homebrew-spotifly

# Update 'latest' tag on both repos
echo -e "${YELLOW}Updating 'latest' tag...${NC}"
cp "${ZIP_NAME}" "Spotifly-latest.zip"

# Main repo
# The tag has to go with the release: deleting a release leaves its tag behind, and
# `gh release create` reuses an existing one rather than moving it — so without this the
# 'latest' release keeps pointing at whatever commit first created the tag. Its assets are
# still replaced, but the source-code links serve that old tree, and GitHub orders releases
# by tag date, which buries 'latest' at the bottom of the page.
gh release delete latest --yes --repo ralph/spotifly 2>/dev/null || true
gh api -X DELETE repos/ralph/spotifly/git/refs/tags/latest &>/dev/null || true
gh release create latest \
    "${ZIP_NAME}" \
    --title "Spotifly (Latest)" \
    --notes "Latest stable release of Spotifly (v${VERSION})

## What's New

${CHANGELOG_ENTRY}

## Download and Install

- **Homebrew**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-latest.zip, extract, and move to Applications

[Full Changelog](https://github.com/ralph/spotifly/blob/main/CHANGELOG.md) · [All Releases](https://github.com/ralph/spotifly/releases)" \
    --repo ralph/spotifly
gh release upload latest "Spotifly-latest.zip" --clobber --repo ralph/spotifly

# homebrew-spotifly (temporary)
gh release delete latest --yes --repo ralph/homebrew-spotifly 2>/dev/null || true
gh api -X DELETE repos/ralph/homebrew-spotifly/git/refs/tags/latest &>/dev/null || true
gh release create latest \
    "${ZIP_NAME}" \
    --title "Spotifly (Latest)" \
    --notes "Latest stable release of Spotifly (v${VERSION})

## What's New

${CHANGELOG_ENTRY}

## Download and Install

- **Homebrew**: \`brew install ralph/spotifly/spotifly\`
- **Manual**: Download Spotifly-latest.zip, extract, and move to Applications

[Full Changelog](https://github.com/ralph/spotifly/blob/main/CHANGELOG.md) · [All Releases](https://github.com/ralph/spotifly/releases)" \
    --repo ralph/homebrew-spotifly
gh release upload latest "Spotifly-latest.zip" --clobber --repo ralph/homebrew-spotifly

echo -e "\n${GREEN}Releases created successfully on both repos!${NC}"
echo ""
echo -e "Main repo: https://github.com/ralph/spotifly/releases/download/v${VERSION}/${ZIP_NAME}"
echo -e "Homebrew tap: https://github.com/ralph/homebrew-spotifly/releases/download/v${VERSION}/${ZIP_NAME}"

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
