# 接收端渲染研究：OpenGL → Metal、本地画指针（2026-10-19）

> 只做研究，没改代码。行号按 `main` 8fe9919。标「估算」的数字没有实测；标「未核实」的写明了原因。

## 结论

1. **值得换 Metal，但不是改 SDL 的一个开关。** 要做的是真正的零拷贝：VideoToolbox 解出的 IOSurface 经 `CVMetalTextureCache` 直接当纹理，自己的 NV12→RGB 着色器画进 SDL Metal 渲染器的编码器，失败时回到现在的 OpenGL 路径。
2. **同时改「到帧就画」为「按刷新率画」。** 每次垂直同步画一次「最新一帧 + 最新指针位置」。这一步对顺滑的贡献不小于 Metal 本身。
3. **5K 48 的轻微顿挫主要不是渲染的问题。** iMac 面板是 60 Hz，48 帧放到 60 Hz 上，每 4 帧有 1 帧要停 2 个刷新周期，形成 12 Hz 的抖动。Lee 觉得 60 明显更顺，和这个算术一致。默认 5K 60（PLAN-1.1「默认 5K 60」）是最便宜的改进。
4. **本地指针的管道已经有了，只是只给「大光标」用。** 1.1 改成：发送端发真实光标图像和高频位置，接收端每次刷新都画。指针延迟估计从约 40–70 ms 降到约 10–25 ms（估算）。
5. 顺序：先加计时日志、量基线 → Metal 零拷贝 + 按刷新率画 → 本地指针。共约 7–10 个工作日，全部改的是上游文件，走 PR-first + `pwe/PATCHES.md`。

## 1. 现在每帧的时间花在哪

接收端是单线程循环（`main.c:3`）。`drain_socket()`（`main.c:1316`）一直读到 `EAGAIN`，每收齐一帧就同步地「解码 → 上传 → 呈现」：

| 步骤 | 代码 | 5K 60 下每帧（估算） |
|---|---|---|
| AVCC → Annex B 拷贝 | `decoder.c:310`，平均 150 Mbit/s ÷ 60 ≈ 0.3 MB | < 0.3 ms |
| 解码，阻塞等待 | FFmpeg 9.0.2 `videotoolbox.c:766` 每帧调用 `VTDecompressionSessionWaitForAsynchronousFrames` | 未知，要量；5K HEVC 估 4–10 ms |
| 锁 CVPixelBuffer 读平面 | `decoder.c:369–380` | 0–3 ms，取决于表面在显存还是内存（未核实） |
| `SDL_UpdateNVTexture` 22.1 MB | `display.c:1166` → SDL `SDL_render_gl.c:790–816` 两次 `glTexSubImage2D` | CPU 拷贝 2–4 ms，加 PCIe 传输；若上一帧还在用这张纹理会再等 |
| 画面 + 指针 + 呈现 | `display.c:1151–1157`，不开垂直同步（`display.c:612–615`） | GPU < 1 ms；何时上屏由 WindowServer 决定 |

实测（2026-10-19，5K 48，片源 24 帧）：接收端 CPU 平均 19.3%，帧率中位 25，约合**每帧 7.7 ms CPU**。线性外推到 60 帧约 46% 单核（估算）。解码等待 + 上传串行，加起来离 16.7 ms 的预算不远，一点抖动就错过一次刷新。

**「零拷贝快速路径」用上了没有？** 用上了，但它不是零拷贝。硬件解码时（日志 `videotoolbox_vld`）`decoder.c:369` 的条件成立，确实跳过了 `av_hwframe_transfer_data`（`decoder.c:390`）。但它只是让 CPU 直接读 IOSurface，再由 SDL 把 22 MB 拷进 GL 纹理。每帧仍有一次 CPU 读和一次上传。`decoder.c:3–5` 的头注释（「Metal renderer」「transfer」）已过时。

另外三点放大抖动：
- 网络突发时两帧连着到，两帧都会被解码并呈现，前一帧白画（`main.c:1316`）。
- 指针包和视频在同一个循环里排队（`main.c:1203–1220`）。距上一帧不到 40 ms 时只记位置不重画（`display.c:1190`），所以指针最多只按视频帧率移动。
- FFmpeg 对 HEVC 只「允许」而不「要求」硬件解码（`videotoolbox.c:852`）。没有硬件 HEVC 的机器会在 VideoToolbox 里悄悄走软件解码，日志照样显示 `videotoolbox_vld`。

## 2. 三个方案

| 方案 | 顺滑收益 | 工作量 / 风险 | 判断 |
|---|---|---|---|
| (b) IOSurface → `CVMetalTextureCache` → 自己的 NV12 着色器，画进 SDL Metal 渲染器 | 高：去掉每帧 22 MB 的 CPU 读和上传，主线程每帧省约 3–6 ms（估算），CPU 大降，按刷新率画的成本几乎为零 | 中：约 3–4 天；新 ObjC 文件 + `display.c`、`decoder.c` 改动 | **做** |
| (c) 保留 OpenGL，用 `CGLTexImageIOSurface2D` | 拷贝收益同 (b) | 中：SDL2 不能把外部 GL 纹理包成 `SDL_Texture`，要自己写 GL 绘制；只能用矩形纹理；OpenGL 自 10.14 弃用；拿不到实际上屏时间 | 不做 |
| (a) `TB_RECEIVER_RENDER_DRIVER=metal` + `SDL_UpdateNVTexture` | 无，可能更差 | 零：已有环境变量（`display.c:571`） | 只做对照 |

**(a) 为什么没用。** SDL 2.32.10 的 Metal 渲染器支持 NV12（Y 用 `R8Unorm`，UV 用 `RG8Unorm`，`SDL_render_metal.m:567–580`）。但第一次之后，每次更新都**新建一张暂存纹理**、`replaceRegion` 拷贝、blit 过去，并单独提交一次命令缓冲（`:654–720`）。NV12 要做两遍（`:794–817`），所以每帧新分配 22 MB、提交两次。它仍然拷贝，比 GL 更重。

**(b) 怎么接进 SDL。** 用 `SDL_RenderGetMetalCommandEncoder()`：它会先刷掉 SDL 的绘制队列（`SDL_render.c:4469`），再交出当前帧的编码器（`SDL_render_metal.m:1524`）。我们在这个编码器里画视频四边形；SDL 的状态缓存每次刷队列时清零（`:1267–1268`），之后 SDL 照常画状态页和指针。这样连接画面、状态 UI 不用重写。要点：
- 解码帧的 `CVPixelBufferRef`（`hw_frame->data[3]`）先 `CVPixelBufferRetain`，再 `av_frame_unref`。在命令缓冲的完成回调里释放 CVMetalTexture 和像素缓冲（Apple 文档要求纹理用完前保持持有）。
- 颜色按 BT.709 有限范围，和现在的 `SDL_SetYUVConversionMode(BT709)`（`display.c:621`）一致；图层不设 `colorspace`，保持 SDL 的默认，A/B 截图比色。
- 软件解码（`decoder.c:76–83`）和 RAW 直通（`main.c:963`）给的是 CPU 内存里的 NV12。这两条路走 3 张预分配纹理轮流 `replaceRegion`，不用 SDL 每帧新建的办法。

**呈现时机。** 渲染器开垂直同步（`SDL_RENDERER_PRESENTVSYNC` → `CAMetalLayer.displaySyncEnabled = YES`，`SDL_render_metal.m:1818`），`maximumDrawableCount` 先用默认 3，量完再试 2（少一帧排队延迟）。循环改成：
- 解码只把「最新帧」放进单格信箱（新的覆盖旧的，计数为「被替换」）。
- 每次垂直同步画一次：信箱里的最新帧 + 最新指针位置。没有新帧就重画上一帧（计数为「重复」）。
- 用 `MTLDrawable addPresentedHandler` 拿实际上屏时间（macOS 10.15.4+），写进计时日志。

为什么能减少顿挫：现在是「到了就画」。帧到达的时间相对刷新边界前后摆动时，有的刷新周期拿到两帧（一帧被丢）、有的一帧都没有（停一拍），看起来就是一顿。固定按刷新呈现后，抖动只会让某帧晚一拍，不会出现突发；指针每拍都动。上游 03299cb 当初强制 OpenGL，是因为 Tahoe 上 Metal 闪屏，它自己的分析是「呈现频率忽快忽慢」。固定节拍正好去掉这个诱因，但 Tahoe 没测过，见第 3 节。

第二阶段（可选，1–2 天）：把解码挪到工作线程。解码等待（`videotoolbox.c:766`）就不再挡住指针包和输入事件。工作线程里只有 C 和 CoreFoundation 调用，不碰 ObjC 对象，不违背 `main.c:8–13` 的初衷。

## 3. 兼容性

| 机型 | GPU | 官方最高系统 | Metal | 硬件 HEVC |
|---|---|---|---|---|
| iMac15,1（2014–15） | R9 M290/M290X（GCN 1.0）、M295X（GCN 1.2） | macOS 11 | 支持 | 无（Haswell、这些 AMD 都没有）→ 5K HEVC 实际是软件解码，渲染换什么都不够；该机型应推荐 1440p 或 4K 档 |
| iMac17,1（2015 末） | R9 M380–M395X | macOS 12 | 支持 | Skylake 有；是否被 VideoToolbox 用上**未核实**（无机器） |
| iMac18,3（2017） | Radeon Pro 570–580（Polaris） | macOS 13 | 支持 | 有（实测 `videotoolbox_vld`、CPU 19%）。解码在 Intel 核显还是 AMD 上做**未核实** |

- 这三代 GPU 都在 Metal 的 Mac 系列 1 里；`CVMetalTextureCache`（10.11+）、`displaySyncEnabled` / `maximumDrawableCount`（10.13+）都低于 minos 11。
- FFmpeg 给解码缓冲设了 `kCVPixelBufferIOSurfacePropertiesKey`，但只设了 OpenGL 兼容键、没设 Metal 兼容键（`videotoolbox.c:825`）。IOSurface 缓冲在 macOS 上一般能直接建 Metal 纹理，但每台机器第一次建纹理必须检查返回值，失败就回退。
- 回退：Metal 设备、纹理缓存、首帧建纹理任一失败 → 释放 Metal 渲染器，改建 OpenGL 渲染器，走现在的上传路径，日志写明原因。保留 `TB_RECEIVER_RENDER_DRIVER=opengl` 强制回退。macOS 26 及以上先默认 OpenGL，等真机测过闪屏再放开。
- 通用二进制：两个切片都编进 Metal 代码；着色器用 `newLibraryWithSource` 运行时编译（启动一次，约几十毫秒），不依赖 Xcode 26 单独下载的 Metal 工具链。Makefile 加 `-framework Metal -framework QuartzCore`。

## 4. 本地指针

**已有的（上游）：** 包 `0x32`（`proto.h:52`），JSON 含位置、源尺寸、可见、5 种形状、大光标。发送端 120 Hz 主线程定时器发位置（`TBDisplaySenderService.swift:3376–3389`、`:3466`），接收端用矢量画 5 种形状（`display.c:769` 起）。但只在打开「大光标」时启用（`:435–440`，理由是 ScreenCaptureKit 能保留所有系统光标形状），此时 `showsCursor = false`（`:2827`）。

**1.1 的协议草案（向后兼容）：**
- 接收端在 hello JSON（`main.c:1867`）加 `"cursorImage":true`。发送端只对声明了的接收端关掉 `showsCursor`，否则保持现状。
- 新包 `0x39` 光标图像，只在变化时发：`[id u32][w u16][h u16][hotX u16][hotY u16][scale u8][BGRA 预乘像素]`。来源 `NSCursor.currentSystem` 的图像和热点，2× 下典型 64×64 = 16 KB。
- `0x32` 位置照旧，加 `"id"` 指向当前图像。改为事件驱动：只听不改的 `CGEventTap`（移动、拖动）放在后台线程，上限 240 Hz，代替会被主线程卡住的定时器。约 100 字节一包，每秒不到 25 KB。
- 接收端每次刷新都按最新位置画图像纹理。「大光标」= 图像放大 2 倍；没收到图像时退回现在的矢量形状。

**延迟收益（估算）：** 现在指针跟着视频：采集 + 编码 + 传输 + 解码 + 上传 + 等刷新，约 40–70 ms，还按视频帧率跳。本地指针：事件 → 包 ≤ 4 ms，雷雳传输 < 1 ms，等下一次刷新 ≤ 16.7 ms，约 10–25 ms，每拍都动。

**取舍和要处理的情况：**
- 拖窗口时，指针会领先窗口约一个视频延迟（指针快、窗口照旧）。这是本地指针方案的通病（随航、Parsec 类同），要 Lee 实际看过再定是否默认打开。
- 镜像模式：`scalesToFit` 会加黑边（13 寸 16:10 镜像到 16:9），而现在的位置换算按整幅线性缩放（`:3478–3479`），会偏。要按实际内容矩形换算。
- HiDPI：位置用点坐标按比例换成像素，已正确；图像要带 scale，接收端按 drawable/源尺寸缩放。
- 应用隐藏光标（看视频、打字时）：公开 API 只有已弃用的 `CGCursorIsVisible`，是否还可靠**未核实**。不可靠就提供开关「本地指针（实验）」，默认值等 Lee 看过再定。
- 输入转发（iMac 的鼠标控制 Mac）时现在会发隐藏包（`applyCursorOverlayMode`）。以后可以直接用 iMac 本机鼠标位置画，延迟最低，列为后续。
- 改动的文件：`TBDisplaySenderService.swift`、`TBMonitorProtocol.swift`、`proto.h`、`main.c`、`display.c`，全是上游文件。

## 5. 测量方案

**接收端计时（环境变量 `TB_RECEIVER_TRACE=1` 打开，默认关）：** 每帧记 `arrive`（包收齐）、`decoded`、`tex_ready`（上传完或建好 Metal 纹理）、`submitted`、`presented`（Metal 用 presentedHandler；GL 用交换返回时间）。每秒汇总一行：`in / shown / replaced / repeat`、解码和上传的 p50/p95、到达间隔抖动 p95、到达 → 上屏 p95。

**iMac 上的脚本：** 照 `pwe-imac-check.command` 的做法，新写 `pwe-imac-perf.command`，双击即跑：
1. 用 `TB_RECEIVER_TRACE=1 TB_RECEIVER_RENDER_DRIVER=opengl` 启动接收端，等 `[dec]` 出现。
2. 采 90 秒：接收端 stderr；`top` 采接收端和 WindowServer；每 2 秒一次 `ioreg -r -c IOAccelerator` 的 Device Utilization %。
3. 换成 Metal 路径重启，重复第 2 步。
4. 把两段结果放进同一个带时间戳的文件夹，另加机型、系统、`VTIsHardwareDecodeSupported(HEVC)` 的结果。

两次的内容必须一样：发送端开 60 帧滚动测试页，再用小脚本让指针按固定圆周以 120 Hz 走 30 秒。

**240 fps 慢动作（Lee）：** 镜像模式，iPhone 同时拍 MacBook 屏和 iMac。
- 延迟：快速甩动指针 10 次，数两边起动差几帧，每帧 4.17 ms。
- 顺滑：拖窗口横穿 iMac，数每张画面停几帧（60 Hz 理想是每 4 帧换一次；出现 8 帧就是停了一拍）。
- 四组对照：A = GL 5K 48；B = GL 5K 60；C = Metal 5K 60；D = C + 本地指针。

**通过标准：** PLAN-1.1 表里的两条（CPU 不高于 OpenGL；5K 60 帧率不低于 OpenGL），再加三条：被替换 + 重复 ≤ 1%；到达 → 上屏 p95 ≤ 解码 p95 + 一个刷新周期；Lee 主观不再觉得卡。

## 6. 1.1 建议的顺序

| 步 | 内容 | 工作量 | 风险 | 上游 |
|---|---|---|---|---|
| 0 | 计时日志 + `pwe-imac-perf.command`；用 (a) 的环境变量和 5K 48/60 量出基线 | 0.5–1 天 | 低 | 计时日志提 PR（对上游也有用） |
| 1 | Metal 零拷贝 + 按刷新率画 + OpenGL 回退；修 `decoder.c` 头注释 | 3–4 天 | 中：Tahoe 闪屏、IOSurface 兼容键、颜色一致 | 提 PR，登记 `PATCHES.md` |
| 2 | 本地指针：图像包、事件驱动位置、镜像黑边、隐藏判断、开关 | 2–3 天 | 中：拖动时指针领先窗口；隐藏光标判断 | 收发两端一起提 PR |
| 3（可选） | 解码移到工作线程 | 1–2 天 | 中：线程安全 | 视第 1 步的数据再定 |

- 第 1、2 步都改 `display.c`、`main.c`，和计划里的 F（网络）排队，规则照 PLAN-1.1 第 23 行。
- 这些都是逻辑改动，不能用 `rebrand.py`（它只在打包时改文字）。上游不收时，在 `PATCHES.md` 写明原因和 PWE 是否保留。
- 默认 5K 60（PLAN-1.1 已列）应与第 1 步同时上：48 帧在 60 Hz 面板上的抖动，渲染器换什么都去不掉。

## 资料

- SDL 2.32.10：`src/render/metal/SDL_render_metal.m`、`src/render/opengl/SDL_render_gl.c`、`src/render/SDL_render.c`（github.com/libsdl-org/SDL，tag `release-2.32.10`，与本机构建缓存逐字节相同）。
- FFmpeg n9.0.2：`libavcodec/videotoolbox.c`（github.com/FFmpeg/FFmpeg）。
- Apple：CVMetalTextureCache、CVMetalTextureCacheCreateTextureFromImage；CAMetalLayer `displaySyncEnabled`、`maximumDrawableCount`；MTLDrawable `addPresentedHandler`、`presentedTime`；CGLTexImageIOSurface2D；SCStreamConfiguration `showsCursor`；NSCursor `currentSystem`（developer.apple.com/documentation）。Metal Feature Set Tables（developer.apple.com/metal）。
- Apple 支持文章：macOS Big Sur / Monterey / Ventura 兼容机型（support.apple.com）。
- 本仓库：`docs/pwe/BASELINE-iMac18,3.md`、`docs/pwe/PLAN-1.1-2026-10-19.md`；上游提交 03299cb（强制 OpenGL 的原因）。
