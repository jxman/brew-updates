#!/bin/bash

# Points the Homebrew cask (jxman/homebrew-tap, Casks/brew-updates.rb) at a published release:
# sets `version` and `sha256`, checks it with `brew style`, commits and pushes. Run it after
# `gh release create`, since the checksum comes from the DMG as GitHub serves it.
#
#   ./scripts/update-cask.sh [version] [--no-push]
#
# version defaults to MARKETING_VERSION in app/project.yml. The tap clone defaults to
# ~/Documents/my-projects/homebrew-tap (override with TAP_DIR).
#
# Users don't need this to get the update: the app updates itself (Sparkle) and the cask says
# `auto_updates true`. It keeps `brew install --cask` handing out the current version.

set -euo pipefail

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly TAP_DIR="${TAP_DIR:-$HOME/Documents/my-projects/homebrew-tap}"
readonly CASK="$TAP_DIR/Casks/brew-updates.rb"
readonly RELEASES="https://github.com/jxman/brew-updates/releases/download"

fail() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

version=""
push=true
for arg in "$@"; do
    case "$arg" in
        --no-push) push=false ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) version="$arg" ;;
    esac
done
[[ -n "$version" ]] || version=$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$REPO_DIR/app/project.yml")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Not a version: $version"

[[ -f "$CASK" ]] || fail "Cask not found: $CASK (clone it: gh repo clone jxman/homebrew-tap \"$TAP_DIR\")"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || fail "The tap has uncommitted changes: $TAP_DIR"
git -C "$TAP_DIR" pull -q --ff-only

# The published file, not dist/: what brew downloads is what the checksum must match
url="$RELEASES/app-v$version/Brew-Updates-$version.dmg"
echo "Downloading $url"
download=$(mktemp)
trap 'rm -f "$download"' EXIT
curl -fsSL -o "$download" "$url" || fail "Couldn't download $url. Is the GitHub release published?"
sha=$(shasum -a 256 "$download" | awk '{ print $1 }')
local_sha="$REPO_DIR/dist/Brew-Updates-$version.dmg.sha256"
if [[ -f "$local_sha" && "$(cat "$local_sha")" != "$sha" ]]; then
    fail "The published DMG doesn't match dist/ ($(cat "$local_sha")). Check the release assets."
fi

sed -i '' -E "s/^  version \"[^\"]+\"/  version \"$version\"/; s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$sha\"/" "$CASK"
if git -C "$TAP_DIR" diff --quiet; then
    echo -e "${GREEN}✓ The cask already points at $version${NC}"
    exit 0
fi
brew style "$CASK" >/dev/null || fail "brew style failed: brew style \"$CASK\""
git -C "$TAP_DIR" diff --stat
git -C "$TAP_DIR" commit -q -am "feat: brew-updates $version"
if [[ "$push" == true ]]; then
    git -C "$TAP_DIR" push -q
    echo -e "${GREEN}✓ Cask updated to $version and pushed${NC}"
else
    echo -e "${GREEN}✓ Cask updated to $version (committed, not pushed)${NC}"
fi
