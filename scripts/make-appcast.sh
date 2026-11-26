#!/bin/bash
# Sign a release zip with Sparkle's EdDSA key and write a one-item appcast.xml for it.
#
#   scripts/make-appcast.sh <app.zip> <download-url> <release-notes-url> [appcast.xml]
#
# The version and minimum macOS come from the zipped app's Info.plist. The private key is
# read from $SPARKLE_ED_PRIVATE_KEY (passed to sign_update on stdin, never written to disk)
# or from the file named by $SPARKLE_ED_KEY_FILE. Release notes, if any, are Markdown read
# from $RELEASE_NOTES_FILE; the item always links to the release page as well.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1" URL="$2" NOTES_URL="$3" OUT="${4:-appcast.xml}"

SIGN_UPDATE="$(find .build/artifacts -type f -path '*/bin/sign_update' | head -1)"
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found; run swift package resolve first" >&2; exit 1; }

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$ZIP")"
elif [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    signature="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" -p "$ZIP")"
else
    echo "Set SPARKLE_ED_PRIVATE_KEY or SPARKLE_ED_KEY_FILE" >&2; exit 1
fi
[[ -n "$signature" ]] || { echo "sign_update gave no signature" >&2; exit 1; }

# Read the version from the app inside the zip, so the feed can't disagree with the update.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$ZIP" "$work"
plist="$(find "$work" -maxdepth 3 -path '*.app/Contents/Info.plist' | head -1)"
[[ -f "$plist" ]] || { echo "No app found in $ZIP" >&2; exit 1; }
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
build="$(read_plist CFBundleVersion)"
version="$(read_plist CFBundleShortVersionString)"
name="$(read_plist CFBundleName)"
min_system="$(read_plist LSMinimumSystemVersion)"

length="$(stat -f %z "$ZIP")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

notes="[Release notes on GitHub]($NOTES_URL)"
if [[ -n "${RELEASE_NOTES_FILE:-}" && -s "$RELEASE_NOTES_FILE" ]]; then
    notes="$(cat "$RELEASE_NOTES_FILE")"$'\n\n'"$notes"
fi
# CDATA can't contain its own terminator.
notes="${notes//]]>/]]&gt;}"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$(printf '%s' "$name" | xml_escape)</title>
    <link>$(printf '%s' "$NOTES_URL" | xml_escape)</link>
    <language>en</language>
    <item>
      <title>Version $(printf '%s' "$version" | xml_escape)</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$(printf '%s' "$build" | xml_escape)</sparkle:version>
      <sparkle:shortVersionString>$(printf '%s' "$version" | xml_escape)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(printf '%s' "$min_system" | xml_escape)</sparkle:minimumSystemVersion>
      <link>$(printf '%s' "$NOTES_URL" | xml_escape)</link>
      <description sparkle:format="markdown"><![CDATA[$notes]]></description>
      <enclosure url="$(printf '%s' "$URL" | xml_escape)" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT"
echo "wrote $OUT: $name $version ($build), $length bytes"
