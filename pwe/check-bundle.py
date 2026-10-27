#!/usr/bin/env python3
"""Check built apps for faults that the source checks cannot see.

    python3 -I pwe/check-bundle.py <app>...

pwe/package.sh runs this on both apps before signing. It also works on the apps
in a mounted release image, to check what was actually shipped.

1. A symbol newer than the binary's own minimum system (macOS 11 for the
   receiver) must be a weak import. A strong import of a missing symbol stops
   dyld before main(), so the app does not open at all on the older system —
   and nothing on a newer Mac shows it.
2. The upstream URL scheme must not survive in code. Swift keeps strings of up
   to 15 bytes inside instructions, not in the string table, so `strings` and the
   source-side leftover check in rebrand.py can both miss one. 1.0.0 shipped
   `url.scheme == "targetbridge"` this way and its URL automation never matched.
   On x86_64 such a literal is a movabs immediate, its first 8 bytes in a row,
   so the x86_64 slice is searched; arm64 splits it into 16-bit pieces.
3. Every add-on manifest bundled in the sender must be compatible with the
   sender's own version, the test TBAddonStore.isCompatible makes. An
   incompatible add-on is off whatever its switch says. 1.0.0 shipped upstream
   manifests asking for sender 3.0, so audio, input sharing and Network Link
   were all dead.
4. No text a person sees may carry the old product name, "PWE iMac Display"
   (renamed PWE Screen Encore on 2026-10-20: a product name must not contain
   Apple's "iMac"). Checked: the bundle's file name, every string in Info.plist
   and in the bundled language and .strings files. The bundle identifiers keep
   the old spelling on purpose; written in lower case, they do not match.
5. No test hook may survive in a shipped executable. The receiver's hooks are
   environment variables named TB_RECEIVER_TEST_* behind `make TEST_HOOKS=1`;
   the sender's are the pweTest* members of its Debug builds. Every
   architecture slice is searched for those names: a name that is in the
   binary is read by the binary, so the hook is live for anyone who sets it.
"""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# Imported symbols that macOS 11 does not have, with the system that added them.
ADDED_IN = {
    "_OBJC_CLASS_$_SMAppService": "13.0",
    "_CVBufferCopyAttachments": "12.0",
}

# Old-name bytes that are meant to stay: the Bonjour service type (receivers of
# every build must find each other), and identifiers users never see — the
# engine's defaults key prefix and its log subsystem.
OLD_SCHEME = b"targetbr"
KEPT_PREFIXES = (b"_", b"com.")

# Names that only test builds may contain, longest first so that one
# occurrence is reported once.
TEST_HOOKS = re.compile(rb"TB_RECEIVER_TEST_LOOPBACK_IS_CABLE|TB_RECEIVER_TEST_|TEST_HOOKS|pweTest")


SENDER_ID = "com.pwegroup.pweimacdisplay"
OLD_NAME = re.compile(r"iMac ?Display")


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def info(app, key):
    plist = app / "Contents/Info.plist"
    return run("/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(plist)).strip()


def executables(app):
    return [app / "Contents/MacOS" / info(app, "CFBundleExecutable")]


def archs(binary):
    return run("lipo", "-archs", str(binary)).split()


def version(text):
    return tuple(int(part) for part in text.split("."))


def minimum_system(binary, arch):
    build = run("vtool", "-arch", arch, "-show-build", str(binary))
    return re.search(r"minos (\S+)", build).group(1)


def check_weak_imports(binary, arch):
    minos = minimum_system(binary, arch)
    faults = []
    for line in run("nm", "-m", "-arch", arch, str(binary)).splitlines():
        symbol = re.search(r"\(undefined\).* (_\S+) \(from ", line)
        if not symbol or symbol.group(1) not in ADDED_IN:
            continue
        name = symbol.group(1)
        if version(ADDED_IN[name]) > version(minos) and "weak external" not in line:
            faults.append(f"{binary.name} {arch}: {name} (macOS {ADDED_IN[name]}+) is a strong "
                          f"import, so the app will not launch on macOS {minos}")
    return faults


def slice_bytes(binary, arch, scratch):
    thin = scratch / f"{binary.name}.{arch}"
    subprocess.run(["lipo", "-thin", arch, str(binary), "-output", str(thin)], check=True)
    data = thin.read_bytes()
    thin.unlink()
    return data


def shown(data, start, end):
    return "".join(chr(b) if 32 <= b < 127 else "." for b in data[max(0, start):end])


def check_old_scheme(binary, scratch):
    if "x86_64" not in archs(binary):
        return [f"{binary.name}: no x86_64 slice to search for the old URL scheme"]
    data = slice_bytes(binary, "x86_64", scratch)
    faults = []
    for match in re.finditer(re.escape(OLD_SCHEME), data):
        start = match.start()
        if any(data[start - len(p):start] == p for p in KEPT_PREFIXES):
            continue
        faults.append(f"{binary.name} x86_64 @0x{start:x}: old scheme bytes in code: "
                      f"{shown(data, start - 8, start + 16)!r}")
    return faults


def check_test_hooks(binary, arch, scratch):
    data = slice_bytes(binary, arch, scratch)
    faults = []
    for match in TEST_HOOKS.finditer(data):
        start = match.start()
        faults.append(f"{binary.name} {arch} @0x{start:x}: test hook in a shipped binary: "
                      f"{shown(data, start, start + 40)!r}")
    return faults


def add_on_version(text):
    # TBAddonStore.compareVersion: a part that is not a number counts as 0.
    parts = [int(part) if part.isdigit() else 0 for part in text.split(".")]
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def check_add_ons(app):
    if info(app, "CFBundleIdentifier") != SENDER_ID:
        return []
    sender = info(app, "CFBundleShortVersionString")
    manifests = []
    for path in sorted((app / "Contents/Resources").rglob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            continue   # the store skips a file it cannot decode, too
        if isinstance(data, dict) and "id" in data and "capabilities" in data:
            manifests.append((path, data))
    if not manifests:
        return [f"{app.name}: no bundled add-on manifests found"]
    faults = []
    for path, data in manifests:
        minimum = data.get("minimumSenderVersion") or ""
        if minimum and add_on_version(sender) < add_on_version(minimum):
            faults.append(f"{app.name}: add-on {data['id']} ({path.name}) needs sender {minimum}, "
                          f"but this sender is {sender}, so the app turns it off as Incompatible")
    return faults


def plist_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from plist_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from plist_strings(item)


def check_old_name(app):
    faults = []
    if OLD_NAME.search(app.name):
        faults.append(f"{app.name}: the bundle still carries the old product name")
    with open(app / "Contents/Info.plist", "rb") as handle:
        for text in plist_strings(plistlib.load(handle)):
            if OLD_NAME.search(text):
                faults.append(f"{app.name} Info.plist: old product name in {text[:80]!r}")
    resources = app / "Contents/Resources"
    for path in sorted(resources.rglob("*.json")) + sorted(resources.rglob("*.strings")):
        data = path.read_bytes()
        if data.startswith(b"bplist"):   # a compiled .strings file
            lines = list(plist_strings(plistlib.loads(data)))
        else:
            encoding = "utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
            lines = data.decode(encoding, errors="replace").splitlines()
        for line in lines:
            if OLD_NAME.search(line):
                faults.append(f"{app.name} {path.relative_to(resources)}: old product name in {line.strip()[:80]!r}")
    return faults


def main(paths):
    if not paths:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    scratch = Path(run("mktemp", "-d").strip())
    faults = []
    try:
        for path in map(Path, paths):
            for binary in executables(path):
                for arch in archs(binary):
                    faults += check_weak_imports(binary, arch)
                    faults += check_test_hooks(binary, arch, scratch)
                faults += check_old_scheme(binary, scratch)
            faults += check_add_ons(path)
            faults += check_old_name(path)
    finally:
        scratch.rmdir()
    for fault in faults:
        print(f"✗ {fault}")
    if faults:
        sys.exit(1)
    print(f"  bundle checks passed: {', '.join(Path(p).name for p in paths)}")


if __name__ == "__main__":
    main(sys.argv[1:])
