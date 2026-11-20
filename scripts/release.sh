#!/bin/bash

# Builds a release of the Brew Updates app: an Apple silicon Release build,
# signed with Developer ID and the hardened runtime, in a signed DMG that Apple has notarized,
# so it opens on any Mac without a Gatekeeper warning. Output goes to dist/ (gitignored):
#   dist/Brew-Updates-<version>.dmg and dist/Brew-Updates-<version>.dmg.sha256
#
# Before running it: bump MARKETING_VERSION in app/project.yml, add a "## [App <version>]"
# section to CHANGELOG.md and commit. It doesn't tag or publish anything.
#
# One-time setup (see docs/DEPLOYMENT.md, "Releasing the app"):
#   1. A "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts >
#      Manage Certificates > + > Developer ID Application)
#   2. Notarization credentials stored in the keychain under the profile name below:
#      xcrun notarytool store-credentials brew-updates-notary \
#          --apple-id <your Apple ID> --team-id <your team ID> --password <app-specific password>
#
# Options:
#   --identity NAME        Signing identity (default: the first "Developer ID Application")
#   --notary-profile NAME  notarytool keychain profile (default: brew-updates-notary)
#   --skip-notarize        Build and sign the DMG but don't notarize it (for testing the
#                          pipeline, e.g. with --identity "Apple Development")
#   --allow-dirty          Allow uncommitted changes (testing only)
#   -h, --help             Show this help

set -euo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly APP_DIR="$REPO_DIR/app"
readonly APP_NAME="Brew Updates.app"
readonly LAUNCHER_ID="com.jxman.BrewUpdates.launcher"

identity=""
notary_profile="brew-updates-notary"
notarize=true
allow_dirty=false

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

step() {
    echo -e "\n${GREEN}==>${NC} $*"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) identity="${2:?--identity needs a name}"; shift 2 ;;
        --notary-profile) notary_profile="${2:?--notary-profile needs a name}"; shift 2 ;;
        --skip-notarize) notarize=false; shift ;;
        --allow-dirty) allow_dirty=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

# --- Checks ---------------------------------------------------------------------------------

step "Checking prerequisites"
for tool in xcodegen xcodebuild git hdiutil xcrun codesign lipo shasum; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found (xcodegen: brew install xcodegen)"
done

if [[ "$allow_dirty" == false && -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    fail "Uncommitted changes. Commit them first (or pass --allow-dirty for a test build)."
fi

version=$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$APP_DIR/project.yml")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Couldn't read MARKETING_VERSION from app/project.yml"
grep -q "^## \[App $version\]" "$REPO_DIR/CHANGELOG.md" \
    || fail "CHANGELOG.md has no \"## [App $version]\" section"

tag="app-v$version"
if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git -C "$REPO_DIR" rev-parse "$tag^{commit}")" == "$(git -C "$REPO_DIR" rev-parse HEAD)" ]] \
        || fail "Tag $tag exists but isn't on this commit: bump MARKETING_VERSION for a new release"
fi

if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
    [[ -n "$identity" ]] || fail "No Developer ID Application certificate found. Create one in Xcode > Settings > Accounts
> Manage Certificates, or pass --identity \"Apple Development\" --skip-notarize for a test build."
fi
security find-identity -v -p codesigning | grep -qF "$identity" || fail "Signing identity not found: $identity"
if [[ "$notarize" == true && "$identity" != *"Developer ID Application"* ]]; then
    fail "Only Developer ID builds can be notarized. Use --skip-notarize with \"$identity\"."
fi
if [[ "$notarize" == true ]] && ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    fail "No notarization credentials in profile \"$notary_profile\". Store them once with:
  xcrun notarytool store-credentials $notary_profile --apple-id <Apple ID> --team-id <team ID> --password <app-specific password>"
fi

build_number=$(git -C "$REPO_DIR" rev-list --count HEAD)
echo "Version $version (build $build_number), signing as: $identity"

# --- Build ----------------------------------------------------------------------------------

step "Building Release (Apple silicon)"
cd "$APP_DIR"
xcodegen generate --quiet
# Architectures come from ARCHS in project.yml (arm64 only: macOS 26 is the last release for
# Intel Macs). Default DerivedData (~/Library): a build folder inside ~/Documents triggers permission prompts
destination='generic/platform=macOS'
xcodebuild -project BrewUpdates.xcodeproj -scheme BrewUpdates -configuration Release \
    -destination "$destination" build -quiet CURRENT_PROJECT_VERSION="$build_number"
products_dir=$(xcodebuild -project BrewUpdates.xcodeproj -scheme BrewUpdates -configuration Release \
    -destination "$destination" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / { print $2; exit }')
built_app="$products_dir/$APP_NAME"
[[ -d "$built_app" ]] || fail "Build product not found at $built_app"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/$APP_NAME"
ditto "$built_app" "$app"
launcher="$app/Contents/MacOS/brew-updates-launcher"

for binary in "$app/Contents/MacOS/Brew Updates" "$launcher"; do
    archs=$(lipo -archs "$binary")
    [[ "$archs" == "arm64" ]] || fail "$(basename "$binary") should be arm64 only, is: $archs"
done
echo "Architectures: $(lipo -archs "$app/Contents/MacOS/Brew Updates")"

# --- Sign -----------------------------------------------------------------------------------

step "Signing with the hardened runtime"
# Nested executables first: signing the app doesn't re-sign them. A secure timestamp
# (--timestamp, needs the network) is required for notarization.
codesign --force --options runtime --timestamp --sign "$identity" -i "$LAUNCHER_ID" "$launcher"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
for binary in "$app" "$launcher"; do
    # Captured first: `grep -q` stops reading early, which pipefail would report as a failure
    details=$(codesign -dv "$binary" 2>&1)
    [[ "$details" == *"flags="*"runtime"* ]] || fail "$(basename "$binary") lacks the hardened runtime"
done
echo "Signed and verified"

# --- DMG ------------------------------------------------------------------------------------

step "Building the DMG"
mkdir -p "$REPO_DIR/dist"
dmg="$REPO_DIR/dist/Brew-Updates-$version.dmg"
staging="$work/dmg"
mkdir "$staging"
ditto "$app" "$staging/$APP_NAME"
# The usual drag-to-install layout: the app next to a link to /Applications
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Brew Updates $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --strict "$dmg"
echo "$dmg"

# --- Notarize -------------------------------------------------------------------------------

if [[ "$notarize" == true ]]; then
    step "Notarizing (usually a few minutes)"
    # notarytool can exit 0 for a rejected submission, so check the reported status
    result=$(xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait 2>&1) || true
    echo "$result"
    if ! grep -q 'status: Accepted' <<<"$result"; then
        submission=$(awk '/^ *id:/ { print $2; exit }' <<<"$result")
        fail "Notarization failed. Apple's report: xcrun notarytool log ${submission:-<id>} --keychain-profile $notary_profile"
    fi
    # Attach the ticket to the DMG so Gatekeeper can check it offline
    xcrun stapler staple -q "$dmg"
    xcrun stapler validate -q "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    echo -e "${GREEN}✓ Notarized and stapled${NC}"
else
    echo -e "${YELLOW}Skipped notarization: other Macs will block this DMG (test build only)${NC}"
fi

shasum -a 256 "$dmg" | awk '{ print $1 }' > "$dmg.sha256"
echo -e "\n${GREEN}✓ $dmg${NC}"
echo "  SHA-256 $(cat "$dmg.sha256")"
if ! git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "  Next: git tag -a $tag -m \"Brew Updates app $version\" && git push origin $tag"
fi
