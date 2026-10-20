#!/bin/zsh
#
# Every automatic check of PWE Screen Encore, in one command. Run it before
# every candidate build and before a release.
#
#   pwe/verify.sh                   the source: sender tests, receiver tests,
#                                   end-to-end receiver smoke on arm64 and x86_64
#   pwe/verify.sh --dmg <image>     also checks the apps inside a built image
#                                   (pwe/check-bundle.py, signatures)
#   pwe/verify.sh --skip-smoke      leave out the smoke runs (they open windows)
#
# Like pwe/package.sh it works on a renamed scratch copy in $TMPDIR, so what is
# tested is what ships, not upstream's names. The working tree's tracked files are
# copied as they stand, uncommitted edits included.
#
# Needs the receiver's libraries from pwe/receiver-deps.sh (the same cache
# package.sh uses; $PWE_DEPS overrides it), xcodegen, and a GUI session for the
# smoke runs. The smoke's video phases also need the ffmpeg command.
#
# Prints one line per check and a table at the end. A check that could not run
# is SKIP with the reason, never PASS. Exit 1 if anything failed.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
DEPS="${PWE_DEPS:-${TMPDIR:-/tmp}/pwe-imacdisplay-deps}"
DMG=""
SMOKE=1
while (( $# )); do
  case "$1" in
    --dmg) DMG="${2:?--dmg needs an image}"; shift ;;
    --skip-smoke) SMOKE=0 ;;
    *) echo "✗ unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ -z "$DMG" || -f "$DMG" ]] || { echo "✗ no image at $DMG"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pwe-imacdisplay-verify.XXXXXX")"
SRC="$WORK/src"
LOGS="$WORK/logs"
mkdir -p "$SRC" "$LOGS"

typeset -a NAMES RESULTS NOTES
record() { NAMES+=("$1"); RESULTS+=("$2"); NOTES+=("$3"); print -r -- "  $2  $1${3:+ — $3}"; }

# ---------------------------------------------------------------- source copy

git ls-files -z | rsync -a --from0 --files-from=- ./ "$SRC/"
VERSION="$(<"$SRC/pwe/VERSION")"
echo "▸ PWE Screen Encore $VERSION — logs in $LOGS"
if python3 -I "$SRC/pwe/rebrand.py" "$SRC" --version "$VERSION" --build 1 > "$LOGS/rebrand.log" 2>&1; then
  record "rename (pwe/rebrand.py)" PASS ""
else
  record "rename (pwe/rebrand.py)" FAIL "see rebrand.log"
  echo "✗ nothing else can run on an unrenamed copy"; exit 1
fi

have_deps() { [[ -f "$DEPS/$1/lib/pkgconfig/libsodium.pc" ]]; }

# ---------------------------------------------------------------- sender

if ! command -v xcodegen >/dev/null; then
  record "sender tests" SKIP "no xcodegen (brew install xcodegen)"
elif [[ ! -f "$DEPS/universal/lib/libsodium.a" ]]; then
  record "sender tests" SKIP "no $DEPS/universal: run pwe/receiver-deps.sh $DEPS"
else
  echo "▸ Sender tests…"
  ( cd "$SRC/TargetBridge-Sender" && xcodegen generate -q &&
    PWE_SODIUM_DIR="$DEPS/universal" xcodebuild -scheme TBDisplaySender -configuration Debug \
      -derivedDataPath "$WORK/DerivedData" CODE_SIGNING_ALLOWED=NO test ) > "$LOGS/sender-test.log" 2>&1
  ran="$(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ tests? skipped and [0-9]+ failures?' "$LOGS/sender-test.log" | tail -1)"
  [[ -n "$ran" ]] || ran="$(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$LOGS/sender-test.log" | tail -1)"
  if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOGS/sender-test.log"; then
    record "sender tests" PASS "$ran"
  else
    record "sender tests" FAIL "${ran:-did not build} — see sender-test.log"
  fi
fi

# ---------------------------------------------------------------- receiver

HOST_ARCH="$(uname -m)"
RECV="$SRC/TargetBridge-Receiver"
receiver_env() {   # <arch>: build this receiver for one architecture from the cached libraries
  export PKG_CONFIG_LIBDIR="$DEPS/$1/lib/pkgconfig" PKG_CONFIG_PATH="" CC="clang -arch $1" PKG="pkg-config --static"
}

if have_deps "$HOST_ARCH"; then
  echo "▸ Receiver unit tests ($HOST_ARCH)…"
  if ( receiver_env "$HOST_ARCH"; make -C "$RECV/TBReceiverC" clean >/dev/null; make -C "$RECV/TBReceiverC" test ) \
       > "$LOGS/receiver-test.log" 2>&1; then
    record "receiver unit tests ($HOST_ARCH)" PASS ""
  else
    record "receiver unit tests ($HOST_ARCH)" FAIL "see receiver-test.log"
  fi
else
  record "receiver unit tests" SKIP "no $DEPS/$HOST_ARCH: run pwe/receiver-deps.sh $DEPS"
fi

if [[ "$SMOKE" == 0 ]]; then
  record "receiver smoke" SKIP "--skip-smoke"
else
  for ARCH in arm64 x86_64; do
    if ! have_deps "$ARCH"; then
      record "receiver smoke ($ARCH)" SKIP "no $DEPS/$ARCH"; continue
    fi
    if [[ "$ARCH" == x86_64 && "$HOST_ARCH" == arm64 ]] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
      record "receiver smoke ($ARCH)" SKIP "Rosetta is not installed"; continue
    fi
    echo "▸ Receiver smoke ($ARCH, opens a window for about a minute)…"
    ( receiver_env "$ARCH"; zsh "$RECV/scripts/loopback_smoke.sh" ) > "$LOGS/smoke-$ARCH.log" 2>&1
    rc=$?
    if [[ $rc == 0 ]] && grep -q '^skipped' "$LOGS/smoke-$ARCH.log"; then
      record "receiver smoke ($ARCH)" SKIP "video and renderer phases skipped: no ffmpeg command"
    elif [[ $rc == 0 ]]; then
      record "receiver smoke ($ARCH)" PASS "all phases"
    else
      record "receiver smoke ($ARCH)" FAIL "see smoke-$ARCH.log"
    fi
  done
fi

# ---------------------------------------------------------------- built image

if [[ -z "$DMG" ]]; then
  record "built apps (check-bundle, signatures)" SKIP "no --dmg given"
else
  MNT="$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF}')"
  if [[ -z "$MNT" ]]; then
    record "built apps" FAIL "could not mount $DMG"
  else
    apps=("$MNT"/*.app)
    if python3 -I "$REPO/pwe/check-bundle.py" "${apps[@]}" > "$LOGS/check-bundle.log" 2>&1; then
      record "built apps: check-bundle" PASS ""
    else
      record "built apps: check-bundle" FAIL "see check-bundle.log"
    fi
    sig_ok=1 notarised=0 unnotarised=0
    for a in "${apps[@]}"; do
      codesign --verify --deep --strict "$a" >> "$LOGS/signatures.log" 2>&1 || sig_ok=0
      gk="$(spctl -a -t exec -vv "$a" 2>&1)"; print -r -- "$gk" >> "$LOGS/signatures.log"
      case "$gk" in
        *"source=Notarized Developer ID"*) notarised=$(( notarised + 1 )) ;;
        *"source=Unnotarized Developer ID"*) unnotarised=$(( unnotarised + 1 )) ;;
        *) sig_ok=0 ;;
      esac
    done
    if [[ $sig_ok == 0 ]]; then
      record "built apps: signatures" FAIL "see signatures.log"
    elif (( notarised == ${#apps} )); then
      record "built apps: signatures and Gatekeeper" PASS "all ${#apps} notarised"
    else
      # A local candidate (package.sh without --notarize): signed, not yet notarised.
      record "built apps: signatures" PASS "Developer ID, valid"
      record "built apps: Gatekeeper" SKIP "$unnotarised of ${#apps} not notarised: a local build"
    fi
    hdiutil detach "$MNT" >/dev/null 2>&1
  fi
fi

# ---------------------------------------------------------------- summary

echo
failed=0
for i in {1..${#NAMES}}; do
  printf '%-6s %s%s\n' "${RESULTS[$i]}" "${NAMES[$i]}" "${NOTES[$i]:+ — ${NOTES[$i]}}"
  [[ "${RESULTS[$i]}" == FAIL ]] && failed=1
done
echo "Logs: $LOGS"
exit $failed
