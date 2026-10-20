# pwestudio.site 上的 PWE Screen Encore 产品页：方案

> 2026-10-20 改名：产品 1.1 起叫 PWE Screen Encore（原名 PWE iMac Display，BRAND 第六节）。下文的路径、键名和文件名已跟着改；页面从没上线，旧路径不需要转发。

> 2026-10-14。Lee 当天说产品页暂时冻结，只出方案。网站仓库（`07 TOOLS/PWE Loan Bar/site/`）一个字没改。
> 解冻后按「改动清单」做，按「验收」查。

## 结论

- 新增 `/screenencore/` 一页，首页加一张卡片，`deploy.sh` 加一段从 GitHub release 拉取并校验的代码。
  做法照 PWE AI Bar：公开仓库，安装包从 release 取，核对 `SHA256SUMS.txt` 和 staple。
- 1.1 起 App 内有更新检查（`pwe/sender-ui/UpdateCheck.swift`），向 `https://pwestudio.site/app/check` 报的产品键是 `screenencore`。`functions/_release.js` 要加 `screenencore` 一条，`told_matches` 照其他产品加；没加之前，检查得不到答复，App 静默不提示。
- 页面上的每个数字都会进 PWE Assist 的知识库（`knowledge.py` 只放行页面上出现过的数字），所以只写核实过的数字。

## 改动清单（网站仓库）

| 文件 | 改动 |
|---|---|
| `site/wordmarks.py` | `NAMES` 加 `"screenencore": "SCREEN ENCORE"`，运行后提交 `public/img/wordmark-screenencore.svg`。需要装了 fonttools 和 uharfbuzz 的 Python 环境；2026-10-14 本机没找到，要先装（见「等 Lee」）。 |
| `site/chrome.py` | `PRODUCTS` 加 `"screenencore": ("PWE Screen Encore", "/screenencore/", "screenencore", "Free tools from PWE Studio.")`；`FREE` 加 `screenencore`；`NAV` 加 `[ALL_TOOLS, ("/screenencore/#setup", "Set up", "怎么连"), ("https://github.com/kenshinice-ai/pwe-imac-display", "GitHub", None)]`；`PAGES` 加一行（标题 `PWE Screen Encore`，用 `STUDIO_CARD`，`uses loop.js` 为 False）；`studio` 的导航加 `("/screenencore/", "iMac Display", None)`。 |
| `site/public/screenencore/index.html` | 新页面，结构见下节。 |
| `site/public/screenencore/img/connection.svg` | 示意图：新 Mac —— 雷雳线 —— iMac，iMac 屏上是 Mac 的桌面。手绘 SVG，不放 App 截图（理由见「截图」）。 |
| `site/public/index.html` | 产品架上加一张卡片，放在 PWE Lumen Bar 后面（都是显示器类）。 |
| `site/deploy.sh` | 照 PWE AI Bar 那段加一段：仓库 `kenshinice-ai/pwe-imac-display`，标签是 `pwe-1.0.0`，所以版本取 `${TAG#pwe-}`；文件 `PWE-Screen-Encore-$VER.dmg`；暂存到 `public/screenencore/download/PWE-Screen-Encore.dmg`；核对校验值和 staple；检查页面写着 `Version $VER`。上线后的检查加一行 `binary_served …/screenencore/download/PWE-Screen-Encore.dmg`。 |
| `site/public/sitemap.xml` | 加 `https://pwestudio.site/screenencore/`。 |
| `site/assist-knowledge.json` | 页面列表加 `screenencore`（id、两种语言的短标签）。 |

## 页面结构和文案初稿

照 `/lumen/` 的骨架：页头（eyebrow、标题、dek、下载按钮、版本说明、配图），正文几节，最后是运行要求。

**页头**

- eyebrow：`macOS 14+ · 5K iMac 2014–2017` ／ `macOS 14+ · 2014–2017 年 5K iMac`
- 标题：`Your old iMac, a 5K display again.` ／ `旧 iMac，重新做回一块 5K 屏。`
- dek：
  - EN: Apple stopped Target Display Mode with the 5K iMac, and Apple silicon Macs cannot use it at all. PWE Screen Encore brings it back in software: one app on your Mac, one on the iMac, one Thunderbolt cable.
  - ZH: Apple 从 5K iMac 开始取消了「目标显示器模式」，Apple 芯片的 Mac 更是完全用不了。PWE Screen Encore 用软件把它接回来：新 Mac 装一个 App，iMac 装一个，中间一根雷雳线。
- 按钮：`Download for macOS` ／ `下载 macOS 版` → `/screenencore/download/PWE-Screen-Encore.dmg`；`Source on GitHub →` ／ `GitHub 上的源代码 →`
- 版本说明：`Version 1.0.0 · 7.3 MB · free and open source · signed and notarised by Apple. One disk image holds both apps.` ／ `1.0.0 版 · 7.3 MB · 免费开源 · 已由 Apple 签名公证。一个 DMG 里装着两个 App。`
- 配图：`connection.svg`。

**正文**

1. `#setup` 怎么连（三步，对应 DMG 里的「读我」）：新 Mac 装 PWE Screen Encore；iMac 装 PWE Screen Encore Receiver；雷雳线连上后点「连接」。
2. 线和转换器：雷雳 3/4/5 线都行；2014、2015 款 iMac 是雷雳 2，要 Apple 的雷雳 3（USB-C）转雷雳 2 转换器；普通 USB-C 转 Mini DisplayPort 转换器不行。
3. 它是怎么做的：新 Mac 上建一块虚拟显示器，硬件编码后经雷雳网桥发送；iMac 硬件解码后全屏显示。不刷机、不拆机、不装 Linux。
4. 基于 TargetBridge：核心代码来自 Marco Caciotti 和社区的开源项目 TargetBridge（MIT）；PWE 做了签名公证、macOS 11 接收端、中文校对；修复先提给上游。链接上游仓库。
5. 它不会假装能做的事（卡片，四张）：
   - 1.0 还没在真实的 Intel iMac 上跑过：Apple 芯片原生与 Rosetta 下的端到端测试通过；遇到问题请开 issue。**真机测过以后改掉这张。**
   - 只走雷雳线：Wi-Fi 和以太网传输（Network Link）默认关闭。
   - 亮度键暂时不能调 iMac 背光：菜单里可以调。
   - 不收集任何数据：没有账号，没有统计；更新检查只发产品键、版本号和 macOS 版本，默认关闭，问过才开。
6. 运行要求：发送端 macOS 14 或更新，Apple 芯片或 Intel；接收端以 macOS 11 为目标。

## 截图

不放 App 截图。理由：

- 2026-10-14 Lee 没有授权屏幕访问，我拍不了。
- 截图里会出现 IP 地址和电脑名，要用演示模式遮掉，而这个 App 没有演示模式。

先用示意图。真机试用时，如果 Lee 愿意拍 iMac 当显示器的实物照片，那比截图更能说明问题。

## 验收

1. 运行 `python3 site/chrome.py --check`。成功判据：退出码 0，说明没有人改动共享部件。
2. 运行 `python3 site/knowledge.py --check`。成功判据：新页面出现在页面列表里，检查全过。
3. 运行 `python3 site/serve.py`，在浏览器里看 `/screenencore/` 和首页。中英文各看一遍，再看 390px 宽的手机布局。
4. 运行 `./site/deploy.sh`。成功判据：没有 `✗`；版本说明检查没有报警告。
5. 上线后取 `https://pwestudio.site/screenencore/download/PWE-Screen-Encore.dmg`。成功判据：是磁盘映像，sha256 是 `2a24e97c…`。

## 等 Lee

- **解冻产品页。**
- **字标写法。** `SCREEN ENCORE`，和 `LUMEN BAR` 一样全大写。名字里没有 Apple 的商标，原来「iMac 全大写」的顾虑不再有。
- **装字标环境。** 需要在一个 venv 里运行 `pip install fonttools uharfbuzz`，这会从 PyPI 下载两个包。
