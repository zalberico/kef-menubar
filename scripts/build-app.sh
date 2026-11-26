#!/bin/bash
# Build "KEF Menu Bar.app", sign it for local use, and optionally install it.
#   scripts/build-app.sh            # build into build/
#   scripts/build-app.sh --install  # also copy to ~/Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_NAME="KEF Menu Bar"
APP="build/$APP_NAME.app"

swift build -c release --product KEFMenuBar --arch arm64
BIN="$(swift build -c release --product KEFMenuBar --arch arm64 --show-bin-path)/KEFMenuBar"

if [[ ! -f Resources/AppIcon.icns || Sources/KEFMenuBar/SpeakerGlyph.swift -nt Resources/AppIcon.icns ]]; then
    ICON_SCRIPT="$(mktemp -d)/make-icon.swift"
    cat Sources/KEFMenuBar/SpeakerGlyph.swift scripts/make-icon.swift > "$ICON_SCRIPT"
    swift "$ICON_SCRIPT" Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/KEFMenuBar"
# SwiftPM links Sparkle with @rpath but only adds @loader_path; the framework lives in Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/KEFMenuBar"

# Embed Sparkle.framework (auto-updates). The app isn't sandboxed, so Sparkle's XPC services
# are unused and dropped, along with headers; the binaries are thinned to arm64 like the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_SRC="$(dirname "$BIN")/Sparkle.framework"
# SwiftPM copies it next to the binary; fall back to the resolved xcframework if it didn't.
[[ -d "$SPARKLE_SRC" ]] || SPARKLE_SRC="$(find .build/artifacts -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' | head -1)"
[[ -d "$SPARKLE_SRC" ]] || { echo "Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
ditto "$SPARKLE_SRC" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices" \
       "$FW/Versions/B/Headers" "$FW/Headers" \
       "$FW/Versions/B/PrivateHeaders" "$FW/PrivateHeaders" \
       "$FW/Versions/B/Modules" "$FW/Modules"
for macho in "$FW/Versions/B/Sparkle" "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    if lipo -archs "$macho" | grep -qw x86_64; then lipo -thin arm64 "$macho" -output "$macho.thin" && mv "$macho.thin" "$macho"; fi
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Release builds stamp the version: APP_VERSION=1.2.0 BUILD_NUMBER=42 scripts/build-app.sh
[[ -n "${APP_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the first Apple Development identity (ad-hoc if there is none).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
# Notarization needs a secure timestamp, so Developer ID builds get one.
TIMESTAMP=--timestamp=none
[[ "$IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP=--timestamp
# The hardened runtime's library validation refuses an ad-hoc signed Sparkle.framework,
# so ad-hoc builds (which can't be notarized anyway) go without it.
RUNTIME=--options=runtime
[[ "${IDENTITY:--}" == "-" ]] && RUNTIME=
# Inside-out, as Sparkle's docs describe for apps signed outside Xcode: the framework's
# helpers, then the framework, then the app.
sign() { codesign --force ${RUNTIME:+"$RUNTIME"} "$TIMESTAMP" --sign "${IDENTITY:--}" "$@"; }
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    pkill -x KEFMenuBar 2>/dev/null && sleep 0.5 || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "installed and launched $DEST"
fi
