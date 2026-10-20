#!/usr/bin/env python3
"""Summarise a soak.sh run: python3 -I summarize.py <run dir> -> <run dir>/summary.md

Reads metrics.csv, events.log, workload.log and run.txt. The verdict lines are
the release gate for "two hours of real work" (PLAN-1.1-final-2026-10-21.md §四):
the iMac display never disappears, the sender never restarts, and its memory
does not keep growing.
"""
import csv
import json
import re
import statistics
import sys
from pathlib import Path

SAMPLE_S = 30
MEMORY_GROWTH_LIMIT_MB_PER_H = 50

EVENT_PATTERNS = {
    "dials": r"connect: dialing|dialing \d",
    "redials over the bridge": r"redialing .* over the Thunderbolt Bridge",
    "pipelines started": r"pipeline started",
    "first frames": r"first encoded frame",
    "routes lost": r"no route",
    "closed connections": r"closing|connection closed|disconnected",
    "errors": r"\berror\b|\bfailed\b",
}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def slope_per_hour(points):
    """Least-squares slope of (seconds, value), in value per hour."""
    if len(points) < 3:
        return None
    xs, ys = zip(*points)
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return None if den == 0 else sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 3600


def p95(values):
    return sorted(values)[max(0, int(len(values) * 0.95) - 1)] if values else None


def fmt(v, unit=""):
    return "n/a" if v is None else f"{v:.1f}{unit}"


def main(run: Path):
    rows = list(csv.DictReader((run / "metrics.csv").open())) if (run / "metrics.csv").exists() else []
    info = dict(line.split("=", 1) for line in (run / "run.txt").read_text().splitlines()
                if "=" in line and not line.startswith("hours=")) if (run / "run.txt").exists() else {}

    # The iMac display: every sample without it, and the longest stretch.
    missing, longest, current = 0, 0, 0
    for r in rows:
        if r["imac_display"] == "1":
            current = 0
        else:
            missing += 1
            current += 1
            longest = max(longest, current)

    pids = [r["sender_pid"] for r in rows if r["sender_pid"] != "NA"]
    restarts = sum(1 for a, b in zip(pids, pids[1:]) if a != b)
    sender_gone = sum(1 for r in rows if r["sender_pid"] == "NA")

    cpu = [v for v in (num(r["sender_cpu"]) for r in rows) if v is not None]
    rss_pts = [(num(r["elapsed_s"]), num(r["sender_rss_mb"])) for r in rows
               if num(r["sender_rss_mb"]) is not None and num(r["elapsed_s"]) is not None]
    # Ignore the first 10 minutes: caches fill up, then it should stay flat.
    settled = [p for p in rss_pts if p[0] >= 600] or rss_pts
    growth = slope_per_hour(settled)
    rcpu = [v for v in (num(r.get("receiver_cpu")) for r in rows) if v is not None]
    rrss_pts = [(num(r["elapsed_s"]), num(r["receiver_rss_mb"])) for r in rows
                if num(r.get("receiver_rss_mb")) is not None]
    rgrowth = slope_per_hour([p for p in rrss_pts if p[0] >= 600] or rrss_pts)

    events_text = (run / "events.log").read_text(errors="replace") if (run / "events.log").exists() else ""
    counts = {k: len(re.findall(p, events_text, re.IGNORECASE)) for k, p in EVENT_PATTERNS.items()}

    steps_ok, steps_failed = 0, []
    if (run / "workload.log").exists():
        for line in (run / "workload.log").read_text(errors="replace").splitlines():
            try:
                s = json.loads(line)
            except ValueError:
                continue
            if s.get("ok"):
                steps_ok += 1
            else:
                steps_failed.append(f"{s.get('t', '?')} {s.get('step')}: {s.get('error')}")

    hours = (num(rows[-1]["elapsed_s"]) or 0) / 3600 if rows else 0
    gates = [
        ("iMac display never disappeared", missing == 0,
         f"{missing} of {len(rows)} samples without it; longest stretch {longest * SAMPLE_S} s"),
        ("sender never restarted or quit", restarts == 0 and sender_gone == 0,
         f"{restarts} restart(s), {sender_gone} sample(s) without the app"),
        (f"sender memory growth below {MEMORY_GROWTH_LIMIT_MB_PER_H} MB/h after the first 10 minutes",
         growth is not None and growth < MEMORY_GROWTH_LIMIT_MB_PER_H, f"{fmt(growth, ' MB/h')}"),
    ]

    out = [
        f"# Soak test summary — {run.name}",
        "",
        f"- Run: {info.get('started', '?')} → {info.get('ended', '?')} ({hours:.2f} h recorded, {len(rows)} samples every {SAMPLE_S} s)",
        f"- Sender: {info.get('sender_version', '?')} build {info.get('build', '?')} on {info.get('mac', '?')} macOS {info.get('macos', '?')}",
        "",
        "## Gates",
        "",
        "| Gate | Result | Evidence |",
        "|---|---|---|",
    ]
    out += [f"| {name} | {'PASS' if ok else 'FAIL'} | {ev} |" for name, ok, ev in gates]
    out += [
        "",
        "## Numbers",
        "",
        f"- Sender CPU: mean {fmt(statistics.fmean(cpu) if cpu else None, '%')}, p95 {fmt(p95(cpu), '%')}, max {fmt(max(cpu) if cpu else None, '%')}",
        f"- Sender memory: first {fmt(rss_pts[0][1] if rss_pts else None, ' MB')}, last {fmt(rss_pts[-1][1] if rss_pts else None, ' MB')}, max {fmt(max(p[1] for p in rss_pts) if rss_pts else None, ' MB')}, trend {fmt(growth, ' MB/h')}",
        f"- Receiver CPU: mean {fmt(statistics.fmean(rcpu) if rcpu else None, '%')}, max {fmt(max(rcpu) if rcpu else None, '%')}"
        + ("" if rcpu else " (not recorded: run with --imac to include it)"),
        f"- Receiver memory trend: {fmt(rgrowth, ' MB/h')}",
        f"- Simulated work: {steps_ok} steps done, {len(steps_failed)} failed",
        "",
        "## Sender log events",
        "",
    ]
    out += [f"- {k}: {v}" for k, v in counts.items()]
    if steps_failed:
        out += ["", "## Failed steps", ""] + [f"- {s}" for s in steps_failed[:30]]
    out += [
        "",
        "Every dial after the first, every lost route and every closed connection during a run",
        "without cable changes is worth a look in events.log at its time stamp.",
        "",
    ]
    (run / "summary.md").write_text("\n".join(out))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
