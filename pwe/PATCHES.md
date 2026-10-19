# PWE 对上游文件的改动

`main` 以 TargetBridge 的上游 `main`（3.6.0，`11b156f`）为基线。PWE 自己的文件在 `pwe/`、`docs/pwe/`、
`HANDOFF.md`、`.github/README.md`、`.github/SECURITY.md`，不在这张表里。

这张表只记**改了上游文件**的提交：改了什么、为什么、上游状态。

- 新增一条：先给上游提 PR，再把 PR 号写进这里。
- 上游合并后：在「状态」一栏写「已合并」和上游的提交号。下次合并上游时，冲突应当自动消失。
- 上游拒绝：写明原因，以及 PWE 是否继续保留。

| 提交 | 改了什么 | 为什么 | 上游 | 状态（2026-10-19） |
|---|---|---|---|---|
| `3ee1bff`（经 `2a5319b` 合并） | 简体中文：`zh.json` 和发送端 Swift 里的中文 | 夹杂英文、术语不统一、用词与 macOS 不一致 | [#212](https://github.com/swellweb/targetBridge/pull/212) | 已合并进上游 `maint-3.6`（`5c4ec84`），上游 3.6.1 未发布 |
| `081c7a5` | 接收端连接画面按字宽居中；新键 `receiver.splash.role`（五种语言） | 文字偏离中心，「RECEIVER」没有翻译 | [#214](https://github.com/swellweb/targetBridge/pull/214) | 已合并进上游 `maint-3.6`（`320be5d`），上游 3.6.1 未发布 |
| `3e9915f` | 接收端：详情画面方向修正；连接画面用 App 自己的图标、窗口标题用 App 名；`TB_RECEIVER_SNAPSHOT` 截图钩子；可选的安静等待画面（`COMPACT_IDLE`）和开机自启询问（`OFFER_LOGIN_ITEM`），默认都关 | 详情画面一直是上下颠倒的；PWE 1.1 要安静画面和开机自启 | 方向修正：[#215](https://github.com/swellweb/targetBridge/pull/215)；其余待提 | 方向修正已合并进上游 `maint-3.6`（`6ec97a3`），上游 3.6.1 未发布 |
| `e3788cf` | 发送端 `project.yml` 排除 `TargetBridge-Shared/scripts/`，重新生成工程 | 开发用的 `check_localizations.sh` 被打进了 App（2026-10-16 检查成品时发现） | [#216](https://github.com/swellweb/targetBridge/pull/216) | 已合并进上游 `maint-3.6`（`060450a`），上游 3.6.1 未发布 |
| `bd2ecac`、`83ec2fc` | 接收端 1.1 修正：开机自启只登记留在原处的副本（11/12 用 `open -b`，13+ 迁走旧 LaunchAgent）；详情画面按窗口缩放、开机自启单独一格；L/I/A 不响应按住重复和组合键；询问框在第一帧之后弹出 | 评审发现：从磁盘映像接受询问后开机不打开、13+ 可能开两个接收端、980×620 窗口里详情画面溢出 | 随 `3e9915f` 的其余部分待提 | 旗标关闭时只有一处不同：L 键不再响应按住重复和 Cmd/Ctrl/Option 组合 |
| `154dacb`（`pwe-1.1`） | 发送端走雷雳网桥时只拨广播里的 `tbIP`（3.0 以前的接收端：拨链路本地的 `ip`）；自动连接在发现窗口内等这个地址 | 接收端网桥还没有地址时，`ip` 是 Wi‑Fi 地址；从 bridge0 拨它必然超时。iMac18,3 拔插 6 次里 5 次各白等约 12.6 秒（`docs/pwe/BASELINE-iMac18,3.md`） | 已备好本地分支 `upstream/sender-bridge-address-only`（基于上游 `maint-3.6`），未推、未开 PR | 等 Lee 同意再提 |
| `6a7ac6f`（`pwe-1.1`） | 发送端 `TBSystemSleepGate`：`willSleep` 到 `didWake` 之间不重连、不调 `IOPMAssertionDeclareUserActivity` | 入睡时链路断开，重试循环 1–3 秒内重连并申明用户在用，把 Mac 叫醒：6 次睡眠里 3 次 | 已备好本地分支 `upstream/sender-no-wake-on-sleep`，未推、未开 PR | 等 Lee 同意再提 |
| `a7c5191`（`pwe-1.1`） | 发送端监视连接的 viability：没有路由满 2 秒就断开；雷雳网桥上 TCP 重传 5 秒无应答即断；连上之后的失败报 `connectionClosed` | 拔线后 18.3–18.6 秒才发现断开（TCP 重传超时）；系统日志显示拔线 0.18 秒后连接就变成 non-viable | 已备好本地分支 `upstream/sender-notice-unplug`，未推、未开 PR | 等 Lee 同意再提 |
| `46d303d`、`70f7119`（`claude/pwe-pairing-1.1`） | 接收端：`proto.h` 新增包类型 0x50–0x5F；`net.h` 声明 `tb_conn`（实现在新文件 `src/tb_conn.c`）；`Makefile` 加 libsodium 链接块和 `test_secure`、`test-loopback`、`bench-secure`；`.gitignore` 加测试产物。共用：新目录 `TargetBridge-Shared/secure/`（`pwe_secure`、`pwe_keystore`）。测试：`tests/test_secure.c`、`secure_receiver.c`、`secure_peer.c`、`secure_loopback.sh` | 1.1 配对与加密（Lee 2026-10-19 定方案）。`main.c` 尚未接入（R2，等 Metal 线合入） | upstream PR after disclosure：披露后再提，作为可选模块 | 本地提交，未推 |
| `7fdeeea`（`claude/pwe-pairing-1.1`） | 发送端：`TBDisplaySenderService.swift` 连接先握手、所有发送经 `PWESecureLink`、接收先解密；`TBDisplaySenderManager.swift` 语言推送改走加密会话；`TBDisplaySenderAutomation.swift` 等用户回答时不重连；`TBMonitorProtocol.swift` 新增包类型；新文件 `TBDisplayShared/PWESecureLink.swift`；桥接头引入 `pwe_secure.h`；`project.yml` 和工程文件加 libsodium | 同上 | upstream PR after disclosure | 本地提交，未推 |
| `3055222` | 删除 `.github/FUNDING.yml` | Lee 2026-10-14 定：本仓库不显示上游的赞助按钮 | 不提交（只属于 PWE） | 保留 |

打包时的改名（`pwe/rebrand.py`）不改仓库里的文件，所以不在这张表里。它的锚点由脚本自己检查：上游改了对应的文字，脚本就会停下。

另有一条上游 PR，不改本仓库文件：
[#213](https://github.com/swellweb/targetBridge/pull/213)，发送端第一次打开时跟随系统语言。PWE 现在是由 `rebrand.py` 在打包时做到这一点的。
它已于 2026-10-16 合并进上游 `maint-3.6`（`afa8c93`，2026-10-19 查）。把上游 3.6.1 合进 `main` 时，删掉 `rebrand.py` 里的 `LANGUAGE_FALLBACK`。
