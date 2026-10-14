# PWE iMac Display — 交接

> 状态（2026-10-14）：仓库已建，还没有 PWE 自己的代码。
> 仓库：`kenshinice-ai/pwe-imac-display`，公开，是 `swellweb/targetBridge` 的 fork。`main` 从上游 3.6.0 起。
> 方向（Lee，2026-10-14）：做 TargetBridge 的下游发行版，同时给上游贡献。理由和规矩见 `docs/pwe/RESEARCH-TargetBridge.md`。
> 本文件和 `docs/pwe/` 是 PWE 加的；其余文件来自上游，改动先提给上游。
> 第五节是定方向前的旧路线，待按下游发行版重写。

## 等 Lee

- **[动手] 阶段 0：在 iMac 上试用 TargetBridge 3.6.0 一天** — 按它 README 装发送端和接收端，用 Thunderbolt 线连上，记下每个卡点（安装、权限、找不到设备、画质、延迟、睡眠）；系统低于 macOS 14 就顺便复现 #167 · 不做则中文指南和老系统修复都缺真机依据 · 自 2026-10-14
- **[给料] iMac 的确切型号和系统** — 关于本机里的型号标识（如 iMac18,3）、显卡、现在的 macOS 版本，以及手边有没有 40 Gbps 的 Thunderbolt 3 线 · 不给则选不了接收端的最低系统版本 · 自 2026-10-14
- **[决定] 中文做到哪一步** — 推荐先做界面重译和用户安装指南，教程片等真机跑通再定 · 不定则第一个上游 PR（中文重译）范围不清 · 自 2026-10-14
- **[动手] 首次公开发版前给上游维护者写信** — 推荐由 Claude 起草、Lee 发送 · 不发则不发版 · 自 2026-10-14

## 仓库规矩

- 远端：`origin` 是 `kenshinice-ai/pwe-imac-display`，`upstream` 是 `swellweb/targetBridge`。
- 跟进上游：`git fetch upstream`，再把上游的发版提交合并进 `main`。成功判据：`git diff <上游标签> main` 只列出 PWE 加的文件。
- 给上游的 PR：从 `upstream/main` 开分支，推到 `origin`，再向 `swellweb/targetBridge` 开 PR。

> ⚠️ 不要执行 `git push --tags`，也不要推送任何 `v*` 标签。否则上游的 `release.yml` 会在本仓库发出 TargetBridge 的版本。
> 原因：本地有上游全部 `v*` 标签，而 `release.yml` 由 `v*` 标签触发。

> ⚠️ 不要在本仓库的 Actions 页面启用工作流，等 PWE 自己的发版流程写好再说。否则上游的 CI 和发版工作流会在本仓库运行。
> 2026-10-14 实测：fork 后没有任何运行记录。

---

## 一、这是什么

一句话：让 2014–2017 年的 5K iMac 不刷机、不装 Linux、不拆机，插一根线就当 Apple 芯片 Mac 的 5K 外接屏。

发送端是 Mac 上的一个菜单栏 app：建一块虚拟屏，抓画面，编码，经 Thunderbolt 桥接发出去。
接收端是 iMac 上的一个 app：解码，全屏显示，并把亮度键对到 iMac 的背光。

## 二、为什么单独开，不进 Lumen Bar

Lee 2026-10-14 定。理由：

| 方面 | Lumen Bar | iMac Display |
|---|---|---|
| 做的事 | 控制已经接着的屏 | 把一台电脑变成屏 |
| 权限 | 辅助功能和屏幕录制，都可选 | 屏幕录制、本地网络，两台机器都要装 |
| 资源 | 空闲时几乎为零 | 一直占 GPU 编码 |
| 最低系统 | macOS 26 | 接收端要能在 macOS 11–13 上跑 |
| 出错的代价 | 「熄掉的屏一定找得回来」靠进程稳定 | 视频管线最容易崩 |

两者共用品牌、pwestudio.site、发版流程和更新检查（`UpdateCheck` 照三份副本加 `check-shared-sources.py` 的做法）。
代码仓库分开。

**一个已知的交接点**：两个 app 同时开时，F1/F2 会冲突。
- Lumen Bar 会对虚拟屏做软件调暗。那样压暗的是画面，不是 iMac 背光。
- 做法：Lumen Bar 认出 PWE 的虚拟屏（按 `vendorID`），把亮度交给本 app。
- 时机：阶段 2 再做，阶段 1 不碰。

## 三、为什么值得做：缝隙在哪

结论：2014–2017 年的 5K iMac 没有好的原生方案。

- Apple 的目标显示器模式从不支持 5K iMac，Apple 芯片的 Mac 也完全用不了它。
- 2019 年及以后的 iMac 有 Apple 自带的「隔空播放到 Mac」。**未核实**：凭记忆，没查 Apple 支持页。
- TargetBridge 的预编译接收端要 macOS 14，而官方能装 14 的 iMac 正是 2019 年及以后的机型。**未核实**，同上。
  它的 issue 里有 2014 款装不上（#108）、Big Sur 上启动就崩（#167）、2012 款不能镜像（#71）。
  2026-10-14 实测：#108 已并入 #167，根因是打包的 FFmpeg 库按 macOS 14 编。这是打包问题，不是架构问题。
- monitorOS 绕开这个问题的办法是在 iMac 上装 Linux，而且只支持 iMac18,3 一个型号。

## 四、参考项目（2026-10-14 实测）

详细研究见 `docs/pwe/RESEARCH-TargetBridge.md`。

| | TargetBridge | monitorOS |
|---|---|---|
| 仓库 | `swellweb/targetBridge`，MIT | `eriskhan/monitorOS`，MIT |
| 接收端 | C + SDL2 + FFmpeg 的 macOS app；预编译版要 macOS 14（Intel）或 15（Apple 芯片）。源码目标是 macOS 11，卡在打包的 FFmpeg 库（#167） | 在 iMac 上装 Linux（Omarchy），只支持 iMac18,3 |
| 管线 | `CGVirtualDisplay` + ScreenCaptureKit + H.264/HEVC 硬件编码；3.5 起有软件解码后备 | `CGVirtualDisplay` + ScreenCaptureKit + 不压缩的 4:2:2，只发变化区域，要 40 Gbps 线 |
| 规模 | 297 星，5,310 次下载，约 10 位外部贡献者 | 40 星，只有 1 个提交（2026-10-07 创建） |
| 签名 | 没有 Developer ID，README 教用户跑 `xattr -cr`；release.yml 能用持久证书签名，没有公证 | pkg 安装器，要管理员密码，装 CoreAudio 驱动 |
| 维护 | 维护者因健康原因不再亲自写新功能，修复和发版照常：3.6.0 于 2026-10-14 发布；7 个 PR 在等审阅 | 一个人 |
| 亮度 | 发送端菜单可调接收端亮度；没有亮度键 | 亮度键调物理背光，16 档 / 64 档 |
| 虚拟屏身份 | `vendorID = 0xEEEE`（`ReceiverBackedVirtualDisplaySession.swift:120`） | — |

可以参考，也可以在注明出处的前提下复用代码（都是 MIT）。

值得先读的文件：
- TargetBridge `TargetBridge-Sender/TBDisplaySender/ReceiverBackedVirtualDisplaySession.swift`：虚拟屏的身份、HiDPI 模式、色域。
- monitorOS `apps/helper-macos/Sources/CGVirtualDisplayPrivate/include/CGVirtualDisplayPrivate.h`：私有类的头文件。
- monitorOS `apps/helper-macos/Sources/MonitorOSHelper/BrightnessControl.swift`：亮度键（16 档，Shift+Option 64 档）。

`CGVirtualDisplay` 等四个 ObjC 类在 macOS 27.0.1 上存在（2026-10-02 在 Lumen Bar 会话里实测）。
C 函数 `CGVirtualDisplayCreate` 不存在，但用不到它。

## 五、路线

### 阶段 0：观察（Lee，约半天）

见「等 Lee」。

关口：
- 如果 TargetBridge 在这台 iMac 上已经够好，PWE 自己做只剩「签了名、更简单」。那就改为给它贡献 macOS 11 的接收端，不另起产品。
- 如果卡在签名、安装、系统版本或画质上，这些卡点就是阶段 1 的需求。

### 阶段 1：技术探针（iMac 放在桌上，约一周会话，粗估）

1. 发送端：建一块 5K HiDPI 虚拟屏，用 ScreenCaptureKit 抓，用 VideoToolbox 低延迟编码。
2. 接收端：以 macOS 11 为目标，用 AppKit + Metal + VideoToolbox 解码，全屏显示。
3. 传输：Network.framework，走 Thunderbolt 桥接的链路本地地址。
4. 测量：打字和拖窗口的延迟（手机 240 fps 慢动作拍），文字锐度，两端 CPU 和 GPU 占用。

成功判据：在同一套硬件上不比 TargetBridge 差。具体数字先测出 TargetBridge 的基线再定，不预先编。

**最大的技术风险：老 iMac 的硬件解码。**
- 2014 款可能没有 HEVC 硬件解码；2014、2015 款只有 Thunderbolt 2。
- 如果压缩路线撑不住 5K，就改走 monitorOS 那种「不压缩、只发变化区域」。

### 阶段 2：最小产品

只做一件事：插上线，自动扩展成一块 5K 屏。

要做：
- 发送端菜单栏 app 和接收端 app，都用 Developer ID 签名并公证。
- 自动发现、断线重连；按接收端面板自动选模式。
- 亮度键直接调 iMac 背光。
- 与 Lumen Bar 的亮度交接（见第二节）。

不做：镜像、多台接收端、Wi-Fi 和网络传输、键鼠共享、剪贴板、插件系统、编码器选项、Linux 接收端、MacBook 当接收端。

阶段 2 之后再定：iMac 扬声器出声。它要装驱动、要管理员密码，等有人真的要再做。

### 量级

TargetBridge 由一位专职维护者加社区做了 5 个月，至今还有卡顿、颜色、睡眠的 issue 没关。
这条线比 Lumen Bar 重一个数量级，长期成本在用户各式各样的旧硬件上。

## 六、会改变判断的证据

- TargetBridge 在 iMac 2017 上已经很好用：不另做产品，改为贡献。
- 老 iMac 解码撑不起 5K：承诺降到 4K 级，或只支持 2017 款。
- 实测延迟明显差于有线显示器：重新评估是否值得做。

## 七、商业模式

跟 PWE 免费工具一致：免费、开源（MIT，名称和标识保留，同 PWE Monitor 和 Lumen Bar）。
支持走 `https://pwestudio.site/support`，所有免费 PWE 工具共用一页。
