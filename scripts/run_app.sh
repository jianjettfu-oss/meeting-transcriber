#!/usr/bin/env bash
# Launch the Meeting Transcriber menu bar app.
# Builds an .app bundle so macOS APIs (notifications, etc.) work correctly.
#
# --build-only: Build the bundle but skip `open -W`. Used by the Pattern-C
#   E2E driver (scripts/e2e-app.sh) which deploys the bundle to a stable
#   path and launches it itself; opening the in-tree bundle there would
#   confuse macOS LaunchServices about which one to use for TCC.

set -euo pipefail

BUILD_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIBER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export TRANSCRIBER_ROOT

SPM_DIR="$TRANSCRIBER_ROOT/app/MeetingTranscriber"
BUILD_BINARY="$SPM_DIR/.build/release/MeetingTranscriber"
APP_BUNDLE="$SPM_DIR/.build/MeetingTranscriber-Dev.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/MeetingTranscriber"
INFO_PLIST="$SPM_DIR/Sources/Info.plist"

# Always rebuild to pick up code changes
echo "Building Meeting Transcriber app..."
cd "$SPM_DIR"
SWIFT_BUILD_FLAGS=(-c release)
# Opt-in fault-injection build for the mic-device-change e2e lane only
# (scripts/e2e-app.sh --mic-device-change). Compiles the issue #379
# reproduction seam in MicCaptureHandler; never set for normal/release builds.
if [ -n "${MTT_FAULT_INJECTION:-}" ]; then
    SWIFT_BUILD_FLAGS+=(-Xswiftc -DE2E_FAULT_INJECTION)
    echo "  (fault-injection build: -DE2E_FAULT_INJECTION)"
fi
swift build "${SWIFT_BUILD_FLAGS[@]}"

# Assemble .app bundle
mkdir -p "$APP_MACOS"
# Use dev bundle identifier to keep permissions separate from release
sed 's/com\.meetingtranscriber\.app/com.meetingtranscriber.dev/' \
    "$INFO_PLIST" > "$APP_BUNDLE/Contents/Info.plist"

# Distinguish the dev build in every OS-level app list. The bundle ID already
# separates permissions, but System Settings > Notifications / Privacy keys its
# ROWS off the display name — with both bundles reading "Meeting Transcriber"
# the two are indistinguishable there, and a permission granted to the release
# build looks like it was granted to this one (2026-07-31: cost a real debugging
# session chasing a notification warning that was telling the truth).
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Meeting Transcriber (Dev)" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Meeting Transcriber (Dev)" \
    "$APP_BUNDLE/Contents/Info.plist"

# Inject version from VERSION file
APP_VERSION=$(cat "$TRANSCRIBER_ROOT/VERSION" | tr -d '[:space:]')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Inject git commit hash into Info.plist
GIT_HASH=$(git -C "$TRANSCRIBER_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommitHash $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist"

cp "$BUILD_BINARY" "$APP_BINARY"

# Code-sign the bundle. NOT optional, and never silently skipped: a bundle left
# linker-signed has `Info.plist=not bound` and `Sealed Resources=none`, so macOS
# will not register it as a notification client — `requestAuthorization()` never
# resolves, `notificationSettings()` stays `.notDetermined` forever, and the
# browser-meeting consent prompt (issue #503) can never appear. TCC also can't
# hold Screen Recording / Accessibility grants across rebuilds without it.
#
# Identity discovery uses the SHA-1 hash to avoid "ambiguous identity" errors
# with duplicate names, and matches the real identity rows (`  1) <40-hex> "…"`)
# rather than `head -1`. On a keychain with no certificate `find-identity` prints
# "     0 valid identities found" as its ONLY line — the previous `head -1 |
# awk '{print $2}'` read the literal word "valid" out of it, passed the `-n`
# test, and ran `codesign --sign valid`, which failed into `2>/dev/null` and left
# the bundle unsigned while the script still exited 0 (2026-07-31: three months
# of dev builds with no notification permission, diagnosed off the Settings
# "Browser meetings cannot be recorded" warning).
SIGN_HASH=$(security find-identity -v -p codesigning \
    | awk '/^ *[0-9]+\) [0-9A-F]{40} /{print $2; exit}')
if [ -n "$SIGN_HASH" ]; then
    SIGN_DESC="identity $SIGN_HASH"
else
    # Ad-hoc still produces the bound Info.plist + sealed-resource envelope that
    # notification/TCC registration actually needs, so it is a real fallback and
    # not a no-op. Caveat: the cdhash changes on every rebuild, so TCC grants
    # reset each time — run scripts/setup-self-hosted-runner.sh for a stable
    # self-signed cert if that churn starts costing more than it saves.
    SIGN_HASH="-"
    SIGN_DESC="ad-hoc (no codesigning identity in keychain)"
fi
echo "  Signing: $SIGN_DESC"
codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE" || {
    echo "ERROR: codesign failed ($SIGN_DESC)." >&2
    echo "       Refusing to launch: an unsigned bundle gets no notification" >&2
    echo "       permission and no stable TCC grant." >&2
    exit 1
}

# Verify the signature took. `codesign --sign` exiting 0 is a receipt, not
# evidence — assert the two properties a linker-signed bundle lacks (sealed
# resources, and an identifier that is the bundle ID rather than the linker's
# default binary name).
codesign --verify "$APP_BUNDLE" || {
    echo "ERROR: codesign --verify failed for $APP_BUNDLE" >&2
    exit 1
}
SIGN_INFO=$(codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1)
grep -q '^Sealed Resources' <<<"$SIGN_INFO" || {
    echo "ERROR: no sealed resources after signing — Info.plist is unbound," >&2
    echo "       so notifications will not work. codesign -dv said:" >&2
    echo "$SIGN_INFO" >&2
    exit 1
}
grep -q '^Identifier=com\.meetingtranscriber\.dev$' <<<"$SIGN_INFO" || {
    echo "ERROR: signed identifier is not com.meetingtranscriber.dev —" >&2
    echo "       $(grep '^Identifier=' <<<"$SIGN_INFO")" >&2
    exit 1
}
echo "  Signed OK: $(grep '^Sealed Resources' <<<"$SIGN_INFO")"

if [ "$BUILD_ONLY" = true ]; then
    echo "Bundle ready: $APP_BUNDLE"
    exit 0
fi

echo "Starting Meeting Transcriber..."
echo "  TRANSCRIBER_ROOT=$TRANSCRIBER_ROOT"

# Launch via `open` so macOS LaunchServices properly registers the app
# (required for notification permissions, etc.).
# The app discovers the project root by walking up from the executable.
open -W "$APP_BUNDLE"
