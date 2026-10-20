# PWE 对上游文件的改动

`main` 以 TargetBridge 的上游 `main`（3.6.0，`11b156f`）为基线。PWE 自己的文件在 `pwe/`、`docs/pwe/`、
`HANDOFF.md`、`.github/README.md`、`.github/SECURITY.md`，不在这张表里。

这张表只记**改了上游文件**的提交：改了什么、为什么、上游状态。

- 新增一条：先给上游提 PR，再把 PR 号写进这里。
- 上游合并后：在「状态」一栏写「已合并」和上游的提交号。下次合并上游时，冲突应当自动消失。
- 上游拒绝：写明原因，以及 PWE 是否继续保留。

| 提交 | 改了什么 | 为什么 | 上游 | 状态（2026-10-20） |
|---|---|---|---|---|
| `3ee1bff`（经 `2a5319b` 合并） | 简体中文：`zh.json` 和发送端 Swift 里的中文 | 夹杂英文、术语不统一、用词与 macOS 不一致 | [#212](https://github.com/swellweb/targetBridge/pull/212) | 已合并进上游 `maint-3.6`（`5c4ec84`），上游 3.6.1 未发布 |
| `081c7a5` | 接收端连接画面按字宽居中；新键 `receiver.splash.role`（五种语言） | 文字偏离中心，「RECEIVER」没有翻译 | [#214](https://github.com/swellweb/targetBridge/pull/214) | 已合并进上游 `maint-3.6`（`320be5d`），上游 3.6.1 未发布 |
| `3e9915f` | 接收端：详情画面方向修正；连接画面用 App 自己的图标、窗口标题用 App 名；`TB_RECEIVER_SNAPSHOT` 截图钩子；可选的安静等待画面（`COMPACT_IDLE`）和开机自启询问（`OFFER_LOGIN_ITEM`），默认都关 | 详情画面一直是上下颠倒的；PWE 1.1 要安静画面和开机自启 | 方向修正：[#215](https://github.com/swellweb/targetBridge/pull/215)；其余待提 | 方向修正已合并进上游 `maint-3.6`（`6ec97a3`），上游 3.6.1 未发布 |
| `e3788cf` | 发送端 `project.yml` 排除 `TargetBridge-Shared/scripts/`，重新生成工程 | 开发用的 `check_localizations.sh` 被打进了 App（2026-10-16 检查成品时发现） | [#216](https://github.com/swellweb/targetBridge/pull/216) | 已合并进上游 `maint-3.6`（`060450a`），上游 3.6.1 未发布 |
| `bd2ecac`、`83ec2fc` | 接收端 1.1 修正：开机自启只登记留在原处的副本（11/12 用 `open -b`，13+ 迁走旧 LaunchAgent）；详情画面按窗口缩放、开机自启单独一格；L/I/A 不响应按住重复和组合键；询问框在第一帧之后弹出 | 评审发现：从磁盘映像接受询问后开机不打开、13+ 可能开两个接收端、980×620 窗口里详情画面溢出 | 随 `3e9915f` 的其余部分待提 | 旗标关闭时只有一处不同：L 键不再响应按住重复和 Cmd/Ctrl/Option 组合 |
| `154dacb`（`pwe-1.1`） | 发送端走雷雳网桥时只拨广播里的 `tbIP`（3.0 以前的接收端：拨链路本地的 `ip`）；自动连接在发现窗口内等这个地址 | 接收端网桥还没有地址时，`ip` 是 Wi‑Fi 地址；从 bridge0 拨它必然超时。iMac18,3 拔插 6 次里 5 次各白等约 12.6 秒（`docs/pwe/BASELINE-iMac18,3.md`） | 已备好本地分支 `upstream/sender-bridge-address-only`（基于上游 `maint-3.6`），未推、未开 PR | 等 Lee 同意再提 |
| `6a7ac6f`（`pwe-1.1`） | 发送端 `TBSystemSleepGate`：`willSleep` 到 `didWake` 之间不重连、不调 `IOPMAssertionDeclareUserActivity` | 入睡时链路断开，重试循环 1–3 秒内重连并申明用户在用，把 Mac 叫醒：6 次睡眠里 3 次 | 已备好本地分支 `upstream/sender-no-wake-on-sleep`，未推、未开 PR | 等 Lee 同意再提 |
| `a7c5191`（`pwe-1.1`） | 发送端监视连接的 viability：没有路由满 2 秒就断开；雷雳网桥上 TCP 重传 5 秒无应答即断；连上之后的失败报 `connectionClosed` | 拔线后 18.3–18.6 秒才发现断开（TCP 重传超时）；系统日志显示拔线 0.18 秒后连接就变成 non-viable | 已备好本地分支 `upstream/sender-notice-unplug`，未推、未开 PR | 等 Lee 同意再提 |
| `162e86d`（`claude/bold-edison-fc242e`） | 接收端计时日志 `TB_RECEIVER_TRACE=1`：每帧到达、解码、纹理就绪、提交、上屏，每秒一行汇总；开着时记 `VTIsHardwareDecodeSupported` | Metal 方案先量基线；`videotoolbox_vld` 证明不了是硬件解码（`docs/pwe/RESEARCH-Metal-2026-10-19.md`） | 待提，等 iMac 实测后备分支 | 未合并进 `pwe-1.1` |
| `7c300b4`、`99db466`、`59746c5`（同上） | 接收端 Metal 零拷贝：VideoToolbox 的 IOSurface 经 `CVMetalTextureCache` 直接当纹理，自己的 BT.709 着色器；按显示刷新出帧，最新帧优先；任何一步失败回到 OpenGL；macOS 26 及以上默认仍是 OpenGL。解码器把 CVPixelBuffer 原样交给显示层；OpenGL 路径两帧之间的指针重画改为每 16 ms 至多一次；修 `decoder.c` 过时的头注释 | OpenGL 路径每帧经 CPU 读 22 MB 再上传，到帧就画、不等垂直同步；5K 48/60 下轻微卡顿（`BASELINE-iMac18,3.md`） | 待提，同上；顺带报告 SDL 2.32.10 Metal 渲染器把 BT.601 全范围矩阵当 BT.709 用 | 未合并；Metal 画面未上过真屏（测试机锁屏） |
| `c7abb3c`（同上） | 接收端自己画指针：接收端配置里 `cursorImage`；新包 `0x39` 带真实指针图像；`0x32` 加 `image`；发送端只对声明了的接收端关掉 `showsCursor`，位置由后台线程的事件 tap 发出（至多 240 Hz）；镜像模式按内容矩形换算（大光标路径也改了） | 指针只跟着视频帧动，约 40–70 ms 延迟（研究文档第 4 节） | 待提，收发两端一起 | 未合并；隐藏指针的判断（`CGCursorIsVisible`）未验证 |
| `2420e30`、`81850ee`（同上） | 回环冒烟测试加第 5–7 段：Metal + 本地指针、拷贝回退、OpenGL 回退；测试用的接收端不进 Bonjour、用 54399 端口（`TB_RECEIVER_NO_BONJOUR`、`TB_RECEIVER_TEST_PORT`，只供测试） | 回退路径要有测试；测试机上开着的发送端会抢走接收端唯一的连接 | 随上两条一起提 | 未合并 |
| `00a2d89`（同上） | 渲染、出帧节奏、本地指针三个开关在没有环境变量时读 `defaults`（`TBReceiverRenderDriver`、`TBReceiverPacing`、`TBReceiverCursorImage`） | iMac 上 Metal 出问题时，一行命令就能回到 OpenGL | 随 `7c300b4` 一起提 | 未合并 |
| `de4fe46`、`88f0172`（`claude/pwe-pairing-1.1`，已合入 `pwe-1.1`） | 接收端：`proto.h` 新增包类型 0x50–0x5F；`net.h` 声明 `tb_conn`（实现在新文件 `src/tb_conn.c`）；`Makefile` 加 libsodium 链接块和 `test_secure`、`test-loopback`、`bench-secure`；`.gitignore` 加测试产物。共用：新目录 `TargetBridge-Shared/secure/`（`pwe_secure`、`pwe_keystore`）。测试：`tests/test_secure.c`、`secure_receiver.c`、`secure_peer.c`、`secure_loopback.sh` | 1.1 配对与加密（Lee 2026-10-19 定方案）。`main.c` 的接入见下面 R2 两行 | upstream PR after disclosure：披露后再提，作为可选模块 | 本地提交，未推 |
| `a7bc2ea`、`1221e71`（`claude/pwe-pairing-1.1`，已合入 `pwe-1.1`） | 发送端：`TBDisplaySenderService.swift` 连接先握手、所有发送经 `PWESecureLink`、接收先解密；`TBDisplaySenderManager.swift` 语言推送改走加密会话；`TBDisplaySenderAutomation.swift` 等用户回答时不重连；`TBMonitorProtocol.swift` 新增包类型；新文件 `TBDisplayShared/PWESecureLink.swift`；桥接头引入 `pwe_secure.h`；`project.yml` 和工程文件加 libsodium | 同上 | upstream PR after disclosure | 本地提交，未推 |
| `9c46530`（`claude/pwe-pairing-r2`） | 接收端 `net.c`/`net.h`：`tb_net_client_is_direct_link()` 及其测试，逐字取自 `security-1.0.1` 的 `b2316e8`（不含该提交的接收策略 `DIRECT_LINK_ONLY`） | 配对只允许经线缆；合并 `security-1.0.1` 时这几处改动相同，应无冲突 | 随 1.0.1 的加固一起提 | 本地提交，未推 |
| `994386f`（`claude/pwe-pairing-r2`） | 接收端 R2：`main.c` 每个连接走 `tb_conn`（读、全部发送、关闭）、显示配置在就绪后发、钥匙串、配对码与提示、Bonjour 只在线缆网卡上发布并加 `pweSec=2`（偏好 `AllowLocalNetwork` 恢复原样）、静默 2 秒的旧发送端走不加密会话；`display.c/.h` 加 `tb_disp_set_notice`；新文件 `src/tb_pairing_menu.{h,m}`（应用菜单两项）；`tb_conn.c` 加 `tb_conn_tick`；`Makefile` 加 `TEST_HOOKS`；`Languages/*.json` 加 15 个键；`scripts/loopback_smoke.sh` 用测试钩子和临时钥匙串 | 同上 | upstream PR after disclosure | 本地提交，未推 |
| `af14af7`（`claude/pwe-pairing-r2`） | 发送端：`TBReceiverPointerSource` 经 `PWESecureLink` 发送；Debug 构建的生成帧测试流（`pweTestSyntheticFrames`） | 指针线程直写连接，会在加密会话里发出未封装的包 | upstream PR after disclosure | 本地提交，未推 |
| `32bc70f`、`8b50a60` | 接收端日志记下配对码的显示、隐藏、输错、过期（不记码本身）；发送端 `stop()` 清掉等码状态，码过期时通知 iMac | 真机：断线、锁定、过期后 Mac 停在输码框（2026-10-20） | 随配对一起提 | PWE 保留 |
| `7f423e7` | 发现：Network Link 只拨网络地址，从不拨雷雳或 USB 地址 | 真机：网络模式拨了雷雳地址，超时 | 待提 | PWE 保留 |
| `8900764` | 自动化：线插回或醒来后先拨上次的雷雳地址；重试间隔不再重启 Bonjour | 真机：插回到出画面 22–27 秒，其中约 20 秒在等 Bonjour | 待提 | 等真机复测 |
| `28057e1`、`edfe45e` | 声音转发在会话内开关；只在转发时采集系统声音 | 真机：切换声音时断开约 1 秒 | 待提 | 等真机复测 |
| `9800ea7` | 醒来之后才开始的采集，不再「醒来重启」 | 真机：出画面 3 秒后采集又重启一次 | 待提 | 等真机复测 |
| `b17e32e` | 接收端日志文件（`~/Library/Logs`，2 MB 轮转）；日志不写按键内容；去掉无限增长的 `input-debug.log` | 从「应用程序」打开时没有日志，没法排查 | 待提 | 等真机复测 |
| `404cf98` | hello 包加可选字段 `receiverRenderer`；接收端默认 OpenGL，可在第一帧前换渲染器 | Lee 2026-10-20 定：OpenGL 和 Metal 都留，让用户选 | 待提 | 等真机复测 |
| `9dd440f` | 计时加 `handoff` 阶段，两种渲染器同一口径 | 原来 OpenGL 和 Metal 的计时终点不同，对比不公平 | 待提 | — |
| `43bd8bf` | 转发的指针从真实位置出发；跨过两屏之间的空隙时保留仍在屏上的那一轴 | 真机：iMac 鼠标控制 Mac 时指针找不到、有些地方过不去 | 待提 | 等真机复测 |
| `3055222` | 删除 `.github/FUNDING.yml` | Lee 2026-10-14 定：本仓库不显示上游的赞助按钮 | 不提交（只属于 PWE） | 保留 |

打包时的改名（`pwe/rebrand.py`）不改仓库里的文件，所以不在这张表里。它的锚点由脚本自己检查：上游改了对应的文字，脚本就会停下。

另有一条上游 PR，不改本仓库文件：
[#213](https://github.com/swellweb/targetBridge/pull/213)，发送端第一次打开时跟随系统语言。PWE 现在是由 `rebrand.py` 在打包时做到这一点的。
它已于 2026-10-16 合并进上游 `maint-3.6`（`afa8c93`，2026-10-19 查）。把上游 3.6.1 合进 `main` 时，删掉 `rebrand.py` 里的 `LANGUAGE_FALLBACK`。
