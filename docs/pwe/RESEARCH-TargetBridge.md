# TargetBridge 与 monitorOS 研究，以及「维护 TargetBridge」的思路

> 2026-10-14 实测（克隆两个仓库，读代码、issue、PR、发版记录；用 `gh` 查元数据）。
> 本文是说明文档，不是步骤；待 Lee 定的事在 `HANDOFF.md` 的「等 Lee」。

## 方向（2026-10-14）

已定（Lee）：
- PWE iMac Display 是 PWE 自己的 app：PWE 的名字、bundle ID、Developer ID 签名公证，中文优先。
- 仓库是 `swellweb/targetBridge` 的公开 GitHub fork（`kenshinice-ai/pwe-imac-display`）。
- 同时给上游贡献：先做中文重译。
- 保留 `LICENSE`，在 About、README 和产品页写明「基于 TargetBridge，作者 Marco Caciotti 及贡献者」。
  About 里不放上游的 Sponsors 链接。
- 首次公开发版前，先告诉上游维护者。

待定（Lee）：做**下游发行版**还是**彻底分叉**。对比见第八节。

下面的结论和第四节是定方向前的分析，保留原样。第五节的上游贡献清单仍然有效。

## 结论（决定前）

1. **TargetBridge 没有停。** 今天（2026-10-14）刚发 3.6.0。停下的是维护者亲自写新功能；
   修复和发版仍在走。真正的瓶颈是维护者审阅和发版的带宽：7 个 PR 在等，其中 5 个从
   2026-08-21 起没人回复；Homebrew tap 的 PR 等了 4 个月。
2. **交接文档说的「缝隙」，在 TargetBridge 里只是一个打包问题。** 老 iMac 装不上接收端，
   是因为 Homebrew 编的 FFmpeg 动态库要 macOS 14（#167），接收端自己的代码目标就是 macOS 11。
   社区里已经有人重编 FFmpeg，在 Big Sur 上跑通了。为这个另起一个产品，代价不对等。
3. **推荐：不 fork，不另做，去上游当贡献者，再争取成为共同维护者。** 专攻 PWE 已经会、而它最缺的两件事：
   发版工程（老系统打包、Developer ID 公证、Homebrew cask）和真机测试。
4. **AI 公司的开源扶持，现在 Lee 和 TargetBridge 都不明显达标。** 正确的顺序是先成为有写权限的维护者，
   再用「项目对生态重要」的通道申请。眼下能做的一件好事，是告诉维护者 Marco 他自己可以申请——他已经在用 Codex。
5. **PWE iMac Display 作为独立产品：建议暂停，保留为后备。**（已被上面的决定取代：改做下游发行版。） 留下两件 PWE 自己的小事：
   Lumen Bar 认出 TargetBridge 的虚拟屏；pwestudio.site 上一页「旧 iMac 当外接屏」指南。

---

## 一、TargetBridge 现状（2026-10-14 实测）

| 项 | 数据 |
|---|---|
| 仓库 | `swellweb/targetBridge`，MIT。2026-05-14 创建 |
| 维护者 | Marco Caciotti（GitHub `swellweb`，意大利，本职 Laravel/PHP 和 SEO 工具） |
| 规模 | 297 星，42 fork，276 个提交，约 20,500 行代码 |
| 下载 | 所有版本合计 5,310 次；3.6.0 发布当天 23 次 |
| 发版 | 3.0 → 3.6.0，五个月 15 个左右版本；最近：3.5.1（09-05）、3.5.2（09-14）、3.6.0（10-14） |
| 外部贡献者 | 过去 12 个月合并过 PR 的外部作者约 10 人。主力：ThomasWaldmann（32 个）、Betafer（9）、tiehfood（6）、DrDavidL（5） |
| 开着的 issue | 21 个（含 PR）；其中 issue 14 个 |
| 开着的 PR | 7 个：#208 音量键（10-12）、#201 无损 5K60（09-16）、Betafer 的 5 个草稿（08-21：原生 Metal 渲染器、会话诊断、睡眠修复等） |
| 资助 | GitHub Sponsors（`.github/FUNDING.yml`） |
| AI 使用 | 分支名大量是 `codex/…`，维护者已经在用 Codex 做维护 |

### 架构

- **发送端**：Swift，约 13,000 行。`TBDisplaySenderService.swift` 一个文件就有 3,985 行。
  `CGVirtualDisplay` 建虚拟屏，ScreenCaptureKit 抓画面，VideoToolbox 编 H.264/HEVC。
  虚拟屏的 `vendorID` 固定为 `0xEEEE`（`ReceiverBackedVirtualDisplaySession.swift:120`）。
- **接收端**：C，约 5,000 行，`TBReceiverC/`。**SDL2 开窗口，FFmpeg 解码**（FFmpeg 再调 VideoToolbox），
  解码后回到 CPU 内存再上传给 SDL 的 Metal 纹理。依赖都来自构建机的 Homebrew，用 `dylibbundler` 打进 app。
  `Makefile` 里 `MACOSX_DEPLOYMENT_TARGET ?= 11.0`。
- **传输**：Thunderbolt Bridge 上的 TCP，Bonjour 发现；另有实验性的 Network Link（以太网、Wi-Fi）。
- **测试**：发送端 175 个单元测试，接收端 654 个解析、队列、看门狗检查，加一个不需要第二台 Mac 的回环冒烟测试。
  这个水准不低。

### 3.5–3.6 已经补上的（交接文档写的时候不知道）

- 按接收端面板的真实几何报告分辨率，不再固定报 5K。
- VideoToolbox 解不了时，退回软件解码（老硬件用）。
- 发送端菜单里调接收端的亮度、音量、Night Shift、True Tone。
- 权限助手（屏幕录制、辅助功能、输入监控）。
- 每台接收端可选 H.264 / HEVC / 自动。
- 发送端也有 Intel 版了。

### 还卡着的，按对 PWE 的相关度排

| 卡点 | 证据 | 性质 |
|---|---|---|
| 老系统（macOS 11–13）接收端装不上 | #167（开着），#108 已并入 #167 | **打包问题**。Homebrew 的 `libavutil` 按 macOS 14 编，引用了 macOS 12 才有的 `CVBufferCopyAttachments`。@preggocl 用 macOS 11 目标重编 FFmpeg 后在 Big Sur 跑通 |
| 没有 Developer ID 和公证 | README 教用户跑 `xattr -cr`；`docs/Sender-Signing.md` 明说「这些脚本没有实现公证」 | **发版工程**。release.yml 已经能用持久证书签名，缺 notarytool 和 staple |
| Homebrew 装不了 | #70；tap 仓库 PR #1 从 2026-06-08 开着没合 | **发版工程** |
| 维护者审阅不过来 | 5 个草稿 PR 两个月没回复；#201 作者问「该怎么集成」没人答 | **人手** |
| 颜色不准、P3 | #74（10 条评论）、#61 | 技术 |
| 长时间指针卡顿、连接超时 | #202、#187、#203 | 技术，需要真机 |
| 显示器不睡眠 | #132；草稿 #182、#179 | 技术 |
| 亮度只能在菜单里调，不能用亮度键 | 音量键 PR #208 刚开，亮度键还没人做 | 功能缺口 |

### 一个关键测量（来自 #201）

在 2020 年 5K iMac 上，不压缩的 5K 帧：每帧光是从网络收字节就要 **23.4 ms**（一个核，卡在 TCP 栈里），
再经 PCIe 推给 GPU 要 **12.9 ms**；60 fps 的预算是 16.7 ms。**瓶颈不是线，是接收端的 CPU。**
这直接回答了交接文档的「最大技术风险」：老 iMac 上不压缩的路线也撑不住满帧 5K60，
要么压缩（现在的 H.264/HEVC），要么像 #201 那样在 GPU 上做无损压缩，要么像 monitorOS 那样只发变化区域。

---

## 二、monitorOS 现状（2026-10-14 实测）

| 项 | 数据 |
|---|---|
| 仓库 | `eriskhan/monitorOS`，MIT。2026-10-07 创建 |
| 历史 | **只有 1 个提交**（`v0.1.1`），一个作者 |
| 规模 | 40 星，0 fork，约 11,200 行（Swift + Rust） |
| 接收端 | 在 iMac 上装 Linux（Omarchy + Limine），Rust 守护进程，DRM/KMS 直接驱动面板 |
| 支持 | 只有 iMac18,3（2017 款 27 英寸），测过 Radeon Pro 580X + M3 Pro |
| 唯一的 issue | #1：用户照 README 装不起来，C 文件编译报错，自己改好了 |

它值得学的东西，PWE 都可以按 MIT 注明出处后借用：

- **亮度键**：`BrightnessControl.swift`（1,071 行）+ HUD，F1/F2 16 档、Shift+Option 64 档，接管的是物理背光。
  这正是 TargetBridge 缺的那块（见上表最后一行）。
- **不压缩 4:2:2 + 只发变化区域**：桌面大部分时间只有光标在动，这个思路对老 iMac 的 CPU 瓶颈有效。
- **5K 面板在 Linux 下的拼接扫描**：2017 款 5K 面板是两路 DisplayPort 拼的，它在 Linux 上做通了。
- **iMac 扬声器作为 CoreAudio 输出设备**。

**不建议维护它。** 理由：它的接收端是一套 Linux 设备系统，只支持一个型号，要装驱动、要管理员密码；
只有一个提交，没有社区；这和「插一根线就用」的方向相反。当参考资料用。

---

## 三、交接文档里需要更正的事实

| 交接文档原文 | 2026-10-14 实测 |
|---|---|
| TargetBridge 296 星，约 5,300 次下载 | 297 星，5,310 次下载 |
| 「维护者因健康原因停了新功能」 | 对，但修复和发版照常：3.6.0 今天发布，社区贡献者在写新功能 |
| issue #108（2014 款装不上）为独立问题 | 已关闭，并入 #167；根因是 FFmpeg 库的系统版本，见第一节 |
| 「预编译接收端要 Intel + macOS 14」 | 对。补充：Apple 芯片的接收端要 macOS 15；发送端现在也有 Intel 版 |
| 阶段 2 要做「亮度键直接调 iMac 背光」，好像 TargetBridge 没有 | TargetBridge 能在菜单里调接收端亮度，但不能用亮度键 |
| 「老 iMac 硬件解码」是最大技术风险 | 3.5 已加软件解码后备；#201 测出瓶颈其实在接收端收包的 CPU |

---

## 四、「维护起来」有三种做法

| | A. Fork 一份自己维护 | B. 上游贡献，争取共同维护 | C. PWE 自己做（交接文档原路线） |
|---|---|---|---|
| 做什么 | 以 PWE 名义发一个 TargetBridge 分支 | 给 `swellweb/targetBridge` 提 PR、测试、发版工程 | 从零写发送端和接收端 |
| 用户得到什么 | 两个版本，分不清该装哪个 | 一个更好的 TargetBridge | 第三个选择 |
| 对维护者 | 出现一个竞争版本，用户被分流 | 正好缓解他的瓶颈 | 无关 |
| PWE 的成本 | 接下全部 issue 和旧硬件支持 | 按自己的节奏，挑与 PWE 相关的做 | 最高；交接文档估计比 Lumen Bar 重一个量级 |
| PWE 得到什么 | 品牌曝光，但名声有风险 | 真实的开源履历，维护者身份，申请扶持的资格 | 自己的产品 |
| 退路 | 难回头 | 随时可以停 | 已投入的难收回 |

**推荐 B。** C 的唯一理由是「老 iMac 没有好方案」，而这个缺口在 B 里只是一个打包问题。
A 只在一种情况下才合理：上游真的没人管了，并且维护者同意或把项目交出来。

---

## 五、推荐路线（B）

### 第 0 步：真机试用（交接文档的阶段 0 照旧，内容更新）

在 iMac 上装 3.6.0，记下卡点。比原计划多做两件事：

- 如果这台 iMac 的系统低于 macOS 14，就复现 #167（这正是 PWE 第一个 PR 的依据）。
- 用手机 240 fps 慢动作拍一次打字和拖窗口，作为以后所有改动的延迟基线。

### 第 1 批贡献（按价值和风险排序）

1. **修 #167：让接收端在 macOS 11–13 上能跑。**
   在 CI 里用 `MACOSX_DEPLOYMENT_TARGET=11.0` 自编一份精简 FFmpeg（只要 H.264/HEVC 解码和 VideoToolbox）
   和 SDL2，不再用 Homebrew 的二进制；再加一步检查所有打进 app 的库的 `minos` 都不高于 11.0。
   价值最大：直接打开 2014–2018 年那批 iMac。也最符合 PWE 原来想做的事。
2. **亮度键调接收端背光。** 跟 #208（音量键）同一个形状，可以参考 monitorOS 的 `BrightnessControl.swift`。
   顺便解决交接文档说的 Lumen Bar F1/F2 冲突。
3. **真机测试报告。** 给草稿 #174（原生 Metal 渲染器）和 #201（无损 5K60）在 iMac 上测出数据。
   维护者最缺的不是代码，是真机证据。这件事不写代码，但最容易建立信任。
4. **公证流程。** 给 release.yml 补 `notarytool submit` 和 `stapler staple`。
   证书由谁出是个要 Lee 定的问题（见第七节）。
5. **Homebrew。** 帮 tap 的 PR #1 更新到 3.6.0 并推动合并。PWE 已经有自己的 cask 流程。

### 怎么开口

- 每做一件，先在对应 issue 下说要做什么、打算怎么做，等维护者点头再提 PR。
- PR 小、带测试、照它现有的风格（它有 `docs/Testing.md` 和回环冒烟测试）。
- 不催。维护者在养病；README 里写了。
- 3–5 个 PR 合并后，问能不能帮忙 triage issue。之后再谈写权限和发版权限。

### PWE 自己保留的两件小事

- **Lumen Bar 认出 TargetBridge 的虚拟屏**（`vendorID == 0xEEEE`），不对它做软件调暗，把亮度交给 TargetBridge。
  无论走哪条路都该做，改动小。
- **pwestudio.site 上一页指南**：「把旧 5K iMac 当外接屏」，讲线、转接头、型号、怎么装，链接到 TargetBridge。
  只做介绍，不冒充：它的 README 说品牌和商业使用另行处理。

### 什么时候回到 C（自己做）

任一条成立，就重新评估：

- 上游 6 个月没有发版，也没人回 PR。
- 维护者明确拒绝支持老系统接收端。
- 维护者希望把项目交出去，PWE 愿意接。

---

## 六、AI 公司的开源扶持（2026-10-14 查官方页面）

| 计划 | 给什么 | 条件（满足任一） | TargetBridge / Lee 现在 |
|---|---|---|---|
| [Anthropic · Claude for Open Source](https://claude.com/open-source-max) | 6 个月 Claude Max 20x | 500+ 个依赖仓库或 20 万+ 月下载；知名基金会项目的提交者；12 个月内给别人的仓库合并 100+ PR；**一个仓库 12 个月内有 20+ 位外部贡献者合并过 PR**；OpenSSF 关键度 ≥ 0.4。都不满足也可以申请，说明项目为什么重要 | 不达标。TargetBridge 外部贡献者约 10 人，离 20 还差一半 |
| [OpenAI · Codex for Open Source](https://developers.openai.com/community/codex-for-oss) | 6 个月 ChatGPT Pro + Codex；有条件给 Codex Security；Codex 开源基金的 API 额度 | 核心维护者，或「被广泛使用的公共项目」；没有公开的数字门槛；不满足也可以申请 | Marco 有资格申请，而且他已经在用 Codex |
| [GitHub · Copilot Pro 免费](https://docs.github.com/en/copilot/how-tos/manage-your-account/get-free-access-to-copilot-pro) | Copilot Pro | 「热门开源仓库的维护者」，GitHub 自行判定，每月重审 | 未核实：2026-04-20 起新注册暂停，现在是否恢复没查到 |

几条判断：

- **这些计划给的是个人订阅，不是给项目的钱。** 价值是让维护者能多用 AI 做 triage、初审 PR、写测试。
  Lee 已经有 Claude，对 Lee 个人的边际价值不大；对 Marco 的价值更大。
- **申请时说的每句话都要是真的。** 只有拿到写权限后，才能说自己是 TargetBridge 的维护者。
  在那之前用 PWE 自己的仓库申请，不会过。
- **最实在的「extra help」是告诉 Marco。** 在合适的时候（比如第一个 PR 合并后）留一句：
  OpenAI 和 Anthropic 都有开源维护者计划，项目不达标也可以说明重要性去申请。这对他是真帮助，也不要求 PWE 付出什么。
- **AI 替代不了的是真机。** TargetBridge 的难题都在各式旧硬件上，自动化测试已经很多了；
  缺的是有人拿真 iMac 测。这正是 PWE 手上有的。

---

## 七、风险和要 Lee 定的事

- **签名身份。** 用 PWE 的 Developer ID 签 TargetBridge，等于 PWE 成为它的发行方，对所有用户负责；
  以后换签名会让用户的权限全部重来。推荐：PWE 贡献公证流程，证书由项目自己出
  （Apple 开发者年费 99 美元，可以由 Sponsors 或 PWE 赞助）。只有维护者主动请求，才考虑用 PWE 的。
- **时间。** B 路线的成本是 Lee 的会话时间和一台放在桌上的 iMac。收益是开源履历和一个能用的产品，不是 PWE 的收入。
- **品牌。** 不用 TargetBridge 的名字做 PWE 的产品；指南页只做介绍和链接。
- **巴士因子。** 现在只有 Marco 能发版。PWE 成为共同维护者能降低这个风险，但也意味着 PWE 接下一部分长期责任。

---

## 八、下游发行版与彻底分叉（待 Lee 定）

| | 下游发行版 | 彻底分叉 |
|---|---|---|
| 一句话 | 同一份代码，PWE 只加一层：名字、签名、更新检查、中文文档 | 从 3.6.0 起，代码归 PWE 自己演进 |
| 核心代码的修改 | 先提给上游，合并后再随上游进来 | 直接改，想给上游再挑着提 |
| 跟进上游新版 | 每次合并几分钟，因为 PWE 几乎不碰核心 | 越往后越难合；一段时间后基本只能手工挑修复 |
| 传输协议 | 与上游兼容，两边的发送端和接收端能混用 | 可以自由改，比如为老 iMac 改走「只发变化区域」 |
| 设计和体验 | 受上游的界面和功能取舍限制 | 可以按 PWE 的设计标准重做界面、删掉不需要的功能 |
| 长期成本 | 低；上游修的 bug 免费拿到 | 高；接下全部旧硬件 issue，上游的修复要自己移植 |
| 和上游的关系 | 自然：PWE 是贡献者 | 竞争者；在维护者养病时尤其敏感 |
| 上游停了怎么办 | 自动变成分叉，那时再定 | 不受影响 |

判断：
- 两者不是一次定终身。下游发行版随时可以变成分叉，反过来几乎不可能。
- 真正会逼 PWE 分叉的，是上游不接受、而 PWE 必须要的改动：
  比如界面按 PWE 的设计标准重做，或者传输协议的大改。
- 推荐先做下游发行版，等出现第一个「上游不收、PWE 必须要」的改动，再决定分不分。
