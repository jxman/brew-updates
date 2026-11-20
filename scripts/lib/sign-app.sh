#!/bin/bash
# Signs a built Brew Updates.app with the hardened runtime, nested code first: signing a
# bundle doesn't re-sign the code inside it, and notarization checks every executable.
# Sourced by scripts/install-app.sh and scripts/release.sh.
#
#   sign_app <app> <identity> [codesign options...]
#
# <identity> is a certificate name, or "-" for ad hoc. Extra options go to every codesign
# call (release.sh passes --timestamp, install-app.sh --timestamp=none).

sign_app() {
    local app="$1" identity="$2"
    shift 2
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"

    # Sparkle's XPC services are only for sandboxed apps; this one isn't sandboxed, so they'd
    # be unused code that still has to be signed and notarized
    rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"

    codesign --force --options runtime --sign "$identity" "$@" "$sparkle/Versions/B/Autoupdate"
    codesign --force --options runtime --sign "$identity" "$@" "$sparkle/Versions/B/Updater.app"
    codesign --force --options runtime --sign "$identity" "$@" "$sparkle"
    # The LaunchAgent runs this helper; macOS shows the job as the app's only when the helper
    # is signed by the same team
    codesign --force --options runtime --sign "$identity" "$@" -i com.jxman.BrewUpdates.launcher \
        "$app/Contents/MacOS/brew-updates-launcher"
    codesign --force --options runtime --sign "$identity" "$@" "$app"
    codesign --verify --strict --deep "$app"
}
