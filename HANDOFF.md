# PWE iMac Display — 交接

> 状态（2026-10-14）：1.0.0 已发布到 GitHub release（标签 `pwe-1.0.0`）和 Homebrew（`kenshinice-ai/tap/pwe-imac-display`）。
> pwestudio.site 产品页冻结中（Lee），方案在 `docs/pwe/SITE-PLAN.md`。还没在真实的 Intel iMac 上试过。
> 仓库：`kenshinice-ai/pwe-imac-display`，公开，是 `swellweb/targetBridge` 的 fork。`main` 从上游 3.6.0 起。
> 方向（Lee，2026-10-14）：PWE 自己签名的 app，同时给上游贡献。下游发行版还是彻底分叉待定。见 `docs/pwe/RESEARCH-TargetBridge.md`。
> PWE 加的只有：本文件、`docs/pwe/`、`pwe/`、`.github/README.md`；删掉的只有上游的 `.github/FUNDING.yml`（Lee）。其余是上游原样，改动先提给上游。
> 改名在打包时对副本做（`pwe/rebrand.py`），所以 `main` 上的上游代码保持原样。

## 等 Lee

- **[动手] 在 iMac 上试 PWE iMac Display 1.0.0** — 接收端装 iMac、发送端装新 Mac，雷雳线连上；记下安装、权限、发现设备、画质、延迟、睡眠的卡点，以及 iMac 型号和系统版本 · 不做则 Intel 真机和 macOS 11 仍无证据，产品页上的「还没在真机上跑过」也撤不掉 · 自 2026-10-14
- **[决定] 解冻 pwestudio.site 产品页** — 方案和文案初稿在 `docs/pwe/SITE-PLAN.md`；同时定字标写法（推荐 `IMAC DISPLAY`）并允许装 fonttools、uharfbuzz · 不定则网站上没有这个产品 · 自 2026-10-14
- **[决定] 下游发行版还是彻底分叉** — 推荐下游发行版；1.0 已按下游方式做（改名在打包时进行），要分叉随时可以 · 不定则不影响现在的工作 · 自 2026-10-14

## 仓库规矩

- 远端：`origin` 是 `kenshinice-ai/pwe-imac-display`，`upstream` 是 `swellweb/targetBridge`。
- 跟进上游：`git fetch upstream`，再把上游的发版提交合并进 `main`。成功判据：`git diff <上游标签> main` 只列出 PWE 加的文件。
- 给上游的 PR：在单独的 worktree 里从 `upstream/main` 开分支（`git worktree add <临时目录> -b <分支> upstream/main`），推到 `origin`，再向 `swellweb/targetBridge` 开 PR。
- 本地打包：运行 `pwe/package.sh`。成功判据：最后一行打印 `pwe/dist/PWE iMac Display <版本>.dmg` 和它的 sha256。
- 发版打包：先提交，再运行 `pwe/package.sh --notarize`。成功判据：输出里 DMG 显示 `source=Notarized Developer ID`。
- 发版：标签用 `pwe-<版本>`（不用 `v`），只推这一个标签；release 上传 `PWE-iMac-Display-<版本>.dmg` 和 `SHA256SUMS.txt`；再改 `homebrew-tap/Casks/pwe-imac-display.rb` 的 `version` 和 `sha256`。成功判据：`gh release download` 回来的文件通过 `shasum -c`，`brew fetch --cask kenshinice-ai/tap/pwe-imac-display` 显示 ✔。
- 如果合并上游后 `pwe/rebrand.py` 报 `upstream text changed`，就按报错改脚本里对应的锚点，不要改上游文件。

> ⚠️ 不要执行 `git push --tags`，也不要推送任何 `v*` 标签。否则上游的 `release.yml` 会在本仓库发出 TargetBridge 的版本。
> 原因：本地有上游全部 `v*` 标签，而 `release.yml` 由 `v*` 标签触发。

> ⚠️ 不要在这个工作区切到上游分支。否则 `pwe/` 会从工作区消失，正在跑的打包和下一次打包都会失败。
> 原因：上游分支没有 `pwe/`；2026-10-14 一次切分支让公证打包中途停下。

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

## 五、1.0 计划（2026-10-14，Lee 定目标）

1.0 只做一件事：插一根线，旧 iMac 就是一块屏。代码是 TargetBridge 3.6.0，加 PWE 这一层。

| 项 | 做法 | 状态 |
|---|---|---|
| 身份 | 发送端 `PWE iMac Display`（`com.pwegroup.pweimacdisplay`），接收端 `PWE iMac Display Receiver`（`com.pwegroup.pweimacdisplay.receiver`），URL scheme `pweimacdisplay://`，配置目录 `PWE iMac Display` | 完成 |
| 互通 | Bonjour 服务 `_targetbridge._tcp` 和传输协议不改，两边可以和 TargetBridge 混用 | 不改 |
| 界面文字 | 所有语言里的 TargetBridge 改成 PWE iMac Display；About 写明基于 TargetBridge | 完成 |
| 语言 | 默认跟随系统语言（上游默认意大利语） | 完成 |
| 默认功能 | Network Link 默认关；键鼠共享维持上游的默认关 | 完成 |
| 接收端 | 自编 FFmpeg 9.0.2（只解码、LGPL）和 SDL2 2.32.10，通用二进制，`minos 11.0` | 完成；arm64 冒烟测试全过，x86_64 未测（本机无 Rosetta） |
| 签名 | Developer ID `2SQV3H5MH9`，hardened runtime，公证用 `PWE_NOTARY` | 完成；2026-10-14 DMG 和两个 App 都显示 `source=Notarized Developer ID` |
| 打包 | 一个 DMG，装两个 App、读我和 `Licenses` | 完成：`pwe/dist/PWE iMac Display 1.0.0.dmg`，7.3 MB，sha256 `2a24e97c…`（2026-10-14，不入库） |
| 文档 | `.github/README.md`（中文）、`docs/pwe/README.en.md`、`pwe/NOTICE.txt` | 完成 |
| 发布 | GitHub release、Homebrew cask、pwestudio.site 产品页 | release 和 cask 完成（2026-10-14，下载回来核对过校验值和公证）；产品页冻结，见 `docs/pwe/SITE-PLAN.md` |
| 中文 | 界面重译（上游 #212）、`docs/pwe/安装指南.md` | 完成；教程片等真机跑通再定（Lee 2026-10-14 按推荐） |
| 上游 | #212 中文、#213 跟随系统语言；两封信 2026-10-14 已用 Lee 的 Gmail 发到 info@swellweb.it | 等回复 |

不进 1.0：App 内更新检查（PWE 的 `UpdateCheck` 要加第四份副本，留到 1.1）、亮度键、扬声器。

## 六、会改变判断的证据

- TargetBridge 在 iMac 2017 上已经很好用：不另做产品，改为贡献。
- 老 iMac 解码撑不起 5K：承诺降到 4K 级，或只支持 2017 款。
- 实测延迟明显差于有线显示器：重新评估是否值得做。

## 七、商业模式

跟 PWE 免费工具一致：免费、开源（MIT，名称和标识保留，同 PWE Monitor 和 Lumen Bar）。
支持走 `https://pwestudio.site/support`，所有免费 PWE 工具共用一页。
