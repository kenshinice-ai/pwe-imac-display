#!/bin/zsh
#
# Soak test: simulated office work on the iMac for hours, with the Mac's view
# of the connection recorded every 30 s. Run it on the Mac (the sender), with
# PWE Screen Encore connected to the iMac as an extended display.
#
#   pwe/tools/soak/soak.sh                     2 hours
#   pwe/tools/soak/soak.sh --hours 8           8 hours; --hours 0 runs until Ctrl-C
#   pwe/tools/soak/soak.sh --video ~/clip.mov  also plays this video now and then
#   pwe/tools/soak/soak.sh --imac lee@LL-iMac-2017.local
#                                              also records the receiver's CPU and
#                                              memory over SSH (Remote Login on)
#   pwe/tools/soak/soak.sh --check             no work, 2 minutes of recording:
#                                              proves the setup before a long run
#
# Writes to docs/pwe/test-mac-<date>/soak-<time>/ (or --out DIR):
#   metrics.csv   one row per 30 s
#   events.log    the sender's own log lines (connects, drops, first frames)
#   workload.log  one JSON line per step of simulated work
#   summary.md    written at the end, also after Ctrl-C
#
# Opens only its own notes file, Safari pages and the given video, and closes
# them at the end without saving. Keeps the Mac awake while it runs. Changes
# no settings. Needs Accessibility for the app running it (System Events types
# and scrolls): System Settings › Privacy & Security › Accessibility.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
hours=2
video=""
imac=""
check=0
out=""
while (( $# )); do
  case "$1" in
    --hours) hours="${2:?}"; shift ;;
    --video) video="${2:?}"; shift ;;
    --imac) imac="${2:?}"; shift ;;
    --check) check=1 ;;
    --out) out="${2:?}"; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ -n "$video" && ! -f "$video" ]] && { echo "✗ no video at $video"; exit 2; }
[[ -n "$out" ]] || out="$repo/docs/pwe/test-mac-$(date +%Y-%m-%d)/soak-$(date +%H%M%S)"
mkdir -p "$out/work"

sender_pid() { pgrep -x "PWE Screen Encore" | head -1; }
imac_present() {
  osascript -l JavaScript "$here/screens.js" 2>/dev/null \
    | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(int(any(x["isIMac"] for x in s)), len(s))' \
    2>/dev/null || echo "0 0"
}

# ---------------------------------------------------------------- preflight
pid="$(sender_pid)"
[[ -n "$pid" ]] || { echo "✗ PWE Screen Encore is not running on this Mac"; exit 1; }
read present nscreens <<<"$(imac_present)"
[[ "$present" == 1 ]] || { echo "✗ no PWE Screen Encore display: connect the iMac first"; exit 1; }
if [[ -n "$imac" ]] && ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$imac" true 2>/dev/null; then
  echo "✗ cannot SSH to $imac without a password (set up a key, or leave out --imac)"; exit 1
fi
echo "▸ Recording into $out"
echo "  sender pid $pid, $nscreens screens, iMac display present"
{
  echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hours=$hours"
  echo "options=check:$check video:${video:-none} imac:${imac:-none}"
  app="$(ps -o comm= -p "$pid" | sed 's|/Contents/MacOS/.*||')"
  echo "sender_version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
  echo "build=$(defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null)"
  echo "mac=$(sysctl -n hw.model)"
  echo "macos=$(sw_vers -productVersion)"
} > "$out/run.txt"

# Keep the Mac and its displays awake for as long as this script runs.
caffeinate -di -w $$ &

# ---------------------------------------------------------------- recorders
log stream --style compact \
  --predicate 'subsystem BEGINSWITH "com.targetbridge" OR subsystem BEGINSWITH "com.pwegroup" OR process == "PWE Screen Encore"' \
  > "$out/events.log" 2>/dev/null &
logger_pid=$!

monitor() {
  local start=$SECONDS
  echo "time,elapsed_s,sender_pid,sender_cpu,sender_rss_mb,imac_display,screens,receiver_cpu,receiver_rss_mb" > "$out/metrics.csv"
  while true; do
    local p cpu=NA rss=NA rcpu=NA rrss=NA
    p="$(sender_pid)"
    if [[ -n "$p" ]]; then
      read cpu rss <<<"$(ps -o %cpu=,rss= -p "$p" 2>/dev/null)"
      rss=$(( ${rss:-0} / 1024 ))
    fi
    read present nscreens <<<"$(imac_present)"
    if [[ -n "$imac" ]]; then
      read rcpu rrss <<<"$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$imac" \
        "ps -axo %cpu=,rss=,comm= | awk '/PWEScreenEncoreReceiver|PWEiMacDisplayReceiver/ {print \$1, int(\$2/1024); exit}'" 2>/dev/null)"
      rcpu="${rcpu:-NA}"; rrss="${rrss:-NA}"
    fi
    echo "$(date +%H:%M:%S),$(( SECONDS - start )),${p:-NA},${cpu:-NA},${rss:-NA},$present,$nscreens,$rcpu,$rrss" >> "$out/metrics.csv"
    sleep 30
  done
}
monitor &
monitor_pid=$!

finish() {
  trap - INT TERM
  echo
  echo "▸ Stopping"
  [[ "$check" == 1 ]] || osascript -l JavaScript "$here/workload.js" cleanup "$out/work" >> "$out/workload.log" 2>&1
  kill $monitor_pid $logger_pid 2>/dev/null
  wait $monitor_pid $logger_pid 2>/dev/null
  echo "ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out/run.txt"
  python3 -I "$here/summarize.py" "$out"
  echo "▸ $out/summary.md"
  exit 0
}
trap finish INT TERM

# ---------------------------------------------------------------- work
end=$(( hours > 0 ? SECONDS + hours * 3600 : 0 ))
if [[ "$check" == 1 ]]; then
  echo "▸ Check: recording for 2 minutes, no simulated work"
  sleep 120
  finish
fi
cycle=(type browse mouse windows type browse video)
i=0
while (( end == 0 || SECONDS < end )); do
  step="${cycle[$(( i % ${#cycle} + 1 ))]}"
  echo "  $(date +%H:%M:%S) $step"
  osascript -l JavaScript "$here/workload.js" "$step" "$out/work" "$video" >> "$out/workload.log" 2>&1
  i=$(( i + 1 ))
  # Reading time: 1–3 minutes with nothing happening, like a person would.
  sleep $(( 60 + RANDOM % 120 ))
done
finish
