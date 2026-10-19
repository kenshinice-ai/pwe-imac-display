#!/bin/zsh
# PWE: two processes over loopback, the real secure layer and the login
# keychain on both sides (test hook until main.c uses tb_conn, step R2).
#
#   1. a new Mac pairs with the code the "iMac" shows, then streams sealed
#   2. it reconnects: no code, encrypted (Noise KK with the stored keys)
#   3. a wrong code: refused, a new code is shown
#   4. an unencrypted sender in compatibility mode: picture only
#   5. the same with compatibility mode off: refused
#
# Keychain items go under a throwaway service name and are removed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-54399}"
TAG="loopback-$$-$(date +%s)"
RSVC="com.pwegroup.pweimacdisplay.test.$TAG.receiver"
SSVC="com.pwegroup.pweimacdisplay.test.$TAG.sender"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pwe-loopback.XXXXXX")"
CODE="$WORK/code"
LOG="$WORK/receiver.log"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass + 1)); }
bad() { echo "✗ $1"; fail=$((fail + 1)); }

wait_listen() {
  for _ in {1..100}; do grep -q LISTENING "$1" 2>/dev/null && return 0; sleep 0.05; done
  return 1
}

cleanup() {
  [[ -n "${RPID:-}" ]] && kill "$RPID" 2>/dev/null || true
  ./secure_peer --service "$SSVC" --forget-everything >/dev/null 2>&1 || true
}
trap cleanup EXIT

PWE_HARNESS_CLEAN=1 ./secure_receiver --port "$PORT" --service "$RSVC" --code-file "$CODE" --connections 4 >"$LOG" 2>&1 &
RPID=$!
wait_listen "$LOG" || { cat "$LOG"; exit 1; }

# 1. Pair, then stream.
if ./secure_peer --port "$PORT" --service "$SSVC" --code-file "$CODE" --frames 60 --expect-code >"$WORK/peer1.log" 2>&1; then
  ok "pairing with the code shown, then 60 sealed 64 KB frames ($(grep -o 'after [0-9]* ms' "$WORK/peer1.log"))"
else bad "pairing"; cat "$WORK/peer1.log"; fi

# 2. Reconnect without a code.
if ./secure_peer --port "$PORT" --service "$SSVC" --frames 10 --expect-no-code >"$WORK/peer2.log" 2>&1; then
  ok "reconnect: encrypted with the stored keys, no code ($(grep -o 'after [0-9]* ms' "$WORK/peer2.log"))"
else bad "reconnect"; cat "$WORK/peer2.log"; fi

# 3. Wrong code (forces pairing even though paired).
rm -f "$CODE"
if ./secure_peer --port "$PORT" --service "$SSVC" --code 000001 >"$WORK/peer3.log" 2>&1; then
  bad "a wrong code was accepted"
else
  grep -q "local 3" "$WORK/peer3.log" && ok "wrong code refused" || { bad "wrong code: unexpected failure"; cat "$WORK/peer3.log"; }
fi

# 4. An unencrypted sender, compatibility mode on.
python3 -I - "$PORT" <<'PY'
import json, socket, struct, sys, time
def pkt(t, obj): b = json.dumps(obj).encode(); return struct.pack(">IB", len(b) + 1, t) + b
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(pkt(0x10, {"senderName": "Old sender"}) + pkt(0x33, {"kind": "keyDown", "keyCode": 0})
          + pkt(0x36, {"text": "should not arrive"}) + pkt(0x34, {"mode": "receiverMaster"})
          + pkt(0x35, {"level": 0.5}) + pkt(0x31, {"reason": "done"}))
time.sleep(0.5); s.close()
PY
sleep 0.5

kill "$RPID" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true; RPID=""
SESSIONS=("${(@f)$(grep '^SESSION' "$LOG")}")
[[ "${SESSIONS[1]}" == *"secure=1"*"frames=60 clipboard=1"*"test=1"* ]] && ok "receiver got 60 frames, the clipboard and the probe, sealed" || bad "session 1: ${SESSIONS[1]:-none}"
[[ "${SESSIONS[2]}" == *"secure=1"*"frames=10"* ]] && ok "receiver: second session encrypted" || bad "session 2: ${SESSIONS[2]:-none}"
grep -q '^WRONG_CODE' "$LOG" && ok "receiver: wrong code counted, new code shown ($(grep -c '^CODE' "$LOG") codes shown in all)" || bad "receiver: no WRONG_CODE"
[[ "${SESSIONS[4]}" == *"secure=0"*"hello=1"*"clipboard=0 input=0 mode=0"* ]] && ok "compatibility: hello and brightness only; input, clipboard, mode dropped" || bad "session 4: ${SESSIONS[4]:-none}"
grep -q '^PLAINTEXT' "$LOG" && ok "receiver warned: unencrypted" || bad "no PLAINTEXT warning"

# 5. Compatibility mode off.
: >"$LOG"
./secure_receiver --port "$PORT" --plaintext-off --connections 1 >"$LOG" 2>&1 &
RPID=$!
wait_listen "$LOG"
python3 -I -c "
import socket, struct, sys, time
s = socket.create_connection(('127.0.0.1', $PORT)); b = b'{}'
s.sendall(struct.pack('>IB', len(b) + 1, 0x10) + b); time.sleep(0.3); s.close()"
wait "$RPID" 2>/dev/null || true; RPID=""
grep -q '^REFUSED_PLAINTEXT' "$LOG" && ok "compatibility off: unencrypted sender refused" || bad "compatibility off: not refused"

echo "secure loopback: $pass passed, $fail failed (logs: $WORK)"
(( fail == 0 ))
