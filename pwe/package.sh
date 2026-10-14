#!/bin/zsh
#
# Build, sign and package PWE iMac Display as one disk image holding both apps.
#
#   pwe/package.sh                 build + sign + dmg   (local check, not for release)
#   pwe/package.sh --notarize      also notarise and staple the apps and the image
#
# Output: pwe/dist/PWE iMac Display <version>.dmg and SHA256SUMS.txt.
#
# The repository holds TargetBridge's code unchanged. Everything here happens to
# a scratch copy in $TMPDIR: pwe/rebrand.py turns it into PWE iMac Display, the
# two apps are built and signed there (iCloud Drive re-attaches
# com.apple.FinderInfo to anything inside it, and codesign refuses a bundle that
# carries it), and only the finished image comes back.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

NAME="PWE iMac Display"
RECEIVER_NAME="PWE iMac Display Receiver"
RECEIVER_ID="com.pwegroup.pweimacdisplay.receiver"
IDENTITY="Developer ID Application: Li Liu (2SQV3H5MH9)"
PROFILE="${NOTARY_PROFILE:-PWE_NOTARY}"
BUILD="$(date +%Y%m%d%H%M%S)"

WORK="${TMPDIR:-/tmp}/pwe-imacdisplay-release"
DEPS="${PWE_DEPS:-${TMPDIR:-/tmp}/pwe-imacdisplay-deps}"
SRC="$WORK/src"
OUT="$WORK/out"
DIST="$REPO/pwe/dist"

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    *) echo "✗ unknown option: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- preflight

security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "✗ signing identity not in the keychain: $IDENTITY"; exit 1; }
if [[ "$NOTARIZE" == 1 ]]; then
  # A locked screen keeps the notary profile in the keychain out of reach, and
  # the failure shows up only when the first submission is made.
  [[ "$(ioreg -n Root -d1 -a | plutil -extract IOConsoleLocked raw -)" == false ]] \
    || { echo "✗ the screen is locked; unlock it and run again"; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "✗ notary profile $PROFILE is not usable"; exit 1; }
  [[ -z "$(git status --porcelain)" ]] \
    || { echo "✗ commit first: a release is built from committed code only"; exit 1; }
fi

echo "▸ $NAME ($BUILD)"

# ---------------------------------------------------------------- source copy

rm -rf "$WORK"
mkdir -p "$SRC" "$OUT" "$DIST"
# Tracked files only, as they stand in the working tree (committed, for --notarize).
git ls-files -z | rsync -a --from0 --files-from=- ./ "$SRC/"
# From here on everything is read from this snapshot, never from the working
# tree: a branch switch or an edit during a ten-minute notarised build must not
# change what gets built. (2026-10-14: a branch switch mid-build removed
# pwe/receiver-deps.sh and the build stopped halfway.)
VERSION="$(<"$SRC/pwe/VERSION")"
DMG="$DIST/$NAME $VERSION.dmg"
python3 -I "$SRC/pwe/rebrand.py" "$SRC" --version "$VERSION" --build "$BUILD"

# ---------------------------------------------------------------- sender

echo "▸ Building the sender (arm64 + x86_64)…"
(
  cd "$SRC/TargetBridge-Sender"
  xcodegen generate -q
  TB_SENDER_BUILD="$BUILD" xcodebuild \
    -scheme TBDisplaySender -configuration Release \
    -derivedDataPath "$WORK/DerivedData" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    build >"$WORK/sender-build.log" 2>&1 \
    || { tail -30 "$WORK/sender-build.log"; exit 1; }
)
SENDER="$OUT/$NAME.app"
ditto "$WORK/DerivedData/Build/Products/Release/$NAME.app" "$SENDER"

# ---------------------------------------------------------------- receiver

echo "▸ Building the receiver's libraries (cached in $DEPS)…"
"$SRC/pwe/receiver-deps.sh" "$DEPS"

echo "▸ Building the receiver (arm64 + x86_64, macOS 11)…"
for ARCH in arm64 x86_64; do
  (
    cd "$SRC/TargetBridge-Receiver/TBReceiverC"
    make clean >/dev/null
    PKG_CONFIG_LIBDIR="$DEPS/$ARCH/lib/pkgconfig" PKG_CONFIG_PATH= \
      make CC="clang -arch $ARCH" PKG="pkg-config --static" \
        APP_VERSION="$VERSION" APP_BUILD="$BUILD" >"$WORK/receiver-$ARCH.log" 2>&1 \
      || { tail -30 "$WORK/receiver-$ARCH.log"; exit 1; }
    mv tbreceiver "$WORK/tbreceiver-$ARCH"
  )
done

RECEIVER="$OUT/$RECEIVER_NAME.app"
mkdir -p "$RECEIVER/Contents/MacOS" "$RECEIVER/Contents/Resources/Languages"
lipo -create "$WORK/tbreceiver-arm64" "$WORK/tbreceiver-x86_64" \
  -output "$RECEIVER/Contents/MacOS/PWEiMacDisplayReceiver"
cp "$SRC/TargetBridge-Shared/Languages/"*.json "$RECEIVER/Contents/Resources/Languages/"
iconutil -c icns "$SRC/pwe/assets/AppIcon.iconset" -o "$RECEIVER/Contents/Resources/AppIcon.icns"
cat > "$RECEIVER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$RECEIVER_NAME</string>
    <key>CFBundleExecutable</key><string>PWEiMacDisplayReceiver</string>
    <key>CFBundleIdentifier</key><string>$RECEIVER_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>$RECEIVER_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>PWE Group. Based on TargetBridge (MIT).</string>
    <key>NSLocalNetworkUsageDescription</key><string>$RECEIVER_NAME receives the picture from your Mac over Thunderbolt Bridge.</string>
    <key>NSBonjourServices</key><array><string>_targetbridge._tcp</string></array>
</dict>
</plist>
EOF
printf 'APPL????' > "$RECEIVER/Contents/PkgInfo"

# Licences travel inside each app and in the image: FFmpeg is LGPL and linked
# statically, so its licence text and the way to rebuild it must ship with it.
LICENSES="$WORK/Licenses"
mkdir -p "$LICENSES"
cp "$SRC/LICENSE" "$LICENSES/TargetBridge LICENSE (MIT).txt"
cp "$SRC/pwe/NOTICE.txt" "$LICENSES/NOTICE.txt"
tar -xJf "$DEPS/src/ffmpeg-"*.tar.xz -O '*/COPYING.LGPLv2.1' > "$LICENSES/FFmpeg COPYING.LGPLv2.1.txt"
tar -xzf "$DEPS/src/SDL2-"*.tar.gz -O '*/LICENSE.txt' > "$LICENSES/SDL2 LICENSE (zlib).txt"
for APP in "$SENDER" "$RECEIVER"; do
  ditto "$LICENSES" "$APP/Contents/Resources/Licenses"
done

# ---------------------------------------------------------------- checks before signing

echo "▸ Checking the bundles…"
for ARCH in arm64 x86_64; do
  MIN="$(vtool -arch $ARCH -show-build "$RECEIVER/Contents/MacOS/PWEiMacDisplayReceiver" | awk '/minos/ {print $2}')"
  [[ "$MIN" == 11.0 ]] || { echo "✗ receiver $ARCH needs macOS $MIN, not 11.0"; exit 1; }
done
# Dependency lines are indented; a universal binary also prints one header per slice.
if otool -L "$RECEIVER/Contents/MacOS/PWEiMacDisplayReceiver" | awk '/^[[:space:]]/ {print $1}' \
     | grep -v -E '^(/System/Library/|/usr/lib/)'; then
  echo "✗ the receiver links a library outside the system"; exit 1
fi
lipo -info "$SENDER/Contents/MacOS/$NAME" | grep -q "x86_64 arm64\|arm64 x86_64" \
  || { echo "✗ the sender is not universal"; exit 1; }

# ---------------------------------------------------------------- sign

echo "▸ Signing with $IDENTITY…"
xattr -cr "$SENDER" "$RECEIVER"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements "$SRC/pwe/sender.entitlements" "$SENDER"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$RECEIVER"
for APP in "$SENDER" "$RECEIVER"; do
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
done

notarize() {  # notarize <file> <label>
  echo "▸ Notarising $2 (profile $PROFILE)…"
  local submit id
  # notarytool exits 0 when Apple rejects a submission; read the status instead.
  submit="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)"
  echo "$submit" | sed 's/^/    /'
  if ! grep -q "status: Accepted" <<<"$submit"; then
    id="$(grep -m1 "  id: " <<<"$submit" | awk '{print $2}')"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" 2>&1 | sed 's/^/    /'
    echo "✗ Apple did not accept $2"; exit 1
  fi
}

if [[ "$NOTARIZE" == 1 ]]; then
  for APP in "$SENDER" "$RECEIVER"; do
    ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
    notarize "$WORK/notarize.zip" "$(basename "$APP")"
    rm -f "$WORK/notarize.zip"
    xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
  done
fi

# ---------------------------------------------------------------- disk image

echo "▸ Building the disk image…"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$SENDER" "$STAGE/$NAME.app"
ditto "$RECEIVER" "$STAGE/$RECEIVER_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$SRC/pwe/read-me-first.txt" "$STAGE/读我 Read Me First.txt"
ditto "$LICENSES" "$STAGE/Licenses"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "$WORK/image.dmg" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$WORK/image.dmg"

if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$WORK/image.dmg" "the disk image"
  xcrun stapler staple "$WORK/image.dmg" && xcrun stapler validate "$WORK/image.dmg"
  echo "▸ Gatekeeper:"
  spctl -a -t open --context context:primary-signature -vv "$WORK/image.dmg" 2>&1 | sed 's/^/    /'
  for APP in "$SENDER" "$RECEIVER"; do
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /'
  done
fi

cp "$WORK/image.dmg" "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)

echo
echo "▸ $DMG"
echo "    $(du -h "$DMG" | cut -f1)   $(cut -c1-16 "$DIST/SHA256SUMS.txt")…"
[[ "$NOTARIZE" == 1 ]] || echo "    Not notarised: a local check only. Release with pwe/package.sh --notarize."
