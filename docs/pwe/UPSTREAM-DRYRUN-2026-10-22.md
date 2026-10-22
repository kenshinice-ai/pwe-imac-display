# Upstream merge dry-run — `upstream/maint-3.6` into `pwe-1.1`

- Date: 2026-10-22
- Worktree: `scratchpad/w-upstream`, detached at `d87021f` (pwe-1.1)
- Upstream head: `upstream/maint-3.6` = `6fa46ac4f1eba7f3797de75d2c22d50ab94def5c`
- `v3.6.0` = `76d3f99`; merge-base with pwe-1.1 = `11b156f` (Release TargetBridge 3.6.0, #210)
- Command: `git merge --no-commit --no-ff upstream/maint-3.6` → "Automatic merge failed" → `git merge --abort`
- After abort: `git status` clean, HEAD still `d87021f`, no `MERGE_HEAD`. Nothing pushed, no other worktree or branch touched.

## Result in one line

18 files in the merge; 4 conflicted (19 conflict hunks in total); 14 auto-merged cleanly.

## Conflicted files

| File | Hunks | Upstream commits touching it | What collides | Effort |
|---|---|---|---|---|
| `TargetBridge-Receiver/TBReceiverC/src/display.c` | 11 | #214, #215, #217 | Upstream re-laid-out the connecting/waiting status screen (new `status_layout.h`, orientation fix, 90+/47−). PWE 1.1 rewrote this file (1416+/209− vs base: Metal video, cursor image, pairing screen, trace). Largest hunk is 74 lines at line ~276; most others are 5–22 lines in the status-screen draw paths. | **L** |
| `TargetBridge-Receiver/TBReceiverC/Makefile` | 3 | #217 | Upstream adds `test_status_layout` target plus `src/display.o: src/status_layout.h`; PWE added the secure-layer, render and smoke test targets in the same `clean` / `test` blocks. Pure additive union. | **S** |
| `TargetBridge-Sender/TargetBridge.xcodeproj/project.pbxproj` | 3 | #213, #216, #217 | Upstream bumps `MARKETING_VERSION` 3.6.0 → 3.6.1 (2 configs); PWE added `OTHER_LDFLAGS` (libsodium + Security) on the same lines and a `secure` group entry. Take both. `project.yml` auto-merged, so regenerating with xcodegen is the alternative. | **S** |
| `TargetBridge-Shared/Languages/zh.json` | 2 | #212, #214 | Upstream polished zh wording and removed some `receiver.permissions.*` keys; PWE added `receiver.pairing.*` / `receiver.menu.*` keys at the tail. Keep PWE keys, take upstream wording. Check `en/de/fr/it.json` (auto-merged) still carry the PWE keys. | **S** |

## Auto-merged (no conflict) — 14 files

Modified: `.github/workflows/ci.yml`, `.gitignore`, `README.md`, `TargetBridge-Receiver/scripts/build_tbreceiver_c_app.sh`,
`TargetBridge-Sender/TBDisplaySender/TBDisplaySenderBuildInfo.swift`, `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderLocalization.swift`,
`TargetBridge-Sender/project.yml`, `docs/Testing.md`.
Added: `TargetBridge-Receiver/TBReceiverC/src/status_layout.h`, `TargetBridge-Receiver/TBReceiverC/tests/test_status_layout.c`,
`TargetBridge-Receiver/scripts/test_idle_display_sleep.sh`, `TargetBridge-Sender/TBDisplaySenderTests/TBDisplaySenderVersionTests.swift`,
`TargetBridge-Sender/TBDisplaySenderTests/TBSenderLanguageTests.swift`, `docs/releases/3.6.1.md`.

Upstream also touched these files that PWE changed too, but git merged them without conflict (worth a read, not a fix):
`TBDisplaySenderAboutView.swift`, `TBDisplaySenderContentView.swift`, `TBDisplaySenderManager.swift`,
`TBDisplaySenderPermissionAssistant.swift`, `TBDisplaySenderSettingsView.swift`, `Languages/{de,en,fr,it}.json`.

## Upstream commits since v3.6.0 (`git log --oneline v3.6.0..upstream/maint-3.6`)

| SHA | Subject | PWE-relevant area |
|---|---|---|
| `6fa46ac` | fix: prepare validated 3.6.1 maintenance candidate (#217) | Receiver `display.c`, `Makefile`, pbxproj version bump, CI, docs — yes |
| `6ec97a3` | fix(receiver): correct waiting-screen layout orientation (#215) | Receiver `display.c` status screen — yes (PWE rewrote this screen) |
| `afa8c93` | fix(sender): follow system language on first launch (#213) | Sender `Localization.swift`, pbxproj, new language test — yes (PWE touched Localization) |
| `320be5d` | fix(receiver): center and localize connecting screen (#214) | Receiver `display.c`, all `Languages/*.json` — yes |
| `5c4ec84` | l10n(zh): polish Sender and Receiver wording (#212) | `zh.json` — yes (PWE's zh strings) |
| `060450a` | build(sender): exclude development scripts from app bundle (#216) | pbxproj / `project.yml` — yes (PWE's pbxproj carries libsodium flags) |
| `11b156f` | Release TargetBridge 3.6.0 (#210) | merge-base, already in pwe-1.1 |

Note: `v3.6.0` tag (`76d3f99`) is not an ancestor on the same line as `11b156f`; the merge brings exactly the 6 commits above `11b156f`.

## Effort estimate

- Total: **M** overall, dominated by `display.c` (**L** on its own).
- `display.c` is the only real work: decide whether PWE's own status/pairing screen supersedes upstream's `status_layout.h` layout (then drop upstream's hunks there, keep the header for its test) or port upstream's centering/orientation fix into PWE's draw path.
- The other three files are mechanical unions (≈15 min together).
- After resolving: `make test` in `TBReceiverC` (upstream adds `test_status_layout`), xcodegen/xcodebuild the Sender, and check `Languages/*.json` key parity between zh and en.
