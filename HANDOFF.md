# PWE iMac Display — 交接

> 状态（2026-10-20）：1.0.0 已发布（GitHub 标签 `pwe-1.0.0`，Homebrew `kenshinice-ai/tap/pwe-imac-display`）；2026-10-16 给它的 release 补上了 FFmpeg 源码包。
> 1.0.1（接收端加固 + 附加功能修复）在本地分支 `security-1.0.1`（d4b4598）上，计划 2026-10-22 发布，先过真线测试。发布说明草稿 `docs/pwe/RELEASE-NOTES-1.0.1-draft.md`（不入库）。
> 2026-10-20 给 Marco 发了补充安全报告（回在 10-14 那封的线程里）；他还没回过任何一封安全邮件。他 10-16 把 #212–#216 合进了 `maint-3.6`，3.6.1 候选版是上游 PR #218（不含安全修复）。
> 1.1 在本地分支 `pwe-1.1`（4dea6cf，2026-10-19 集成，2026-10-20 修了冒烟脚本，未推送）：基线问题的修复、菜单栏优先的设置重设计、亮度键、Metal 零拷贝渲染、iMac 自己画指针、配对与加密。
> 接收端 8 组单元测试、发送端 247 个测试、本地无签名打包都通过（2026-10-19，这台 M1）；**全部未在真机上验证**。测试清单 `docs/pwe/TEST-1.1-2026-10-19.md`。
> 方案和决定：`docs/pwe/PLAN-1.1-2026-10-19.md`、`DESIGN-pairing-2026-10-19.md`、`RESEARCH-Metal-2026-10-19.md`（三份都不入库）。
> pwestudio.site 产品页冻结中（Lee），方案在 `docs/pwe/SITE-PLAN.md`。
> 2026-10-19 在真机 iMac18,3（macOS 13.7.8）上做了基线：画面、真 5K（48 和 60 帧）、拔线和睡眠恢复都能用；声音不工作。
> 结果和证据在 `docs/pwe/BASELINE-iMac18,3.md`（未入库），本文件「八」节是摘要。
> 仓库：`kenshinice-ai/pwe-imac-display`，公开，是 `swellweb/targetBridge` 的 fork。`main` 从上游 3.6.0 起。
> 方向（Lee，2026-10-14）：PWE 自己签名的 app，同时给上游贡献。下游发行版还是彻底分叉待定。见 `docs/pwe/RESEARCH-TargetBridge.md`。
> `main` = 上游基线 + `pwe/PATCHES.md` 登记的补丁 + PWE 自己的文件（本文件、`docs/pwe/`、`pwe/`、`.github/README.md`、`.github/SECURITY.md`）。
> 改上游文件之前先提 PR 给上游，再登记进 `pwe/PATCHES.md`。改名在打包时对副本做（`pwe/rebrand.py`），不改仓库里的文件。

## 等 Lee

- **[动手] 在 iMac 上测 1.0.1 和 1.1 的 Developer ID 包** — 按下面「iMac 测试顺序」做；包在 `pwe/dist/local/`（2026-10-20 打，校验值在 `SHA256SUMS.txt`）· 不测则 10-22 发不了 1.0.1，1.1 没有真机证据 · 自 2026-10-19
- **[决定] 2026-10-22 发布 1.0.1 吗** — 推荐：测试顺序第 1–3 步通过就发；Claude 按下面「1.0.1 发布步骤」做 · 不定则加固和声音修复留在本地 · 自 2026-10-15
- **[决定] `docs/pwe/TEST-1.1-2026-10-19.md`「G」节的六件事** — 推荐 E、F 组测完再定；不定则按现在的默认值发 · 不定不卡 1.0.1 · 自 2026-10-19
- **[决定] 解冻 pwestudio.site 并加 `imacdisplay`** — 产品页方案在 `docs/pwe/SITE-PLAN.md`；1.1 的检查更新要在 `functions/_release.js` 加一条 `imacdisplay` · 不定则「检查更新」只会说「已经是最新版本」 · 自 2026-10-14
- **[决定] 本仓库 Sponsor 按钮** — 组规矩 §0.9 要求放 `custom: [pwestudio.site/support]`，并由 Lee 同意打开 Sponsorships 开关；1.1 的「关于」里已有「支持 PWE…」 · 不定则仓库页没有支持入口 · 自 2026-10-15
- **[决定] 下游发行版还是彻底分叉** — 推荐下游发行版；上游已合并我们的 5 个 PR，下游路线走得通 · 不定则不影响现在的工作 · 自 2026-10-14

## iMac 测试顺序（2026-10-20 起，Lee 做）

先测 1.0.1，因为它决定 10-22 能不能发。

1. **装 1.0.1 的接收端。** 按「八」节「升级 iMac 上的接收端」换上 `PWE-iMac-Display-1.0.1.dmg` 里的接收端，再给它重新允许辅助功能和输入监控。成功判据：「关于」里的构建号是 `20261020120408`。
2. **真线连接。** MacBook 装 1.0.1 的发送端，用雷雳线连接。成功判据：几秒内 iMac 出画面。
3. **声音和键鼠共享。** 打开声音和键鼠共享。成功判据：iMac 出声；在 iMac 上能操作 MacBook。
4. **局域网被拒。** 拔掉雷雳线，只留 Wi‑Fi。在 1.0.1 发送端的「接收端」一栏选「手动输入」，填 iMac 的 Wi‑Fi 地址（「系统设置 > Wi‑Fi > 详细信息」里能看到）。成功判据：连不上。这证明 1.0.1 只接受直连。
5. **换成 1.1。** 两边都换成 `PWE-iMac-Display-1.1.0.dmg` 里的 App，按 `docs/pwe/TEST-1.1-2026-10-19.md` 的 A–F 组测。
6. **记结果。** 每一步的结果写进 `docs/pwe/BASELINE-iMac18,3.md`，第 1–4 步的结论写进本文件「八」节。

## 1.0.1 发布步骤（2026-10-22，Claude 做，测试顺序第 1–3 步通过之后）

1. 在 `main` 上合并：`git merge --no-ff security-1.0.1`。成功判据：`git merge-base --is-ancestor security-1.0.1 main` 退出码 0。
2. 把 `docs/pwe/AUDIT-2026-10-15.md` 和 `PLAN-2026-10-15.md` 入库（2026-10-15 定：1.0.1 发布后再入库）。
3. 打标签 `git tag pwe-1.0.1`，在解锁的屏幕上运行 `pwe/package.sh --notarize`。成功判据：DMG 显示 `source=Notarized Developer ID`，`bundle checks passed`。
4. 推送：`git push origin main pwe-1.0.1`。只推这一个标签。
5. 用草稿发 release，上传 `pwe/dist/` 的三个文件。成功判据：`gh release download` 回来的文件通过 `shasum -c`。
6. 改 cask 的 `version` 和 `sha256`。成功判据：`brew fetch --cask kenshinice-ai/tap/pwe-imac-display` 显示 ✔。
7. 写信告诉 Marco 1.0.1 已发布（回在 10-14 那封的线程里）。
8. 接着做下面「1.1 发版前」的第一条。

## 1.1 发版前（Claude 做，不等 Lee）

- 先发 1.0.1，再把 `main` 合进 `pwe-1.1`。成功判据：`git merge-base --is-ancestor security-1.0.1 pwe-1.1` 退出码 0，证明加固进了 1.1。
- `package.sh` 的接收端 make 行合并后要同时带 `DIRECT_LINK_ONLY=1 COMPACT_IDLE=1 OFFER_LOGIN_ITEM=1`。
- cask 的 `zap` 加上 `~/Library/LaunchAgents/com.pwegroup.pweimacdisplay.receiver.plist`。
- 给上游提 PR：发送端「重新打开」按钮只退出不重开（PWE 已在 `rebrand.py` 里修）。
- 基线里发送端的问题已在 `pwe-1.1` 修完（2026-10-19），新 2017 款 iMac 默认 5K 60。等真机复测。
- Lumen Bar 的交接在它自己仓库的分支 `claude/imac-display-handoff-8e14dc`（e27f28a），未合并。和 1.1 一起发。
- 上游 PR 草稿在 `docs/pwe/notes-2026-10-19/upstream-pr*.md`，都没开。配对相关的要等披露之后。#212–#216 已在 2026-10-16 合进上游 `maint-3.6`，上游合并后从 `pwe/PATCHES.md` 里标「已合并」。
- 另一台 MacBook 的 `.claude/worktrees/` 里有两个 iCloud 冲突副本 `tb_trace 2.h`（2026-10-20 发现）。在那台 Mac 上删，不要从这台删。

## 仓库规矩

- 远端：`origin` 是 `kenshinice-ai/pwe-imac-display`，`upstream` 是 `swellweb/targetBridge`。
- 跟进上游：`git fetch upstream`，再把上游的发版提交合并进 `main`。成功判据：`git diff <上游标签> main` 只列出 PWE 加的文件。
- 给上游的 PR：在单独的 worktree 里从 `upstream/main` 开分支（`git worktree add <临时目录> -b <分支> upstream/main`），推到 `origin`，再向 `swellweb/targetBridge` 开 PR。
- 看界面不用截屏：运行打包出的 `PWE iMac Display.app/Contents/MacOS/PWE iMac Display --pwe-snapshot <目录>`，每个状态出一张中英文 PNG；接收端设 `TB_RECEIVER_SNAPSHOT=<文件.png>` 运行。
- 本地打包：运行 `pwe/package.sh`。成功判据：最后打印 `pwe/dist/local/PWE-iMac-Display-<版本>.dmg` 和它的 sha256。正式包只由 `--notarize` 写进 `pwe/dist/`。
- 无签名打包（用户自己换 FFmpeg 重新链接，见 `pwe/NOTICE.txt`）：运行 `pwe/package.sh --unsigned --deps <目录>`。成功判据：同上，App 为 ad hoc 签名。
- 检查成品：挂载 DMG 后运行 `python3 -I pwe/check-bundle.py <两个 App>`。成功判据：打印 `bundle checks passed`。打包时已自动跑一次。
- 发版打包：
  1. 提交，再在本地打标签 `git tag pwe-<版本>`（不推）。
  2. 运行 `pwe/package.sh --notarize`。它要求 HEAD 正好是这个标签。成功判据：输出里 DMG 显示 `source=Notarized Developer ID`。
- 发版：
  1. 只推这一个标签：`git push origin pwe-<版本>`（不用 `v`）。
  2. release 上传 `pwe/dist/` 里的三个文件：`PWE-iMac-Display-<版本>.dmg`、`ffmpeg-9.0.2.tar.xz`（LGPL 要求在同一处提供源代码）、`SHA256SUMS.txt`。
  3. 改 `homebrew-tap/Casks/pwe-imac-display.rb` 的 `version` 和 `sha256`。
  成功判据：`gh release download` 回来的文件通过 `shasum -c`，`brew fetch --cask kenshinice-ai/tap/pwe-imac-display` 显示 ✔。
- 如果合并上游后 `pwe/rebrand.py` 报 `upstream text changed`，就按报错改脚本里对应的锚点，不要改上游文件。

> ⚠️ 不要推送本地分支 `security-1.0.1`，等 Lee 批准或到 2026-10-22。否则发布前就公开了它的内容。
> 原因：按负责任披露的惯例，先给上游维护者一周时间。

> ⚠️ 不要推送 `pwe-1.1`，等 1.0.1 发布、并且 Marco 有时间处理 10-20 的补充报告。否则配对代码会先公开新发现的问题。
> 原因：负责任披露；2026-10-14 起算的 90 天到 2027-01-12。

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
| 接收端 | 自编 FFmpeg 9.0.2（只解码、LGPL）和 SDL2 2.32.10，通用二进制，`minos 11.0` | 完成；冒烟测试 arm64 原生与 x86_64（Rosetta）都全过（2026-10-14，构建 20261014233736）；真机未测 |
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

## 八、2026-10-19 真机基线（摘要）

详细数据和证据：`docs/pwe/BASELINE-iMac18,3.md`。设备：发送端 MacBook Pro M1（macOS 27.2），接收端 iMac18,3（macOS 13.7.8），1.1.0 本地包。

| 项 | 结果 |
|---|---|
| 安装与首次连接 | 通过，不用终端，不绕过安全机制 |
| 真 5K | 默认是 1440p，不是 5K。「Work 5K」= 5120×2880 @ 48；`preset=5k60` = @ 60，Lee 觉得 60 明显更流畅 |
| MacBook 负载（5K 60） | 发送端 CPU 7–14%，GPU 42–51%，不是瓶颈 |
| 只用 iMac 一块屏 | 合盖、不合盖（Lumen Bar 熄内建屏）都能用 |
| 拔线 6 次 | 全部自动恢复，但插回后 22.6–35.8 秒才出画面；5 次先拨了 Wi‑Fi 地址 |
| 睡眠 5 轮 | 画面 1.2–2.8 秒回来；但 Mac 睡不着，3 次是本 App 叫醒的 |
| 声音（修复前） | 不工作：附加功能被判「不兼容」。修复已提交（436247f、d4b4598） |
| 全屏视频的菜单栏和灰边 | 是这台 Mac「全屏也显示菜单栏」的设置，不是本 App |
| iMac 解码（5K 48） | 硬件解码，接收端 CPU 平均 19%，整机平均空闲 85%，有余量 |
| 声音（修复后） | iMac 出声；但 MacBook 也同时响，iMac 稍慢。要加「声音只在 iMac 播放」的选项（Lee 同意） |
| 设置界面 | 分在三个窗口、规则矛盾、术语多。审查和建议结构在 `docs/pwe/UX-REVIEW-2026-10-19.md`（未入库） |
| 未测 | 5K 60 下的 iMac 解码、延迟、两小时办公、1.0.1 过真线、键鼠共享 |

### 在另一台 Mac 上打包

仓库在 iCloud 里，两台 Mac 看到的是同一个 `.git`。

> ⚠️ 不要在两台 Mac 上同时跑 git 或打包。否则 iCloud 会生成「… 2」这样的冲突副本，弄坏 `.git`。
> 原因：iCloud 同步不懂 git 的锁。

1. 等 iCloud 同步完。成功判据：`git log --oneline -1 security-1.0.1` 显示 `d4b4598`，`git log --oneline -1 pwe-1.1` 显示 `8bfcfcf` 或更新。
2. 运行 `security find-identity -v -p codesigning`。成功判据：列出 `Developer ID Application: Li Liu (2SQV3H5MH9)`。
3. 打 1.1 的包前，先在那台 Mac 上运行 `pwe/receiver-deps.sh "$TMPDIR/pwe-imacdisplay-deps"`。成功判据：生成 `universal/lib/libsodium.a`（1.1 起要它，没有它 `package.sh` 会停下）。
4. 切到要打的分支，运行 `pwe/package.sh`。成功判据：最后打印 `pwe/dist/local/PWE-iMac-Display-<版本>.dmg` 和 sha256，`bundle checks passed`。
5. 挂载 DMG，运行 `codesign -dv "<挂载点>/PWE iMac Display.app"`。成功判据：`Authority=Developer ID Application: Li Liu (2SQV3H5MH9)`。
6. 正式发 1.0.1 时按「仓库规矩」的发版打包和发版步骤走（`--notarize`，只推一个标签）。

### 升级 iMac 上的接收端

iMac 开了文件共享。访客登录被拒绝（2026-10-19 实测），要用 iMac 的账号登录。

1. 在 MacBook 的 Finder 里，点侧栏「网络」里的 LL-iMac-2017，点「连接身份」，用 iMac 的账号登录（Lee 输密码）。成功判据：`ls /Volumes` 里出现 iMac 的共享。
2. 把新的「PWE iMac Display Receiver.app」拷到共享里 iMac 用户的「桌面」。
3. 在 iMac 上退出接收端（`⌘Q`）。
4. 在 iMac 上把桌面上的 App 拖进「应用程序」，选「替换」。
5. 在 iMac 上打开接收端。成功判据：发送端几秒内自动连上；「关于」里显示新的构建号。

> ⚠️ 换成别的签名（ad hoc ↔ Developer ID）后，要在 iMac 上重新给接收端授权辅助功能和输入监控。否则键鼠共享不工作。
> 原因：这两项权限绑定 App 的签名。发送端的录屏权限同理。
