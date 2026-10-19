#!/usr/bin/env python3
"""Turn a copy of the TargetBridge source tree into the PWE iMac Display build.

Run it on a scratch copy, never on the repository: `main` keeps upstream's code
unchanged so that merging a new TargetBridge release stays a plain merge. The
PWE build is what this script makes of that code at packaging time.

    python3 -I pwe/rebrand.py <copy-of-the-tree> --version 1.0.0 --build 20261014120000

What it changes, and what it leaves alone on purpose:

- Names, bundle identifiers, the URL scheme, the settings folders and the icon
  become PWE iMac Display's, so the app never shares an identity, a privacy
  permission or a settings file with an installed TargetBridge.
- The wire protocol and the Bonjour service type `_targetbridge._tcp` stay as
  they are: a PWE sender finds a TargetBridge receiver and the other way round.
- The About text credits TargetBridge and its authors.
- Network Link is off by default; the sender's language follows the system.

Every edit is anchored to text that must be found exactly as often as expected.
If upstream changes that text, the script stops instead of guessing, and the
final check fails the build if any user-visible "TargetBridge" is left over.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

NAME = "PWE iMac Display"
RECEIVER_NAME = "PWE iMac Display Receiver"
SENDER_ID = "com.pwegroup.pweimacdisplay"
RECEIVER_ID = "com.pwegroup.pweimacdisplay.receiver"
SCHEME = "pweimacdisplay"
REPO = "https://github.com/kenshinice-ai/pwe-imac-display"
UPSTREAM = "github.com/swellweb/targetBridge"

# Credits replace upstream's "Created by swellweb …" line in each language.
# `⟪TB⟫` survives the generic rename and becomes "TargetBridge" at the end.
CREDITS = {
    "Created by swellweb": (
        f"Based on ⟪TB⟫, created by Marco Caciotti (swellweb) with the ⟪TB⟫ open-source "
        f"community, including ThomasWaldmann, DrDavidL and potar712 — {UPSTREAM}, MIT License. "
        f"This build is made and signed by PWE Group."
    ),
    "由 swellweb": (
        f"基于 ⟪TB⟫。⟪TB⟫ 由 Marco Caciotti（swellweb）创建，开源社区共同完善，"
        f"重要贡献者包括 ThomasWaldmann、DrDavidL、potar712 —— {UPSTREAM}，MIT 许可。"
        f"本版本由 PWE Group 构建并签名。"
    ),
    "Creato da swellweb": (
        f"Basato su ⟪TB⟫, creato da Marco Caciotti (swellweb) con la community open source di ⟪TB⟫, "
        f"tra cui ThomasWaldmann, DrDavidL e potar712 — {UPSTREAM}, licenza MIT. "
        f"Questa build è realizzata e firmata da PWE Group."
    ),
    "Erstellt von swellweb": (
        f"Basiert auf ⟪TB⟫, erstellt von Marco Caciotti (swellweb) mit der ⟪TB⟫-Open-Source-Community, "
        f"darunter ThomasWaldmann, DrDavidL und potar712 — {UPSTREAM}, MIT-Lizenz. "
        f"Dieser Build wird von PWE Group erstellt und signiert."
    ),
    "Créé par swellweb": (
        f"Basé sur ⟪TB⟫, créé par Marco Caciotti (swellweb) avec la communauté open source de ⟪TB⟫, "
        f"dont ThomasWaldmann, DrDavidL et potar712 — {UPSTREAM}, licence MIT. "
        f"Cette version est compilée et signée par PWE Group."
    ),
}

RECEIVER_TITLES = {
    "en": "PWE iMac Display Receiver",
    "zh": "PWE iMac Display 接收端",
    "it": "PWE iMac Display Receiver",
    "de": "PWE iMac Display Empfänger",
    "fr": "PWE iMac Display Receiver",
}

LANGUAGE_FALLBACK = """\
            for code in Locale.preferredLanguages {
                if code.hasPrefix("zh") { return .chinese }
                if code.hasPrefix("it") { return .italian }
                if code.hasPrefix("de") { return .german }
                if code.hasPrefix("fr") { return .french }
                if code.hasPrefix("en") { return .english }
            }
            return .english"""

SWIFT_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
C_LITERAL = SWIFT_LITERAL


class RebrandError(Exception):
    pass


def edit(path: Path, old: str, new: str, count: int = 1) -> None:
    """Replace `old` with `new`, which must occur exactly `count` times."""
    text = path.read_text(encoding="utf-8")
    found = text.count(old)
    if found != count:
        raise RebrandError(f"{path}: expected {count}× {old!r}, found {found}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def rename_in_literals(path: Path, keep: tuple[str, ...] = ()) -> int:
    """Rename TargetBridge inside string literals, except literals containing `keep`."""
    text = path.read_text(encoding="utf-8")
    changes = 0

    def swap(match: re.Match[str]) -> str:
        nonlocal changes
        body = match.group(1)
        if "TargetBridge" not in body or any(k in body for k in keep):
            return match.group(0)
        changes += 1
        return '"' + body.replace("TargetBridge Receiver", RECEIVER_NAME).replace("TargetBridge", NAME) + '"'

    out = []
    for line in text.split("\n"):
        # Comments are not user-visible; leave them as upstream wrote them.
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            out.append(line)
        else:
            out.append(SWIFT_LITERAL.sub(swap, line))
    path.write_text("\n".join(out), encoding="utf-8")
    return changes


def rebrand_languages(root: Path) -> None:
    for path in sorted((root / "TargetBridge-Shared/Languages").glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for key, value in data.items():
            data[key] = value.replace("TargetBridge", NAME)
        # Upstream sets this title in capitals. "iMac" is never written in
        # capitals, so the PWE title is in ordinary case in every language.
        data["receiver.ui.title"] = RECEIVER_TITLES[path.stem]
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def rebrand_addons(root: Path) -> None:
    for path in sorted((root / "TargetBridge-Shared/Addons").glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        # `author` stays "TargetBridge": it is a credit, and it is accurate.
        # The bundled add-ons ship with the engine they belong to, so they need
        # no minimum. Theirs ("3.0") is in upstream numbering; against the PWE
        # version (1.x) every add-on read as Incompatible and stayed off — 1.0.0
        # shipped that way, with no audio on the iMac (2026-10-19, iMac18,3).
        data.pop("minimumSenderVersion", None)
        if "summary" in data:
            data["summary"] = data["summary"].replace("TargetBridge", NAME)
        if data.get("id") == "targetbridge.network-link":
            # PWE iMac Display 1.0 is a Thunderbolt cable product. Network Link
            # stays available, but a person has to turn it on.
            data["defaultEnabled"] = False
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def rebrand_sender(root: Path, version: str, build: str) -> None:
    sender = root / "TargetBridge-Sender"
    support = sender / "TargetBridgeSupport"

    plist = support / "Info.plist"
    edit(plist, "<string>TargetBridge</string>", f"<string>{NAME}</string>")
    edit(plist, "<string>TargetBridge - Free &amp; Open Source</string>",
         "<string>PWE Group. Based on TargetBridge (MIT).</string>")
    edit(plist, "<string>com.targetbridge.sender</string>", f"<string>{SENDER_ID}</string>")
    edit(plist, "<string>targetbridge</string>", f"<string>{SCHEME}</string>")
    text = plist.read_text(encoding="utf-8")
    plist.write_text(text.replace("<string>TargetBridge requires", f"<string>{NAME} requires")
                         .replace("<string>TargetBridge uses", f"<string>{NAME} uses")
                         .replace("<string>TargetBridge connects", f"<string>{NAME} connects"),
                     encoding="utf-8")

    project = sender / "project.yml"
    edit(project, "bundleIdPrefix: com.targetbridge", "bundleIdPrefix: com.pwegroup")
    # The Swift module keeps its upstream name: the tests `@testable import TargetBridge`,
    # and nobody sees a module name.
    edit(project, 'PRODUCT_NAME: "TargetBridge"',
         f'PRODUCT_NAME: "{NAME}"\n        PRODUCT_MODULE_NAME: TargetBridge')
    edit(project, "PRODUCT_BUNDLE_IDENTIFIER: com.targetbridge.sender.tests",
         f"PRODUCT_BUNDLE_IDENTIFIER: {SENDER_ID}.tests")
    edit(project, "PRODUCT_BUNDLE_IDENTIFIER: com.targetbridge.sender", f"PRODUCT_BUNDLE_IDENTIFIER: {SENDER_ID}")
    edit(project, "ENABLE_HARDENED_RUNTIME: NO", "ENABLE_HARDENED_RUNTIME: YES")
    edit(project, "$(BUILT_PRODUCTS_DIR)/TargetBridge.app/Contents/MacOS/TargetBridge",
         f"$(BUILT_PRODUCTS_DIR)/{NAME}.app/Contents/MacOS/{NAME}")
    text = project.read_text(encoding="utf-8")
    text, n = re.subn(r'MARKETING_VERSION: "[^"]+"', f'MARKETING_VERSION: "{version}"', text)
    if n != 1:
        raise RebrandError(f"{project}: MARKETING_VERSION found {n}×")
    text, n = re.subn(r'CURRENT_PROJECT_VERSION: "[^"]+"', f'CURRENT_PROJECT_VERSION: "{build}"', text)
    if n != 1:
        raise RebrandError(f"{project}: CURRENT_PROJECT_VERSION found {n}×")
    text, n = re.subn(r'static let marketingVersion = "[^"]+"', f'static let marketingVersion = "{version}"', text)
    if n != 1:
        raise RebrandError(f"{project}: marketingVersion found {n}×")
    project.write_text(text, encoding="utf-8")

    swift = sender / "TBDisplaySender"
    for view in ("TBDisplaySenderAboutView.swift", "TBDisplaySenderSettingsView.swift"):
        edit(swift / view, '"https://github.com/swellweb/targetBridge/releases/latest"', f'"{REPO}/releases/latest"')
        edit(swift / view, '"https://github.com/swellweb/targetBridge"', f'"{REPO}"')

    about = swift / "TBDisplaySenderAboutView.swift"
    text = about.read_text(encoding="utf-8")
    for prefix, credit in CREDITS.items():
        pattern = re.compile(r'"' + re.escape(prefix) + r'(?:[^"\\]|\\.)*"')
        text, n = pattern.subn(lambda _m: '"' + credit + '"', text)
        if n != 1:
            raise RebrandError(f"{about}: credit line {prefix!r} found {n}×")
    about.write_text(text, encoding="utf-8")

    edit(swift / "TBDisplaySenderLocalization.swift",
         "              let language = TBDisplaySenderLanguage(rawValue: raw) else {\n            return .italian\n",
         "              let language = TBDisplaySenderLanguage(rawValue: raw) else {\n" + LANGUAGE_FALLBACK + "\n")

    for path in sorted(swift.glob("*.swift")) + sorted((sender / "TBDisplayShared").glob("*.swift")):
        rename_in_literals(path, keep=("TargetBridge-Shared", "⟪TB⟫"))
        path.write_text(path.read_text(encoding="utf-8").replace("⟪TB⟫", "TargetBridge"), encoding="utf-8")

    # The one test that pins the settings folder follows it to the PWE name.
    edit(sender / "TBDisplaySenderTests/TBSenderAutomationParsingTests.swift",
         '"Library/Application Support/TargetBridge/Sender/enabled"',
         f'"Library/Application Support/{NAME}/Sender/enabled"')

    # The engine is TargetBridge's; the window is PWE's (pwe/sender-ui). The PWE
    # App replaces upstream's entry point, and reads the session phase the engine
    # already tracks.
    edit(swift / "TBDisplaySenderApp.swift", "@main\nstruct TBDisplaySenderApp: App {",
         "struct TBDisplaySenderApp: App {")
    edit(swift / "TBDisplaySenderService.swift",
         "    private var statusState: TBDisplaySenderStatusState = .ready",
         "    @Published private(set) var statusState: TBDisplaySenderStatusState = .ready")
    # 1.0 shipped with this still "targetbridge", so URL automation did nothing.
    edit(swift / "TBDisplaySenderAutomation.swift",
         'guard url.scheme?.lowercased() == "targetbridge" else { return }',
         f'guard url.scheme?.lowercased() == "{SCHEME}" else {{ return }}')
    # The PWE window shows "Trying again…" only while the engine really is. The
    # engine ends its retrying on its own (a Stop from the menu bar, a capture
    # failure, a missing permission), so the window reads it from here.
    edit(swift / "TBDisplaySenderAutomation.swift",
         "    private static var continuousConnectTask: Task<Void, Never>?\n",
         "    private static var continuousConnectTask: Task<Void, Never>? {\n"
         "        didSet { NotificationCenter.default.post(name: automaticConnectionDidChange, object: nil) }\n"
         "    }\n"
         "    /// True while the engine keeps a connection up and retries it by itself.\n"
         "    static var isConnectingAutomatically: Bool { continuousConnectTask != nil }\n"
         '    static let automaticConnectionDidChange = Notification.Name("pwe.automaticConnectionDidChange")\n')
    # "Reopen" on the permission screen only quit: opening a running app's own
    # bundle activates it rather than starting another. Relaunch once this
    # process has gone instead. (Upstream bug too; see the report on item 6.)
    edit(swift / "TBDisplaySenderManager.swift",
         "    func restartAfterPermissionChange() {\n"
         "        let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)\n"
         "        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in\n"
         "            guard error == nil else { return }\n"
         "            DispatchQueue.main.async {\n"
         "                NSApp.terminate(nil)\n"
         "            }\n"
         "        }\n"
         "    }\n",
         "    func restartAfterPermissionChange() {\n"
         "        // Wait (up to 10 s) for this process to exit, then open the app again.\n"
         "        let relaunch = Process()\n"
         '        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")\n'
         "        relaunch.arguments = [\n"
         '            "-c",\n'
         '            "for _ in $(/usr/bin/jot 50); do /bin/kill -0 \\"$0\\" 2>/dev/null || break; /bin/sleep 0.2; done; /usr/bin/open \\"$1\\"",\n'
         '            String(ProcessInfo.processInfo.processIdentifier),\n'
         "            Bundle.main.bundlePath,\n"
         "        ]\n"
         "        do {\n"
         "            try relaunch.run()\n"
         "        } catch {\n"
         '            NSLog("[permissions] unable to schedule relaunch: \\(error.localizedDescription)")\n'
         "            return\n"
         "        }\n"
         "        NSApp.terminate(nil)\n"
         "    }\n")
    pwe_ui = swift / "PWE"
    pwe_ui.mkdir()
    for source in sorted((root / "pwe/sender-ui").glob("*.swift")):
        shutil.copy(source, pwe_ui / source.name)
    # PWE's own unit tests run with upstream's, against the same app target.
    for source in sorted((root / "pwe/sender-tests").glob("*.swift")):
        shutil.copy(source, sender / "TBDisplaySenderTests" / source.name)

    icon = support / "Assets.xcassets/AppIcon.appiconset"
    shutil.rmtree(icon)
    shutil.copytree(root / "pwe/assets/AppIcon.appiconset", icon)


def rebrand_receiver(root: Path) -> None:
    src = root / "TargetBridge-Receiver/TBReceiverC/src"
    edit(src / "main.c", 'CFSTR("com.targetbridge.receiver")', f'CFSTR("{RECEIVER_ID}")')
    for path in sorted(src.glob("*.c")) + sorted(src.glob("*.m")):
        rename_in_literals(path)
    assets = root / "TargetBridge-Receiver/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset"
    shutil.copy(root / "pwe/assets/icon_1024.png", assets / "icon_1024.png")


# Literals that may still say TargetBridge after the rename, and why.
ALLOWED = (
    "TargetBridge-Shared",   # source path of the language files, used in development builds only
    "swellweb",              # the credit line
    "Based on TargetBridge",  # Info.plist copyright
)


def leftovers(root: Path) -> list[str]:
    found = []
    files = (list((root / "TargetBridge-Sender/TBDisplaySender").glob("*.swift"))
             + list((root / "TargetBridge-Sender/TBDisplayShared").glob("*.swift"))
             + list((root / "TargetBridge-Receiver/TBReceiverC/src").glob("*.[cm]")))
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
            if line.lstrip().startswith(("//", "*", "/*")):
                continue
            for match in SWIFT_LITERAL.finditer(line):
                body = match.group(1)
                if "TargetBridge" in body and not any(a in body for a in ALLOWED):
                    found.append(f"{path.relative_to(root)}:{number}: {body[:80]}")
    for path in (root / "TargetBridge-Shared/Languages").glob("*.json"):
        for key, value in json.loads(path.read_text(encoding="utf-8")).items():
            if re.search("targetbridge", value, re.IGNORECASE):
                found.append(f"{path.relative_to(root)}: {key}")
    # The Chinese interface names its two apps 发送端 and 接收端. An English role
    # word left in it is a string nobody translated (1.0 shipped "RECEIVER").
    zh = json.loads((root / "TargetBridge-Shared/Languages/zh.json").read_text(encoding="utf-8"))
    for key, value in zh.items():
        if re.search(r"\b(sender|receiver|master|slave)\b", value.replace(RECEIVER_NAME, ""), re.IGNORECASE):
            found.append(f"zh.json: {key}: English role word in {value!r}")
    automation = (root / "TargetBridge-Sender/TBDisplaySender/TBDisplaySenderAutomation.swift").read_text(encoding="utf-8")
    if '== "targetbridge"' in automation:
        found.append("TBDisplaySenderAutomation.swift: URL scheme check still says targetbridge")
    plist = (root / "TargetBridge-Sender/TargetBridgeSupport/Info.plist").read_text(encoding="utf-8")
    for line in plist.split("\n"):
        if "<string>" in line and re.search("targetbridge", line, re.IGNORECASE) \
                and "_targetbridge._tcp" not in line and not any(a in line for a in ALLOWED):
            found.append(f"Info.plist: {line.strip()}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("tree", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    root = args.tree.resolve()
    if (root / ".git").exists():
        print("refusing to rebrand a git checkout; run it on a scratch copy", file=sys.stderr)
        return 2
    try:
        rebrand_languages(root)
        rebrand_addons(root)
        rebrand_sender(root, args.version, args.build)
        rebrand_receiver(root)
    except RebrandError as error:
        print(f"rebrand: upstream text changed, update pwe/rebrand.py: {error}", file=sys.stderr)
        return 1
    left = leftovers(root)
    if left:
        print("rebrand: user-visible TargetBridge left over:", file=sys.stderr)
        for line in left:
            print(f"  {line}", file=sys.stderr)
        return 1
    print(f"rebrand: {NAME} {args.version} ({args.build}) ready in {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
