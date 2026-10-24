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
#   8a. catching up  -> a 1.5 s stall mid-stream: the backlog is decoded and
#                       only its newest picture shown, no fast-forward (PWE
#                       1.1.1; skipped without ffmpeg)
#   3b. watchdog     -> a main loop held up for 3 s is reported with its phase
#                       and stack, and again when it runs (PWE, T40)
#   8b. picture changes -> six session changes with sound on Metal, each taken
#                       within 5 s, the sound device kept open across them, and
#                       no main-loop stall (PWE, T40; skipped without ffmpeg)
#   8c. quit while the sound device is closing -> a close held up for 3 s
#                       (test hook) does not hang or crash the receiver's exit
#   10. a redial for a silent session -> off the cable it never takes the slot;
#                       over the cable it replaces a session silent for 2.5 s,
#                       never a live one (PWE, T45; loopback stands in for the
#                       cable through a test hook). Off the cable, a connection
#                       during a live session is closed at once, not left in the
#                       listen queue (PWE, T47)
#   11. clipboard    -> an encrypted test sender switches to receiverMaster:
#                       the Mac's text reaches the iMac's clipboard and is not
#                       sent back, a copy on the iMac reaches the Mac, reads
#                       held up 3 s (test hook) never stall the main loop, and
#                       quitting during one does not hang (PWE, T40). Uses a
#                       named test pasteboard, never the system clipboard
#   11b. event tap   -> in receiverMaster the global tap (listen-only, test
#                       hook) forwards still mouse moves (post_moves) on its own
#                       thread, also while the main loop is stalled for 1.5 s;
#                       with TB_RECEIVER_TAP_ON_MAIN=1 (the 1.1.0 arrangement)
#                       none get through during the stall (PWE 1.1.1, A15)
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
# TB_SMOKE_PORT: another port, so two smoke runs on one Mac (two worktrees)
# cannot take each other's connections.
PORT="${TB_SMOKE_PORT:-54399}"
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

# PWE (T40): the clipboard phase's sender keys and test pasteboard.
PEER_SERVICE="com.pwegroup.pweimacdisplay.test.smoke-peer.$$"
TEST_PASTEBOARD="com.pwegroup.pweimacdisplay.test.smoke.$$"

cleanup() {
    [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
    wait 2>/dev/null
    [[ -x "$SRC/smoke_peer" ]] && "$SRC/smoke_peer" --service "$PEER_SERVICE" --forget-everything >/dev/null 2>&1
    [[ -x "$SRC/pboard_tool" ]] && "$SRC/pboard_tool" "$TEST_PASTEBOARD" release >/dev/null 2>&1
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

    phase "Phase 8a: catching up after a stall (1.1.1)"
    relaunch
    mock --mode stream --duration 5 --stall-at 1.5 --stall-ms 1500 || fail "mock stream with a stall exited non-zero"
    expect_log "[main] behind the sender in " "receiver skipped the backlog's older pictures"
    if grep -qE '^\[trace\] in=[0-9]+ shown=[0-9]+ replaced=[1-9]' "$LOG"; then
        pass "the trace counts the skipped pictures as replaced"
    else
        fail "no trace line with replaced > 0 after the stall"
    fi

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

phase "Phase 10: a redial for a silent session (T45)"
relaunch
if mock --mode displace --expect kept; then
    pass "a new connection off the cable did not take a silent session's slot"
else
    fail "a connection off the cable took a silent session's slot"
fi
expect_log "only a cable connection replaces a silent one" "receiver closed it and kept the session"
sleep 1   # the last session's TEARDOWN is handled before the next one dials
if mock --mode displace --expect closed --live; then
    pass "a connection off the cable during a live session was closed at once (T47)"
else
    fail "a connection off the cable waited in the queue during a live session (T47)"
fi
relaunch TB_RECEIVER_TEST_LOOPBACK_IS_CABLE=1
if mock --mode displace --expect taken --max-change-s 3.5; then
    pass "a cable redial replaced the silent session within 3.5 s (the idle timeout takes 10 s)"
else
    fail "a cable redial waited for the silent session"
fi
expect_log "closing the stale session" "receiver logged why it closed the old session"
if mock --mode displace --expect kept --live; then
    pass "a live session kept the slot; the redial was taken after its TEARDOWN"
else
    fail "a cable redial took a live session's slot, or was lost"
fi

phase "Phase 11: clipboard in receiverMaster, off the main loop (T40)"
if ! make -C "$SRC" smoke_peer pboard_tool >/dev/null; then
    fail "could not build the clipboard phase's test sender"
else
    CODE_FILE="$(mktemp -t tb_smoke_code)"
    rm -f "$CODE_FILE"
    PEER_LOG="$(mktemp -t tb_smoke_peer)"
    relaunch TB_RECEIVER_TEST_LOOPBACK_IS_CABLE=1 TB_RECEIVER_TEST_CODE_FILE="$CODE_FILE" \
        TB_RECEIVER_TEST_PASTEBOARD="$TEST_PASTEBOARD" TB_RECEIVER_TEST_NO_INPUT_CAPTURE=1 \
        TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS=3000
    expect_log "[test] clipboard: $TEST_PASTEBOARD pasteboard" "receiver uses the test pasteboard"
    if "$SRC/smoke_peer" --port "$PORT" --service "$PEER_SERVICE" --code-file "$CODE_FILE" --expect-code \
           --clipboard "$TEST_PASTEBOARD" --pboard-tool "$SRC/pboard_tool" --leave-read >"$PEER_LOG" 2>&1; then
        pass "paired; Mac -> iMac, no echo, iMac -> Mac ($(grep -o 'after [0-9]* ms' "$PEER_LOG" | tr '\n' ' '))"
    else
        fail "clipboard exchange: $(tail -1 "$PEER_LOG")"
    fi
    expect_log "[input] control mode updated to receiverMaster" "receiver switched to receiverMaster"
    expect_log "[clipboard] the clipboard took 3." "slow clipboard reads ran on the clipboard thread"
    # PWE (1.1.1, A10): one line per sync with its length, never the text.
    expect_log "[clipboard] Mac -> iMac: " "receiver logged the Mac's clipboard by length"
    expect_log "[clipboard] iMac -> Mac: " "receiver logged the iMac's clipboard by length"
    if grep -qF "copied on the" "$LOG"; then
        fail "the clipboard text itself reached the receiver's log"
    else
        pass "no clipboard text in the receiver's log"
    fi
    if grep -qF "[watchdog] main loop stuck" "$LOG"; then
        fail "main loop stalled: $(grep -F "[watchdog] main loop stuck" "$LOG" | head -1)"
    else
        pass "no main-loop stall while the clipboard took 3 s per read"
    fi
    # The peer left while the receiver was inside a 3 s read: quit now.
    kill -TERM "$RECEIVER_PID" 2>/dev/null
    quit_tries=0
    while kill -0 "$RECEIVER_PID" 2>/dev/null && (( quit_tries < 40 )); do sleep 0.1; quit_tries=$((quit_tries + 1)); done
    if kill -0 "$RECEIVER_PID" 2>/dev/null; then
        fail "receiver still running 4 s after quit"
    else
        wait "$RECEIVER_PID" 2>/dev/null
        quit_status=$?
        if (( quit_status == 0 )); then pass "receiver quit cleanly during a clipboard read (exit 0)"
        else fail "receiver exit status $quit_status (crash?)"; fi
    fi
    RECEIVER_PID=""
    expect_log "[main] bye (clipboard thread still waiting for the clipboard)" "receiver left the stuck clipboard read behind"
    rm -f "$CODE_FILE"
fi

phase "Phase 11b: the event tap on its own thread (1.1.1, A15)"
# Still mouse moves (post_moves) stand in for the iMac's mouse; the tap only
# listens (test hook), so the Mac running the smoke keeps its keyboard and
# pointer. Halfway, the receiver's main loop stalls for 1.5 s (test hook).
if ! make -C "$SRC" smoke_peer post_moves >/dev/null; then
    fail "could not build the event-tap phase's helpers"
else
    tap_check() {   # <label> [relaunch env...]: prints the events that came during the stall
        local label="$1"; shift
        CODE_FILE="$(mktemp -t tb_smoke_code)"
        rm -f "$CODE_FILE"
        PEER_LOG="$(mktemp -t tb_smoke_peer)"
        relaunch TB_RECEIVER_TEST_LOOPBACK_IS_CABLE=1 TB_RECEIVER_TEST_CODE_FILE="$CODE_FILE" \
            TB_RECEIVER_TEST_TAP_LISTEN_ONLY=1 TB_RECEIVER_TEST_INPUT_RATE_MS=2000 "$@"
        "$SRC/post_moves" 1000 4 &
        local poster=$!
        "$SRC/smoke_peer" --port "$PORT" --service "$PEER_SERVICE" --code-file "$CODE_FILE" \
            --input-check 4000 --stall-ms 1500 >"$PEER_LOG" 2>&1
        wait "$poster" 2>/dev/null
        rm -f "$CODE_FILE"
        TAP_DURING="$(sed -n 's/^PEER input events [0-9]*, \([0-9]*\) while.*/\1/p' "$PEER_LOG")"
        TAP_TOTAL="$(sed -n 's/^PEER input events \([0-9]*\),.*/\1/p' "$PEER_LOG")"
    }
    tap_check "own thread"
    if grep -qF "[test] receiverMaster: listen-only tap unavailable" "$LOG"; then
        print "tap check not run: this process may not create an event tap (Input Monitoring)"
    else
        expect_log "(consume=false, own thread)" "the tap runs on its own thread"
        if [[ -n "$TAP_TOTAL" ]] && (( TAP_TOTAL > 0 && TAP_DURING > 0 )); then
            pass "input reached the Mac during a 1.5 s main-loop stall ($TAP_DURING of $TAP_TOTAL events)"
        else
            fail "no input during the stall (events: ${TAP_TOTAL:-none}, during: ${TAP_DURING:-none}): $(tail -1 "$PEER_LOG")"
        fi
        expect_log "[input] forwarded to the Mac over " "the tap logs how fast input reaches the Mac"
        tap_check "main run loop" TB_RECEIVER_TAP_ON_MAIN=1
        expect_log "(consume=false, main run loop)" "TB_RECEIVER_TAP_ON_MAIN puts the tap on the main run loop"
        if [[ -n "$TAP_DURING" ]] && (( TAP_DURING == 0 )); then
            pass "with the tap on the main run loop (1.1.0), none came during the stall (of $TAP_TOTAL)"
        else
            fail "the main-run-loop tap forwarded during a stall (${TAP_DURING:-none}): the comparison is broken"
        fi
    fi
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
