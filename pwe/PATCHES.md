# PWE 对上游文件的改动

`main` 以 TargetBridge 的上游 `main`（3.6.0，`11b156f`）为基线。PWE 自己的文件在 `pwe/`、`docs/pwe/`、
`HANDOFF.md`、`.github/README.md`、`.github/SECURITY.md`，不在这张表里。

这张表只记**改了上游文件**的提交：改了什么、为什么、上游状态。

- 新增一条：先给上游提 PR，再把 PR 号写进这里。
- 上游合并后：在「状态」一栏写「已合并」和上游的提交号。下次合并上游时，冲突应当自动消失。
- 上游拒绝：写明原因，以及 PWE 是否继续保留。

| 提交 | 改了什么 | 为什么 | 上游 | 状态（2026-10-21） |
|---|---|---|---|---|
| `3ee1bff`（经 `2a5319b` 合并） | 简体中文：`zh.json` 和发送端 Swift 里的中文 | 夹杂英文、术语不统一、用词与 macOS 不一致 | [#212](https://github.com/swellweb/targetBridge/pull/212) | 已合并进上游 `maint-3.6`（`5c4ec84`），上游 3.6.1 未发布 |
| `081c7a5` | 接收端连接画面按字宽居中；新键 `receiver.splash.role`（五种语言） | 文字偏离中心，「RECEIVER」没有翻译 | [#214](https://github.com/swellweb/targetBridge/pull/214) | 已合并进上游 `maint-3.6`（`320be5d`），上游 3.6.1 未发布 |
| `b2316e8` | 接收端：音频环形缓冲独立成 `audio_ring.c` 并限定边界；可选的 `DIRECT_LINK_ONLY` 构建开关，只接受直连（雷雳网桥、USB、回环）的发送端，用户可用 `AllowLocalNetwork` 放开。并入 1.1 时（合并 `security-1.0.1`）改为 `net.c` 的 `tb_net_accept_policy()`：非直连的发送端在读任何字节前关闭；放开后只接受已配对 Mac 的加密会话，配对仍只走线缆；带测试 | 接收端加固（1.0.1） | 2026-10-15 私下发给维护者，等他选择接收方式 | 等回复 |
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
| `a8c14d4` | 接收端 PWE 画面：夜色底、翅膀（从包里的 PDF 画）、各状态共用一个锚点；系统字体和等宽数字；转圈和详情页换色；新提示类型 `TB_DISP_NOTICE_ERROR`；配对码只画数字 | 品牌规范 `docs/pwe/BRAND-iMac-Display-2026-10-20.md` R1–R5（2026-10-20） | 不提交（只属于 PWE 的外观） | 旗标关闭时只多一处：上游的连接卡片也按错误类型着色 |
| `9d7677d` | 发送端 `TBDisplaySenderService.swift`：`startCapture` 返回后，第一帧已经到了就不再把状态写回「等第一帧」（`pweCaptureDidStart`）；Debug 构建的测试钩子 `pweTestCaptureStart` | 真机 T33：出画面后菜单和主窗口一直停在「连接中 · 等待画面」，4 次换画面里 3 次。第一帧可能在 `startCapture` 等待期间到达，上游这一行会把 `captureActive` 覆盖掉。上游同样有这个问题 | [#222](https://github.com/swellweb/targetBridge/pull/222)（2026-10-21，基于 `maint-3.6`，只含状态这一行；测试钩子不提） | 等上游审；等真机复测 |
| `ffb220c`、`3c3424d` | 发送端：接收端发来的剪贴板只在「iMac 控制 Mac」且加密会话时接受（`pweTakesReceiverClipboard`） | 1.1 的输入模式约定 | upstream PR after disclosure | 本地提交，未推 |
| `b4fbc9e` | 发送端 `PWESecureLink.swift`（PWE 新文件，在上游目录里）：「忘记」返回结果、确认钥匙串条目已删、删掉指向它的全部提示 | 真机 T37：设置里的「忘记」没有效果 | upstream PR after disclosure | 本地提交，未推 |
| `044511b` | 接收端 `display.c`：建窗后关掉文字输入；快捷键按键盘上标的字母认，非拉丁布局按物理键；PWE 构建里 Esc 按两次才退出并提示，出画面时不响应；标题只写 App 名、变了才设。`main.c`：权限一行和配对提示改为从语言文件取、画的时候再取。`Languages/*.json`：新键 `receiver.ui.quit_confirm`、`receiver.permissions.*` | 真机 T36：中文输入法拦住 I 键，Esc 直接退出；T35：标题栏露出主机名和 IP | 关文字输入、Esc 忽略重复和组合键、权限文字进语言文件：待提；其余属于 PWE 构建 | 旗标关闭时：文字输入关、Esc 不响应重复和组合键、标题只在变化时设置 |
| （T37 第二处，`pwe-1.1`） | 共用 `TargetBridge-Shared/secure/pwe_keystore.c`：`SecItemDelete` 返回 `errSecInvalidOwnerEdit` 时改按引用删除（`SecKeychainItemDelete`）；新字段 `last_delete_status` 记删除那一步的状态，发送端日志用它 | 真机 RC2：别的构建（代码哈希不同）写的配对条目，`SecItemDelete` 删不掉，「忘记」失败；同一 Developer ID 的下一个版本同样删不掉（2026-10-21 在本机实测，-25244），所以正式用户升级后也会遇到 | 随配对一起提（upstream PR after disclosure） | 本地提交，未推 |
| `3055222` | 删除 `.github/FUNDING.yml` | Lee 2026-10-14 定：本仓库不显示上游的赞助按钮 | 不提交（只属于 PWE） | 保留 |
| `fcd83b5`、`a8e717a`（`pwe-1.1-t34`） | 接收端 `net.c`/`net.h`：新增只收 IPv6 的监听口 `tb_net_listen6`（IPv4 监听口不变）、`tb_net_get_tb_ip6`（雷雳网桥的 fe80 地址）；`tb_net_client_is_direct_link` 也判 IPv6 连接，规则在新的 `tb_net_is_direct_link_ipv6`：只有两端都是链路本地、且在系统网络设置认得的网桥上（或回环）才算直连，其余网卡走 IPv6 一律不算。`main.c`：两个监听口都接受；网桥一有 IPv6 地址就在网桥上发布 Bonjour，TXT 新键 `tbIP6`，IPv4 到来前不带 `ip`；只有 TXT 变时原地更新、不重新注册。测试：`test_net_parser.c` 加 IPv6 判定（接受与拒绝）和真套接字（`::1`、`fe80::1%lo0`、本机 Wi‑Fi/以太网地址）；`loopback_smoke.sh` 加第 1b 段；`a8e717a`：冒烟测试等接收端端口打开再开始（Rosetta 下首次启动超过 2 秒） | 真机 T34：「使用 DHCP」的雷雳网桥要等 DHCP 放弃才有 169.254 地址，插线后约 19.6 秒；接收端在此之前既不发布也没有可拨的地址。IPv6 链路本地地址一两秒内就有 | 待提，收发两端一起（上游也有同样的 20 秒） | 本地提交，未推；等真机复测 |
| `4bc5088`（`pwe-1.1-t34`） | 发送端：发现把 `tbIP6` 限定到本机的网桥（Bonjour 解析到它的那个网桥，或本机唯一有链路本地地址的网桥），只有这个地址的接收端也列出；`ip(for: .thunderboltBridge)` 依次取 `tbIP`、旧版链路本地 `ip`、限定后的 IPv6；Network Link 从不拨它；`connect()` 拨 IPv6 时不绑 IPv4 源地址、不要求本机网桥有 IPv4；自动化的本地网卡检查放行这种情况；会话查找和语言推送也认 IPv6 地址。新测试 `pwe/sender-tests/PWEBridgeIPv6Tests.swift` | 同上：插线后约 20 秒才出画面，门槛是 5 秒 | 随上一条一起提 | 本地提交，未推；等真机复测 |
| `5c33775`（`pwe-1.1-t34`） | 接收端 `net.c`/`net.h`：IPv4 的直连规则 `tb_net_is_direct_link` 只把系统网络设置认得的网桥算作线缆，与 IPv6 规则同一个判断（共用 `net.c` 里的辅助函数）；回环、USB、`en*` 不变。`main.c` 启动时记一行 `[net] cable bridges: …`。测试加网桥的接受与拒绝 | 两种地址族用同一条线缆规则；真机测试时一眼能看出雷雳网桥有没有被认出 | 随 1.0.1 的加固一起提 | 本地提交，未推；可单独回退 |
| `46a1c9b`（`pwe-1.1-t34`） | 接收端评审修正：广播的地址变了就重新注册（会话中原地更新 TXT，会话结束后再注册）；IPv6 监听口起来后才带 `tbIP6`，两个监听口都起来后才首次发布；每轮两个监听口都 accept、轮流先后；IPv6 连接只接受线缆和回环（`tb_net_accept_policy_family`）；可当线缆的网桥列表缓存 15 秒；非 Apple 系统没有线缆网桥；`tb_net_get_tb_ip` 只取雷雳网桥；日志：启动时列出线缆网桥及成员、网桥 IPv6 地址出现和消失、每次 Bonjour 注册或原地更新。测试同步补上 | 独立评审 2026-10-21 | 随 `fcd83b5` 一起提 | 本地提交，未推；等真机复测 |
| `cac6fcb`（`pwe-1.1-t34`） | 发送端评审修正：发现监视 TXT 更新（`startMonitoring`）；`tbIP6` 只在系统设置认得的网桥上用（Bonjour 在那里解析到，或尚未解析时本机唯一的线缆网桥）；「连接」按钮与 `connect()` 同一条件（`pweHasDialAddresses`）；PWE 窗口的插线判断以网桥 IPv6 地址为准，之后到来的 IPv4 不算第二次插线 | 同上 | 随 `4bc5088` 一起提 | 本地提交，未推；等真机复测 |
| `89bf80e`、`efdfba1`（`pwe-1.1-t40`） | 接收端主循环看门狗：新文件 `src/tb_loopwatch.{h,c}`，后台线程每 200 ms 看一次，一轮超过 2 秒就记 `[watchdog] main loop stuck … in <阶段>` 和主线程调用栈，之后每 10 秒一行，恢复时再记一行。`main.c`、`decoder.c`、`display.c`、`tb_metal_video.m` 在可能阻塞的调用前写下阶段名（`TB_LOOP_PHASE`）；测试构建可按请求停住主循环（`TEST_DATA` 包 `stall <ms>`，只在 `TEST_HOOKS=1`）。`Makefile` 加源文件和 `test_loopwatch` | 真机 T40：换画面时主循环停了 46–47 秒，日志一行没有，原因无从查起 | 待提（与上游无关的诊断，也适用于上游） | 本地提交，未推；等真机复测 |
| `692c9ee`（`pwe-1.1-t40`） | 接收端声音输出移出主循环：新文件 `src/audio_out.{h,c}`，工作线程负责打开、关闭 SDL 输出设备和设系统音量；主循环只在自己的锁下把 PCM 拷进环形缓冲，不再取 SDL 的设备锁。设备在会话第一个声音包时打开，会话结束 5 秒后才关，换画面时保持打开。`main.c` 去掉 `audio_callback`、`tb_audio_open_for_frame`、`tb_audio_close_for_idle`、`tb_set_system_volume`。`mock_sender.py` 加 `--audio`、`stall`、`cycles`；`Makefile` 加 `test_audio_out`（SDL dummy 驱动） | T40 两次停住时声音都在 iMac。SDL 2.32.10 的 CoreAudio 回调在交还缓冲（`AudioQueueEnqueueBuffer`）时持有设备锁，主循环每个声音包都要取这把锁；打开、关闭设备也在主循环上（本机实测打开 24–452 ms、关闭约 90 ms）。是否就是 T40 的原因未证实 | 待提 | 本地提交，未推；等真机复测 |
| `2b31425`（`pwe-1.1-t40`） | `loopback_smoke.sh` 加第 3b 段（看门狗报出停住的阶段、调用栈和恢复）和第 8b 段（带声音的 Metal 会话连换 6 次，每次 5 秒内接上、声音设备只开一次、没有主循环停顿） | T40 的回归测试 | 随上两条一起提 | 本地提交，未推 |
| （T39，`pwe-1.1-tx5`） | 发送端 `TBDisplaySenderService.swift`：心跳不再用主循环的 `Timer`，改由 `PWEHeartbeat`（加在 PWE 新文件 `TBDisplayShared/PWESecureLink.swift` 里）在自己的队列上经 `PWESecureLink` 发出；开始、停止的位置不变 | 真机 RC2 T39（2026-10-21）：发送端 10 秒一个包都没发，iMac 判定会话失效并断开。主循环的 `Timer` 在主线程卡住、或主循环不在默认模式（菜单打开、模态面板、拖动改尺寸）时都不触发 | 待提（上游有同样的问题） | 本地提交，未推；等真机复测 |
| （`pwe-1.1-wake`） | 发送端 `TBDisplaySenderAutomation.swift`：本文件的 `NSLog` 由文件内同名函数接管，写进统一日志（`com.targetbridge.sender`，类别 `automation`，notice 级，公开） | 发布版里 `NSLog` 只到 stderr（T38），睡眠唤醒、拔插时重连循环的每一步在测试机上都没有记录（RC4 Q3） | 待提 | 本地提交，未推 |
| （`pwe-1.1-wake`） | 发送端 `TBBridgeRedial`：记住的网桥地址也可以是接收端的 IPv6 链路本地地址（不带 scope）；唤醒或链路起来后，在本机唯一一个系统设置认得的网桥上重拨 `fe80::…%bridgeN`（与发现 `tbIP6` 同一条规则）；也监视网桥 IPv6 地址的出现。仍只在本机会话已断开、不在睡眠、Bonjour 未列出时拨，每秒一次、窗口 10 秒 | RC4 Q3：真睡眠后亮屏 2.8 秒才拨号，等的是 Bonjour 重新列出 iMac；出画面 4.9 秒，门槛 5 秒 | 随 `4bc5088` 一起提 | 本地提交，未推；等真机复测，不过就退回 1.1.1 |

打包时的改名（`pwe/rebrand.py`）不改仓库里的文件，所以不在这张表里。它的锚点由脚本自己检查：上游改了对应的文字，脚本就会停下。

另有一条上游 PR，不改本仓库文件：
[#213](https://github.com/swellweb/targetBridge/pull/213)，发送端第一次打开时跟随系统语言。PWE 现在是由 `rebrand.py` 在打包时做到这一点的。
它已于 2026-10-16 合并进上游 `maint-3.6`（`afa8c93`，2026-10-19 查）。把上游 3.6.1 合进 `main` 时，删掉 `rebrand.py` 里的 `LANGUAGE_FALLBACK`。
