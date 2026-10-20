# PWE Screen Encore — 发布与推广方案

> 产品 1.1 起叫 **PWE Screen Encore**（Lee 2026-10-20 定，BRAND 第六节）。旧名 PWE iMac Display 只留在历史记录里；文件名不改。

> 2026-10-20，只出方案：没有发布、没有发帖、没有联系任何人。品牌部分见 `BRAND-iMac-Display-2026-10-20.md`（下称 BRAND）。
> 事实依据：`docs/pwe/BASELINE-iMac18,3.md`、`docs/pwe/ISSUES-test-mac-2026-10-20.md`（两份都不入库）、HANDOFF「八」。每条对外说法都要能回到这几份文件里的一行。

## 结论

- **真正的发布是 1.1，不是 1.0.1。** 1.0.1 安静地发（GitHub release + Homebrew），不做推广：它的主界面还是上游仪表盘，5K 60 只能用命令打开，拔线后要 20 多秒才回来。
- **1.1 的发布有四道门**：真机复测 1.1 的 P1 问题已修；名字已定（PWE Screen Encore，2026-10-20）；pwestudio.site 解冻；对外怎么讲 1.1 先和 Marco 对一遍。四道都过才推。
- **中文先，英文后。** 中文渠道：少数派、V2EX、B 站、小红书。英文渠道：GitHub、r/mac 与 r/iMac、MacRumors 论坛、YouTube。Hacker News 等英文渠道稳定后再考虑；不上 Product Hunt。
- **配对与加密在 1.1 正式发布前不对外提**；发布后怎么讲，先和 Marco 对一遍。演示片里也不出现配对画面，直到那时。

## 一、定位

**一句话**
- 中：旧 iMac，重新做回一块 5K 屏。
- 英：Your old iMac, a 5K display again.

**副句**：一根雷雳线，两个 App。不刷机，不拆机，不装 Linux。免费开源。
One Thunderbolt cable, two apps. No firmware hacks, no teardown, no Linux. Free and open source.

**三条证据（2026-10-20 当天为真，范围写在括号里）**

| # | 说法 | 依据 | 对外写法里必须带的限定 |
|---|---|---|---|
| 1 | 真 5K：5120 × 2880，60 Hz | BASELINE：iMac18,3 上 `native5k60Experimental`，系统里这块屏 60 Hz（2026-10-19、10-20） | 「1.1；在 2017 款 iMac18,3 上实测」。1.0.x 界面里最高 5K 48 Hz。2014、2015 款没测过 |
| 2 | 什么都不改：iMac 还是一台跑自己 macOS 的 Mac，只装一个 App；双击即开，不用终端 | 接收端目标 macOS 11（`minos 11.0`，打包时检查）；Developer ID 签名并经 Apple 公证（1.0.0 起） | 「真机只测过 macOS 13.7.8」。macOS 11、12 上未测 |
| 3 | 免费、开源（MIT），站在 TargetBridge 上，修复先交给上游 | 上游 2026-10-16 把 #212–#216 合进 `maint-3.6`（HANDOFF） | 致谢用 BRAND 2.1 那一句 |

**不说的话**（没有证据或证据不够）：「低延迟」「零延迟」「和原生显示器一样」（延迟没测）；「即插即用」「秒连」（拔线后 22–36 秒，ISSUES T10）；「支持所有 5K iMac」（只测过一台 2017 款）；「省钱 ×× 元」（没有可核实的数字）。

## 二、谁会用

| 人群 | 他们的处境 | 我们对他们说的第一句话 | 主要渠道 |
|---|---|---|---|
| A. 手里有 2014–2017 款 5K iMac、换了 Apple 芯片笔记本的人（中、英） | 屏很好，Mac 太慢；目标显示器模式用不了 | 「把它接到你的新 Mac 上，当一块 5K 屏。」 | 少数派、V2EX、B 站、r/mac、MacRumors |
| B. 二手市场上买卖这几年 iMac 的人（中文为主） | 这批 iMac 二手价低，「能不能当显示器」是常见问题 | 「买之前看一眼型号和雷雳口；当屏用不用拆机。」 | 小红书、B 站、闲鱼话题（只发内容，不挂商品） |
| C. 用 Apple 芯片笔记本、桌上缺一块大屏的人 | 想要 5K 屏，新的太贵 | 「如果你已经有一台旧 iMac，或能低价买到一台……」 | 同 A；不主动去说服没有 iMac 的人买 iMac |
| D. 已经在用 TargetBridge 的人 | 遇到装不上（上游 #167）、没签名、要跑 `xattr` | 「同一个引擎，签好名的一个构建；能连 TargetBridge 原版。」 | GitHub；上游的 issue 里**不主动发**，先问 Marco |

## 三、竞争格局（对上游公道）

| 方案 | 是什么 | 和我们的关系 | 依据 |
|---|---|---|---|
| Apple 目标显示器模式 | 2009 到 2014 年中的非 Retina iMac 可以当外接屏；5K iMac 从来没有 | 我们补的就是这个缺口 | 多家媒体一致（如 9to5Mac 2021-04、MacRumors）；Apple 芯片 Mac 能否作信号源：**未核实** |
| 隔空播放到 Mac | 新一些的 Mac 可以接收隔空播放 | 2014–2017 iMac 不在支持名单里：**未核实**（凭记忆，HANDOFF 三） | — |
| Luna Display（Astropad）Mac-to-Mac | 一个硬件小棒插在副 Mac 上，让它当屏 | 付费硬件；价格各来源不一（2019 年报道 $69.99，2022 年 $134.95），当前价未核实；5K 支持的说法前后不一 | MacRumors 2019-10-17，Astropad 博客 |
| MacDisplay | 付费 App（检索结果写 $29 买断，有限制的免费版），经雷雳、以太网或 Wi‑Fi 把另一台 Mac 当屏 | 最直接的同类。我们的区别：免费开源；是否支持 5K 60、是否支持这几年的 iMac：**未核实** | AlternativeTo / Trustpilot 检索结果，2026-10-20 |
| Air Display、Duet、Sidecar | 主要是把 iPad 当屏；Air Display 也能用 Mac | 不同场景；不点名比较 | — |
| 拆机改驱动板 | 把 5K 面板拆出来配驱动板，变成普通显示器 | 不可逆、要动手；我们不拆机。不贬低，说清差别即可 | 中文二手圈常见；价格未核实 |
| monitorOS | 在 iMac 上装 Linux，只支持 iMac18,3 | 换了 iMac 的系统；我们不换 | HANDOFF 四 |
| **TargetBridge（上游）** | 我们的引擎。Marco Caciotti 与社区的 MIT 项目 | **是来源，不是对手。** 我们的话术是「一个签好名的构建 + 中文 + 老系统接收端」，修复先给上游。不说「比 TargetBridge 好」，不在它的 issue 里拉人 | HANDOFF、RESEARCH-TargetBridge |

**对比表只写我们自己能证明的那一栏。** 别人的栏目只写公开、可链接的事实，写日期；查不到就空着，不猜。

## 四、名字与说法（分语言）

- 名字：**PWE Screen Encore**（BRAND 第六节，2026-10-20 定）。接收端 PWE Screen Encore Receiver。两种语言都不译。
- 指代说法：「for iMac」/「用于 iMac」，不是名字的一部分，也不能比名字醒目。
- 标语：「让 5K iMac 返场。」/ "Your 5K iMac, back on stage."
- 旧名：面向已装用户的地方说一次「原名 PWE iMac Display」（README、release 说明、安装指南），宣传物料里不提。
- 中文：产品名不译；第一次出现带说明语「把 2014–2017 年的 5K iMac 变回一块外接屏」。用词按 BRAND 2.8（Mac 不写 MacBook，雷雳线，扩展 / 镜像）。
- 英文：iMac 按原样大小写；兼容说法用 "for 2014–2017 5K iMac"。
- 两种语言都带同一句致谢（BRAND 2.1）和同一组限定（第一节）。

**标题备选**（发帖时按渠道挑，不需要全用）

| 中文 | 英文 |
|---|---|
| 旧 iMac，重新做回一块 5K 屏 | Your old iMac, a 5K display again |
| 2017 年的 5K iMac，接上 M1 当外接屏：一根雷雳线，不拆机 | A 2017 5K iMac as an external display for an M1 MacBook — one Thunderbolt cable |
| 我把 TargetBridge 签了名、编了 macOS 11 的接收端，还做了中文 | We signed TargetBridge, built a macOS 11 receiver, and translated it |

## 五、渠道（挑过的，不是全部）

| 渠道 | 语言 | 用不用 | 理由 | 形式 |
|---|---|---|---|---|
| pwestudio.site `/screenencore/` | 中英 | 用（解冻后） | 下载、安装指南、PWE Assist 的知识都从这一页来 | 按 `SITE-PLAN.md`，加第一节的限定 |
| GitHub README + release | 中英 | 用 | 开源用户的第一站；release 说明就是更新日志 | README 换成 1.1 的截图和 BRAND 的致谢句 |
| Homebrew（`kenshinice-ai/tap`） | — | 用 | 已有 | 每次发版改 cask |
| 少数派（Matrix 投稿） | 中 | 用 | Mac 重度用户最集中；长文能讲清型号、线材、限定 | 一篇实测长文：Lee 署名，配真机照片 |
| V2EX「分享创造」 | 中 | 用 | 开发者多，愿意试开源工具，会提有用的问题 | 一帖，短，链 GitHub |
| B 站 | 中 | 用 | 演示需要看到 iMac 亮起来，视频最有说服力 | 第七节的片子，横版剪一版 |
| 小红书 | 中 | 用 | B 人群（二手 iMac）集中；图文笔记搜索寿命长 | 3–5 张图：真机照片、型号对照、线材 |
| 微信公众号 / 视频号 | 中 | 只发 PWE 自己的号 | 熟人传播；不买量 | 同少数派文章的短版 |
| r/mac、r/iMac | 英 | 用 | A 人群；「旧 iMac 当屏」是反复出现的问题 | 先读版规里的自我推广条款；用「我们做了一个签名构建」的口吻 |
| MacRumors 论坛 | 英 | 用 | 目标显示器模式的老帖里有大量正在找办法的人 | 只在相关老帖里回一条，说清来历和限定 |
| YouTube（@PWEStudioAU） | 英 | 用 | 片子的英文版有地方放 | 第七节的片子 |
| Hacker News「Show HN」 | 英 | 晚一点，看情况 | 流量大，但第一个问题一定是「这不就是 TargetBridge 吗」。只在：有第二台 iMac 型号的验证、issue 处理得过来、Marco 不介意 | 标题直接写基于 TargetBridge |
| Product Hunt | 英 | 不用 | 受众要的是新产品；这个工具只对手里有特定旧 iMac 的人有用，而且是 fork，会被问来历 | — |
| AlternativeTo | 英 | 顺手 | 有人搜「Luna Display 替代」时能找到；成本低 | 一条条目，写清免费开源、基于 TargetBridge |
| TargetBridge 的 issue 区 | 英 | 不主动 | 在别人的仓库里拉用户不公道 | 只在 Marco 同意后，在 #167 这类「装不上」的帖子里留一句 |

## 六、时间线（跟着版本走）

| 时间 | 版本 | 做什么 | 门槛 |
|---|---|---|---|
| 2026-10-22 起 | 1.0.1 | 按 HANDOFF「1.0.1 发布步骤」发；release 说明写清 1.0.0 没有声音、1.0.1 修了；写清从测试包或 TargetBridge 换过来要重置权限（ISSUES T1）。**不推广** | 测试顺序第 1–3 步通过 |
| 1.0.1 之后，1.1 之前 | — | Lee 定名字；实施 BRAND R1–R9；修 ISSUES 的 P1（T9、T10、T11、T20）；拍真机素材；写少数派长文初稿；站点页按 SITE-PLAN 备好但不上线 | — |
| 1.1 发布当天（日期未定） | 1.1 | 站点页上线；GitHub release；cask；README 换新图 | 四道门：P1 修完并在真机复测；名字已定；站点解冻；对外说法和 Marco 对过 |
| 发布后 1–3 天 | 1.1 | 中文：少数派（投稿要提前几天）、V2EX、B 站、小红书；PWE 公众号 | 片子剪好、Lee 看过 |
| 发布后 4–10 天 | 1.1 | 英文：r/mac、r/iMac、MacRumors、YouTube；AlternativeTo | 第一周的 issue 已分类回复 |
| 发布后 2–4 周 | 1.1.x | 视情况 Show HN | 第五节的三个条件 |

## 七、演示片

照组规矩放在 `Video/film/`：竖版 1080 × 1920，字幕加音乐，不配旁白；工具五件套从 `PWE Loan Bar/Video/tutorial` 逐字复制（`check-film-tools.py` 检查）。中英文一套剪辑表。另剪一版横版给 B 站和 YouTube。

**要讲的一件事**：一台闲着的 5K iMac，插一根线，变成新 Mac 的一块屏。

**拍法**：iMac 上发生的事用相机拍（三脚架、锁曝光、iPhone 4K），Mac 上的界面用 `winrec` 录。屏幕上的东西都是真的，不事后合成；电脑名和 IP 用演示用的名字（例如把 iMac 改名「iMac」），或者在录之前隐去。

| # | 秒 | 画面 | 字幕（中 / 英） | 来源 |
|---|---|---|---|---|
| 1 | 0–4 | 桌上一台熄着屏的 27 寸 iMac，旁边一台 MacBook | 2017 年的 5K 屏，还很好。/ A 2017 5K screen. Still great. | 相机 |
| 2 | 4–8 | 特写：雷雳线插进 MacBook，再插进 iMac 背后 | 一根雷雳线。/ One Thunderbolt cable. | 相机 |
| 3 | 8–12 | iMac 亮起空闲画面：翅膀、「等待 Mac 连接」（R1 实施后再拍） | iMac 上装一个 App。/ One app on the iMac. | 相机 |
| 4 | 12–18 | Mac 上主窗口出现这台 iMac，点「用作显示器」 | Mac 上装一个。/ One on the Mac. | winrec |
| 5 | 18–26 | iMac 出现 Mac 的桌面；把一个窗口从 MacBook 拖到 iMac 上，一镜到底，不剪 | 它现在是一块 5K 屏。/ Now it's a 5K display. | 相机 |
| 6 | 26–32 | 菜单栏放大：「画面」里选 5K · 60 Hz | 5120 × 2880，60 Hz。/ 5120 × 2880 at 60 Hz. | winrec（菜单栏放大，同 Monitor 片子的做法） |
| 7 | 32–38 | 按 MacBook 的亮度键，iMac 背光跟着变 | 亮度键调的是 iMac 的背光。/ Your brightness keys dim the iMac. | 相机 |
| 8 | 38–43 | 静帧字卡，下面一行来源条 | 实测：iMac18,3 · macOS 13.7.8 · 2026-10-19 / Measured on iMac18,3 · macOS 13.7.8 | 字卡 |
| 9 | 43–48 | 片尾：翅膀 + 名字 + 网址；一行致谢 | 免费 · 开源 · 基于 TargetBridge / Free · open source · built on TargetBridge | 字卡 |

- 不拍拔线重连，除非 T10 修好：剪掉等待会让人以为是即时的。
- 不拍配对画面，直到 1.1 发布、对外说法定了。
- 第 7 镜用带物理功能键的 Mac（或 fn + F1/F2）：Touch Bar 机型的亮度条调不了 iMac（ISSUES T20），片子不能暗示它可以。

## 八、看什么数

不在 App 里加任何统计：「不收集数据」是产品的承诺。只看公开、本来就有的数。

| 指标 | 怎么取 | 用来决定什么 |
|---|---|---|
| 每个版本的 DMG 下载次数 | `gh api repos/kenshinice-ai/pwe-imac-display/releases` 的 `download_count` | 各渠道发帖前后对比，决定下一次把力气放在哪 |
| 站点下载 | 站点有没有下载计数：**未核实**（`SITE-PLAN.md` 没写） | 同上 |
| Homebrew 安装量 | 自建 tap 没有 Homebrew 的统计 | 不看 |
| issue：按类型（装不上 / 权限 / 连不上 / 画面 / 声音 / 键鼠）和 iMac 型号分 | 每周分一次类，打标签 | 安装类多 → 改读我和安装指南；某个型号多 → 去找那个型号的真机 |
| 第一次回复用时 | issue 时间线 | 支持负担是不是超过了 Lee 能给的时间 |
| 星标、fork | GitHub | 只看趋势，不当目标 |
| 给上游的 PR 合并数 | 上游仓库 | 和上游的关系是不是健康 |

不设下载量目标：没有基线，任何数字都是编的。第一个月的数就是基线。

## 九、风险

| 风险 | 会怎样 | 怎么减 |
|---|---|---|
| 支持量 | 硬件组合多（三代 iMac、雷雳 2 转换器、macOS 11–13、Touch Bar），一篇帖子就能带来一批「连不上」 | 发布前把安装指南的排错一节写满（权限重置 T1、转换器、型号表）；issue 模板要求填型号、系统、线；每周集中处理一次，不承诺时效 |
| 只测过一台 iMac | 2014、2015 款出问题，口碑先坏在第一周 | 所有对外说法带第一节的限定；发布前找一台 2014 或 2015 款验证；找不到就在页面上写「未测」 |
| 拔线后要等 20 多秒（T10） | 用户以为坏了 | 1.1 发布前修；修不好就在安装指南写明，并让界面显示「正在等 iMac 回来」 |
| 和上游的关系 | 被看成「拿了别人的代码换个名字推广」；或让 Marco 难做 | 每份物料带同一句致谢；修复先交上游；不在上游 issue 区拉人；1.1 的对外说法先给 Marco 看；版本说明里列出给上游的 PR |
| 名字 | 「iMac」在产品名里，宣传越响风险越大 | 已改名 PWE Screen Encore（2026-10-20）；物料只用「for iMac」指代 |
| 说多了 | 一句「零延迟」就会被测出来 | 第一节「不说的话」；每条说法回到 BASELINE 的一行 |
| 配对与加密说早了 | 打乱和上游约好的节奏 | 1.1 正式发布前不提；之后的说法先和 Marco 对 |
| 声音两边都响、键鼠共享的边缘问题（T30） | 被当成主要功能来试 | 宣传只讲画面、亮度、声音在 iMac 播放；键鼠共享标「实验性」，不进片子 |

## 十、物料清单

| 物料 | 状态 | 谁做 |
|---|---|---|
| 名字决定 | 已定：PWE Screen Encore（2026-10-20），代码和文档已改（分支 `pwe-1.1-rename`） | — |
| 1.1 的界面和接收端品牌化（BRAND R1–R9） | 规格已写 | Claude |
| 图标一对（BRAND R6） | 提案已出，等 Lee | Lee 定，Claude 做 |
| DMG 窗口、读我 | 已做（`pwe/brand/dmg/`） | — |
| 真机照片：iMac 当屏用的桌面，正面、侧面、线 | 没有 | Lee 拍（不能用别人的照片，不用 AI 图冒充实拍） |
| 演示片（竖版 + 横版，中英） | 没有；第七节是分镜 | Claude 搭工程，Lee 拍相机镜头 |
| 站点页 `/screenencore/` | 方案在 `SITE-PLAN.md`，冻结中 | 解冻后 Claude |
| GitHub 社交预览图（1280 × 640） | 没有 | Claude（用品牌资产，无实拍时不放「效果图」） |
| README 中英新截图 | 没有 | Claude（`--pwe-snapshot`） |
| 安装指南排错一节、型号与线材表 | 部分有（`安装指南.md`） | Claude |
| 1.0.1、1.1 的 release 说明 | 1.0.1 有草稿 | Claude |
| 少数派长文、V2EX 帖、小红书图文、Reddit 帖 | 没有 | Claude 起草，Lee 定稿发 |
| 给 Marco 的一封：1.1 的对外说法 | 没有 | Claude 起草，Lee 发 |
| issue 模板（型号、系统、线、日志） | 没有 | Claude |

## 等 Lee 定

- **[决定] 1.1 的推广按本方案的四道门和时间线走吗** — 推荐：走；1.0.1 不推广 · 不定则不影响 1.0.1 发布 · 自 2026-10-20
- **[给料] 真机照片和相机镜头** — 推荐：R1 实施后一次拍完（第七节 1、2、3、5、7 镜和桌面照片） · 不给则片子和小红书都做不了 · 自 2026-10-20
