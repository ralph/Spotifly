# Release Command

Release a new version of Spotifly.

## Arguments
- `version`: The version number to release (e.g., `1.1.5`)

## Instructions

1. **Validate version**: Ensure the provided version follows semver (e.g., `1.2.3`)

2. **Update CHANGELOG.md in this repo**:
   - Read the current `[Unreleased]` section
   - If empty, ask the user what changes to include
   - Move entries from `[Unreleased]` to a new `## [version] - YYYY-MM-DD` section
   - Keep `## [Unreleased]` header (now empty) at the top

3. **Bump version in Xcode project**:
   - Update all `MARKETING_VERSION` entries in `Spotifly.xcodeproj/project.pbxproj` to the new version

4. **Update ../homebrew-spotifly/CHANGELOG.md**:
   - Add a new version section with today's date
   - Summarize only user-visible changes (brief, one line each)
   - Features go under `### Added`
   - Bug fixes go under `### Fixed`
   - Group minor/technical fixes as "Bug fixes and performance improvements"
   - Add the version link at the bottom of the file

5. **Commit both repos**:
   - In this repo: `git add CHANGELOG.md Spotifly.xcodeproj/project.pbxproj && git commit -m "Bump version to [version]"`
   - In ../homebrew-spotifly: `git add CHANGELOG.md && git commit -m "Add v[version] to changelog"`

6. **Report**: Show the user what was done and remind them to push both repos
