#!/bin/zsh
# loopback_smoke.sh — end-to-end receiver smoke test on one Mac, no
# Thunderbolt hardware and no real sender.
#
# Builds the receiver, runs it windowed, then drives it over 127.0.0.1 with
# tests/mock_sender.py through four phases:
#   1. handshake     -> receiver logs the sender hello
#   1b. IPv6         -> the same over ::1 and fe80::1%lo0 (PWE, T34: the
#                       Thunderbolt Bridge's link-local IPv6 path)
#   2. badlen        -> parser rejects a corrupt length and disconnects
#   3. hang          -> idle watchdog reaps a silent sender (~10s)
#   4. stream        -> real H.264 decode (skipped without ffmpeg CLI or
#                       with --no-stream)
#   5-7. renderers   -> Metal zero-copy with the receiver-drawn pointer, then
#                       the copy fallback and the OpenGL fallback, each in a
#                       fresh receiver (also skipped without ffmpeg)
#   8. the Mac's choice -> the HELLO's receiverRenderer switches to Metal and
#                       back to OpenGL (PWE; skipped without ffmpeg)
#   3b. watchdog     -> a main loop held up for 3 s is reported with its phase
#                       and stack, and again when it runs (PWE, T40)
#   8b. picture changes -> six session changes with sound on Metal, each taken
#                       within 5 s, the sound device kept open across them, and
#                       no main-loop stall (PWE, T40; skipped without ffmpeg)
#   8c. quit while the sound device is closing -> a close held up for 3 s
#                       (test hook) does not hang or crash the receiver's exit
#   9. log file      -> every receiver above also wrote a stamped receiver.log
#
# The receiver runs with TB_RECEIVER_NO_BONJOUR=1 on TB_RECEIVER_TEST_PORT, so a
# sender running on the same Mac cannot find or redial it and take its single
# client slot.
# Needs a GUI session (SDL window) and the receiver build deps
# (brew install ffmpeg sdl2 pkgconf libsodium, or PKG_CONFIG_LIBDIR pointing at
# pwe/receiver-deps.sh's <root>/<arch>/lib/pkgconfig). Exits non-zero on any failed phase.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/TBReceiverC"
LOG="$(mktemp -t tb_smoke_receiver.err)"
# PWE: the receivers' log file goes here, not to ~/Library/Logs.
export TB_RECEIVER_LOG_DIR="$(mktemp -d -t tb_smoke_logs)"
PORT=54399
MOCK_PY="$SRC/tests/mock_sender.py"
mock() { python3 "$MOCK_PY" --port "$PORT" "$@"; }
NO_STREAM=0
[[ "${1:-}" == "--no-stream" ]] && NO_STREAM=1

FAILURES=0
RECEIVER_PID=""

phase() { print -P "%B== $1 ==%b"; }
pass()  { print -P "%F{green}PASS%f  $1"; }
fail()  { print -P "%F{red}FAIL%f  $1"; FAILURES=$((FAILURES + 1)); }

expect_count() {   # <needle> <count> <what>: at least <count> lines
    local needle="$1" want="$2" what="$3" tries=0
    while (( tries < 20 )); do
        if (( $(grep -cF "$needle" "$LOG") >= want )); then pass "$what"; return 0; fi
        sleep 0.5; tries=$((tries + 1))
    done
    fail "$what (wanted $want log lines: $needle)"
    return 1
}

expect_log() {
    local needle="$1" what="$2" tries=0
    while (( tries < 20 )); do
        if grep -qF "$needle" "$LOG"; then pass "$what"; return 0; fi
        sleep 0.5; tries=$((tries + 1))
    done
    fail "$what (missing log line: $needle)"
    return 1
}

# Until the receiver logs that its port is open (up to 15 s): a freshly built
# x86_64 binary's first launch under Rosetta can take longer than 2 s.
wait_listening() {
    local tries=0
    while (( tries < 30 )); do
        grep -qF "[net] listening on port" "$LOG" && return 0
        kill -0 "$RECEIVER_PID" 2>/dev/null || return 1
        sleep 0.5; tries=$((tries + 1))
    done
    return 1
}

cleanup() {
    [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

phase "Build receiver"
# PWE: TEST_HOOKS=1 so the receiver keeps its pairing key under a throwaway
# keychain service, deleted when it exits: a rebuilt ad-hoc binary would
# otherwise stop at the keychain's access prompt for the previous build's item.
SMOKE_KEYCHAIN="com.pwegroup.pweimacdisplay.test.smoke.$$"
# Say what is missing up front, not as a compile error deep in pwe_secure.c.
pkg-config --exists libsodium || {
    print "libsodium not found: brew install libsodium, or set PKG_CONFIG_LIBDIR to"
    print "<pwe/receiver-deps.sh root>/<arch>/lib/pkgconfig"; exit 1
}
make -C "$SRC" clean >/dev/null   # the hook switch is a compile flag
if ! make -C "$SRC" TEST_HOOKS=1 >/dev/null; then
    print "receiver build failed"; exit 1
fi
pass "build"

phase "Launch receiver (windowed, log -> $LOG)"
TB_LANG=en TB_RECEIVER_NO_BONJOUR=1 TB_RECEIVER_TEST_PORT=$PORT \
    TB_RECEIVER_TEST_KEYCHAIN_SERVICE="$SMOKE_KEYCHAIN" TB_RECEIVER_TEST_CLEAN_ON_EXIT=1 \
    "$SRC/tbreceiver" --windowed 2>"$LOG" &
RECEIVER_PID=$!
wait_listening
if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
    print "receiver exited early:"; tail -5 "$LOG"; exit 1
fi
pass "receiver running (pid $RECEIVER_PID)"
expect_log "[net] cable bridges: " "receiver names its cable bridges"

phase "Phase 1: handshake"
mock --mode handshake --duration 3 || fail "mock handshake exited non-zero"
expect_log "[main] hello from sender" "receiver saw HELLO"
expect_log "[main] teardown requested by sender" "receiver honored TEARDOWN"
sleep 1

phase "Phase 1b: IPv6 (::1 and fe80::1%%lo0)"
expect_log "over IPv4 and IPv6" "receiver listens on IPv6 too"
mock --host ::1 --mode handshake --duration 2 || fail "mock handshake over ::1 exited non-zero"
expect_count "client connected (lo0, IPv6" 1 "receiver took the ::1 client as loopback"
expect_count "[main] hello from sender" 2 "receiver saw HELLO over ::1"
sleep 1
mock --host "fe80::1%lo0" --mode handshake --duration 2 || fail "mock handshake over fe80::1%%lo0 exited non-zero"
expect_count "client connected (lo0, IPv6" 2 "receiver took the fe80::1%%lo0 client as loopback"
expect_count "[main] hello from sender" 3 "receiver saw HELLO over fe80::1%%lo0"
sleep 1

phase "Phase 2: corrupt length"
mock --mode badlen || fail "mock badlen exited non-zero"
expect_log "bad pkt_len=4294967295" "parser rejected corrupt length"
expect_log "[main] client disconnected" "receiver dropped the corrupt session"
sleep 1

phase "Phase 3: silent sender (idle watchdog)"
mock --mode hang --duration 14 || fail "mock hang exited non-zero"
expect_log "closing stale session" "idle watchdog reaped silent sender"
sleep 1

phase "Phase 3b: main-loop watchdog"
expect_log "[watchdog] watching the main loop" "watchdog started"
mock --mode stall --stall-ms 3000 || fail "mock stall exited non-zero"
expect_log "[watchdog] main loop stuck" "watchdog reported the stalled loop"
expect_log "in packet: test stall (main.c:" "watchdog named the phase"
expect_log "on_packet" "watchdog printed the main thread's stack"
expect_log "[watchdog] main loop ran again after 3." "watchdog reported the recovery"
sleep 1

phase "Phase 4: H.264 stream"
if (( NO_STREAM )) || ! command -v ffmpeg >/dev/null; then
    print "skipped (no ffmpeg or --no-stream)"
else
    mock --mode stream --duration 4 || fail "mock stream exited non-zero"
    expect_log "param sets changed, opening decoder" "decoder accepted param sets"
    expect_log "[disp] texture " "receiver rendered decoded video"
fi

# A fresh receiver per renderer phase: the renderer is chosen at start-up.
relaunch() {
    [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
    wait "$RECEIVER_PID" 2>/dev/null
    LOG="$(mktemp -t tb_smoke_receiver.err)"
    env TB_LANG=en TB_RECEIVER_NO_BONJOUR=1 TB_RECEIVER_TEST_PORT=$PORT TB_RECEIVER_TRACE=1 \
        TB_RECEIVER_TEST_KEYCHAIN_SERVICE="$SMOKE_KEYCHAIN" TB_RECEIVER_TEST_CLEAN_ON_EXIT=1 \
        "$@" "$SRC/tbreceiver" --windowed 2>"$LOG" &
    RECEIVER_PID=$!
    wait_listening
}

if (( ! NO_STREAM )) && command -v ffmpeg >/dev/null; then
    phase "Phase 5: Metal zero-copy + receiver-drawn pointer"
    relaunch TB_RECEIVER_RENDER_DRIVER=metal
    expect_log "[metal] zero-copy video on" "Metal path passed its start-up checks"
    mock --mode pointer --fps 60 --duration 4 || fail "mock pointer exited non-zero (no cursorImage in the profile?)"
    expect_log "Metal zero-copy: first frame" "Metal path took a decoded frame"
    expect_log "pointer picture arrived" "receiver took the pointer picture"
    expect_log "[trace] in=" "trace summary lines"

    phase "Phase 6: decoder buffers refused -> copy fallback"
    relaunch TB_RECEIVER_RENDER_DRIVER=metal TB_RECEIVER_METAL_FAIL=wrap
    mock --mode stream --duration 3 || fail "mock stream exited non-zero"
    expect_log "copying each frame" "Metal path copies frames it cannot texture"

    phase "Phase 7: Metal unusable -> OpenGL fallback"
    relaunch TB_RECEIVER_RENDER_DRIVER=metal TB_RECEIVER_METAL_FAIL=texture
    mock --mode stream --duration 3 || fail "mock stream exited non-zero"
    expect_log "falling back to OpenGL" "renderer fell back to OpenGL"
    expect_log "[disp] texture " "OpenGL rendered decoded video after the fallback"

    phase "Phase 8: the Mac chooses the renderer"
    relaunch
    mock --mode stream --duration 3 --renderer metal || fail "mock stream (metal) exited non-zero"
    expect_log "the Mac asks for Metal: switching the renderer" "receiver switched to Metal for the session"
    expect_log "Metal zero-copy: first frame" "Metal path took the session's frames"
    mock --mode stream --duration 3 --renderer opengl || fail "mock stream (opengl) exited non-zero"
    expect_log "the Mac asks for OpenGL: switching the renderer" "receiver switched back to OpenGL"
    expect_log "[disp] texture " "OpenGL rendered the next session"

    phase "Phase 8b: picture changes with sound (T40)"
    relaunch TB_RECEIVER_RENDER_DRIVER=metal
    if mock --mode cycles --cycles 6 --duration 1 --audio --renderer metal --max-change-s 5; then
        pass "six picture changes, each taken within 5 s"
    else
        fail "a picture change took longer than 5 s, or a session was not taken"
    fi
    expect_count "[main] client disconnected" 6 "receiver ended every old session"
    if (( $(grep -cF "[audio] output device opened" "$LOG") == 1 )); then
        pass "sound device opened once and kept across the changes"
    else
        fail "sound device opened $(grep -cF "[audio] output device opened" "$LOG") times (wanted 1)"
    fi
    if grep -qF "[watchdog] main loop stuck" "$LOG"; then
        fail "main loop stalled during the changes: $(grep -F "[watchdog] main loop stuck" "$LOG" | head -1)"
    else
        pass "no main-loop stall during the changes"
    fi

    phase "Phase 8c: quit while the sound device is closing (T40)"
    relaunch TB_RECEIVER_TEST_AUDIO_CLOSE_DELAY_MS=3000
    mock --mode stream --duration 2 --audio || fail "mock stream with sound exited non-zero"
    expect_log "[audio] output device opened" "sound device opened"
    kill -TERM "$RECEIVER_PID" 2>/dev/null
    quit_tries=0
    while kill -0 "$RECEIVER_PID" 2>/dev/null && (( quit_tries < 40 )); do sleep 0.1; quit_tries=$((quit_tries + 1)); done
    if kill -0 "$RECEIVER_PID" 2>/dev/null; then
        fail "receiver still running 4 s after quit"
    else
        wait "$RECEIVER_PID" 2>/dev/null
        quit_status=$?
        if (( quit_status == 0 )); then pass "receiver quit cleanly (exit 0)"
        else fail "receiver exit status $quit_status (crash?)"; fi
    fi
    RECEIVER_PID=""
    expect_log "[main] bye (sound device still closing)" "receiver left the stuck sound device behind"
fi

phase "Phase 9: log file"
RECEIVER_LOG_FILE="$TB_RECEIVER_LOG_DIR/receiver.log"
if [[ -s "$RECEIVER_LOG_FILE" ]] &&
   grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]{12} \[main\] hello from sender$' "$RECEIVER_LOG_FILE" &&
   grep -qF "[log] receiver " "$RECEIVER_LOG_FILE"; then
    pass "receiver.log holds the stamped session lines"
else
    fail "receiver.log missing or without stamped lines ($RECEIVER_LOG_FILE)"
fi

print ""
if (( FAILURES == 0 )); then
    print -P "%F{green}loopback smoke: all phases passed%f"
    exit 0
fi
print -P "%F{red}loopback smoke: $FAILURES failure(s)%f — log: $LOG"
exit 1
