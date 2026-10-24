#!/usr/bin/env python3
"""Mock TargetBridge sender — drives a receiver over plain TCP with no
Thunderbolt hardware, no Apple Silicon, and no screen capture.

Speaks the wire protocol from src/proto.h:
    [4 bytes BE uint32 length][1 byte type][payload (length-1 bytes)]

Modes (--mode):
    handshake   connect, HELLO, heartbeat for --duration, TEARDOWN, close.
    stream      handshake + generate H.264 with the ffmpeg CLI (testsrc2)
                and stream it as PARAM_SETS + AVCC FRAMEs at ~30 fps.
    hang        connect, HELLO, then go silent (no heartbeats) while keeping
                the socket open — exercises the receiver's idle watchdog,
                which should reap the session after ~10s.
    badlen      connect, HELLO, then send a corrupt 0xFFFFFFFF length prefix —
                the receiver's parser must reject it and disconnect.
    drop        connect, HELLO, send half a packet, then close abruptly —
                the receiver must return to "waiting for sender".
    pointer     stream, plus the receiver-drawn pointer: checks that the
                receiver's display profile says "cursorImage": true, sends one
                CURSOR_IMAGE picture and CURSOR positions on a circle at 240 Hz
                between the video frames.
    stall       test builds only (TEST_HOOKS=1): handshake, then ask the
                receiver to hold up its main loop for --stall-ms, so its
                watchdog has a stall to report (PWE, T40). With stream,
                --stall-at S asks for the stall S seconds into the stream and
                keeps streaming through it, so the receiver has a backlog to
                catch up on (PWE 1.1.1).
    cycles      a picture-preset change, --cycles times: stream for
                --duration (with --audio, silent PCM too), end the session the
                way a sender does, dial again at once with the next size from
                --sizes, and time how long the receiver takes to take the new
                session. Fails if one change takes longer than --max-change-s
                (PWE, T40).
    displace    a cable replug before the receiver's 10 s idle timeout (PWE,
                T45): session A says HELLO, then goes silent with its socket
                open (--live: it heartbeats every 0.5 s instead). 0.5 s later
                connection B dials and says HELLO at once, as the Mac does after
                a replug, and the mode times how long the receiver takes to send
                B its display profile. --expect taken: within --max-change-s,
                and A closed. --expect kept: B is not taken while A is there
                (4 s); with --live, B is then taken once A says TEARDOWN.
                --expect closed: the receiver closes B within 1 s and A keeps
                the slot (PWE, T47: off the cable, during a live session).

--audio adds silent 48 kHz stereo PCM (AUDIO_FRAME) to stream, pointer and
cycles, so the receiver opens and closes its sound device as with "sound on
the iMac".

Stdlib only. Example:
    python3 tests/mock_sender.py --mode handshake --duration 3
"""

import argparse
import json
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

# Packet types (src/proto.h)
PKT_HELLO_RECEIVER = 0x10
PKT_PARAM_SETS = 0x20
PKT_FRAME = 0x21
PKT_AUDIO_FRAME = 0x23
PKT_TEST_DATA = 0x40
PKT_HEARTBEAT = 0x30
PKT_TEARDOWN = 0x31
PKT_CURSOR = 0x32
PKT_DISPLAY_PROFILE = 0x11
PKT_CURSOR_IMAGE = 0x39


def packet(ptype: int, payload: bytes) -> bytes:
    return struct.pack(">I", 1 + len(payload)) + bytes([ptype]) + payload


def json_packet(ptype: int, obj) -> bytes:
    return packet(ptype, json.dumps(obj).encode("utf-8"))


def hello_packet(name: str, renderer: str = "") -> bytes:
    hello = {
        "senderName": name,
        "uiLanguage": "en",
        "capturePreset": "standard1440p",
        "captureSource": "desktopMirror",
        "captureWidth": 1280,
        "captureHeight": 720,
        "codec": "h264",
    }
    if renderer:
        hello["receiverRenderer"] = renderer   # PWE: the Mac's rendering choice
    return json_packet(PKT_HELLO_RECEIVER, hello)


def drain_receiver(sock: socket.socket, quiet: bool = False) -> None:
    """Read whatever the receiver sent (DISPLAY_PROFILE etc.) so its writes
    don't back up; log packet types for debugging."""
    sock.setblocking(False)
    try:
        data = sock.recv(65536)
        while data:
            if len(data) >= 5:
                (length,) = struct.unpack(">I", data[:4])
                if not quiet:
                    print(f"[mock] receiver sent type=0x{data[4]:02x} len={length}")
                data = data[4 + length:]
            else:
                break
    except (BlockingIOError, socket.error):
        pass
    finally:
        sock.setblocking(True)


# ---- H.264 generation & AVCC conversion (stream mode) ----------------------

_H264_CACHE = {}


def generate_h264(duration_s: int, fps: int = 30, size: str = "1280x720") -> bytes:
    """Render a test pattern to Annex-B H.264 using the ffmpeg CLI."""
    key = (duration_s, fps, size)
    if key in _H264_CACHE:
        return _H264_CACHE[key]
    with tempfile.NamedTemporaryFile(suffix=".h264", delete=False) as tmp:
        path = tmp.name
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={fps}:duration={duration_s}",
        "-c:v", "libx264", "-preset", "ultrafast", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-g", str(fps), "-f", "h264", path,
    ]
    subprocess.run(cmd, check=True)
    with open(path, "rb") as f:
        _H264_CACHE[key] = f.read()
    return _H264_CACHE[key]


def split_annexb(data: bytes):
    """Split an Annex-B stream into raw NAL units (start codes removed)."""
    nals, i, n = [], 0, len(data)
    while i < n:
        if data[i:i + 4] == b"\x00\x00\x00\x01":
            start = i + 4
        elif data[i:i + 3] == b"\x00\x00\x01":
            start = i + 3
        else:
            i += 1
            continue
        j = start
        while j < n:
            if data[j:j + 4] == b"\x00\x00\x00\x01" or data[j:j + 3] == b"\x00\x00\x01":
                break
            j += 1
        nals.append(data[start:j])
        i = j
    return nals


def read_profile(sock: socket.socket, timeout_s: float = 3) -> dict:
    """The DISPLAY_PROFILE the receiver sends as soon as it accepts us."""
    sock.settimeout(timeout_s)
    buf = b""
    try:
        while True:
            while len(buf) >= 5:
                (length,) = struct.unpack(">I", buf[:4])
                if len(buf) < 4 + length:
                    break
                ptype, payload = buf[4], buf[5:4 + length]
                buf = buf[4 + length:]
                if ptype == PKT_DISPLAY_PROFILE:
                    return json.loads(payload.decode("utf-8"))
            chunk = sock.recv(65536)
            if not chunk:
                return {}
            buf += chunk
    except (socket.timeout, ConnectionResetError):
        return {}
    finally:
        sock.settimeout(None)


def cursor_image_packet(image_id: int) -> bytes:
    """A 16x16 picture: white square with a black border, premultiplied BGRA,
    hot spot top-left, covering 32x32 frame pixels."""
    w = h = 16
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            edge = x in (0, w - 1) or y in (0, h - 1)
            v = 0 if edge else 255
            pixels += bytes([v, v, v, 255])
    header = struct.pack(">IHHHHHH", image_id, w, h, 0, 0, 32, 32)
    return packet(PKT_CURSOR_IMAGE, header + bytes(pixels))


def cursor_position_packet(t: float, width: int, height: int, image_id: int) -> bytes:
    import math
    x = int(width / 2 + width / 4 * math.cos(t * 2 * math.pi))
    y = int(height / 2 + height / 4 * math.sin(t * 2 * math.pi))
    return json_packet(PKT_CURSOR, {"x": x, "y": y, "width": width, "height": height,
                                    "visible": True, "type": 0, "large": False, "image": image_id})


def audio_packet(seconds: float) -> bytes:
    """Silent 48 kHz stereo 16-bit PCM, as the sender's AUDIO_FRAME carries it."""
    frames = max(1, int(48000 * seconds))
    return packet(PKT_AUDIO_FRAME, bytes(frames * 4))


def stream_video(sock: socket.socket, duration_s: int, fps: int = 30, size: str = "1280x720",
                 pointer: bool = False, audio: bool = False, stall_at: float = -1.0,
                 stall_ms: int = 0) -> None:
    nals = split_annexb(generate_h264(duration_s, fps, size))
    width, height = (int(v) for v in size.split("x"))

    sps = next(n for n in nals if n and (n[0] & 0x1F) == 7)
    pps = next(n for n in nals if n and (n[0] & 0x1F) == 8)

    # PARAM_SETS payload: [1B codec (1=H264)][1B count] then [4B BE size][bytes] per set.
    params = bytes([1, 2])
    for ps in (sps, pps):
        params += struct.pack(">I", len(ps)) + ps
    sock.sendall(packet(PKT_PARAM_SETS, params))
    print(f"[mock] sent param sets (SPS {len(sps)}B, PPS {len(pps)}B)")
    if pointer:
        sock.sendall(cursor_image_packet(1))
        print("[mock] sent cursor image id=1")

    # Group slices into frames: a frame is one slice NAL (types 1/5) here
    # (baseline testsrc2 output, one slice per picture).
    frame_interval = 1.0 / fps
    heartbeat_due = time.monotonic()
    start = time.monotonic()
    seq = 0
    frames_sent = 0
    positions_sent = 0
    next_frame = time.monotonic()
    for nal in nals:
        ntype = nal[0] & 0x1F if nal else 0
        if ntype not in (1, 5):
            continue
        if stall_at >= 0 and time.monotonic() - start >= stall_at:
            # Test builds: the receiver's loop stops for stall_ms; frames keep coming.
            sock.sendall(packet(PKT_TEST_DATA, f"stall {stall_ms}".encode()))
            print(f"[mock] asked the receiver to stall {stall_ms} ms mid-stream")
            stall_at = -1.0
        # FRAME payload: AVCC — 4-byte BE length-prefixed NAL units.
        sock.sendall(packet(PKT_FRAME, struct.pack(">I", len(nal)) + nal))
        frames_sent += 1
        if audio:
            sock.sendall(audio_packet(frame_interval))
        now = time.monotonic()
        if now >= heartbeat_due:
            sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": seq}))
            seq += 1
            heartbeat_due = now + 2.0
        drain_receiver(sock, quiet=True)
        next_frame += frame_interval
        while True:
            now = time.monotonic()
            if now >= next_frame:
                break
            if pointer:
                sock.sendall(cursor_position_packet(now - start, width, height, 1))
                positions_sent += 1
                time.sleep(min(1.0 / 240.0, max(0.0, next_frame - now)))
            else:
                time.sleep(next_frame - now)
    print(f"[mock] streamed {frames_sent} frames" + (f", {positions_sent} pointer positions" if pointer else ""))


# ---- modes ------------------------------------------------------------------

def connect_for_session(args, deadline_s: float):
    """Dial until the receiver takes the session (sends its display profile),
    as the sender does after a preset change. Returns (socket, seconds) or
    (None, seconds)."""
    start = time.monotonic()
    while time.monotonic() - start < deadline_s:
        try:
            sock = socket.create_connection((args.host, args.port), timeout=3)
        except OSError:
            time.sleep(0.2)
            continue
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if read_profile(sock):   # 3 s, like the sender's handshake timeout
            return sock, time.monotonic() - start
        sock.close()
    return None, time.monotonic() - start


def end_session(sock: socket.socket, style: str) -> None:
    """End a session the ways a sender does: TEARDOWN and a clean close, or
    TEARDOWN then a reset, or a reset with nothing said (the sender's
    connection cancelled with data still queued)."""
    if style in ("teardown", "teardown-reset"):
        try:
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "sender_internal_stop"}))
        except OSError:
            pass
    if style in ("reset", "teardown-reset"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


def run_cycles(args) -> int:
    sizes = [s for s in args.sizes.split(",") if s]
    styles = ["teardown", "teardown-reset", "reset"]
    for size in sizes:
        generate_h264(args.duration, args.fps, size)
    sock, took = connect_for_session(args, 10)
    if not sock:
        print("[mock] ERROR: the receiver did not take the first session")
        return 1
    worst = 0.0
    for i in range(args.cycles):
        size = sizes[i % len(sizes)]
        sock.sendall(hello_packet(args.name, args.renderer))
        stream_video(sock, args.duration, args.fps, size, audio=args.audio)
        style = styles[i % len(styles)]
        end_session(sock, style)
        sock, took = connect_for_session(args, args.max_change_s + 60)
        worst = max(worst, took)
        print(f"[mock] cycle {i + 1}/{args.cycles}: {size}, ended with {style}, "
              f"next session taken after {took:.2f} s", flush=True)
        if not sock:
            print("[mock] ERROR: the receiver did not take the next session")
            return 1
    sock.sendall(hello_packet(args.name, args.renderer))
    end_session(sock, "teardown")
    print(f"[mock] {args.cycles} changes, slowest {worst:.2f} s")
    if worst > args.max_change_s:
        print(f"[mock] ERROR: a change took {worst:.2f} s (limit {args.max_change_s} s)")
        return 1
    return 0


def closed_by_receiver(sock: socket.socket, timeout_s: float) -> bool:
    """True when the receiver closes this connection within timeout_s."""
    sock.settimeout(timeout_s)
    try:
        while True:
            if not sock.recv(65536):
                return True
    except ConnectionResetError:
        return True
    except (socket.timeout, OSError):
        return False
    finally:
        sock.settimeout(None)


def run_displace(args) -> int:
    a = socket.create_connection((args.host, args.port), timeout=5)
    a.sendall(hello_packet(args.name + " A"))
    if not read_profile(a):
        print("[mock] ERROR: the receiver did not take session A")
        return 1
    print(f"[mock] session A taken; it now {'heartbeats' if args.live else 'goes silent'}", flush=True)
    stop = threading.Event()

    def heartbeats():
        seq = 0
        while not stop.wait(0.5):
            try:
                a.sendall(json_packet(PKT_HEARTBEAT, {"sequence": seq}))
            except OSError:
                return
            seq += 1
            drain_receiver(a, quiet=True)

    beater = threading.Thread(target=heartbeats, daemon=True)
    if args.live:
        beater.start()
    time.sleep(0.5)

    start = time.monotonic()
    b = socket.create_connection((args.host, args.port), timeout=5)
    b.sendall(hello_packet(args.name + " B"))
    if args.expect == "closed":
        rc = 0
        if closed_by_receiver(b, 1.0):
            print(f"[mock] the receiver closed B after {time.monotonic() - start:.2f} s")
        else:
            print("[mock] ERROR: B was left open (queued) for 1 s while A was there")
            rc = 1
        stop.set()
        if args.live:
            beater.join()
        if closed_by_receiver(a, 0.3):
            print("[mock] ERROR: session A lost the slot")
            rc = 1
        else:
            print("[mock] session A kept the slot")
        for sock in (a, b):
            try:
                sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))
            except OSError:
                pass
            sock.close()
        return rc
    window = args.max_change_s if args.expect == "taken" else 4.0
    profile = read_profile(b, window)
    took = time.monotonic() - start
    rc = 0
    if args.expect == "taken":
        if not profile:
            print(f"[mock] ERROR: B was not taken within {window:.1f} s")
            rc = 1
        else:
            print(f"[mock] B taken after {took:.2f} s")
            if closed_by_receiver(a, 2.0):
                print("[mock] the receiver closed session A")
            else:
                print("[mock] ERROR: session A is still open")
                rc = 1
    else:
        if profile:
            print(f"[mock] ERROR: B took the slot after {took:.2f} s while A was there")
            rc = 1
        else:
            print(f"[mock] B not taken in {window:.1f} s: session A kept the slot")
            if args.live:
                stop.set()
                beater.join()
                a.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))
                start = time.monotonic()
                if read_profile(b, 5):
                    print(f"[mock] B taken {time.monotonic() - start:.2f} s after A's TEARDOWN (it had waited)")
                else:
                    print("[mock] ERROR: B was not taken after A's TEARDOWN")
                    rc = 1
    stop.set()
    for sock in (a, b):
        try:
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))
        except OSError:
            pass
        sock.close()
    return rc


def run(args) -> int:
    if args.mode == "cycles":
        return run_cycles(args)
    if args.mode == "displace":
        return run_displace(args)
    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"[mock] connected to {args.host}:{args.port}")
    if args.mode == "pointer":
        profile = read_profile(sock)
        if profile.get("cursorImage") is not True:
            print(f"[mock] ERROR: receiver profile has no \"cursorImage\": true ({profile.get('cursorImage')!r})")
            sock.close()
            return 1
        print("[mock] receiver draws the pointer (cursorImage: true)")
    else:
        time.sleep(0.2)
        drain_receiver(sock)

    sock.sendall(hello_packet(args.name, args.renderer))
    print("[mock] sent HELLO")

    try:
        if args.mode == "handshake":
            deadline = time.monotonic() + args.duration
            seq = 0
            while time.monotonic() < deadline:
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": seq}))
                seq += 1
                drain_receiver(sock)
                time.sleep(2.0)
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))
            print("[mock] sent TEARDOWN")

        elif args.mode in ("stream", "pointer"):
            stream_video(sock, args.duration, args.fps, args.size, pointer=args.mode == "pointer",
                         audio=args.audio, stall_at=args.stall_at, stall_ms=args.stall_ms)
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock stream done"}))

        elif args.mode == "stall":
            sock.sendall(packet(PKT_TEST_DATA, f"stall {args.stall_ms}".encode()))
            print(f"[mock] asked the receiver to stall {args.stall_ms} ms")
            time.sleep(args.stall_ms / 1000.0 + 1.0)
            sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": 0}))
            sock.sendall(json_packet(PKT_TEARDOWN, {"reason": "mock done"}))

        elif args.mode == "hang":
            print(f"[mock] going silent for {args.duration}s (socket stays open, no heartbeats)")
            time.sleep(args.duration)
            # If the receiver's idle watchdog works, it already closed us.
            try:
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": 0}))
                sock.sendall(json_packet(PKT_HEARTBEAT, {"sequence": 1}))
                print("[mock] receiver still accepted writes after silence")
            except (BrokenPipeError, ConnectionResetError):
                print("[mock] receiver closed the stale session (watchdog OK)")

        elif args.mode == "badlen":
            sock.sendall(struct.pack(">I", 0xFFFFFFFF) + b"\x21")
            print("[mock] sent corrupt 0xFFFFFFFF length prefix")
            sock.settimeout(5)
            try:
                data = sock.recv(4096)
                while data:
                    data = sock.recv(4096)
                print("[mock] receiver disconnected us (parser rejected corrupt length)")
            except socket.timeout:
                print("[mock] ERROR: receiver did not disconnect within 5s")
                return 1

        elif args.mode == "drop":
            # Announce a 1000-byte packet but send only half, then vanish.
            sock.sendall(struct.pack(">I", 1001) + b"\x21" + b"\x00" * 500)
            print("[mock] sent partial frame; closing abruptly")

    finally:
        sock.close()
    print("[mock] done")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=54321)
    ap.add_argument("--mode", choices=["handshake", "stream", "hang", "badlen", "drop", "pointer", "stall", "cycles",
                                       "displace"],
                    default="handshake")
    ap.add_argument("--duration", type=int, default=5, help="seconds (mode-specific)")
    ap.add_argument("--fps", type=int, default=30, help="stream/pointer: frame rate")
    ap.add_argument("--size", default="1280x720", help="stream/pointer: frame size, WxH")
    ap.add_argument("--audio", action="store_true", help="stream/pointer/cycles: silent PCM audio too")
    ap.add_argument("--stall-ms", type=int, default=3000, help="stall: how long the receiver's loop stalls")
    ap.add_argument("--stall-at", type=float, default=-1.0,
                    help="stream: seconds into the stream to ask for a --stall-ms stall (test builds)")
    ap.add_argument("--cycles", type=int, default=6, help="cycles: how many preset changes")
    ap.add_argument("--sizes", default="1280x720,1920x1080,2560x1440", help="cycles: sizes in turn")
    ap.add_argument("--max-change-s", type=float, default=5.0, help="cycles: slowest change allowed")
    ap.add_argument("--expect", choices=["taken", "kept", "closed"], default="taken",
                    help="displace: whether the second connection should take the slot")
    ap.add_argument("--live", action="store_true", help="displace: the first session keeps heartbeating")
    ap.add_argument("--name", default="MockSender")
    ap.add_argument("--renderer", choices=["", "opengl", "metal"], default="",
                    help="PWE: receiverRenderer in the HELLO (absent by default, as from upstream)")
    return run(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
