# PWE Screen Encore — 品牌规范与落地清单

> 产品 1.1 起叫 **PWE Screen Encore**（Lee 2026-10-20 定，见第六节）。本文件名和下文的历史记录保留旧名 PWE iMac Display。

> 2026-10-20，分支 `pwe-1.1-brand`（从 `pwe-1.1-simplify` 5686aa2 开出）。
> 上位标准：`00 PLANNING 2026/08-品牌识别标准.md` v2.6（下称「08」）。本文件只记录**这个产品**的决定和它与 08 的每一处偏离；冲突时以 08 为准。
> 这一轮只动了 `pwe/brand/`、`pwe/package.sh` 的磁盘映像一段、`pwe/read-me-first.txt` 和本文件。界面和接收端的改动写成第三节的规格，由主会话在合并后实施。

## 结论

1. **接收端画面是最显眼的表面，也是最不像 PWE 的表面。** 27 寸屏上铺的是上游的冷灰底、TargetBridge 绿、Helvetica、全大写英文标签；连接中还多一张卡片和一个绿色「接收端」字样。改成夜色底、静止的纸色翅膀、系统字体，绿色全部拿掉（规格 R1–R3）。
2. **菜单栏图标在两个状态之间换了一个物体**（未连接是 `display` 显示器，连接后是 `desktopcomputer` iMac），而且未连接时和系统「显示器」菜单、PWE Lumen Bar 的字形都撞。已做好一套自己的模板字形：同一台 iMac，连上时屏幕亮起（R4）。
3. **两个 App 用同一个图标**，DMG 里并排放着，用户要靠名字分辨哪个装在哪台电脑上——这是装错的最大来源。DMG 窗口已经改好（两台电脑的示意 + 一根线）；图标已改成一对：琥珀框发送端、纸色框接收端（R6，Lee 2026-10-20 同意，已做）。
4. **图标里的屏幕是一块 3:2 的通用显示器，没有 iMac 的下巴**，代码注释写着 "screen, chin and stand"，画出来却没有下巴。而且这个外框是 08 §4.6 名单之外的「第二图形」，没有登记。已改成 16:9 屏 + 下巴 + 底座（R6，已做）；登记进 08 §4.6 的措辞见 2.4，等 Lee 写进 08。
5. **产品名里有「iMac」。** Apple 的商标指南明文不许第三方在产品名里使用 iMac（见第六节）。**已定（2026-10-20）：改名 PWE Screen Encore**，「for iMac」「用于 iMac」只作指代说法。

## 一、审计：用户看得见的每一处

2026-10-20 实查：发送端用 `ui/snap-simplified/`（5686aa2 的 `--pwe-snapshot`），接收端用这次在离屏渲染器里跑的 1.1 代码（已过 `rebrand.py`，所以文字是改名后的），DMG 挂载了 `pwe/dist/local/PWE-iMac-Display-1.1.0.dmg`。

| 表面 | 现在 | 问题 | 处理 | 影响 |
|---|---|---|---|---|
| iMac 上的空闲画面 | 冷灰 `#0F1217` 底；中间是 App 图标（夜色方块浮在另一种深色上）；页脚带 IP | 底色不是品牌夜色；方块像贴纸；IP 在日常画面上是工程噪音 | R1：夜色底、静止纸色翅膀、IP 移到详情 | 高：27 寸、天天看见 |
| iMac 上的配对码 | 54 号 Menlo 粗体，TargetBridge 绿 `#6EED99` | 绿色在 PWE 里没有含义 | R1：纸色、系统字体等宽数字、分两组 | 高 |
| iMac 上的「连接中」 | 圆角卡片 + 绿色等宽「接收端 / RECEIVER」+ 绿色转圈；图标位置比空闲时高 36 单位 | 状态一换，整块内容跳一下；卡片和角色字是多余的（用户就站在 iMac 前） | R1：和空闲同一个版式，只换两行字；转圈用 `label-3` | 高 |
| iMac 上的详情（按 I） | 上游仪表盘配色，绿色 IP，英文标签全大写（`STATUS`、`IP THUNDERBOLT BRIDGE`），说明里叫人「在 MacBook 上填入 IP 地址」 | 说明是上游手动填 IP 的流程，PWE 是自动发现；全大写不是 PWE 的强调方式（08 §7.2：靠字重） | R1、R2 | 中 |
| 接收端字体 | 英文 Helvetica / Menlo，中文苹方 | 08 §7.2：界面用系统字体；数字等宽 | R3 | 中 |
| 接收端措辞 | 「正在连接你的 MacBook」「开机自动打开」 | 发送端可能是 Mac mini / Studio；macOS 的词是「登录时打开」，发送端也这么写 | R2 | 中 |
| 菜单栏图标 | SF Symbols `display` ↔ `desktopcomputer` | 换物体；未连接时和系统「显示器」、Lumen Bar 撞 | R4：`pwe/brand/menubar/` 两个模板字形 | 高：每天都看 |
| App 图标（发送端） | 夜色底、琥珀翅膀（线稿）、琥珀 3:2 外框 + 颈 | 不像 iMac（没下巴、比例不对）；第二图形未登记 | R6，已做 | 中 |
| App 图标（接收端） | 与发送端同一个 | DMG、iMac 的程序坞里分不出两端 | R6，已做：纸色框 | 中 |
| 主窗口页头 | 40 pt App 图标 + 名字 + ⓘ | 没问题 | 不改 | — |
| 主窗口第一次连接的提示 | 「以后在菜单栏的 [desktopcomputer] 里调…」 | 内嵌字形要和菜单栏一致 | R4 一并改 | 低 |
| 关于 | 图标、版本、致谢、源代码、支持 PWE…、检查更新 | 没有署名行，没有版权行（Lumen Bar 有） | R7 | 低 |
| 设置 › 高级 › 完整控制台 | 「TargetBridge 自己的控制台，包含引擎的全部设置。」窗口标题「完整控制台」 | 名字可以留；说明要讲清它长得不一样、改动会覆盖这里 | R8：只改说明 | 低 |
| 亮度提示框（HUD） | 仿系统 HUD，系统材质、`sun.max.fill` | 这是系统级控件，本来就该像系统 | 不改 | — |
| 警告色 | 主窗口和设置里 `.orange`，部分 `exclamationmark.triangle` 用 `.yellow` | 同一种警告两种颜色 | R9 | 低 |
| 通知 | 没有 | — | — | — |
| 虚拟显示器名字 | 「PWE Screen Encore」（1.0.x 是「TB Extend - iMac」，1.1 改名前的测试版是「PWE iMac Display」） | 没问题 | 不改 | — |
| Info.plist 版权 | `PWE Group. Based on TargetBridge (MIT).` | 和 Lumen Bar 的 `© 2026 PWE Group Pty Ltd` 写法不一致 | R7 | 低 |
| DMG 窗口 | 没有 `.DS_Store`：Finder 默认排列，没有背景，卷图标是默认磁盘 | 两个 App 并排、看不出哪个去哪台电脑 | **已做**：背景、位置、卷图标（第四节） | 高：第一印象 |
| DMG 读我 | 中英文步骤 | 缺「不是 TargetBridge 官方版本」和署名行 | **已做** | 低 |
| Finder 里的名字 | `PWE Screen Encore.app` / `PWE Screen Encore Receiver.app` | 已按第六节改名 | **已做** | — |
| 工具站字标方案 | `SITE-PLAN.md` 推荐 `IMAC DISPLAY` 全大写 | Apple 要求按原样大小写书写其商标 | R10 | 低（页面还冻结） |
| 上游痕迹 | Sponsors 链接、TargetBridge 字样 | 已查：界面、语言包、接收端里都没有 Sponsors 链接；致谢只在关于和完整控制台说明里 | 不改 | — |

## 二、品牌卡

### 2.1 名字、中文、署名

- 产品名：**PWE Screen Encore**（第六节，2026-10-20 定）。接收端：**PWE Screen Encore Receiver**，中文界面里也这么叫（产品名不译）；界面泛指时仍说「接收端」。
- 指代说法（不是名字的一部分）：「for iMac」/「用于 iMac」，只在帮得上忙的地方用：关于窗口的副标、README 第一行、DMG 读我。
- 标语：「让 5K iMac 返场。」/ "Your 5K iMac, back on stage."
- 旧名 PWE iMac Display 只出现在历史记录和「装过旧版」的提示里。为了已装的用户，这些标识不改：bundle id `com.pwegroup.pweimacdisplay(.receiver)`、URL scheme `pweimacdisplay://`、Application Support 下的设置目录、Bonjour 服务类型、握手协议常量。
- **不起中文名。** 08 §2、§8：产品名不译，像 iPhone 一样。中文文案第一次出现时带一个说明语，不是名字：「PWE Screen Encore，把 2014–2017 年的 5K iMac 变回一块外接屏」。不写「天域 iMac 屏」之类——「天域」是房子的名字，不进产品名。
- 署名行：`PWE · 天域出品`，两种语言都印整行（与 Lumen Bar 一致）。版权行写法律主体：`© 2026 PWE Group Pty Ltd`。
- 署名和致谢（固定说法，所有对外物料一样；Lee 2026-10-29 定 PWE Group 为主）：
  - 主行：「由 PWE Group 构建并签名。」英文："Built and signed by PWE Group."
  - 小字：「基于开源项目 TargetBridge（Marco Caciotti 与社区，MIT），不是 TargetBridge 的官方版本。」英文："Based on TargetBridge by Marco Caciotti and its community (MIT); not an official TargetBridge release."
  - 界面里小字用更小一号、次要颜色；纯文本里主行在前、小字另起一行。
- 不放上游的 Sponsors 链接。支持入口只有「关于」里的「支持 PWE…」（07 TOOLS HANDOFF §0.9）。

### 2.2 颜色（全部来自 `armature.json`）

| 用在哪 | token | 值 |
|---|---|---|
| 接收端画面的地 | `night` | `#0E1729` |
| 接收端详情的卡片 | `night-2` | `#16233D` |
| 接收端主文字、翅膀 | dark `label` | `#F7F5F2` |
| 接收端次级文字、页脚 | dark `label-2` | `#F7F5F2` 66% |
| 接收端转圈、分隔 | dark `label-3` / `line` | 40% / 12%（非文字色） |
| 接收端「需要你看」的一行（如未加密） | dark `signal` | `#F5B335` |
| 接收端出错（如被拒绝、读不到钥匙串） | dark `alert` | `#E8654E` |
| 图标的地 / 发送端外框与翅膀 | `night` / `signal-strong` | `#0E1729` / `#F5B335`（深底，合法） |
| DMG 背景 / 示意线 | light `ground` / `label-3` | `#F7F5F2` / 墨 36% |
| 发送端界面 | 系统颜色与用户的强调色 | 不用品牌色（同 Lumen Bar BRANDING §五） |

- **绿色不是 PWE 的颜色。** 接收端里 TargetBridge 的绿（IP、配对码、角色字、转圈）全部拿掉。发送端「已连接」的绿勾是系统 `.green`，保留：那是 macOS 的语言。
- 琥珀在这个产品里只有三处：图标、接收端「需要你看」的那一行、（发送端）系统橙色的警告——后者是系统色不是品牌琥珀。

### 2.3 字体

- 两端都用系统字体。接收端是 C 代码，用 `CTFontCreateUIFontForLanguage(kCTFontUIFontSystem / kCTFontUIFontEmphasizedSystem, …)`；中文由 Core Text 自动落到苹方（08 §8 实测结论），不另写字体名。
- 数字一律等宽（`kNumberSpacingType` / `kMonospacedNumbersSelector`）：配对码、IP、版本号。IP 不再用 Menlo。
- 强调靠字重，不靠全大写和字距（08 §7.2）。英文标签用句首大写。
- 字号走 08 §7.2 的表，单位是 `display.c` 的 u（= 短边 / 720；2560×1440 的画面 1 u = 2 pt）：名字 28（title1），状态 22（title2），配对码 34（large title），说明 15（subhead），页脚 12（caption）。

### 2.4 图标家族（Lee 2026-10-20 同意，已做）

- 一对图标，同一副骨架：夜色圆角方块（与已发布的 Loan Bar、Monitor、AI Bar、Lumen Bar 同一块地），线稿翅膀放在一台 2014–2017 款 27 寸 iMac 的正面轮廓里。
  - **发送端**：外框、下巴、底座都是琥珀。琥珀是信号，发送端发出画面。
  - **接收端**：外框换成纸色 `#F7F5F2`，翅膀仍是琥珀。纸色框就是被点亮的那台 iMac。
- 骨架数值（板宽 P = 画布 × 0.83，与现在相同）：机身宽 0.80 P，机身高 = 宽 × 450/650，描边 0.024 P，圆角 0.045 P；下巴占机身高 19%，画一条与描边同粗的横线；底座梯形上宽 0.12 P、下宽 0.17 P、高 0.07 P；整组垂直居中再上移 0.01 P；翅膀宽 = 机身宽 × 0.66，在下巴以上的屏幕区里居中。
- 翅膀仍用线稿（与已发布的四个兄弟一致）。v2 的实心档要整组迁移，不由这个产品单独先走。
- 生成：`pwe/icon/main.swift`（`drawAppIcon(in:side:frame:)`），输出 `pwe/assets/`（发送端：`AppIcon.appiconset`、`AppIcon.iconset`、`icon_1024.png`）和 `pwe/assets/receiver/`（接收端：`AppIcon.iconset`、`icon_1024.png`）。磁盘映像的卷图标和 README 仍用发送端那一份。颜色按 sRGB 画，PNG 里的像素就是 token 值（2026-10-20 实测 `#0E1729`、`#F5B335`、`#F7F5F2`；以前用 Generic RGB，夜色画成了 `#101F36`）。
- 小尺寸：所有边落在整像素上，线至少 1 px（128 px 时描边取整为 3 px）。32 px 屏、下巴、底座都清楚。16 px 时下巴横线和机身底边并成一条 2 px 的实条，读作实心下巴；翅膀只剩一道琥珀斜线（08 §4.6：16 px 只能读整体色）。两端在 16 px 靠框色分得开。
- **偏离 08 §4.6「不加第二个图形」**：iMac 外框是这个产品本身，理由和 Receipts 的票面相同。Lee 2026-10-20 同意了图标；08 本身还没改，建议 Lee 照下面的措辞写进去：
  - §4.6 第一段改为：「……**不加文字、不加第二个图形**（有名有姓的例外只有三个：Studio 的星火、Receipts 的票面、iMac Display 的 iMac 框，见下表）。」
  - 表里加一行：「| PWE iMac Display（发送端 / 接收端） | 夜 | 琥珀线稿翼，是一台 2014–2017 款 27 寸 iMac 正面轮廓里的画面：16:9 屏、下巴、底座。框色分两端：发送端 `--signal-strong`，接收端纸 `#F7F5F2`；翼宽 = 机身宽 × 0.66。数值见 `PWE iMac Display/docs/pwe/BRAND-iMac-Display-2026-10-20.md` 2.4 |」
  - 修订记录加一行：「2026-10-20 v2.7：**iMac Display 图标加 iMac 框**（Lee 拍板；§4.6）——第三个带第二图形的图标，因为让旧 iMac 当显示器就是这个产品本身。一对图标同一副骨架，只换框色区分发送端和接收端；翼仍是线稿，与已发布的四个夜底兄弟一致。」
- 不选纸底接收端图标（预览里的「备选」）：它在 iMac 自己的程序坞里是一块亮方块，16 px 时在浅色背景上几乎消失。
- 预览：提案 `pwe/brand/preview/icon-before-after.png`；落地后的前后对比 `pwe/brand/preview/icon-pair-final.png`（256 / 128 / 64 / 32 / 16 px，浅深两种背景，16 px 放大 6 倍、32 px 放大 3 倍，取自实际输出的 PNG）。

### 2.5 菜单栏字形（已做）

- 文件：`pwe/brand/menubar/PWEMenuBarReady.imageset`、`PWEMenuBarShowing.imageset`（矢量 PDF，模板渲染），预览 PNG 在 `menubar/png/`。
- 一个物体，两种状态：**可以连接**是 iMac 的轮廓（屏幕空着，下巴实心）；**正在用作显示器**是同一台 iMac，屏幕亮起（内缩 1 pt 的实心面）。不再换成另一个物体。
- 18 pt 画布，字形 16 × 14 pt，外框 1 pt，下巴 2 pt；外框的边都落在整点上，1x、2x 都清楚。重量和系统的 Wi‑Fi、电池字形对齐（`preview/menubar.png`，浅深两种菜单栏，旁边放了现在用的两个 SF Symbols 作对照）。
- 不放翅膀：22 px 以下翅膀只剩一团（08 §4.4），而菜单栏图标的职责是认出功能，不是身份（与 Lumen Bar BRANDING §四 同理）。
- 未连接时仍由代码设 `appearsDisabled`，由系统调淡。

### 2.6 接收端画面（提案）

一个版式，四种状态，只换中间两三行字，翅膀和名字不动——状态切换时画面不跳（Apple 的空间一致性）。

| 元素 | 位置（C = 画面竖直中线，u 见 2.3） | 样式 |
|---|---|---|
| 翅膀 | 顶边 C − 190 u，宽 144 u（高 89 u），水平居中 | 实心档（08 §4.1：屏幕、hero 尺寸），`label` 单色，静止 |
| 名字 | 基线 C − 24 u | 28 u，半粗，`label` |
| 第一行 | 基线 C + 26 u | 空闲 / 连接中：状态，22 u 常规，`label`；配对：配对码 34 u 半粗等宽，`label`，三位一组，组间一个 en 空 |
| 第二行 | 基线 C + 56 u（配对时 C + 70 u） | 15 u，`label-2`；配对时这一行是「在 Mac 上输入这 6 位数字」，17 u，`label` |
| 第三行 | 基线 C + 94 u | 配对：「不是你在配对？拔掉线即可。」15 u，`label-2` |
| 转圈 | 中心 C + 100 u，半径 14 u | 只在连接中；12 根，`label-3` |
| 提醒 | 基线 C + 130 u | 未加密等：15 u，`signal`；出错：`alert` |
| 页脚 | 基线 H − 34 u | `1.1.0 · 按 I 查看详情`，12 u，`label-2`；IP 移到详情 |

- 动效：没有新增。状态之间直接切换，和现在一样；转圈是唯一会动的东西，它表示「真的在等」。翅膀永不循环（08 §4.5）。
- 详情（按 I）：同一个夜色地；卡片 `night-2`、圆角 13 u、无描边；标题 28 u；标签 13 u 半粗 `label-2`；值 20 u `label`；IP 28 u 等宽数字 `label`。说明只留两行：怎么连、按键。
- 预览：`preview/receiver-before-after-zh.png`（左：现在的代码离屏渲染；右：提案），`preview/receiver-proposal-en.png`。提案是 HTML 画的示意，字体渲染与 Core Text 有细微差别。

### 2.7 DMG 窗口（已做）

- 640 × 400 pt，纸色地。上方两个示意：左边一台笔记本，右边一台 iMac，中间一根虚线——两台电脑、一根线。下方：发送端 → 「应用程序」（箭头），竖线右边是接收端；最下一排是读我和许可。
- **背景里没有文字。** Finder 自己会在图标下写名字；示意图不分语言；也就不涉及把哪种字体栅格化进安装包。
- 背景按浅色设计：带背景图的窗口，Finder 一律用浅色样式画图标名字（C-Command 论坛的多份报告，本机未验证，见第五节）。
- 卷图标用发送端的 App 图标。卷名：`PWE Screen Encore <版本>`；映像文件 `PWE-Screen-Encore-<版本>.dmg`。
- 预览（示意，不是 Finder 截图）：`preview/dmg-window-concept.png`，用的是提案的一对图标。

### 2.8 语气和用词

- 照 `.agents/product-marketing.md` 的语气：克制、具体、敢于说不确定的事。界面里每句话都要经得起真机验证。
- 用词表（界面、文档、宣传同一套）：

| 用 | 不用 | 为什么 |
|---|---|---|
| Mac / 这台 Mac | MacBook（指发送端时） | 发送端也可能是 Mac mini、Mac Studio |
| iMac | 接收端（在主界面和宣传里） | 「发送端 / 接收端」只在详情、设置、文档里出现 |
| 用作显示器 | 连接（作为主按钮） | 1.1 主窗口的说法 |
| 扩展显示 / 镜像显示 | 独立的一块屏 / 和这台 Mac 一样 | macOS 的词（SIMPLIFY-UI 方案） |
| 登录时打开 | 开机自动打开 | macOS 的词；发送端已经这么写 |
| 雷雳线 | 数据线、USB-C 线 | 普通 USB-C 线不行，要说准 |
| 5K（5120 × 2880） | 视网膜、Retina | Retina 是 Apple 的商标；5K 是事实 |
| TargetBridge 原版 | 官方版、正版 | 不暗示谁是「正版」 |

### 2.9 做与不做

- 做：接收端画面上翅膀静止、单色；状态变了只换字。
- 做：所有数字等宽；所有写在界面上的数字都要能在 BASELINE 里找到出处。
- 做：致谢 TargetBridge，用 2.1 那一句，不缩写。
- 不做：在接收端、DMG、README 里用绿色、渐变、发光、投影。
- 不做：把琥珀当按钮底、卡片底或装饰。
- 不做：在宣传图里画一台「概念 iMac」却不标「概念插画」；不用别人的 iMac 照片。
- 不做：把 Apple 的商标写成全大写或改写（`IMAC`、`I-Mac`）。

## 三、代码改动规格（按用户影响排序）

每条写明文件、现在、改成、为什么。R1–R5、R7–R9 不需要 Lee 拍板；R6、R10 需要（R6 已于 2026-10-20 同意并做完）。上游文件一律经 `pwe/rebrand.py` 在打包时改，不直接改仓库里的上游文件。

| # | 文件 | 现在 | 改成 | 为什么 |
|---|---|---|---|---|
| R1 | `TargetBridge-Receiver/TBReceiverC/src/display.c`：`tb_disp_rebuild_status_texture` 的 `connecting` 分支与 `TB_RECEIVER_COMPACT_IDLE` 分支 | 地 `0.06,0.07,0.09`（连接中 `0.035,0.045,0.06` 加 600×490 u 圆角卡片）；`tb_disp_draw_app_icon` 132 u；绿 `0.43,0.93,0.60` 的配对码；绿色角色字 `receiver.splash.role`；页脚带 IP；连接中图标顶边 C − 206 u、空闲 C − 170 u | 地 `night`（`0.055,0.090,0.161`）；去掉卡片和角色字；按 2.6 的表画：翅膀从 `receiver-wing.pdf`（R5）画 144 u 宽，找不到就退回 `tb_disp_draw_app_icon`；所有状态共用一个锚点；配对码 `label`；页脚 `版本 · 按 I 查看详情` | 最显眼的表面；去掉上游的颜色；状态切换不跳 |
| R1b | 同文件 `tb_disp_draw_connecting_spinner` | `SDL_SetRenderDrawColor(d->ren, 84, 225, 137, alpha)`，中心 `drawable_h/2 + min_side/5` | 颜色 `247,245,242`，alpha 上限 102（40%）；中心 C + 100 u，半径 14 u | 绿色去掉；位置跟 2.6 的版式 |
| R1c | 同文件 `tb_disp_draw_details_scaled` | 冷灰三层地；绿 IP；Menlo；标签 `0.54,0.62,0.76` 蓝灰 | 地 `night`，不再画 48 u 内框；卡片 `night-2`、圆角 13 u；标签 `label-2`，值 `label`；IP 等宽数字 `label`；分隔线 `line`；帮助行两行：`help_1`，然后 `help_4 · details_back` 一行 | 同 R1 |
| R2 | `pwe/rebrand.py`：`rebrand_languages` 加一个 `PWE_STRINGS = {"zh": {...}, "en": {...}}`，在 `RECEIVER_TITLES` 之后覆盖 | 见右列「现在」 | **zh**：`receiver.ui.subtitle` 「5K / HiDPI 接收端已就绪，等待发送端连接」→「等待 Mac 连接」；`ip_thunderbolt_bridge`「雷雳网桥 IP」→「雷雳网桥地址」；`sender`「发送端」→「Mac」；`stream_profile`「码流配置」→「画面」；`help_1`「在 MacBook 上打开发送端，填入上面这个 IP 地址。」→「在 Mac 上打开 PWE iMac Display，接上雷雳线即可。」；`help_4`「按 L 可切换接收端语言。」→「按 L 切换语言」；`details_back`「按 I 返回。」→「按 I 返回」；`login_item`「开机自动打开」→「登录时打开」；`receiver.login.title`「开机后自动打开接收端吗？」→「登录时打开接收端吗？」；`receiver.login.yes`「自动打开」→「登录时打开」；`receiver.splash.connecting`「正在连接你的 MacBook」→「正在连接你的 Mac」；`receiver.status.waiting_for_sender`「等待发送端」→「等待 Mac 连接」。**en**：`subtitle` → "Waiting for your Mac"；全大写标签改句首大写（`STATUS`→"Status"，`SENDER`→"Mac"，`DISPLAY`→"Display"，`STREAM PROFILE`→"Picture"，`LANGUAGE`→"Language"，`PERMISSIONS`→"Permissions"，`OPEN AT LOGIN`→"Open at Login"，`IP THUNDERBOLT BRIDGE`→"Thunderbolt Bridge address"）；`help_1` → "Open PWE iMac Display on your Mac and connect a Thunderbolt cable."；`splash.connecting` → "Connecting to your Mac"；`status.waiting_for_sender` "waiting for sender" → "Waiting for your Mac"；`login.title` → "Open the receiver at login?" | 上游流程是手动填 IP，PWE 是自动发现；用 macOS 的词；英文不靠全大写强调。`leftovers()` 的中文角色词检查不受影响 |
| R3 | `display.c`：`tb_disp_text_width`、`tb_disp_draw_text` 的字体来源 | `CTFontCreateWithName("Helvetica" / "Helvetica-Bold" / "PingFangSC-*" / "Menlo")` | 加一个取字体的小函数：名字是 `".system"`、`".system-semibold"`、`".system-digits"` 时用 `CTFontCreateUIFontForLanguage(kCTFontUIFontSystem 或 kCTFontUIFontEmphasizedSystem, size, NULL)`，`-digits` 再加等宽数字特性；其余名字照旧。各处 `title_font` / `body_font` / `mono_font` 改用这三个名字 | 08 §7.2；中文自动落到苹方，`zh ?` 分支可以删掉。macOS 11 起两个 API 都在 |
| R4 | `pwe/sender-ui/PWEStatusMenu.swift:88` `updateButton` | `NSImage(systemSymbolName: showing ? "desktopcomputer" : "display", accessibilityDescription: strings.appName)` | `let image = NSImage(named: showing ? "PWEMenuBarShowing" : "PWEMenuBarReady"); image?.accessibilityDescription = strings.appName`；`isTemplate`、`appearsDisabled`、`toolTip` 不变 | 一个物体两个状态；不和系统「显示器」、Lumen Bar 撞 |
| R4b | `pwe/rebrand.py` `rebrand_sender` 末尾，复制 `AppIcon.appiconset` 那里 | 只复制图标 | 再把 `pwe/brand/menubar/*.imageset` 复制进 `TargetBridgeSupport/Assets.xcassets/` | 资产进包 |
| R4c | `pwe/sender-ui/PWEMainView.swift:200` | `Image(systemName: "desktopcomputer")` | `Image("PWEMenuBarReady")` | 提示里的字形和菜单栏上的一样 |
| R5 | `pwe/package.sh` 接收端一段（`iconutil … AppIcon.icns` 之后） | 无 | `cp "$SRC/pwe/brand/receiver/receiver-wing.pdf" "$RECEIVER/Contents/Resources/"`；`display.c` 用 `CFBundleCopyResourceURL(…"receiver-wing", "pdf")` + `CGPDFDocumentCreateWithURL` 画第一页，宽 144 u | R1 要画的翅膀；几何来自 `wing_gen.py`，不在 C 里手写路径 |
| R6 | `pwe/icon/main.swift`；`pwe/package.sh` 接收端 `iconutil` 一行；`pwe/rebrand.py` `rebrand_receiver` 复制 `icon_1024.png` 一行 | 一个图标两端共用；3:2 外框，无下巴 | **已做（2026-10-20，Lee 同意）。** `drawAppIcon(in:side:frame:)` 按 2.4 的数值画，`frame` 为琥珀（发送端）或纸色（接收端）；输出 `pwe/assets/`（发送端）和 `pwe/assets/receiver/`（接收端）；`package.sh` 的接收端 `iconutil` 和 `rebrand_receiver` 的 `icon_1024.png` 改读接收端那一份。08 §4.6 的措辞等 Lee 写进 08（见 2.4） | 认出 iMac；分清两端 |
| R7 | `pwe/sender-ui/PWEMainView.swift` `PWEAboutView`；`pwe/rebrand.py` 的 Info.plist 版权一行；`pwe/package.sh` 接收端 Info.plist 的 `NSHumanReadableCopyright` | 关于里没有署名；版权 `PWE Group. Based on TargetBridge (MIT).` | 关于最下面加一行 `Text("PWE · 天域出品 · © 2026 PWE Group Pty Ltd")`，`.footnote`、`.secondary`；两处版权改 `© 2026 PWE Group Pty Ltd. Based on TargetBridge (MIT).`（`rebrand.py` 的 `ALLOWED` 里已有 "Based on TargetBridge"，检查不受影响） | 与 Lumen Bar 一致（08 §1 署名行） |
| R8 | `pwe/sender-ui/PWEStrings.swift:328` | 「TargetBridge 自己的控制台，包含引擎的全部设置。」/ "TargetBridge's own console, with every engine setting." | 「TargetBridge 引擎自带的控制台：全部设置都在这里，界面保持上游原样。」/ "TargetBridge's own console: every engine setting, in the upstream interface." 名字「完整控制台」不变（安装指南已用这个名字） | 说清它为什么长得不一样；不暗示它是 PWE 设计的 |
| R9 | `pwe/sender-ui/PWEMainView.swift:244`、`PWEBrightnessKeys.swift:407` | `.foregroundStyle(.yellow)` | `.orange`，与同一界面里其他警告一致 | 同一种警告一种颜色 |
| R10 | `docs/pwe/SITE-PLAN.md` 字标一行（站点解冻时） | 推荐 `IMAC DISPLAY` 全大写 | 跟第六节的名字决定走；若保留现名，字标写 `iMac Display`，不全大写 | Apple 商标指南要求原样大小写 |

R1–R3 改的是 `display.c` 和语言包覆盖，这两处这一轮正有别的会话在改；合并后再做。验收：离屏渲染（`TB_RECEIVER_SNAPSHOT`，或本轮用过的 `display.c` 包含式渲染器）出 zh / en 四种状态，与 `preview/receiver-*.png` 对照；`rebrand.py` 的遗留检查通过。

## 四、这一轮做好的东西

| 文件 | 是什么 | 怎么重新生成 |
|---|---|---|
| `pwe/brand/make.py` | 生成下面三组资产的脚本，几何全是数字 | 在装了 `cairosvg` 的 venv 里运行 `python -I pwe/brand/make.py`。成功判据：打印 `wrote menubar/, dmg/, receiver/` |
| `pwe/brand/menubar/*.imageset`、`menubar/png/` | 菜单栏模板字形（R4） | 同上 |
| `pwe/brand/receiver/receiver-wing.pdf`、`.svg` | 接收端画面上的纸色实心翅膀，144 pt 宽（R5） | 同上；需要 `01 BRAND ASSETS/source/wing_gen.py`（默认按仓库在 iCloud 里的位置去找，或用 `--brand-source`） |
| `pwe/brand/dmg/background.png`、`background@2x.png` | DMG 背景，640 × 400 和 1280 × 800 | 同上 |
| `pwe/brand/dmg/settings.py` | dmgbuild 的窗口设置：图标位置、隐藏工具栏和侧栏、卷图标 | 手写 |
| `pwe/brand/dmg/requirements.txt` | dmgbuild 1.6.7 及两个依赖，固定版本和 sha256，只装 wheel | 手写 |
| `pwe/package.sh` | 新增「disk-image tool」一段（缓存的 venv，requirements 变了就重装）；磁盘映像改用 dmgbuild；做完先只读挂载、`codesign --verify --deep --strict` 两个 App，再签名映像 | — |
| `pwe/read-me-first.txt` | 加了「不是 TargetBridge 的官方版本」和署名行 | — |
| `pwe/brand/proposals/icon_proposals.py`、`receiver_mock.py` | 图标和接收端提案的预览工具，不进打包 | 见各自文件头 |
| `pwe/brand/preview/*.png` | 五张预览：图标前后、接收端前后（中文）、接收端提案（英文）、菜单栏、DMG 窗口示意 | 预览工具 + 本轮的离屏渲染 |

已验证（2026-10-20，这台 M1）：

- 用 1.1.0 本地包里的两个 App 走了一遍新的 `package.sh` 磁盘映像两段（单独抽出来跑，ad hoc 签名映像）。成功判据都满足：第一次装 dmgbuild、第二次复用缓存；映像里 `.DS_Store` 的五个位置与 `settings.py` 一致，`WindowBounds {{200, 140}, {640, 400}}`，背景是 640×400 + 1280×800 两层的 TIFF，卷有自定义图标标记；两个 App `codesign --verify --deep --strict` 通过，`check-bundle.py` 打印 `bundle checks passed`；映像 9.3 MB，和原来的 9.4 MB 同一量级。
- 试做时踩到一次：dmgbuild 的「隐藏扩展名」会在 .app 上写 `com.apple.FinderInfo`，签名随之失效（`codesign: resource fork, Finder information, or similar detritus not allowed`）。现在只给读我隐藏扩展名，并加了上面那道挂载检查。
- 菜单栏字形：在 Swift 里按模板图着色，放在浅、深两种菜单栏上和 SF Symbols 对比过（`preview/menubar.png`）。

## 五、没验证的

- **Finder 实际怎么画这个 DMG 窗口。** 规矩是不开窗口，所以没在 Finder 里看过；`preview/dmg-window-concept.png` 是按同样坐标画的示意。要 Lee 双击一次新打的 DMG 看。
- **深色模式下 Finder 的图标名字颜色。** 据 C-Command 论坛的报告，带背景图的窗口一律用浅色样式（黑字），所以背景按浅色做；没在本机核实。
- **接收端提案在真 iMac 上的观感**（夜色底在 2017 款面板上的明暗、翅膀的大小）。提案是 HTML 画的；R1 实施后要在 iMac 上看一次。
- **完整的 `pwe/package.sh` 没有从头跑一遍**：这一轮有三个会话在改代码，打包会和他们争 `$TMPDIR` 里的依赖缓存（07 TOOLS HANDOFF §0.11）。下一次正常打包就是验收：成功判据是输出里出现 `▸ Building the disk image…` 之后没有 `✗`，最后打印 DMG 和 sha256。

## 六、名字：「iMac」在产品名里

Apple《Guidelines for Using Apple Trademarks and Copyrights》（2026-10-20 查阅）：

- 「未经授权的使用」第 1 条：第三方不得在公司、产品或服务名中**全部或部分**使用 Apple 的商标，列举里点名了 iMac。
- 「兼容性」条：可以用 "for"、"compatible with" 这类指代说法表明兼容，但 Apple 的商标不得成为产品名的一部分，且不得比产品名醒目。
- 「Mac」另有一条有条件的放行，「iMac」没有。

这不是法律意见。现实风险：免费开源工具被追究的情况少见，但这个产品要上 Reddit、Hacker News、少数派这类公开渠道，名字越响，风险越实。改名的代价随时间增长：现在只有 1.0.0 一个公开版本。

| 方案 | 做法 | 代价 |
|---|---|---|
| A 保留 | 名字不动；所有物料按原样大小写写 iMac | 风险留着；之后再改更贵 |
| B 改名（推荐方向） | 1.1 起换一个不含 Apple 商标的名字，副标用指代说法：「PWE ___ for iMac」→ 例如 **PWE Display Bridge**（「雷雳网桥」上的显示器，也和 TargetBridge 的来历呼应） | App 名、DMG、卷名、cask（新 token + 旧的 `deprecate!`）、仓库名（GitHub 会转发）、文档、虚拟显示器名、接收端标题；bundle id 和设置目录可以不动，权限不受影响 |
| C 延后 | 1.1 先用现名发，宣传只做中文渠道，英文渠道等名字定了再上 | 两次物料 |

**决定（Lee，2026-10-20）：方案 B，改名 PWE Screen Encore。** 发送端 PWE Screen Encore，接收端 PWE Screen Encore Receiver（可执行文件 `PWEScreenEncoreReceiver`）。分支 `pwe-1.1-rename` 已实施：界面、语言包、Info.plist、DMG、读我、NOTICE、README、安装指南；`rebrand.py` 和 `check-bundle.py` 会在用户看得见的地方发现「iMac Display」时让构建失败。

不改的（用户看不见，改了会丢数据或断兼容）：bundle id、`pweimacdisplay://`、设置目录、Bonjour 服务类型、握手协议常量、仓库名和 `$TMPDIR` 里的缓存目录名。cask token 和工具站页面路径（`/imacdisplay/`）在别的仓库，跟发布一起定。第三节的字串是实施记录，保留当时的写法。
