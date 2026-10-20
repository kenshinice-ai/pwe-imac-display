#!/bin/zsh
#
# Build, sign and package PWE iMac Display as one disk image holding both apps.
#
#   pwe/package.sh                 build + sign + dmg   (local check, not for release)
#   pwe/package.sh --notarize      also notarise and staple the apps and the image
#   pwe/package.sh --unsigned --deps <dir>
#                                  anyone's build: ad-hoc signed, with the FFmpeg
#                                  and SDL2 already built in <dir>/{arm64,x86_64}
#                                  (how NOTICE.txt tells users to relink FFmpeg)
#
# Output: pwe/dist/PWE-iMac-Display-<version>.dmg, SHA256SUMS.txt, and the FFmpeg
# source the receiver was built from (LGPL: offered from the same place).
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

# A fresh directory per run, so two builds never delete or mix each other's files.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pwe-imacdisplay-release.XXXXXX")"
DEPS="${PWE_DEPS:-${TMPDIR:-/tmp}/pwe-imacdisplay-deps}"
SRC="$WORK/src"
OUT="$WORK/out"
DIST="$REPO/pwe/dist"   # notarised release builds only; local checks go to dist/local

NOTARIZE=0
UNSIGNED=0
OWN_DEPS=0
while (( $# )); do
  case "$1" in
    --notarize) NOTARIZE=1 ;;
    --unsigned) UNSIGNED=1; IDENTITY="-" ;;
    --deps) DEPS="${2:?--deps needs a directory}"; OWN_DEPS=1; shift ;;
    *) echo "✗ unknown option: $1"; exit 1 ;;
  esac
  shift
done
[[ "$NOTARIZE$UNSIGNED" != 11 ]] || { echo "✗ --notarize needs the Developer ID"; exit 1; }

# ---------------------------------------------------------------- preflight

[[ "$UNSIGNED" == 1 ]] || security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "✗ signing identity not in the keychain: $IDENTITY"; exit 1; }
if [[ "$NOTARIZE" == 1 ]]; then
  # A locked screen keeps the notary profile in the keychain out of reach, and
  # the failure shows up only when the first submission is made.
  [[ "$(ioreg -n Root -d1 -a | plutil -extract IOConsoleLocked raw -)" == false ]] \
    || { echo "✗ the screen is locked; unlock it and run again"; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "✗ notary profile $PROFILE is not usable"; exit 1; }
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || { echo "✗ commit first: a release is built from committed code only"; exit 1; }
  # The release is the tagged commit, so the version and the code cannot drift apart.
  TAG="pwe-$(<pwe/VERSION)"
  git tag --points-at HEAD | grep -qx "$TAG" \
    || { echo "✗ tag the release first: git tag $TAG (HEAD is not $TAG)"; exit 1; }
fi

echo "▸ $NAME ($BUILD)"

# ---------------------------------------------------------------- source copy

[[ "$NOTARIZE" == 1 ]] || DIST="$DIST/local"
mkdir -p "$SRC" "$OUT" "$DIST"
# Tracked files only, as they stand in the working tree (committed, for --notarize).
git ls-files -z | rsync -a --from0 --files-from=- ./ "$SRC/"
# From here on everything is read from this snapshot, never from the working
# tree: a branch switch or an edit during a ten-minute notarised build must not
# change what gets built. (2026-10-14: a branch switch mid-build removed
# pwe/receiver-deps.sh and the build stopped halfway.)
VERSION="$(<"$SRC/pwe/VERSION")"
DMG="$DIST/PWE-iMac-Display-$VERSION.dmg"   # the name the release and the cask use
python3 -I "$SRC/pwe/rebrand.py" "$SRC" --version "$VERSION" --build "$BUILD"

# ---------------------------------------------------------------- disk-image tool

# dmgbuild lays out the disk-image window (background, icon places, volume icon)
# by writing .DS_Store itself, so no Finder window opens during a build. Pinned
# wheels in a cached venv, reinstalled when pwe/brand/dmg/requirements.txt changes.
# Early, so a missing tool stops the run before ten minutes of building.
DMGBUILD="${PWE_DMGBUILD:-${TMPDIR:-/tmp}/pwe-imacdisplay-dmgbuild}"
DMG_REQS="$SRC/pwe/brand/dmg/requirements.txt"
if ! cmp -s "$DMG_REQS" "$DMGBUILD/requirements.txt" || [[ ! -x "$DMGBUILD/bin/dmgbuild" ]]; then
  echo "▸ Installing dmgbuild into $DMGBUILD…"
  rm -rf "$DMGBUILD"
  python3 -m venv "$DMGBUILD"
  "$DMGBUILD/bin/pip" install -q --require-hashes --only-binary :all: -r "$DMG_REQS" \
    || { rm -rf "$DMGBUILD"; echo "✗ could not install dmgbuild (pwe/brand/dmg/requirements.txt)"; exit 1; }
  cp "$DMG_REQS" "$DMGBUILD/requirements.txt"
fi

# ---------------------------------------------------------------- libraries

# Before the sender: it links libsodium from here too (pairing and encryption).
if [[ "$OWN_DEPS" == 1 ]]; then
  echo "▸ Using the receiver's libraries as built in $DEPS"
else
  echo "▸ Building the receiver's libraries (cached in $DEPS)…"
  "$SRC/pwe/receiver-deps.sh" "$DEPS"
fi
[[ -f "$DEPS/universal/lib/libsodium.a" ]] \
  || { echo "✗ no $DEPS/universal/lib/libsodium.a: run pwe/receiver-deps.sh $DEPS"; exit 1; }

# ---------------------------------------------------------------- sender

echo "▸ Building the sender (arm64 + x86_64)…"
(
  cd "$SRC/TargetBridge-Sender"
  xcodegen generate -q
  TB_SENDER_BUILD="$BUILD" xcodebuild \
    -scheme TBDisplaySender -configuration Release \
    -derivedDataPath "$WORK/DerivedData" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    PWE_SODIUM_DIR="$DEPS/universal" \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    build >"$WORK/sender-build.log" 2>&1 \
    || { tail -30 "$WORK/sender-build.log"; exit 1; }
)
SENDER="$OUT/$NAME.app"
ditto "$WORK/DerivedData/Build/Products/Release/$NAME.app" "$SENDER"

# ---------------------------------------------------------------- receiver

echo "▸ Building the receiver (arm64 + x86_64, macOS 11)…"
for ARCH in arm64 x86_64; do
  (
    cd "$SRC/TargetBridge-Receiver/TBReceiverC"
    make clean >/dev/null
    # A clean environment: the Makefile appends to CFLAGS and LDFLAGS, so an
    # exported -I/opt/homebrew/include would compile against other headers.
    env -i PATH="$PATH" HOME="$HOME" \
      PKG_CONFIG_LIBDIR="$DEPS/$ARCH/lib/pkgconfig" \
      make CC="clang -arch $ARCH" PKG="pkg-config --static" DIRECT_LINK_ONLY=1 COMPACT_IDLE=1 OFFER_LOGIN_ITEM=1 \
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
# The paper wing on the receiver's screens (display.c, tb_disp_draw_wing).
cp "$SRC/pwe/brand/receiver/receiver-wing.pdf" "$RECEIVER/Contents/Resources/"
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
    <key>NSHumanReadableCopyright</key><string>© 2026 PWE Group Pty Ltd. Based on TargetBridge (MIT).</string>
    <key>NSLocalNetworkUsageDescription</key><string>$RECEIVER_NAME receives the picture from your Mac over Thunderbolt Bridge.</string>
    <key>NSBonjourServices</key><array><string>_targetbridge._tcp</string></array>
</dict>
</plist>
EOF
printf 'APPL????' > "$RECEIVER/Contents/PkgInfo"

# Licences travel inside each app and in the image: FFmpeg is LGPL and linked
# statically, so its licence text, its exact configuration and the way to
# relink it ship with it, and its source goes next to the image.
FFMPEG_SRC="$(sed -n 's/^FFMPEG=//p' "$SRC/pwe/receiver-deps.sh").tar.xz"
SDL_SRC="$(sed -n 's/^SDL=//p' "$SRC/pwe/receiver-deps.sh").tar.gz"
SODIUM_SRC="$(sed -n 's/^SODIUM=//p' "$SRC/pwe/receiver-deps.sh").tar.gz"
DEPS_SRC="${PWE_DEPS_SRC:-$DEPS/src}"
LICENSES="$WORK/Licenses"
mkdir -p "$LICENSES"
cp "$SRC/LICENSE" "$LICENSES/TargetBridge LICENSE (MIT).txt"
cp "$SRC/pwe/NOTICE.txt" "$LICENSES/NOTICE.txt"
tar -xJf "$DEPS_SRC/$FFMPEG_SRC" -O '*/COPYING.LGPLv2.1' > "$LICENSES/FFmpeg COPYING.LGPLv2.1.txt"
tar -xzf "$DEPS_SRC/$SDL_SRC" -O '*/LICENSE.txt' > "$LICENSES/SDL2 LICENSE (zlib).txt"
tar -xzf "$DEPS_SRC/$SODIUM_SRC" -O '*/LICENSE' > "$LICENSES/libsodium LICENSE (ISC).txt"
for ARCH in arm64 x86_64; do
  if [[ -f "$DEPS/$ARCH/ffmpeg-configuration.txt" ]]; then
    # The prefix is the builder's own path; it says nothing about the build.
    print -r -- "$ARCH: ./configure $(sed 's|--prefix=[^ ]*|--prefix=<prefix>|' "$DEPS/$ARCH/ffmpeg-configuration.txt")"
  else  # only with --deps: FFmpeg built some other way
    print -r -- "$ARCH: not recorded (FFmpeg was built outside pwe/receiver-deps.sh)"
  fi
done > "$LICENSES/FFmpeg configuration.txt"
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
for ARCH in arm64 x86_64; do
  MIN="$(vtool -arch $ARCH -show-build "$SENDER/Contents/MacOS/$NAME" | awk '/minos/ {print $2}')"
  [[ "$MIN" == 14.0 ]] || { echo "✗ sender $ARCH needs macOS $MIN, not the 14.0 the docs promise"; exit 1; }
done
# Without the wing the receiver falls back to the app icon: it works, but it is not the design.
[[ -s "$RECEIVER/Contents/Resources/receiver-wing.pdf" ]] || { echo "✗ the receiver has no receiver-wing.pdf"; exit 1; }
# Weak imports for older systems, and the old URL scheme hidden in code.
python3 -I "$SRC/pwe/check-bundle.py" "$SENDER" "$RECEIVER"

# ---------------------------------------------------------------- sign

echo "▸ Signing with $IDENTITY…"
xattr -cr "$SENDER" "$RECEIVER"
TIMESTAMP=(--timestamp)
[[ "$UNSIGNED" == 0 ]] || TIMESTAMP=(--timestamp=none)
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" \
  --entitlements "$SRC/pwe/sender.entitlements" "$SENDER"
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$RECEIVER"
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
    # One command per line: zsh's set -e ignores a failure on the left of &&,
    # and an unstapled receiver cannot be checked on an iMac that is offline.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
  done
fi

# ---------------------------------------------------------------- disk image

echo "▸ Building the disk image…"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$SENDER" "$STAGE/$NAME.app"
ditto "$RECEIVER" "$STAGE/$RECEIVER_NAME.app"
cp "$SRC/pwe/read-me-first.txt" "$STAGE/读我 Read Me First.txt"
ditto "$LICENSES" "$STAGE/Licenses"
iconutil -c icns "$SRC/pwe/assets/AppIcon.iconset" -o "$WORK/VolumeIcon.icns"
# The window: pwe/brand/dmg/settings.py (icon places, the Applications link) and
# pwe/brand/dmg/background{,@2x}.png (pwe/brand/make.py).
"$DMGBUILD/bin/dmgbuild" -s "$SRC/pwe/brand/dmg/settings.py" \
  -D stage="$STAGE" -D icon="$WORK/VolumeIcon.icns" \
  -D background="$SRC/pwe/brand/dmg/background.png" \
  "$NAME $VERSION" "$WORK/image.dmg" >"$WORK/dmgbuild.log" 2>&1 \
  || { tail -20 "$WORK/dmgbuild.log"; exit 1; }
# The apps must come out of the image as they went in: a Finder flag on a bundle
# (dmgbuild's hide-extension, for one) breaks its signature. Read-only, not shown.
CHECK_MNT="$WORK/check-mount"
mkdir -p "$CHECK_MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$CHECK_MNT" "$WORK/image.dmg"
for APP in "$NAME.app" "$RECEIVER_NAME.app"; do
  codesign --verify --deep --strict "$CHECK_MNT/$APP" \
    || { hdiutil detach -quiet "$CHECK_MNT"; echo "✗ $APP in the image fails codesign --verify"; exit 1; }
done
hdiutil detach -quiet "$CHECK_MNT"
codesign --force "${TIMESTAMP[@]}" --sign "$IDENTITY" "$WORK/image.dmg"

if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$WORK/image.dmg" "the disk image"
  xcrun stapler staple "$WORK/image.dmg"
  xcrun stapler validate "$WORK/image.dmg"
  echo "▸ Gatekeeper:"
  spctl -a -t open --context context:primary-signature -vv "$WORK/image.dmg" 2>&1 | sed 's/^/    /'
  for APP in "$SENDER" "$RECEIVER"; do
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /'
  done
fi

cp "$WORK/image.dmg" "$DMG"
cp "$DEPS_SRC/$FFMPEG_SRC" "$DIST/$FFMPEG_SRC"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$FFMPEG_SRC" > SHA256SUMS.txt)

echo
echo "▸ $DMG"
echo "    $(du -h "$DMG" | cut -f1)   $(head -1 "$DIST/SHA256SUMS.txt" | cut -c1-16)…"
echo "    Upload all three to the release: the image, $FFMPEG_SRC, SHA256SUMS.txt."
[[ "$NOTARIZE" == 1 ]] || echo "    Not notarised: a local check only. Release with pwe/package.sh --notarize."
rm -rf "$WORK"
