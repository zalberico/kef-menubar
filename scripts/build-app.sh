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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KEFMenuBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the first Apple Development identity (ad-hoc if there is none).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict --verbose=1 "$APP"
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
