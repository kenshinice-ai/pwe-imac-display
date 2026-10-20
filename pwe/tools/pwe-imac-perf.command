#!/bin/bash
# PWE Screen Encore — receiver rendering comparison (1.1).
#
# Double-click on the iMac while the Mac is streaming to it. The script restarts
# the receiver once per renderer, waits for the Mac to reconnect, and records
# 90 seconds of each: the receiver's per-frame trace (TB_RECEIVER_TRACE=1),
# CPU of the receiver and WindowServer, and GPU utilisation. At the end it
# opens the receiver again the normal way and writes a summary.
#
# Before you start, on the Mac: pick the stream you want to measure (5K 60 or
# 5K 48) and leave a moving 60 fps page full screen on the iMac, for example
# testufo.com. Keep the same page for every phase.
#
# Read-only apart from restarting the receiver; nothing is installed.

phase_seconds="${PWE_PHASE_SECONDS:-90}"

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/pwe-perf-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

app="${PWE_RECEIVER_APP:-}"   # for testing the script elsewhere
# The receiver's name before the 2026-10-20 rename is searched for too.
[ -n "$app" ] || for n in "PWE Screen Encore Receiver" "PWE iMac Display Receiver"; do
  for d in /Applications "$HOME/Applications" "$HOME/Desktop" "$HOME/Downloads"; do
    [ -d "$d/$n.app" ] && { app="$d/$n.app"; break 2; }
  done
done
[ -z "$app" ] && app="$(mdfind "kMDItemCFBundleIdentifier == 'com.pwegroup.pweimacdisplay.receiver'" | head -1)"
if [ -z "$app" ] || [ ! -d "$app" ]; then
  echo "Could not find PWE Screen Encore Receiver.app. Nothing was changed." | tee "$out/ERROR"
  exit 1
fi
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
bin="$app/Contents/MacOS/$exe"
if [ ! -x "$bin" ]; then
  echo "Receiver binary not found at $bin. Nothing was changed." | tee "$out/ERROR"
  exit 1
fi
echo "Receiver: $app"
echo "Writing results to: $out"

{
  echo "== machine"; sysctl -n hw.model machdep.cpu.brand_string hw.ncpu hw.memsize
  sw_vers
  system_profiler SPDisplaysDataType | grep -E "Chipset Model|VRAM|Resolution|Metal|Refresh"
  echo "== receiver"; echo "$app"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist"
  codesign -dv "$app" 2>&1 | grep -E "Authority|TeamIdentifier|Signature"
  echo "== started $(date)"
} > "$out/machine.txt" 2>&1

stop_receiver() {
  osascript -e 'tell application id "com.pwegroup.pweimacdisplay.receiver" to quit' >/dev/null 2>&1
  for _ in 1 2 3 4 5 6; do pgrep -f "$bin" >/dev/null || return 0; sleep 0.5; done
  pkill -f "$bin" 2>/dev/null
  sleep 1
}

# run_phase <name> <ENV=VALUE>...
# Each phase starts the receiver from this script with its switches in the
# environment; the receiver also reads them from its defaults
# (TBReceiverRenderDriver, TBReceiverCursorImage), which the environment overrides.
run_phase() {
  local name="$1"; shift
  local dir="$out/$name"
  mkdir -p "$dir"
  echo
  echo "== Phase $name ($*) — $(date +%H:%M:%S)"
  stop_receiver
  env TB_RECEIVER_TRACE=1 "$@" "$bin" > "$dir/receiver-stdout.log" 2> "$dir/receiver-stderr.log" &
  local rpid=$!
  echo "$rpid" > "$dir/receiver.pid"

  echo "   Waiting up to 60 s for the Mac to reconnect..."
  local i
  for i in $(seq 1 60); do
    grep -q "^\[trace\] in=" "$dir/receiver-stderr.log" 2>/dev/null && break
    sleep 1
  done
  echo "first frames after ~${i}s" > "$dir/reconnect.txt"
  if ! grep -q "^\[trace\] in=" "$dir/receiver-stderr.log" 2>/dev/null; then
    echo "   No video arrived. Is the Mac streaming to this iMac? Skipping this phase."
    echo "no video within 60 s" > "$dir/SKIPPED"
    return
  fi

  echo "   Recording ${phase_seconds} s. Keep the 60 fps page moving on the iMac."
  # A sound at the start of each recording, for filming the phase with a phone.
  afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
  local ws
  ws="$(pgrep -x WindowServer | head -1)"
  wc -l < "$dir/receiver-stderr.log" | tr -d ' ' > "$dir/window.txt"   # trace lines before the recording
  top -l "$phase_seconds" -s 1 -stats pid,command,cpu,mem,threads -pid "$rpid" ${ws:+-pid "$ws"} \
      > "$dir/top.txt" 2>&1 &
  local tpid=$!
  while kill -0 "$tpid" 2>/dev/null; do
    ioreg -r -c IOAccelerator -d 1 2>/dev/null \
      | grep -o '"Device Utilization %"=[0-9]*' | head -1 | sed "s/^/$(date +%H:%M:%S) /" >> "$dir/gpu.txt"
    sleep 2
  done
  wait "$tpid" 2>/dev/null   # only top; never `wait` on the receiver
  wc -l < "$dir/receiver-stderr.log" | tr -d ' ' >> "$dir/window.txt"
  echo "   Done."
}

summarise() {
  local dir="$1" name
  name="$(basename "$dir")"
  [ -f "$dir/SKIPPED" ] && { echo "$name: skipped (no video)"; return; }
  local rpid; rpid="$(cat "$dir/receiver.pid" 2>/dev/null)"
  local renderer
  renderer="$(grep -m1 '^\[trace\] on:' "$dir/receiver-stderr.log" | sed 's/^\[trace\] on: //')"
  local fallback
  fallback="$(grep -m1 -i 'falling back\|fallback' "$dir/receiver-stderr.log")"
  # top: skip the first sample (it has no CPU figure yet).
  local cpu
  cpu="$(awk -v pid="$rpid" '$1==pid {n++; if (n>1) {s+=$3; c++; v[c]=$3}} END {
           if (!c) {print "-"; exit}
           for (i=1;i<=c;i++) for (j=i+1;j<=c;j++) if (v[j]<v[i]) {t=v[i]; v[i]=v[j]; v[j]=t}
           printf "mean %.1f%%, median %.1f%%, max %.1f%%", s/c, v[int((c+1)/2)], v[c] }' "$dir/top.txt")"
  local ws_cpu
  ws_cpu="$(awk '$2=="WindowServer" {n++; if (n>1) {s+=$3; c++}} END { if (c) printf "mean %.1f%%", s/c; else print "-" }' "$dir/top.txt")"
  local gpu
  gpu="$(sed 's/.*=//' "$dir/gpu.txt" 2>/dev/null | awk '{s+=$1; c++} END { if (c) printf "mean %.0f%%", s/c; else print "-" }')"
  # Trace lines: frames shown per second, and how many were replaced, repeated or late.
  local trace
  local from to
  from="$(sed -n 1p "$dir/window.txt" 2>/dev/null)"; to="$(sed -n 2p "$dir/window.txt" 2>/dev/null)"
  trace="$(awk -v from="${from:-0}" -v to="${to:-999999999}" 'NR > from && NR <= to && /^\[trace\] in=/ {
             for (i=1;i<=NF;i++) {
               split($i, kv, "=")
               if (kv[1]=="in") tin+=kv[2]; if (kv[1]=="shown") {sh+=kv[2]; secs++; v[secs]=kv[2]}
               if (kv[1]=="replaced") rep+=kv[2]; if (kv[1]=="repeat") rpt+=kv[2]; if (kv[1]=="late") late+=kv[2]
               if ($i=="total") { split($(i+1), pp, "/"); tot[++nt]=pp[2] }
               if ($i=="decode") { split($(i+1), dd, "/"); dec[++nd]=dd[2] }
             } }
             END {
               if (!secs) { print "no trace lines"; exit }
               for (i=1;i<=secs;i++) for (j=i+1;j<=secs;j++) if (v[j]<v[i]) {t=v[i]; v[i]=v[j]; v[j]=t}
               for (i=1;i<=nt;i++) for (j=i+1;j<=nt;j++) if (tot[j]<tot[i]) {t=tot[i]; tot[i]=tot[j]; tot[j]=t}
               for (i=1;i<=nd;i++) for (j=i+1;j<=nd;j++) if (dec[j]<dec[i]) {t=dec[i]; dec[i]=dec[j]; dec[j]=t}
               bad = (sh+rep > 0) ? 100.0*(rep+rpt)/(sh+rep+rpt) : 0
               printf "shown/s median %d (in %d, shown %d over %d s); replaced %d, repeat %d (together %.1f%%), late %d; decode p95 median %s ms; total p95 median %s ms",
                      v[int((secs+1)/2)], tin, sh, secs, rep, rpt, bad, late, dec[int((nd+1)/2)], tot[int((nt+1)/2)]
             }' "$dir/receiver-stderr.log")"
  {
    echo "$name"
    echo "  renderer:     ${renderer:--}"
    [ -n "$fallback" ] && echo "  fallback:     $fallback"
    echo "  receiver CPU: $cpu (100% = one core)"
    echo "  WindowServer: $ws_cpu"
    echo "  GPU:          $gpu"
    echo "  frames:       $trace"
  }
}

echo
echo "Three phases of ${phase_seconds} s each. Do not touch the Mac's stream settings until the end."

# Today's path: OpenGL, frame uploaded through the CPU, presented on arrival, pointer in the video.
run_phase 1-opengl TB_RECEIVER_RENDER_DRIVER=opengl TB_RECEIVER_CURSOR_IMAGE=0
# 1.1: Metal zero-copy, presented once per refresh, pointer still in the video.
run_phase 2-metal TB_RECEIVER_RENDER_DRIVER=metal TB_RECEIVER_CURSOR_IMAGE=0
# 1.1: as phase 2, and the iMac draws the pointer itself (needs the 1.1 sender).
run_phase 3-metal-pointer TB_RECEIVER_RENDER_DRIVER=metal

stop_receiver
echo
echo "Opening the receiver again the normal way..."
open "$app"

{
  echo "PWE Screen Encore — renderer comparison, $(date)"
  echo "Pass (PLAN-1.1): Metal CPU not above OpenGL; Metal shown/s not below OpenGL;"
  echo "replaced + repeat ≤ 1%; total p95 ≤ decode p95 + one refresh (16.7 ms at 60 Hz)."
  echo
  for d in "$out"/[0-9]-*; do summarise "$d"; echo; done
} > "$out/summary.txt"
cat "$out/summary.txt"
echo "done $(date)" > "$out/DONE"
echo "Finished. Send the folder $out back to the Mac."
