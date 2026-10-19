# 1.1 接收端渲染：iMac 真机测试单

> 2026-10-19 写。代码在分支 `claude/bold-edison-fc242e`，基于 `pwe-1.1`（`4cfae7a`），未合并、未推送。
> 要测三件事：Metal 零拷贝、按刷新出帧、iMac 自己画指针。方案见 `RESEARCH-Metal-2026-10-19.md`，基线见 `BASELINE-iMac18,3.md`（两份都在主检出的 `docs/pwe/`，未入库）。

## 结论

本机（M1，macOS 27.2）上能测的都过了。但测试时这台 Mac 的屏幕是锁着的，Metal 画面一次也没有真正上屏。
所以画面对不对、顺不顺、指针隐藏灵不灵，都要在 iMac 上看。

## 本机已验证（2026-10-19）

- 接收端单元测试 7 组全过，arm64 和 x86_64（Rosetta）都过。其中 Metal 离屏读回 71 项：BT.709 颜色（视频范围和全范围）、照 FFmpeg 方式建的 IOSurface 缓冲、两条拷贝回退、指针的混合与位置。
- 发送端单元测试全过（185 个；新增 8 个：0x39 包格式、配置字段、镜像黑边换算、指针图像）。
- 回环冒烟测试 7 段、16 项，连跑 3 次全过：握手、坏长度、静默、H.264 流、Metal + 本地指针、拷贝回退、OpenGL 回退。
- 独立代码审查（2026-10-19）：没有内存错误；指出的阻塞、遮挡空转、回退黑屏、「This Mac is Master」下没有指针、10 位缓冲五处已修（`59746c5`）。
- 通用包：`pwe/package.sh --unsigned` 通过 `check-bundle`，接收端两个切片都是 minos 11.0。

## 未验证

- 已知未修：视频低于 60 帧时（30 帧片源、不规则重绘），单独重画指针可能占掉一次刷新，让下一帧视频晚一拍。B 节拖窗口时留意。
- 回退到 OpenGL 时，SDL 会重建窗口，全屏会闪一下（离开再进入全屏空间）。只在 Metal 出错时发生。

- Metal 画面在真屏上的颜色、闪烁、上屏时间：本机屏幕锁着，所有帧都没上屏（trace 里 `shown=0`）。
- `CGCursorIsVisible` 能否看到别的 App 隐藏指针：锁屏时测试 App 拿不到前台，隐藏不生效。
- macOS 11、12 能否启动：没有装这两个系统的机器（iMac15,1 最高 11，iMac17,1 最高 12）。
- 发送端事件 tap 在签名的 PWE 包里能否建立：只在命令行测过，能建。建不了时自动改成每秒 240 次轮询。

## 准备（Lee）

1. 在 MacBook 上退出 PWE iMac Display。
2. 打开本分支打的包（路径见文末「包」）。成功：磁盘映像里有两个 App。
3. 把两个 App 拷到 MacBook 的「应用程序」，替换旧的。成功：发送端「关于」里的构建号与「包」一节相同。
4. 经文件共享把接收端 App 拷到 iMac 的「应用程序」，替换旧的。
5. 经文件共享把 `pwe/tools/pwe-imac-perf.command` 拷到 iMac 桌面的「PWE iMac 检查」文件夹。
6. 在 MacBook 上把串流设成 5K 60。成功：设置里显示 `5120 × 2880 @ 60`。
7. 在 MacBook 上用浏览器打开 testufo.com，把窗口拖到 iMac 上并全屏。成功：iMac 上有一直移动的画面。

## A. 自动对比（约 6 分钟）

脚本分三段，每段先重启接收端、等 Mac 重连，再录 90 秒：

| 段 | 渲染 | 指针 |
|---|---|---|
| 1-opengl | OpenGL（现在的路径） | 画在视频里 |
| 2-metal | Metal 零拷贝，按刷新出帧 | 画在视频里 |
| 3-metal-pointer | 同上 | iMac 自己画 |

1. 在 iMac 上双击 `pwe-imac-perf.command`。成功：终端显示 `== Phase 1-opengl`。
2. 每段开始录时会响一声。录的时候不要改 MacBook 上的串流设置。
3. 等终端显示 `Finished`。成功：同一文件夹里有 `pwe-perf-<时间>/summary.txt`。
4. 把整个 `pwe-perf-<时间>` 文件夹拷回 MacBook，交给 Claude。

## B. 240 fps 慢动作（和 A 同时做）

用 iPhone 240 fps 同时拍 MacBook 屏和 iMac。每段响声之后拍两条：
- 延迟：快速甩动指针 10 次。数两边开始动的帧差，每帧 4.17 ms。
- 顺滑：拖一个窗口横穿 iMac。数每张画面停几帧：60 Hz 理想是 4 帧，出现 8 帧就是停了一拍。

1. 在第 1 段拍两条。这是 B 组：OpenGL 5K 60。
2. 在第 2 段拍两条。这是 C 组：Metal 5K 60。
3. 在第 3 段拍两条。这是 D 组：Metal 5K 60 + 本地指针。
4. 脚本结束后，把 MacBook 的串流改成 5K 48。
5. 再双击一次脚本，只在第 1 段拍两条。这是 A 组：OpenGL 5K 48。

## C. 逐项看（脚本结束后）

脚本最后会照常打开接收端。这时它用默认设置：Metal + iMac 自己画指针。

1. 对比第 1 段和第 2 段的照片。成功：同一画面颜色一样。
2. 在 iMac 上全屏放一段视频，5 秒不动鼠标。成功：iMac 上指针消失，和在 Mac 上一样。
3. 在 iMac 上的文本编辑里打字。成功：指针和在 Mac 上一样隐藏。
4. 在发送端打开「Large cursor on receiver」。成功：iMac 上的指针约大一倍，指尖位置不变。
5. 把指针移到 MacBook 自己的屏上。成功：iMac 上不再有指针。
6. 如果用「This Mac is Master」（这台 Mac 控制 iMac）：切过去。成功：指针照旧画在视频里，不消失。
7. 换成镜像模式，把指针移到画面四个角。成功：指尖落在画面的角上，不落在左右黑边里。
8. 来回拖窗口，看指针领先窗口多少。这是本地指针的固有现象。记下能否接受，用来定默认开还是关。

## 通过标准

| 项 | 标准 | 看哪里 |
|---|---|---|
| CPU | 第 2 段接收端 CPU 均值不高于第 1 段 | `summary.txt` 的 receiver CPU |
| 帧率 | 5K 60 下第 2 段 shown/s 中位不低于第 1 段 | frames |
| 丢帧 | 第 2 段 replaced + repeat ≤ 1% | frames 括号里的百分比 |
| 延迟 | 第 2 段 total p95 ≤ decode p95 + 16.7 ms | frames |
| 启动 | macOS 11–13 都能启动 | 13.7.8 本次测；11、12 未测，没有机器 |
| 指针 | D 组甩动延迟少于 C 组；拖动时指针每次刷新都动 | B 节的视频 |
| 手感 | Lee 不再觉得卡 | B、C 两节 |

CPU 和帧率两条来自 `PLAN-1.1-2026-10-19.md`；丢帧、延迟、手感三条来自研究文档第 5 节。

读数时注意两点：
- 两段的 total 不能直接比。OpenGL 段的「上屏」只是交给窗口服务器的时刻（不等垂直同步）；Metal 段是画面真正上屏的时刻（`presentedTime`），多含一次等刷新。
- 延迟一条可能偏严：Metal 段的帧要等到下一次刷新才上屏，合成器还可能再晚一拍。不达标时先看 B 节视频，再和 Claude 商量是否放宽。

## 出问题时

> ⚠️ 如果 Metal 画面异常（闪、黑、颜色错），在 iMac 的终端运行下面这行，再重开接收端。不运行的话，接收端默认一直用 Metal。原因：没有环境变量时，接收端读这个设置。

```bash
defaults write com.pwegroup.pweimacdisplay.receiver TBReceiverRenderDriver opengl
```

成功：画面回到 OpenGL 时的样子。恢复默认：

```bash
defaults delete com.pwegroup.pweimacdisplay.receiver TBReceiverRenderDriver
```

只关本地指针，二选一：
- iMac 端：`defaults write com.pwegroup.pweimacdisplay.receiver TBReceiverCursorImage -bool false`，重开接收端后生效。
- MacBook 端：`defaults write com.pwegroup.pweimacdisplay fd.tbdisplaysender.receiverDrawnPointer -bool false`，下次开始串流时生效。

## 开关一览

| 开关 | 环境变量 | 接收端 defaults 键 | 值 |
|---|---|---|---|
| 渲染 | `TB_RECEIVER_RENDER_DRIVER` | `TBReceiverRenderDriver` | `metal`（macOS 15 及以下默认）、`opengl`（macOS 26 及以上默认）、`metal-sdl`（SDL 自带 Metal，只做对照） |
| 出帧节奏 | `TB_RECEIVER_PACING` | `TBReceiverPacing` | `vsync`（默认）、`immediate` |
| 本地指针 | `TB_RECEIVER_CURSOR_IMAGE` | `TBReceiverCursorImage` | 默认开；`0` / `NO` 关 |
| 计时日志 | `TB_RECEIVER_TRACE` | — | `1` 开 |
| 排队帧数 | `TB_RECEIVER_DRAWABLES` | — | `3`（默认）、`2` |
| 测回退 | `TB_RECEIVER_METAL_FAIL` | — | `init`、`wrap`、`texture` |

## 包

- 文件：`.claude/worktrees/bold-edison-fc242e/pwe/dist/local/PWE-iMac-Display-1.1.0.dmg`（在主检出目录下；不入库）。
- 构建 `20261019190047`，来自提交 `81850ee`。ad hoc 签名，未公证，只给这两台机器用。
- sha256 `a36534b8d2a13e827f92462bb8a20273618e52a760c28d6a474c147b9b096af9`
- 接收端：arm64 + x86_64，两个切片 minos 11.0；`check-bundle` 通过（2026-10-19）。
