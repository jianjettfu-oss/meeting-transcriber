#!/usr/bin/env bash
# Launch the Meeting Transcriber menu bar app.
# Builds an .app bundle so macOS APIs (notifications, etc.) work correctly.
#
# Build happens in-tree under .build/; the LAUNCH always happens from the
# canonical deploy path ~/Applications/MeetingTranscriber-Dev.app, the same
# one scripts/e2e-*.sh use. Launching the in-tree bundle instead would give
# LaunchServices a second copy to arbitrate over, and would anchor the app's
# identity inside a directory that `swift package clean` deletes.
#
# --build-only: build + sign in-tree, skip deploy + launch. Used by the
#   Pattern-C E2E driver (scripts/e2e-app.sh), which does its own deploy to
#   the same canonical path and launches it itself.

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
# Canonical deploy path — same constant as scripts/e2e-*.sh's DEV_BUNDLE_DEPLOY,
# so a manual launch and an e2e run share ONE bundle (and therefore one set of
# TCC grants). ~/Applications rather than /Applications because it needs no
# admin rights, which is what the self-hosted runner user has.
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"

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
# Sign one bundle and assert the result. Applied to the in-tree bundle and
# again to the deployed copy: rsync carries the signature over, but re-signing
# at the destination is what keeps `codesign --verify` meaningful there.
sign_and_verify() {
    local bundle="$1" info
    echo "  Signing ($SIGN_DESC): $bundle"
    codesign --force --sign "$SIGN_HASH" "$bundle" || {
        echo "ERROR: codesign failed ($SIGN_DESC) for $bundle." >&2
        echo "       Refusing to continue: an unsigned bundle gets no" >&2
        echo "       notification permission and no stable TCC grant." >&2
        exit 1
    }
    # `codesign --sign` exiting 0 is a receipt, not evidence — assert the two
    # properties a linker-signed bundle lacks (sealed resources, and an
    # identifier that is the bundle ID rather than the linker's default binary
    # name).
    codesign --verify "$bundle" || {
        echo "ERROR: codesign --verify failed for $bundle" >&2
        exit 1
    }
    info=$(codesign -dv --verbose=2 "$bundle" 2>&1)
    grep -q '^Sealed Resources' <<<"$info" || {
        echo "ERROR: no sealed resources after signing $bundle — Info.plist is" >&2
        echo "       unbound, so notifications will not work. codesign -dv said:" >&2
        echo "$info" >&2
        exit 1
    }
    grep -q '^Identifier=com\.meetingtranscriber\.dev$' <<<"$info" || {
        echo "ERROR: signed identifier is not com.meetingtranscriber.dev —" >&2
        echo "       $(grep '^Identifier=' <<<"$info")" >&2
        exit 1
    }
    echo "  Signed OK: $(grep '^Sealed Resources' <<<"$info")"
}

sign_and_verify "$APP_BUNDLE"

if [ "$BUILD_ONLY" = true ]; then
    echo "Bundle ready: $APP_BUNDLE"
    exit 0
fi

# Deploy to the canonical path before launching. rsync into the EXISTING
# directory rather than delete+recreate: LaunchServices re-registers a
# recreated bundle from scratch, and a half-registered app is a worse failure
# than a stale one. TCC itself keys on the bundle ID + code-signing
# requirement, not the path (verified 2026-07-31: the same signed bundle moved
# between /Applications and ~/Applications kept all four grants), so the
# constant path is about LaunchServices and about humans being able to tell
# which copy is running — not about preserving permissions.
echo "Deploying to $DEV_BUNDLE_DEPLOY"
mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
    rsync -a --delete "$APP_BUNDLE/" "$DEV_BUNDLE_DEPLOY/"
else
    cp -R "$APP_BUNDLE" "$DEV_BUNDLE_DEPLOY"
fi
sign_and_verify "$DEV_BUNDLE_DEPLOY"

echo "Starting Meeting Transcriber..."
echo "  bundle=$DEV_BUNDLE_DEPLOY"

# Launch via `open` so macOS LaunchServices properly registers the app
# (required for notification permissions, etc.), and from the deployed copy
# rather than the in-tree one so there is exactly one registered bundle.
#
# The app does NOT need the project tree at runtime: every path it uses comes
# from AppPaths (~/Library/Application Support/MeetingTranscriber), and no
# Swift source reads TRANSCRIBER_ROOT — it is script-local. (`open` would not
# pass the exported value through LaunchServices anyway.)
open -W "$DEV_BUNDLE_DEPLOY"
