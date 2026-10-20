# 真机基线：iMac18,3（2017 款 27 寸 5K）

> 2026-10-19 开始，按 `PLAN-2026-10-15.md` 第三节。未完成的项目标「未测」，并写明谁来做。

## 设备

| | 发送端 | 接收端 |
|---|---|---|
| 机器 | MacBook Pro 13 寸 M1（MacBookPro17,1） | iMac18,3，主机名 `LL-iMac-2017`；Core i5-7500 4 核 3.4 GHz，Radeon Pro 570 4 GB，8 GB 内存 |
| 系统 | macOS 27.2（26B5112a） | macOS 13.7.8（Lee 告诉，2026-10-19） |
| App | PWE iMac Display 1.1.0（构建 20261016160116，本机构建，未公证） | PWE iMac Display Receiver 1.1.0（同一个 DMG） |
| 线 | 雷雳 3，40 Gb/s 链路（`system_profiler SPThunderboltDataType` 实测） | 雷雳 3 接口，不需要转换器 |
| 供电 | 接电源 | — |

## 结果（2026-10-19 实测）

| 场景 | 结果 | 证据 |
|---|---|---|
| 安装与首次连接 | 通过。不用终端命令，不绕过安全机制。接收端用文件共享拷到 iMac | 发送端自动发现 iMac；点「Use as Display」后几秒出画面；Lee 拍照确认 iMac 显示扩展桌面 |
| 发现 | 接收端同时出现在雷雳网桥和 Wi‑Fi（en0）上 | `dns-sd -B _targetbridge._tcp` 两条记录，接口 12（bridge0）和 11（en0） |
| 线缆测试 | 10.82 Gbit/s | 发送端「Run Cable Test」 |
| 默认码流 | Standard 2560×1440，HEVC。iMac 收到的是 1440p 画面再放大，**不是 5K** | Advanced 窗口「Extended Desktop active (2560 × 1440, HEVC)」 |
| 真 5K | 可用。「Work 5K」= 5120×2880 @ 48，HEVC，渲染和码流一比一 | 发送端显示「5120 × 2880 @ 48, HEVC」；系统里这块屏 5120×2880，按 2560×1440 HiDPI，48 Hz |
| 5K 码流 | 画面基本静止时 39–71 Mbit/s；发送端 CPU 7–9% | `netstat -ibn -I bridge0` 两次采样 |
| 只用 iMac（不合盖） | 通过。iMac 设为主显示器，内建屏用 Lumen Bar 熄掉，5K 码流不断；90 秒后内建屏自动亮回 | `pwelumenctl main 5`、`off 1`、`on 1`；`system_profiler` 只剩 iMac 一块屏 |
| 登录时打开 | Lee 在主窗口里打开；系统登记为启用（`sfltool dumpbtm`：`enabled, allowed, notified`），并弹出「Login Item Added」。重启后是否自动连上，未测 | 2026-10-19 16:17 实查 |
| 合盖只用 iMac | 通过（Lee 实测：合盖、单屏，效果不错） | Lee 口述，2026-10-19；`pmset` 记录 16:04:33 开盖 |
| 5K 48 下的流畅度 | 基本流畅，轻微卡顿，鼠标滑动轻微不流畅（Lee 目测） | Lee 口述；没量化，接收端解码路径和 CPU 仍未测 |
| 退出后重连 | 能连上，但要「Refresh IP」、拔线再插，连接时间略长（Lee 实测） | 见下面「退出后重连」 |
| 声音 | 失败。声音只从 MacBook 出，iMac 没有（Lee 实测）。设置里「Audio Relay」显示 Enabled，但标红「Incompatible」 | 发送端设置窗口；原因见「附加功能不兼容」 |
| 声音（修复后） | 通过。装上带修复的 ad hoc 包（构建 20261019161520，pwe-1.1 436247f）后，iMac 出声。但 MacBook 和 iMac 同时响，iMac 稍慢一点（Lee 实测，16:40） | 5 次 `afplay Glass.aiff`；发送端设置里三个附加功能不再标「Incompatible」 |
| 5K 60 | 可用。`preset=5k60` = 5120×2880 @ 60，HEVC；系统里这块屏 60 Hz。Lee 感觉得出 48 和 60 的差别；60 下鼠标和拖窗口明显比 48 流畅（Lee 目测） | 16:08:59 日志 `pipeline started preset=native5k60Experimental`；发送端遥测 47 帧/秒 |
| 5K 60 下 MacBook 的负载 | 发送端 CPU 7–14%，WindowServer 44–56%，GPU 42–51%，码流 138–302 Mbit/s；负载不满 | 5 次采样，每次 2 秒（`ps`、`ioreg` 的 Device Utilization %、`netstat`） |
| 全屏视频 | 顶部有菜单栏，左右各一条灰边（Lee 两张照片：Elmedia Player 和 Chrome 全屏）。不是本 App 的问题 | 照片里顶部是发送端 App 的菜单（「Elmedia Player 文件 编辑…」「Chrome File Edit…」），不是接收端的。这台 Mac 设了全屏也显示菜单栏：`AppleMenuBarVisibleInFullscreen = 1`，`AutoHideMenuBarOption = 3`。菜单栏占掉高度，16:9 视频按剩余高度缩放，左右留边。改设置后的效果未测 |
| 解码路径、接收端 CPU | 通过。硬件解码（VideoToolbox），OpenGL 渲染，5120×2880 NV12 纹理。播视频时接收端 CPU 平均 19.3%（最高 26.7%，按单核 100% 计），整机平均空闲 85%（最低 67.5%）。帧率中位 25（片源 24 帧），最高 56，没有错误日志。这次跑的是 5K 48（重连后回落），5K 60 下的数据未测 | 16:45:33–16:47 iMac 上运行检查脚本；`[dec] HW decode pix_fmt=videotoolbox_vld`；`top` 89 次采样；接收端每秒帧数 266 条 |
| 打字与拖窗口延迟（240 fps） | 未测。等 Lee | — |
| 两小时办公 | 未测。等 Lee | — |
| 拔线重连（做了 6 次，Lee 定 5 次左右够用） | 6 次全部自动恢复，不用碰发送端。插回到出画面 22.6–35.8 秒；6 次里 5 次先拨 Wi‑Fi 地址白等约 12.6 秒；回来都是 5K 48 | 见「拔线重连记录」 |
| 睡眠唤醒（Lee 做了 5 轮，记录里有 6 次入睡） | 画面每次都自动回来，屏幕亮后 1.2–2.8 秒出画面，都拨对雷雳地址。**但 Mac 没睡着**：每次入睡后 0.6–3.7 秒屏幕就亮回来，pmset 只记了一次真正的睡眠。3 次是本 App 叫醒的，3 次是按键。窗口位置、按键、排列都正常（Lee 实测）。回来都是 5K 48 | 见「睡眠唤醒记录」 |
| 停止与退出 | 通过。「Stop」和退出 App 后，虚拟屏从系统消失，PWE 的防睡眠断言全部释放，连接关闭 | 16:10–16:11 实测：`system_profiler` 只剩内建屏；`pmset -g assertions` 没有 PWE；`netstat` 只剩 TIME_WAIT |
| 退出后重开发送端 | 通过。自动连上，从拨号到第一帧约 1.2 秒（接收端一直开着）。但回到 5K 48，不是 60 | 16:11:56 拨号，16:11:57.548 第一帧 |
| 1.0.1 包过真线 | 未测 | — |

## 发现的问题

1. **默认不是 5K。** 1.1 首次连接用 Standard 1440p。产品承诺是 5K，默认档位要等解码数据再定（计划第三节）。
2. **显示器名字是「TB Extend - iMac」。** 用户在「系统设置 › 显示器」里看到的是上游名字，`rebrand.py` 没覆盖。
3. **连接时闪过「The iMac is no longer connected」。** 点「Use as Display」后，旧状态的淡出和「正在连接」叠在一起。
4. **1.1 的接收端在 Wi‑Fi 上也能被发现。** 符合预期：1.1 还没合入 1.0.1 的 `DIRECT_LINK_ONLY`。
5. **会话设置在连接中全部变灰。** 要先「Stop」才能换档位；1.1 主窗口没有换档位的入口。
6. **发送端首次启动后自动重开过一次**（15:48:58），没有崩溃报告。推测是录屏授权后的重开，未核实。
7. **退出后重连要刷新 IP、重插线。** 原因见「退出后重连」一节。只退出发送端不会出现（16:11 实测自动重连），问题出在接收端重开或雷雳网桥断过之后。
8. **声音不走 iMac：三个附加功能全被判成「不兼容」。** 见「附加功能不兼容」一节。1.0.0 正式版和 1.0.1 包里的清单也是这样（实查）。
9. **5K 60 不会被记住。** 用命令切的 60 帧，重开后变回「Work 5K」的 48 帧；界面上也没有 5K 60 的入口。
10. **连着 iMac 时 Mac 睡不着。** 6 次里 3 次是本 App 叫醒的（`pmset` 证据），另 3 次是按键。 入睡后 App 立即重连，重连时调用 `IOPMAssertionDeclareUserActivity` 申明「用户在用」，把 Mac 叫醒。见「睡眠唤醒记录」。
11. **声音两边同时响，iMac 稍慢。** 音频转发只是复制系统声音，不切换 Mac 的输出，所以 MacBook 扬声器照响。要么转发时把 Mac 本机静音，要么做成一个开关。

## 只用 iMac 一块屏：做法

- 不合盖：把 iMac 设成主显示器，再用 PWE Lumen Bar 熄掉内建屏（菜单里「熄屏」，或 `⌃⌥P`）。已实测可用。
- 合盖：可用（Lee 实测，2026-10-19：合盖、单屏，效果不错）。要接电源，还要有能操作 MacBook 的键盘鼠标，因为 iMac 的键盘配对在 iMac 上。

## 退出后重连（2026-10-19 分析）

结论：接收端在雷雳网桥没有地址的那段时间，把 Wi‑Fi 地址写进广播的 `ip` 字段；
发送端照这个字段从雷雳网桥去拨 Wi‑Fi 地址，必然超时；重试停下后，1.1 要等拔插线才再连。

证据：
- 发送端日志 16:03:43：`connect: dialing 10.0.0.183:54321 from 169.254.78.140 (bridge0) transport=thunderboltBridge`，
  5 秒后 `timed out`。10.0.0.183 是 iMac 的 Wi‑Fi 地址。16:03:56 改拨 `169.254.45.128%bridge0` 后，10 毫秒连上。
- 接收端 `main.c:2028` 和 `main.c:2097`：`ip` 取雷雳地址，没有就取局域网地址。广播会随地址变化更新。
- 发送端 `TBReceiverDiscovery.swift:197`：`preferredIP` 先取广播的 `ip` 字段，不看当前走的是哪种连接。
- 1.1 `PWESenderModel.refresh()`：引擎停止重试后设 `pausedUntilReplug`，只有 iMac 从列表消失再出现才恢复，所以要拔插线。

未核实：
- Lee 退出的是哪一个 App。发送端进程从 15:48:58 起没换过，所以退出的应是 iMac 上的接收端，或只是关了窗口。
- 16:02:27 发送端的 bridge0 报 `Network is down`，推测是那时拔了线或合了盖。

修法（候选，都没做）：
1. 发送端：走雷雳网桥时只拨广播里的 `tbIP`；没有 `tbIP` 就等，不拨 Wi‑Fi 地址。改的是上游文件，先提 PR。
2. 1.1：引擎停止重试后，广播里的 `tbIP` 重新出现或变化，也算「插回来了」，自动再连。
3. 1.0.1 的 `DIRECT_LINK_ONLY` 合进 1.1 之后，重测这一项。

## 附加功能不兼容（2026-10-19 分析）

结论：PWE 打包把发送端版本改成 1.1.0，而三个附加功能的清单要求发送端至少 3.0（上游的版本号）。
所以音频转发、键鼠共享、Network Link 在 PWE 的包里全部失效，界面上只有一个红色的「Incompatible」。

证据：
- 发送端设置窗口：Audio Relay、Input Dockstation、Network Link 三项都标「Incompatible」。
- `Resources/audio-relay.json`：`"minimumSenderVersion": "3.0"`。
- `TBAddonStore.swift:64`：能力生效要同时满足「已启用、有这项能力、兼容」。
- `TBAddonStore.swift:74`：兼容 = `marketingVersion` 不低于 `minimumSenderVersion`。
- `rebrand.py` 把 `marketingVersion` 改成 PWE 的版本号，`rebrand_addons()` 没动 `minimumSenderVersion`。

1.0.0 正式版和 1.0.1 本地包也一样：版本 1.0.0 / 1.0.1，三份清单都写 `"minimumSenderVersion": "3.0"`（2026-10-19 挂载 DMG 实查）。没在那两个版本上实际运行过。

修法（候选，没做）：`rebrand_addons()` 删掉内置清单的 `minimumSenderVersion`（内置附加功能和引擎同版）；
`check-bundle.py` 加一条：内置附加功能必须全部兼容。

临时验证没做成：往用户附加功能文件夹写一份不带版本下限的音频清单，这一步被本机的权限规则拦下，等 Lee 决定。

## 拔线重连记录

后台用 `log stream` 记录发送端连接事件、雷雳插拔和电源事件（2026-10-19）。时间取自这份记录。

| 次 | 插回 | iMac 链路就绪 | 第一次拨号 | 拨的地址 | 出画面 | 插回到出画面 |
|---|---|---|---|---|---|---|
| 1 | 16:14:17.14 | 16:14:18.65 | 16:14:38.13 | Wi‑Fi 10.0.0.183，超时 | 16:14:51.90 | 34.8 秒 |
| 2 | 16:19:47.04 | 16:19:48.55 | 16:20:08.72 | Wi‑Fi，超时 | 16:20:22.51 | 35.5 秒 |
| 3 | 16:20:28.40 | 16:20:29.91 | 16:20:49.97 | Wi‑Fi，超时 | 16:21:03.76 | 35.4 秒 |
| 4 | 16:21:09.75 | 16:21:11.27 | 16:21:31.15 | 雷雳 169.254.45.128 | 16:21:32.36 | 22.6 秒 |
| 5 | 16:21:37.48 | 16:21:39.00 | 16:21:59.54 | Wi‑Fi，超时 | 16:22:13.24 | 35.8 秒 |
| 6 | 16:22:18.83 | 16:22:20.35 | 16:22:39.66 | Wi‑Fi，超时 | 16:22:53.30 | 34.5 秒 |

结论：
- 可靠：6 次全部自动恢复，没有一次要刷新 IP 或手动连接。
- 慢：雷雳链路在插回后 1.5 秒就绪，画面却要 22.6–35.8 秒才回来。时间花在两处：
  - 链路就绪后，约 20 秒才开始第一次拨号（发现断开慢、加上重试间隔）。第 1、2 次测得拔线后 18.3–18.6 秒才发现断开。
  - 6 次里 5 次先拨 iMac 的 Wi‑Fi 地址，5 秒超时，再等约 7.5 秒才拨雷雳地址，每次白等约 12.6 秒。原因同「退出后重连」。
- 拨对地址后，连上到出画面只要约 1.2 秒。所以两处修好后，插回到出画面可能降到几秒。这是推算，未测。
- 每次回来都是 5K 48（`preset=native5k`），不是断开前的 5K 60。
- 6 次的数据很一致，再多做几次不会改变结论。

## 睡眠唤醒记录

Lee 用苹果菜单「睡眠」做了 5 轮，每轮间隔约 10 秒（2026-10-19）。时间取自后台事件记录。

| 次 | 开始入睡 | 屏幕熄 | 屏幕亮 | 亮屏前后的事 | 出画面 | 亮屏到出画面 |
|---|---|---|---|---|---|---|
| 1 | 16:24:43.93 | 16:24:44.19 | 16:24:46.91 | 16:24:46.64 App 先重连，0.27 秒后亮屏 | 16:24:48.29 | 1.4 秒 |
| 2 | 16:24:54.18 | 16:24:54.29 | 16:24:57.27 | 16:24:56.95 App 先重连，0.32 秒后亮屏 | 16:24:58.98 | 1.7 秒 |
| 3 | 16:25:02.49 | 16:25:02.56 | 16:25:03.82 | 按键唤醒：WindowServer 记 HID 输入（AppleMesa，Touch ID 键），唤醒原因「HID Activity」 | 16:25:06.62 | 2.8 秒 |
| 4 | 16:25:11.26 | 16:25:11.42 | 16:25:12.01 | 按键唤醒：WindowServer 记 HID 输入（AppleMesa） | 16:25:14.67 | 2.7 秒 |
| 5 | 16:25:19.50 | 16:25:19.59 | 16:25:20.56 | 按键唤醒：WindowServer 记 HID 输入（AppleMesa） | 16:25:23.27 | 2.7 秒 |
| 6 | 16:25:33.10 | 16:25:33.28 | 16:25:36.75 | 16:25:36.43 App 先重连，0.32 秒后亮屏 | 16:25:37.92 | 1.2 秒 |

结论：
- 画面恢复快：屏幕亮后 1.2–2.8 秒出画面，6 次都拨对雷雳地址。睡眠不触发 Wi‑Fi 地址的 bug，因为雷雳链路没断。
- Mac 没有真正睡着：入睡后 0.6–3.7 秒屏幕就亮回来。`pmset -g log` 这段时间只有一条 Sleep（16:25:02，1 秒）。
- 第 1、2、6 次的顺序都是「App 重连 → 0.3 秒后亮屏」。App 重连时会调 `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)`
  （`TBDisplaySenderService.swift:3037`，日志「capture: requested graphical-session wake」），这会把屏幕叫醒。
  `pmset -g log` 里这三次亮屏前唯一的 UserIsActive 来自「PWE iMac Display capture requested」。
  推测：入睡时 App 断开，重试循环在系统睡着前又连上，并申明用户在用，于是睡眠被打断。
- 第 3、4、5 次是按键唤醒，不是 App。
- 不是屏幕共享：测试后没有 `screensharingd`、`ARDAgent` 进程，5900、3283 端口没有连接（16:27 实查）。
- 每次回来都是 5K 48，不是入睡前的 5K 60。
- 每次出画面后 3–8 秒，采集管线又重启一次（「Auto-restart capture after wake / unlock」）。对画面的影响未测。

- 睡眠后窗口位置不变，没有按键卡住，iMac 在显示器排列里的位置不变（Lee 实测，2026-10-19）。

未测：Mac 真正睡着（比如断开 iMac 后再睡）时的唤醒恢复。

## iMac 端检查（2026-10-19）

检查脚本放在 iMac 桌面的「PWE iMac 检查」文件夹（经文件共享拷过去）：重启接收端并保存它的输出，再用 `top` 采样 90 秒。结果在同一文件夹的 `pwe-check-20261019-164526/`。

- 解码：`[dec] HW decode pix_fmt=videotoolbox_vld device=videotoolbox`，`[disp] renderer = opengl`，`[disp] texture 5120x2880 NV12`。
- 声音：`SDL audio device opened on first audio frame: 48000Hz stereo 16-bit PCM`。
- 重启接收端后，发送端 4 秒内重连（前两次连接被重置，第三次成功）。
- 结论：iMac18,3 解 5K HEVC 有余量，Lee 看到的轻微卡顿不像是解码跟不上。原因未查明；候选是 48 Hz 本身、OpenGL 上传 5K 纹理、或画面变化时的码率尖峰。
- 第一次运行失败：接收端放在 iMac 桌面上，不在「应用程序」里，脚本找不到。已改成自动查找。
- 脚本的小毛病：最后的 `wait` 也在等接收端，所以终端不会显示「Finished」。数据不受影响。

## 1.0.1 真线测试（2026-10-20）

包：`pwe/dist/local/PWE-iMac-Display-1.0.1.dmg`（另一台 Mac 2026-10-20 打，Developer ID，未公证），两个 App 构建号都是 `20261020120408`，sha256 `f7e164c4…`，内置附加功能清单里已没有 `minimumSenderVersion`。
接收端经文件共享拷到 iMac，Lee 放进「应用程序」。iMac 广播里 `version=1.0.1`。
插拔后雷雳网桥换了地址：MacBook `169.254.171.182`，iMac `169.254.6.224`。

| 步 | 结果 | 证据 |
|---|---|---|
| 1 装接收端 | 通过 | iMac 广播 `version=1.0.1`；`tbIP=169.254.6.224` |
| 2 真线连接 | 通过（权限修好之后）。12:48:34 拨号，12:48:35.600 第一帧，5K 48，HEVC | `connect: ready — 169.254.6.224 via bridge0`；系统里出现 5120×2880 的虚拟屏 |
| 3a 声音 | 通过。iMac 出声（Lee 实测）。三个附加功能都没有「Incompatible」 | 5 次 `afplay Glass.aiff`；发送端设置窗口 |
| 3b 键鼠共享 | 通过（权限修好之后）。会话设成「Receiver is Master」，iMac 的鼠标键盘能点击、输入，`⌃⌥⌘K` 交还（Lee 实测） | — |
| 4 局域网被拒 | 通过。拔掉雷雳线，会话改为 Network Link、本机 `en0 10.0.0.126`、接收端 `10.0.0.183`：4 次连接都是 TCP 握手成功，约 11 ms 后被接收端重置，没有建立会话，没有出虚拟屏；4 次后发送端自己停了 | 13:08:34.237 `ready — 10.0.0.183 via en0`，13:08:34.248 `ECONNRESET`；13:08:40–42 又 3 次同样 |

注意：
- 用 `nc` 直接探测 iMac 的 Wi‑Fi 地址 54321 端口，结果不稳定（一次连上，之后超时）；未用端口 54399 是「拒绝」。应用层的结论以第 4 步为准：会被立即重置。
- 1.0.1 的接收端仍在 Wi‑Fi 上广播 Bonjour（`dns-sd` 看到接口 11 和 12 两条），但不接受 Wi‑Fi 上的会话。

### 卡住测试的权限问题（2026-10-20）

发送端从 ad hoc 包换成 Developer ID 包后，「录屏」和「辅助功能」都打开了，但 App 仍说没有权限：
- `tccd` 日志：存下的代码要求是一个 cdhash `72ac1dbb0ca265112aef3eb50f162538ad8c5e61`（某个旧的 ad hoc 测试包），而装的 1.0.1 是 arm64 `30e90520…`、x86_64 `6efc8af9…`，所以 `Failed to match existing code requirement`。
- 开着的「系统设置」会把它缓存的旧要求写回去。只重置不退出「系统设置」不够。
- 修法（Lee 做，已验证）：`⌘Q` 退出「系统设置」→ `tccutil reset ScreenCapture|Accessibility|ListenEvent|PostEvent com.pwegroup.pweimacdisplay` → 在 App 的权限窗口点「Allow」→ 在系统设置里打开 → 重启 App。
- 症状对照：录屏不对 → `capture: screen recording permission missing; automatic reconnect suspended`；辅助功能不对 → 鼠标能移动，不能点击和打字。

## 1.1 真机测试（2026-10-20）

包：`pwe/dist/local/PWE-iMac-Display-1.1.0.dmg`，两个 App 构建号 `20261020120453`，Developer ID，未公证，sha256 `ac7501ff…`。
发送端代码要求和 1.0.1 相同（Developer ID 的 designated requirement），从 1.0.1 换过来时权限沿用，没再出问题。

| 项 | 结果 | 证据 |
|---|---|---|
| 接收端 Metal | 通过（启动和出画面）。`[metal] zero-copy video on AMD Radeon Pro 570, vsync=1, drawables=3`；`Metal zero-copy: first frame 5120x2880 (IOSurface, no copy)` | iMac 上 `pwe-imac-log.command` 抓的接收端日志 |
| 接收端只在雷雳网桥上广播 | 通过。Bonjour 只在接口 12（bridge0）；TXT 有 `pweSec=2` | `dns-sd -B`、`dns-sd -L` |
| F1 首次配对出码 | 通过（App 新启动时）。Mac 显示「Enter the code shown on your iMac」，iMac 显示 6 位码 | Lee 实测；接收端 `[sec] paired with "MacBook Pro"` |
| F2 输码后出画面 | 通过。13:17:38 连上，13:17:50 配对完成，13:17:51 第一帧（≤ 30 秒） | 发送端 `pairing: paired with LL iMac 2017`、`encrypted session` |
| F1/F2 的异常路径 | **失败**。等输码时线断了（13:12:46 拔插），或点「Cancel」再连：Mac 一直停在「输入配对码」，不重新拨号，iMac 也就不出码；只有退出重开 App 才好 | 13:12:25 连上后接收端没有任何 `[sec]` 配对行；13:15 之后发送端没有拨号；接收端 13:16 起没有 `client connected` |
| iMac 自己画指针 | 通过（功能上）。`pointer: receiver draws the pointer; event tap on`；接收端 `the sender's pointer picture arrived (56x80)` | 手感未评 |
| A2 发现拔线 | 通过。拔线后约 0.2 秒 `no route … closing in 2 s`，2 秒后关闭（基线 18.3–18.6 秒） | 6 次都一样 |
| A1 拔插 6 次（含 F3） | 6 次都自动恢复，不再要码，都直接拨雷雳地址（Wi‑Fi 地址的问题修好了）。**但插回到出画面 22.5–26.8 秒，没达到 ≤ 5 秒** | 见下表 |
| A4 5K 60 被记住 | 通过（第二次）。13:26:26 换成 `native5k60Experimental`，`pwe.pictures` 存成 60，拔插后仍是 60，显示器 60 Hz。第一次在菜单里选（约 13:18）没有任何效果，日志里也没有痕迹，原因未查到 | `defaults read com.pwegroup.pweimacdisplay pwe.pictures` |
| A6 显示器名字 | 通过。「PWE iMac Display」 | `system_profiler SPDisplaysDataType` |

拔插记录（1.1）：

| 次 | 插回 | iMac 链路就绪 | Bonjour 重新出现 | 第一次拨号 | 出画面 | 插回到出画面 |
|---|---|---|---|---|---|---|
| 1 | 13:19:42.1 | 13:19:42.2 | 未记 | 13:20:08.1 | 13:20:08.9 | 26.8 秒 |
| 2 | 13:21:04.5 | 13:21:04.6 | 未记 | 13:21:27.5 | 13:21:28.3 | 23.8 秒 |
| 3 | 13:22:41.5 | 13:22:41.6 | 未记 | 13:23:03.2 | 13:23:03.9 | 22.5 秒 |
| 4 | 13:23:31.4 | 13:23:31.5 | 未记 | 13:23:55.1 | 13:23:55.9 | 24.5 秒 |
| 5 | 13:24:04.4 | 13:24:04.5 | 未记 | 13:24:28.3 | 13:24:29.0 | 24.6 秒 |
| 6（5K 60） | 13:27:13.3 | 13:27:13.4 | 13:27:33.4 | 13:27:36.0 | 13:27:36.8 | 23.5 秒 |

结论：剩下的约 20 秒是等 Bonjour 重新发现 iMac（第 6 次：链路就绪后 20.0 秒才 `Add`，再过 2.6 秒拨号）。
iMac 的雷雳地址每次都没变（`169.254.6.224`），接收端每 1 秒检查一次地址（`main.c` `last_ip_check_ms >= 1000`），所以不是接收端慢。
建议：链路恢复后先直接拨上次用过的雷雳地址，失败再等 Bonjour。

其他观察：
- 接收端日志里有一次 `client connected (?)` 紧接 `client disconnected`（第 1 次拔插前后），接口不明，来源未查明。
- 从脚本启动接收端时，它的权限算在「终端」头上，日志显示 `inputMonitoring=false accessibility=false`。测键鼠共享要正常打开接收端。

| 项（1.1，续） | 结果 | 证据 |
|---|---|---|
| A3 重开接收端 | 通过。13:32:44 iMac 上重开接收端，13:32:50.6 Mac 自动重连，13:32:51.4 出画面（约 7 秒）；不用刷新 IP、不用拔插、不再要码 | 接收端日志 `client connected (bridge0, cable)`、`session ready (encrypted)` |
| A5 睡眠：App 不再叫醒 Mac | 通过（1 次真睡眠 + 1 次短睡眠）。13:33:16 真睡眠 29 秒（pmset `Entering Sleep state`）；App 的 UserIsActive 只在醒来后的 13:34:08 才出现；13:31:51 那次短睡眠也是按键唤醒（WindowServer HID） | `pmset -g log`；powerd 日志 |
| A5 睡眠：醒来后出画面 | 短睡眠（4 秒，链路没断）：亮屏后 1.0 秒出画面。**真睡眠：亮屏后 26 秒才出画面**（13:33:42.8 → 13:34:08.8），原因同拔插（链路断过，等 Bonjour） | 同上 |
| A5 醒来后采集管线又重启一次 | 醒来出画面 3 秒后（13:32:00）管线又启动一次，来自「唤醒后重启采集」。是否造成可见卡顿未测 | `capture: pipeline started` 连续两次 |
| B 切换声音 | 每次切换都断开重连（13:30:56、13:31:09），黑屏约 0.6–0.9 秒（Lee 看到了「重新连」）。设计上如此（在两次连接之间开关音频转发） | 发送端日志 |
| Lee 只做了 1 轮长睡眠 | 另外 3 轮未做（13:33 之后到 13:34:35 没有睡眠记录） | — |
| B1 只在 iMac 出声 | 通过。只有 iMac 响，Mac 音量图标静音（Lee 实测） | — |
| B2 断开、退出后 Mac 扬声器恢复 | 通过（Lee 实测）；重开 App 自动连上，不再要码 | — |
| B3 两边都播放 / 只在这台 Mac | 通过（Lee 实测） | — |
| B 切换声音时断开重连 | 仍然有，每次约 1 秒黑屏（已记为 T14） | Lee 实测 |
| C1 菜单栏内容 | 通过。状态一行「LL-iMac-2017 is a display」、亮度滑块、夜览；没有原彩（iMac 没报）；画面、声音、断开、排列显示器、打开主窗口、设置、退出 | Claude 实测截图 |
| C2 菜单里换画面 | 功能在，但**每次操作晚一拍执行**（T11，P1）。实际生效时重连约 1 秒，48 / 60 都能存住 | 13:42:38、13:43:29 |
| C3 连接中改设置 | 通过。打开「大指针」后底部出现「Reconnecting to apply the change…」，1.2 秒后重连完成 | 13:40:47 |
| C5 关窗后从菜单打开 | 主窗口和设置窗口都能打开，但受 T11 影响，出来的是上一次点的那个 | 13:43–13:45 |
| C7 存储报告 | 通过，但报告太大、多是系统日志（T16） | `~/Documents/PWE iMac Display report.txt` |
| C8 语言 | 通过。en-AU 的 Mac 上是英文；iMac 名字显示「LL-iMac-2017」 | 截图 |
| C4 新 iMac 默认 5K 60 | 通过。删掉 `pwe.pictures` 后重开，13:46:53 自动连上（不要码），第一次就是 `native5k60Experimental`，并重新存下，显示器 60 Hz。没有再出首次设置最后一屏（`pwe.setupFinished=1`） | 发送端日志、`defaults read` |
| C6 隐藏菜单栏图标 | 通过。关掉「Show in menu bar」后图标消失，设置里提示「再次打开 App 就能看到窗口」；关窗后从访达打开，主窗口回来。测完已恢复 | Claude 实测截图 |
| C3 测试后复原 | 「大指针」已关回去 | — |
| D2 指针在 iMac 上按亮度键 | **Touch Bar 上的亮度按钮不行**：只调 MacBook，iMac 不变，没有提示框，App 日志里也没有记录。**按住 fn 用 F1/F2 可以**：iMac 背光一档一档变（Lee 实测，14:0x） | 这台 MacBook Pro 13 寸 M1 是 Touch Bar 机型，没有实体 F1/F2 |
| D2 提示框 | 按键调节时，iMac 屏幕右上角出现亮度提示块（与新系统的位置一致） | Lee 实测 |
| D3 Shift+Option 细调 | 通过（Lee 实测） | — |
| D4 指针在 MacBook 上 | 通过，调的是 MacBook，iMac 不变（Lee 实测） | — |
| D6 `pweimacdisplay://brightness?step=-1` | 能调：3 次后 iMac 变暗（Lee 实测）。**但没有提示框**（设计上 step 要出提示框）。是否多开窗口未确定：System Events 数到 2 个窗口，AX 列表只有 1 个 | 14:05:14–17，App 日志 `RECEIVED:(GURL,GURL)` |
| 设置里的亮度滑块 | 能调 iMac（Lee 实测） | — |
| D1、D5 | 未测（权限已在，看不到首次提示；D5 可选） | — |
| D7 Lumen Bar 交接 | 未测：Lumen Bar 分支没打包，测试机上没有 | — |

### E 组：OpenGL 对 Metal（第 1 次，2026-10-20 14:10–14:14）

方法：测试机自己写的脚本 `pwe-imac-render-ab.command`（放在 iMac 桌面「PWE iMac 检查」里，不入库；那台 Mac 的 `pwe/tools/pwe-imac-perf.command` 在 `pwe-1.1` 分支上，测试机拿不到）。
同一段视频全屏放在 iMac 上，接收端先 OpenGL 再 Metal，各采样约 90 秒，`TB_RECEIVER_TRACE=1`。片源实际每秒 24–25 帧（不是 60 帧）。结果在 `render-ab-20261020-141056/`。

| 指标 | OpenGL | Metal（零拷贝、按刷新出帧） |
|---|---|---|
| 接收端 CPU（单核 %） | 平均 21.5，最高 31.6 | 平均 14.8，最高 18.3 |
| 上传 p50 / p95 | 5.6 / 6.1 ms | 0.0 / 0.0 ms |
| 解码 p50 / p95 | 14.2 / 16.3 ms | 13.3 / 15.1 ms |
| 等待上屏 p50 / p95 | 0.4 / 0.5 ms | 14.4 / 23.4 ms |
| 收到到上屏 p50 / p95 | 20.3 / 23.1 ms | 31.3 / 40.2 ms |
| 帧 | 收 2573，显示 2573 | 收 2522，显示 2347，被顶掉 175（7%，集中在 13 秒里），迟到 32 |
| 最长间隔 | 1762 ms（一次） | 264 ms |

初步结论：Metal 的 CPU 低约 31%，零拷贝生效；但按刷新出帧让接收端每帧多等约一次刷新，延迟中位多 11 ms、p95 多 17 ms。60 帧片源下的表现未测。Lee 主观感受待补；Lee 换视频重测中。

### E 组：第 2、3 次（2026-10-20 14:17–14:28）

| 次 | 片源（每秒收到的帧） | 渲染 | CPU 平均 / 最高 | 收到到上屏 p50 / p95 | 显示 / 收到 | 迟到 | 被顶掉 |
|---|---|---|---|---|---|---|---|
| 1 | 约 25 | OpenGL | 21.5 / 31.6 % | 20.3 / 23.1 ms | 2573 / 2573 | 0 | 0 |
| 1 | 约 25 | Metal | 14.8 / 18.3 % | 31.3 / 40.2 ms | 2347 / 2522 | 32 | 7% |
| 2 | 约 25 | OpenGL | 20.0 / 29.6 % | 18.8 / 24.1 ms | 2575 / 2575 | 0 | 0 |
| 2 | 约 25 | Metal | 14.9 / 19.4 % | 31.8 / 40.9 ms | 2295 / 2313 | 13 | 1% |
| 3 | 约 49（4K 视频） | OpenGL | 28.5 / 31.8 % | 17.3 / 18.9 ms | 4890 / 4890 | 0 | 0 |
| 3 | 约 48（4K 视频） | Metal | 17.2 / 21.4 % | 29.7 / 48.7 ms | 4530 / 4807 | 621 | 6% |

结果在 `render-ab-20261020-141056/`、`-141732/`、`-142406/`（iMac 桌面「PWE iMac 检查」）。

结论：
- Metal 零拷贝生效（上传 0 ms），接收端 CPU 低 25–40%，帧间隔稍匀（第 3 次 p95 38.5 对 45.0 ms）。
- 代价：按刷新出帧让每帧多等约一次刷新，延迟中位多 11–13 ms；约 50 帧时 p95 多 30 ms，13% 的帧迟到、6% 被顶掉，每秒显示 45 帧（OpenGL 49 帧）。
- 对照 `PLAN-1.1` 的标准：「Metal 的 CPU 不高于 OpenGL」通过；「帧率不低于 OpenGL」在约 50 帧时不通过。
- Lee 的体感（第 3 次，4K 视频）：两条路线没太大差别。
- **Lee 的决定（2026-10-20）：OpenGL 和 Metal 都保留，让用户选。**默认用哪个待 Lee 定；测试机的建议见问题清单 T22。
- 每次两轮都出现过一次约 1.2 秒的间隔（第 2 次），和渲染方式无关，来源未查。

### F 组：配对（续，2026-10-20 14:29–16:22）

| 项 | 结果 | 证据 |
|---|---|---|
| F3 拔插不再要码 | 通过（A1 的 6 次拔插都直接 `encrypted session`） | 发送端日志 |
| F6 Wi‑Fi 上看不到 iMac | 通过。`dns-sd -B` 只在接口 12（bridge0）看到 | 14:29:42 |
| F7 Wi‑Fi 上乱发数据不出码 | 通过（按清单标准）。iMac 空闲时，来自 Wi‑Fi（iMac 的 `en1`）的连接**被接收端接受并开始解析**，`hello…` 被读成包长度 1751477356 → `[net] bad pkt_len` → 断开；没有任何 `[sec]` 行，不出码。对比 1.0.1：Wi‑Fi 连接握手后 11 ms 就被重置。iMac 正在出画面时，新连接只在系统排队，App 不处理 | iMac 日志 `receiver-20261020-143031.log` 第 899–908 行 |
| 线缆测速（1.1） | 3.12 Gbit/s，约 50 秒；1.0.1 是 10.82 Gbit/s。测速数据走加密会话，测到的是加密吞吐量 | 设置 › 高级，16:20 |
| Network Link（「Connect over: Network」） | **连不上**：从 `en0 10.0.0.126` 去拨 iMac 的**雷雳地址** `169.254.6.224`，5 秒超时（T25）。所以「真 1.1 发送端从 Wi‑Fi 连」测不了 | 16:21:42 `dialing 169.254.6.224:54321 from 10.0.0.126 (en0) transport=networkLink` |
| 出错界面 | 连不上时主窗口显示「Could not reach the iMac」、说明和「Trying again… / Stop」，清楚 | 截图 16:22 |
| 测完复原 | 「Connect over」改回雷雳线，16:22:19 重连，5K 60 | — |
| F13 在 Mac 上「忘记」 | 通过。设置 › 高级 › Forget 有确认框；当前会话不断开，断开重连后 Mac 要码；输对（Lee 读 iMac 上的 412599）后 16:27:06 `paired with LL iMac 2017`，1 秒内出画面 | 发送端日志、iMac 日志第 996–1000 行 |
| F4 输错 5 次 | iMac 端通过：每次输错都换码（Mac 提示「Your iMac is showing a new one」），第 5 次后 `pairing locked for 60 s after 5 wrong codes`。**Mac 端不提示锁定**（T27） | 16:24:50–16:25:16；iMac 日志第 977–993 行 |
| 锁定结束后 | Mac 仍停在输码框，但连接已断，iMac 显示「Waiting for your Mac」（T9 再现）。点 Cancel、再点主窗口「Use as Display」后 iMac 出新码 | Lee 实测 16:26 |
| 连接时的状态叠在一起 | 1.1 里仍有：点「Use as Display」时「The iMac is no longer connected」和「Connecting to LL-iMac-2017」叠着闪一下（基线第 3 条） | 截图 16:26:49 |
| F14 旧版发送端（1.0.1）连 1.1 的 iMac | 通过。iMac：`unencrypted connection (compatibility mode): picture, sound, brightness and volume only`；画面 5K 60、硬件解码、有声音；`ignored packet 0x13 / 0x34: needs an encrypted session`。连上到出画面约 5.8 秒（1.1 发送端不到 1 秒） | 16:29:07.6 `ready`，16:29:13.4 第一帧；iMac 日志第 1065–1096 行 |
| F15 iMac 上关掉「Allow Unencrypted Connections」 | 通过。当前未加密会话立即断开（`client disconnected` → `unencrypted connections turned off`），iMac 提示拒绝连接（Lee 实测）；1.0.1 发送端之后 40 次重试都被拒（`refused an unencrypted connection`）。重新打开后恢复兼容模式 | iMac 日志第 1118–1327 行 |
| 测完复原 | Mac 换回 1.1（16:32:40 加密会话，5K 60）；iMac 的「Allow Unencrypted Connections」已由 Lee 重新打开 | — |
| 换包时的一次自动重启 | 16:27 退出 1.1 后，3 秒内又出现一个 1.1 进程（PID 16527），导致第一次换成 1.0.1 没生效。之后同样的退出没有复现（12 秒内无新进程）。原因未查明 | 进程启动时间 16:27:43 |
| F12 iMac 上「Forget All Paired Macs」 | 通过。当前会话立即断开（`client disconnected` → `forgot all paired Macs`），Mac 16:35:54 自动重连并要码 | iMac 日志第 1425–1430 行 |
| F5 码 60 秒过期 | iMac 端通过：码出现约 60 秒后主动断开（第 1434 行），旧码 213809 在 16:37:50 不再被接受。**Mac 端不提示过期**（T29）：一直停在输码框，输旧码后只是重连并清空 | — |
| F5 之后用新码配对 | 通过。16:38:34 用 iMac 新码 778847 配对，1 秒内出画面，5K 60 | 发送端 `paired with LL iMac 2017` |
| F 组未测 | F8（抓包，要 sudo）、F10（iMac 上测加密速度）、F16（1.1 发送端连 1.0.1 iMac）、F17（iMac 自动登录后重启）、F18（Network Link，被 T25 挡住）、F19（换系统语言）| Lee 决定先不测 |
