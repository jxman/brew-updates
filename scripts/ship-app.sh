#!/bin/bash

# Ships a new version of the Brew Updates app: bumps the version, turns the CHANGELOG's
# Unreleased section into this release, builds the notarized DMG, tags, publishes the GitHub
# release and points the Homebrew cask at it. It wraps scripts/release.sh (build, sign,
# notarize, appcast) and scripts/update-cask.sh, which still work on their own.
#
#   ./scripts/ship-app.sh <version> [options]
#   ./scripts/ship-app.sh 1.8.0 --dry-run
#
# Steps (each stops the script on failure; running the same command again resumes):
#   1. Checks: clean tree on main, in sync with origin, tools, gh login, notary profile,
#      tag and release don't exist, Unreleased has content
#   2. Version: MARKETING_VERSION in app/project.yml, xcodegen, Swift tests, SwiftLint
#   3. CHANGELOG: "## [Unreleased]" becomes "## [App <version>] - <today>" (you review the
#      diff), committed as "chore(app): release <version>"
#   4. scripts/release.sh builds dist/Brew-Updates-<version>.dmg and dist/appcast.xml
#   5. Confirmation, then: tag app-v<version>, push main and the tag, gh release create
#   6. scripts/update-cask.sh <version>
#
# What you decide: the version (the argument), the CHANGELOG text (it becomes the in-app
# update notes) and the final "publish" confirmation. Publishing can't be taken back cleanly:
# Sparkle offers the update to every installed copy as soon as the release exists.
#
# Options:
#   --dry-run      Run the checks and show every change and command, but change nothing:
#                  no file edits, commits, build, tag, push or release
#   --yes          Skip the confirmation prompts (CHANGELOG review, publish)
#   --skip-tests   Skip xcodegen/test/lint in step 2 (release.sh still builds and verifies)
#   -h, --help     Show this help

set -euo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly APP_DIR="$REPO_DIR/app"
readonly PROJECT_YML="$APP_DIR/project.yml"
readonly CHANGELOG="$REPO_DIR/CHANGELOG.md"
readonly TAP_DIR="${TAP_DIR:-$HOME/Documents/my-projects/homebrew-tap}"
readonly NOTARY_PROFILE="brew-updates-notary"
readonly REPO_SLUG="jxman/brew-updates"

usage() {
    sed -n '3,34p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

step() {
    echo -e "\n${GREEN}==>${NC} $*"
}

# Printed instead of running a command in --dry-run
would() {
    echo -e "    ${YELLOW}[dry-run] would:${NC} $*"
}

# Git-state problems stop a real release; a dry run only warns, so it can be tried any time
state_fail() {
    if [[ "$dry_run" == true ]]; then
        echo -e "${YELLOW}warning (a real run would stop here): $*${NC}"
    else
        fail "$*"
    fi
}

confirm() {
    [[ "$assume_yes" == true ]] && return 0
    [[ -t 0 ]] || fail "No terminal to ask on. Pass --yes to skip the prompts."
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

version=""
dry_run=false
assume_yes=false
skip_tests=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --yes) assume_yes=true; shift ;;
        --skip-tests) skip_tests=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 1 ;;
        *) [[ -z "$version" ]] || { usage >&2; exit 1; }; version="$1"; shift ;;
    esac
done
[[ -n "$version" ]] || { usage >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Not a version (want X.Y.Z): $version"
tag="app-v$version"

cd "$REPO_DIR"
[[ "$dry_run" == true ]] && echo -e "${YELLOW}DRY RUN: nothing will be changed${NC}"

# The prompts need a terminal. Check now, before anything is edited (Claude Code's "!" prefix
# has none)
if [[ "$dry_run" == false && "$assume_yes" == false && ! -t 0 ]]; then
    fail "No terminal to ask on, so nothing was changed. Run this in a terminal window (or pass --yes to skip the prompts)."
fi

# Undo the version bump and CHANGELOG edit if the script stops before they are committed,
# so the tree stays clean and the same command can be run again
edited=false
cleanup() {
    [[ -n "${changed:-}" ]] && rm -f "$changed"
    if [[ "$edited" == true ]]; then
        git -C "$REPO_DIR" checkout -- "$PROJECT_YML" "$CHANGELOG" 2>/dev/null || true
        echo -e "${YELLOW}Stopped before committing: the version bump and CHANGELOG edit were undone.${NC}" >&2
    fi
}
trap cleanup EXIT

# --- 1. Checks ------------------------------------------------------------------------------

step "Checking prerequisites"
for tool in git gh xcodegen xcodebuild swiftlint xcrun security awk sed diff; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
gh auth status >/dev/null 2>&1 || fail "gh isn't logged in (gh auth login)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarization credentials in profile \"$NOTARY_PROFILE\" (see docs/DEPLOYMENT.md, Releasing the app)"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "No Developer ID Application certificate in the keychain"

[[ -f "$TAP_DIR/Casks/brew-updates.rb" ]] || fail "Cask not found in $TAP_DIR (gh repo clone jxman/homebrew-tap)"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || fail "The tap has uncommitted changes: $TAP_DIR"

branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == "main" ]] || state_fail "On branch $branch: releases are made from main"
[[ -z "$(git status --porcelain)" ]] || state_fail "Uncommitted changes. Commit or stash them first."
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || state_fail "main isn't in sync with origin/main (push or pull first)"

current=$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Couldn't read MARKETING_VERSION from app/project.yml"

# Resuming: an earlier run already bumped and committed this version
prepared=false
if [[ "$current" == "$version" ]] && grep -q "^## \[App $version\]" "$CHANGELOG"; then
    prepared=true
    echo "Version $version is already prepared (resuming)."
else
    [[ "$current" != "$version" && "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" == "$version" ]] \
        || fail "$version isn't newer than the current version $current"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    fail "Tag $tag already exists locally"
fi
[[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || fail "Tag $tag already exists on GitHub"

if [[ "$prepared" == false ]]; then
    unreleased=$(awk '/^## \[Unreleased\]/ { found = 1; next } found && /^## / { exit } found && NF { print }' "$CHANGELOG")
    [[ -n "$unreleased" ]] || fail "CHANGELOG.md has nothing under \"## [Unreleased]\": add what changed first"
fi
echo "Releasing $version (current $current), tag $tag, from $(git rev-parse --short HEAD)"

# --- 2. Version and checks ------------------------------------------------------------------

if [[ "$prepared" == false ]]; then
    step "Setting MARKETING_VERSION to $version"
    if [[ "$dry_run" == true ]]; then
        would "change app/project.yml: MARKETING_VERSION $current -> $version"
    else
        sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1$version/" "$PROJECT_YML"
        edited=true
        grep -q "MARKETING_VERSION: $version" "$PROJECT_YML" || fail "Couldn't set MARKETING_VERSION"
    fi
fi

if [[ "$skip_tests" == true ]]; then
    echo "(skipping tests and lint)"
elif [[ "$dry_run" == true ]]; then
    step "Tests and lint"
    would "(cd app && xcodegen generate)"
    would "xcodebuild test (BrewUpdates scheme, arm64) and swiftlint lint --strict"
else
    step "Generating the project, running tests and lint"
    (cd "$APP_DIR" && xcodegen generate >/dev/null)
    test_output=$(cd "$APP_DIR" && xcodebuild -project BrewUpdates.xcodeproj -scheme BrewUpdates \
        -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -5 || true)
    echo "$test_output"
    [[ "$test_output" == *"TEST SUCCEEDED"* ]] || fail "Tests failed"
    (cd "$APP_DIR" && swiftlint lint --strict --quiet) || fail "SwiftLint found violations"
fi

# --- 3. CHANGELOG and commit ----------------------------------------------------------------

if [[ "$prepared" == false ]]; then
    step "CHANGELOG: Unreleased becomes App $version"
    today=$(date +%Y-%m-%d)
    changed=$(mktemp)
    # A fresh empty Unreleased stays at the top; what was in it moves under the new heading
    awk -v v="$version" -v d="$today" '
        /^## \[Unreleased\]/ && !done { print; print ""; print "## [App " v "] - " d; done = 1; next }
        { print }' "$CHANGELOG" > "$changed"
    diff -u "$CHANGELOG" "$changed" | sed -n '1,40p' || true
    if [[ "$dry_run" == true ]]; then
        would "write that to CHANGELOG.md, then: git commit -m \"chore(app): release $version\""
    else
        confirm "Use this CHANGELOG? (it becomes the in-app update notes)" || fail "Stopped before changing the CHANGELOG. Edit it, then run this again."
        edited=true
        cp "$changed" "$CHANGELOG"
        git add "$PROJECT_YML" "$CHANGELOG"
        git commit -q -m "chore(app): release $version"
        edited=false
        echo "Committed $(git rev-parse --short HEAD)"
    fi
fi

# --- 4. Build -------------------------------------------------------------------------------

step "Building the notarized DMG and appcast"
if [[ "$dry_run" == true ]]; then
    would "./scripts/release.sh   (Developer ID build, notarization, dist/appcast.xml)"
else
    ./scripts/release.sh
fi

dmg="$REPO_DIR/dist/Brew-Updates-$version.dmg"
appcast="$REPO_DIR/dist/appcast.xml"
notes="$REPO_DIR/dist/release-notes.md"
if [[ "$dry_run" == false ]]; then
    for file in "$dmg" "$appcast" "$notes"; do
        [[ -f "$file" ]] || fail "release.sh didn't produce $file"
    done
fi

# --- 5. Tag, push, publish ------------------------------------------------------------------

step "Publishing $tag"
if [[ "$dry_run" == true ]]; then
    would "git tag -a $tag -m \"Brew Updates app $version\""
    would "git push origin main $tag"
    would "gh release create $tag dist/Brew-Updates-$version.dmg dist/appcast.xml --title \"Brew Updates $version\" --notes-file dist/release-notes.md --verify-tag"
else
    echo "DMG:      $dmg"
    echo "SHA-256:  $(cat "$dmg.sha256" 2>/dev/null || shasum -a 256 "$dmg" | awk '{ print $1 }')"
    echo "Releasing from commit $(git rev-parse --short HEAD) as $tag: Sparkle offers it to every installed copy."
    confirm "Publish $tag now?" || fail "Not published. Run the same command again to resume (the build is redone)."
    git tag -a "$tag" -m "Brew Updates app $version"
    git push origin main "$tag"
    gh release create "$tag" "$dmg" "$appcast" \
        --title "Brew Updates $version" --notes-file "$notes" --verify-tag
fi

# --- 6. Homebrew cask -----------------------------------------------------------------------

step "Updating the Homebrew cask"
if [[ "$dry_run" == true ]]; then
    would "./scripts/update-cask.sh $version   (downloads the published DMG, sets version + sha256, pushes the tap)"
    echo -e "\n${GREEN}Dry run finished: all checks passed, nothing was changed.${NC}"
else
    ./scripts/update-cask.sh "$version"
    echo -e "\n${GREEN}✓ Released $version${NC}"
    echo "  https://github.com/$REPO_SLUG/releases/tag/$tag"
    echo "  brew install --cask jxman/tap/brew-updates   (or: brew upgrade --cask --greedy brew-updates)"
fi
