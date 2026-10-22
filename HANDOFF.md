# PWE Screen Encore（原名 PWE iMac Display）— 交接

> 状态（2026-10-20）：1.0.0 已撤下（Lee 2026-10-20 定）：release 改回草稿、Homebrew cask 删除、README 写「1.1 即将推出」。不单独发 1.0.1，它的修复并进 1.1。
> 1.1 候选版（产品改名 **PWE Screen Encore**，Lee 2026-10-20 定；bundle ID、`pweimacdisplay://`、数据路径不变）在本地分支 `pwe-1.1`（未推送），已含 1.0.1 的全部修复。**RC3**（2026-10-21，源码 `b770bd7`，构建号 20261021100614，sha256 `23abf70f…`）在 `pwe/dist/local/PWE-Screen-Encore-1.1.0.dmg`：在 RC2 上加了 T33 菜单开着时整体刷新、T38 日志进系统日志、T34 插线后走雷雳网桥的 IPv6 本地地址（IPv4 照旧作后备），并收紧了「哪个网桥算线缆」。RC2 移到 `pwe/dist/local/rc2-20261021012201/`，RC1 在 `rc1-20261020225620/`。**计划 2026-10-28（周三）发布**，Marco 2026-10-20 已收到一周通知。
> 2026-10-20 给 Marco 发了补充报告（回在 10-14 那封的线程里）。他 10-16 把 #212–#216 合进了 `maint-3.6`，3.6.1 候选版是上游 PR #218。
> 渲染方式（Lee 2026-10-22 定）：iMac 默认 OpenGL；用户可在设置 › 高级改成「占用更少（Metal）」。测试里两种都通过。
> 2026-10-22 给 Marco 发了英文公告和致谢句（Lee 授权，回在 10-14「a signed build of TargetBridge, before we publish」那条线程，只讲发布，不提安全）。他还没回过任何一封；Show HN 要等他不反对。同日 Lee 把测试版私发给第一批人。
> **RC8**（2026-10-22 17:30，`pwe-1.1` d00ee1b，构建号 20261022173038，sha256 `2fb9f9b3…`，未公证）在 `pwe/dist/local/`：RC7 加 1.1.1 的全部 27 项修复（发送端 15、接收端 12；Lee 2026-10-22 定全部进 1.1），每项过了独立评审，评审提出的问题已修。验证：源码全套通过（发送端 390 个测试、接收端单元测试、两种架构冒烟）；成品检查通过（check-bundle、无测试钩子、两端版本一致、签名有效）。另：`test_audio_out` 的退出计时检查在一次带负载的运行里超出 280–1000 ms 窗口，单独重跑 5 次全过，是负载下的计时抖动，1.1.1 放宽上限。RC7 移到 `pwe/dist/local/rc7-20261022085717/`。真机测试按 `TEST-1.1-rc-2026-10-21.md`「RC8」W0–W12，10-25 晚前做完；不过就发 5a568d2（RC7 + 文档），修复留 1.1.1。
> 打磨（Lee 2026-10-22 定：按清单 https://claude.ai/artifact/TVduMSotx4napQXPrUZgth 执行）。已做：仓库 Issues 打开、两个 issue 模板推到 main（41795e7）、Actions 关掉（API）、描述/主页/wiki 改好；`pwe-1.1` 上文档扫过一遍、加「更新」一节、`docs/pwe/COMPATIBILITY.md`、`docs/pwe/releases/1.1.0.md`（74d86c0）；上游 maint-3.6 合并干跑：18 个文件，4 个冲突（`display.c` 11 处最重），见 `docs/pwe/UPSTREAM-DRYRUN-2026-10-22.md`。`pwe-1.1` 现在是 5a568d2：74d86c0 之上加了 verify.sh 四项检查（贴票据、两端版本一致、成品无测试钩子字符串、标签在 HEAD；3049f99）和一处两行的接收端修正（`TB_RECEIVER_TEST_PORT`、`TB_RECEIVER_NO_BONJOUR` 只在测试构建里读，06de21a——新的钩子扫描发现的，正式版不会再认这两个环境变量）；2026-10-22 全套 verify 通过（376 个发送端测试、接收端单元测试、两种架构冒烟）。这两行没有重新上真机：改动只是让正式版不读两个没人设置的环境变量。进行中（本地分支，发布后再合）：`pwe-1.1.1-sender`、`pwe-1.1.1-receiver`。1.1.1 目标 11 月中旬，和 T+14 同天。
> Lee 2026-10-22 按推荐定：1.1 完全免费（不注册、不试用、不锁功能，收入靠赞助，收费推到 2.0、T+60 约 2026-12-27 复盘）；新 cask 叫 `pwe-screen-encore`；仓库 Sponsor 按钮指向 pwestudio.site/support；10-26 晚的 go/no-go 推荐 go，到时只核对门槛。
> 宣发（Lee 2026-10-21 定，按宣发简报的推荐）：发布和推广拆开，英文推广等第二款机型的结果和第一周 issue 处理得过来；10-26 晚按门槛定 go/no-go，推迟就整个日历顺延；首波只开微信、小红书、V2EX；T+14 前推广不提配对和加密；仓库 `pwe-imac-display` 发布周不改名，1.1.x 再议。简报 `docs/pwe/LAUNCH-BRIEF-1.1-2026-10-21.md`，网页版 https://claude.ai/artifact/DVXRmqViPuUQFGeBgR5oFS 。
> 测试版（Lee 2026-10-21 定）：等 RC5（含 T40 剪贴板的真正修复）真机测过后，10-23～24 公证、用私下链接发给第一批测试者（不放 GitHub release，`pwe-1.1` 不推）。反馈走 GitHub issue 或 support@pwestudio.site。给测试者的说明 `docs/pwe/BETA-1.1-testers.md`（不入库，两处「发前核对」等 RC4 结果）。
> **公证测试版**（2026-10-22，`pwe-1.1` c9f5398 = RC6 加截图倍数开关 `PWE_SNAPSHOT_SCALE`，构建号 20261022083325，sha256 `8d250a67…`，Gatekeeper：Notarized Developer ID）在 `pwe/dist/beta-20261022083325/`（DMG、ffmpeg 源码包、SHA256SUMS）。本地标签 `pwe-1.1.0` 指向它，未推；正式版前标签会移。RC6 真机全部通过（U0–U3、2 小时办公、网络边界 N1–N3）。测试者说明已定稿。
> T47（P2，网络边界测试发现，详情不入库）：**真机通过（RC7，2026-10-22），已并进 `pwe-1.1`（e7104e3，本地，未推）**，进 1.1 正式版。RC7（构建号 20261022085717，sha256 `bd9acb25…`，未公证）在 `pwe/dist/local/`：V1 会话中 Wi‑Fi 连接 8–96 ms 内被拒、V3 换画面 9 次 1.9–2.7 秒、V2 快速重插 3 次 2.1–3.5 秒（测试机 11:44 全部通过）。结果见 `docs/pwe/BASELINE-iMac18,3.md`「RC7（T47）」。RC6 在 `pwe/dist/local/rc6-20261021234804/`。
> 使用说明（中英双语，带截图）：https://claude.ai/artifact/3aYZkUhTKifqsYKJJYSZ7V （私有，要分享从页面里点；可导出 PDF/Word）。现在只给测试者；以后上自己网站（Lee 2026-10-22 定）：上网站前换成正式版截图，T+14 前去掉配对码那张图，由工具站会话做成 pwestudio.site 的页面。
> **测试者回报（Lee 2026-10-22 定，对外承诺）：参加测试的朋友，PWE Screen Encore 以后所有版本终身免费，含更新——包括将来如果出收费版。** 已写进测试者说明和朋友圈邀请；名单记在 `docs/pwe/BETA-testers-roster.md`（不入库）。以后定价、做授权时必须兑现。
> 测试版分享包（2026-10-22）：iCloud Drive `PWE/Screen Encore 测试版 1.1/`（DMG、ffmpeg 源码包、SHA256SUMS、去掉内部说明的测试者说明），Lee 从访达共享链接发给测试者。
> **RC6**（2026-10-21，`pwe-1.1` ded0d5d，构建号 20261021234804，sha256 `17a14cbb…`）在 `pwe/dist/local/PWE-Screen-Encore-1.1.0.dmg`：RC5 再加 T46（保存报告不再卡 15 秒）、「关于」显示构建号、21.5 吋 4K iMac 默认 4096 × 2304。RC5 真机已过：T45、插线、醒来重连、T39、换画面、界面；23:29 那次 -3817 断开是 Lee 自己点了录屏指示，不是问题。RC5 在 `pwe/dist/local/rc5-20261021172703/`。
> **RC5**（2026-10-21，`pwe-1.1` 2bcbace，构建号 20261021172703，sha256 `83b03151…`）在 `pwe/dist/local/PWE-Screen-Encore-1.1.0.dmg`：RC4 再加 T40 真正的修复（剪贴板改到单独线程，不再每 100 ms 开 `pbpaste`）、T45（快速重插时顶掉静默 ≥ 2.5 秒的旧会话，只限线缆）、T39（心跳独立于主线程，主线程 30 秒无响应才停；主线程卡顿检测）、醒来和插线后直接拨 iMac 的 IPv6 地址、界面统一版式、iMac 如实报告 HEVC 硬解（没有就让 Mac 用 HEVC + 软件解码）、日志开头 `[sys]` 一行。每批改动都有独立只读审查，提出的问题已修。RC4 在 `pwe/dist/local/rc4-20261021131443/`。
> RC5 验证（2026-10-21，这台 Mac）：发送端 373 个测试（4 个跳过，0 失败）、接收端全部单元测试、两种架构冒烟各 51 项通过；DMG 两个 App 过 check-bundle、Developer ID 签名有效，未公证；成品里没有测试钩子的字符串。RC4 真机已过：T37、T38、T33、T34（IPv6 2.5–3.3 秒）、换画面 14 次。**RC5 的改动都没上真机。**
> Lee 2026-10-21 定：重连门槛拆成两条（睡眠和换画面每次 ≤ 5 秒；拔插从 iMac 有地址起 ≤ 5 秒，T34 的约 20 秒写进已知问题，1.1.1 改走 IPv6）；忘记正连着的 iMac 就断开，下次要码；出画面时 Esc 不响应；快捷键按键盘上标的字母认；「忘记」失败的提示定稿。
> 方案和决定：`docs/pwe/PLAN-1.1-2026-10-19.md`、`DESIGN-pairing-2026-10-19.md`、`RESEARCH-Metal-2026-10-19.md`（三份都不入库）。
> 2026-10-20 申请了 OpenAI Codex for Open Source 和 Claude for Open Source（Lee 提交；名字 Li Liu，lee.liu.melbourne@gmail.com）。结果会发邮件，滚动审核。
> pwestudio.site 的 `/screenencore/` 2026-10-21 上线（Lee 同意，工具站会话部署）：状态写「10 月底推出」，没有下载链接；没有提配对或加密。
> 2026-10-19 在真机 iMac18,3（macOS 13.7.8）上做了基线：画面、真 5K（48 和 60 帧）、拔线和睡眠恢复都能用；声音不工作。
> 结果和证据在 `docs/pwe/BASELINE-iMac18,3.md`（未入库），本文件「八」节是摘要。
> 仓库：`kenshinice-ai/pwe-imac-display`，公开，是 `swellweb/targetBridge` 的 fork。`main` 从上游 3.6.0 起。
> 方向（Lee，2026-10-14）：PWE 自己签名的 app，同时给上游贡献。下游发行版还是彻底分叉待定。见 `docs/pwe/RESEARCH-TargetBridge.md`。
> `main` = 上游基线 + `pwe/PATCHES.md` 登记的补丁 + PWE 自己的文件（本文件、`docs/pwe/`、`pwe/`、`.github/README.md`、`.github/SECURITY.md`）。
> 改上游文件之前先提 PR 给上游，再登记进 `pwe/PATCHES.md`。改名在打包时对副本做（`pwe/rebrand.py`），不改仓库里的文件。

## 阶段

- **[阶段] 内测** — 下一步：RC8 真机测试（W0–W12），10-25 晚前；10-26 公证、晚上 go/no-go · 负责：Lee（发链接、测试）、本仓库会话（T47、打包、素材）· 卡在：没有 · 自 2026-10-22

## 宣发

- **[排队] 小红书 · 发布图文 1 篇（T+1，10-29 12:00 墨尔本）** — 9 张定稿在 `~/Documents/ClaudeCode/小红书-图文/PWE-Screen-Encore-返场/out/`，2026-10-22 Claude 核过事实（删了一句没出处的线材说法）；不放网址和 GitHub（小红书判站外引导会限流），结尾请机主在评论区报机型 · Lee 2026-10-22 已定：标题「家里那台5K iMac｜别卖，接上当5K屏」、只写 A$2,599 起。小红书会话 10-28 19:17 确认发布后换截图、核价、设定时
- **[排队] 朋友圈 · 测评邀请 1 条** — 正文 A 定稿、P3 文字卡在 `docs/pwe/launch-kit-2026-10-22/moments-beta-invite.md` 和 `moments-beta/` · 等 Blender（P1）和 ChatGPT（P2）出图，Claude 加「效果图」后 Lee 发
- **[已发] 官网 · 2026-10-21 · /screenencore/ 加逐年机型表（2014–2020，状态和最高 macOS）和「21.5 吋 4K 还没测过、暂不承诺」** — 工具站会话部署（main 62b3590，Cloudflare 36566e3b），PWE Assist 知识已同步；线上已核对；仍无下载链接 · 数据：未抄
- **[排队] 微信、小红书、V2EX · 3 条** — 草稿在宣发简报附录 A · 等 10-28 发布后由 Lee 发

## 等 Lee

- **[给料] 测试者名单** — Lee 2026-10-22 已把测试版发给第一批人；请把发给了谁（称呼、联系方式、iMac 年份）记进 `docs/pwe/BETA-testers-roster.md`，终身免费要靠这份名单兑现 · 不记则以后核对不了谁该免费 · 自 2026-10-22
- **[动手] GitHub Sponsors 审核通过后打开仓库的 Sponsorships 开关** — 资料已提交，2026-10-22 状态 Pending（GitHub 审核中）；通过后 GitHub 会发邮件，Lee 到仓库 Settings › General › Features 勾选 Sponsorships · 不开则仓库页没有赞助入口（支持页另由工具站会话放出按钮）· 自 2026-10-21
- **[动手] 小红书主页简介写上 pwestudio.site/screenencore（纯文字）** — 10-29 发帖前；帖子里不放网址，评论区有人问就回「主页简介里有」· 不写则问下载的人找不到 · 自 2026-10-22
- **[给料] 更多真机照片** — Lee 之后拍（2026-10-22）：小红书要 iMac 亮屏正面、一根线的特写；关掉屏幕共享、用中文界面 · 不拍则小红书只能用效果图和截图 · 自 2026-10-21

## GitHub Sponsors 跟进（2026-10-22 起）

1. 查状态（Claude，每次会话开头顺带查）：`gh api graphql -f query='{ viewer { hasSponsorsListing sponsorsListing { isPublic url } } }'`。成功判据：`hasSponsorsListing` 为 `true`，`https://github.com/sponsors/kenshinice-ai` 不再 302 到个人主页。2026-10-22 实测：`false`、302。
2. 通过后，请工具站会话把 pwestudio.site/support 上藏着的「Sponsor on GitHub」按钮放出来（页面里已写好，带 `hidden`）。部署要 Lee 在那个会话里说「部署」。成功判据：线上支持页能点到 GitHub Sponsors 页。
3. 通过后，`.github/FUNDING.yml` 加一行 `github: kenshinice-ai`（保留 `custom`）。如果 1.1 已发布，随下一次推送；没发布就随 1.1。成功判据：仓库页的 Sponsor 按钮同时列出 GitHub Sponsors 和支持页。
4. Lee 打开仓库 Sponsorships 开关（见「等 Lee」）。
5. 10-28 前还没通过也照常发布：FUNDING.yml 现在只指向我们自己的支持页，支持页写着「开通后会放在这里」，不会出现死链接。

## 1.1 发布步骤（2026-10-28，Claude 做，候选版测试的 P1 修完之后）

1. 把 `pwe-1.1` 合进 `main`（不快进，留合并提交）。`HANDOFF.md` 冲突一律取 main 的（分支上那份停在 10-16）。成功判据：`git merge-base --is-ancestor pwe-1.1 main` 退出码 0。
1b. 文档扫一遍（2026-10-22 已在 `pwe-1.1` 做过一轮，74d86c0；发布当天再核）：`git grep -n "pwe-imac-display\b" -- '*.md' '*.txt'` 只剩仓库 URL；`git diff origin/main..main -- HANDOFF.md` 里没有不该公开的内容（测试者名单、私下链接、安全细节）；`docs/pwe/releases/1.1.0.md` 填上构建号和 sha256。成功判据：三条都过。
2. 把 `docs/pwe/` 里还没入库、也不含安全细节的方案文档按需入库；`AUDIT-2026-10-15.md`、`DESIGN-pairing-2026-10-19.md`、`DRAFT-upstream-report-2026-10-19.md` 等含安全细节的继续不入库。
3. 打标签 `git tag pwe-1.1.0`（测试版用过的同名本地标签已于 10-22 删掉，重新打即可），在解锁的屏幕上运行 `pwe/package.sh --notarize`。成功判据：DMG 和两个 App 都是 `source=Notarized Developer ID`，`bundle checks passed`。
4. 推送：`git push origin main pwe-1.1.0`，只推这一个标签。
5. 发 release：`gh release create pwe-1.1.0 --notes-file docs/pwe/releases/1.1.0.md`，上传 `pwe/dist/` 的三个文件；说明只写一般说法，不写复现细节。成功判据：`gh release download` 回来的文件通过 `shasum -c`。
6. 在 `homebrew-tap` 加新 cask `pwe-screen-encore`（Lee 2026-10-22 定）。`zap` 要列全：`~/Library/Application Support/PWE Screen Encore*`、`~/Library/Preferences/com.pwegroup.pweimacdisplay*.plist`、`~/Library/LaunchAgents/com.pwegroup.pweimacdisplay.receiver.plist`、`~/Library/Logs/PWE Screen Encore Receiver/`、`~/Library/Saved Application State/com.pwegroup.pweimacdisplay.savedState`、`~/Library/HTTPStorages/com.pwegroup.pweimacdisplay`；`caveats` 写「接收端要拷到 iMac 上：在 iMac 上打开同一个磁盘映像」。成功判据：`brew fetch --cask` 显示 ✔。
7. README 第一段改回下载说明。
7a. 更新工具站（iCloud 里 `PWE Loan Bar` 的 checkout；做法见那边 `site/README.md`「A new product」）。
    1. 在 `site/functions/_release.js` 加 `screenencore`（version、published、notes_en、notes_cn）。成功判据：产品页「Latest」不再显示 `No release yet.`。
    2. 在 `site/chrome.py` 把 `ACTION["screenencore"]` 设成下载链接和文字；把 `site/public/screenencore/index.html` 首屏的状态行换成下载按钮。
    3. 把首页卡片（`site/public/index.html` 的「Coming late October」）和 `/help` 的 Screen Encore 卡片改成已发布。
    4. 运行 `python3 site/chrome.py`，看 `git status`，再运行 `./site/deploy.sh`。成功判据：它核对每个 sitemap 页面和下载校验值，全部通过；`curl 'https://pwestudio.site/app/check?product=screenencore&version=1.0.0'` 返回 1.1.0。
    5. 把新的 pwe-tools 知识提交号发给 PWE Assist 会话（「PWE Assist 项目总规划」）。号码看 `deploy.sh` 的输出，或 `https://pwestudio.site/_pwe/status.json`。成功判据：那边回复已按新的 Screen Encore 事实重跑问题集。
7c. 发布后马上给「小红书 文案 图文 创意 总监」会话发一条：go 了没有、正式版截图目录名（`docs/pwe/film-assets-2026-10-28/release-<构建号>/`）；推迟就给新日期。它 10-28 19:17（墨尔本）换图、核价、设 10-29 12:00 的定时。成功判据：那边回复已设定时。
7b. 给「Screen Encore 全 3D 产品片制作」会话交正式版素材（10-30 前），放进 `docs/pwe/film-assets-2026-10-28/`，按它 README 的状态表填，每批交完发消息给那个会话。发送端截图用 `PWE_SNAPSHOT_SCALE=3`（`pwe-1.1` c9f5398 起）。内容：用正式构建跑 `--pwe-snapshot`（发送端 01、02、04、05、07，浅色和深色，中文）；接收端等待画面（中文，5120 × 2880，用素材目录 `tools/` 里的离屏渲染工具）；菜单栏图标（浅色、深色栏）；一张合成的「扩展桌面」图（PWE 壁纸加一个 PWE 窗口，不出现 Apple 标志和别家 App）。再用正式版实测插线到出画面 3–5 次，把秒数和日期发过去。成功判据：那边回复已收到，片子里没有测试版号。
8. 回信告诉 Marco 已发布（10-14 那封的线程）。
9. 删除本地分支 `security-1.0.1`（已全部并进 1.1）。

## 1.1.0 发出去不行怎么撤（2026-10-22 写，未演练）

1. 把 release 改成 pre-release 并隐藏下载：`gh release edit pwe-1.1.0 --prerelease --draft`。成功判据：`gh release view pwe-1.1.0 --json isDraft` 是 true。
2. 停止更新检查推新版：工具站 `site/functions/_release.js` 把 `screenencore` 的 version 改回上一版或删掉，重新部署（Lee 在那个会话说「部署」）。成功判据：`curl https://pwestudio.site/app/check?product=screenencore&version=1.1.0` 不再返回更新。
3. cask：`homebrew-tap` 里 `git revert` 加 cask 的那次提交并推送。成功判据：`brew fetch --cask kenshinice-ai/tap/pwe-screen-encore` 报找不到。
4. README 第一段改回「1.1 即将推出」，推 main。成功判据：仓库首页不再有下载链接。
5. 已装的用户：发一条 issue 置顶说明问题和临时办法；接收端的副本收不回，只能在说明里写。
6. 标签 `pwe-1.1.0` 不删不动（修好后发 1.1.1，不复用标签）。

## 1.0.0 撤下后怎么恢复（2026-10-20）

- release：`gh release edit pwe-1.0.0 --draft=false`。1.1 发布时不恢复它，直接发 `pwe-1.1.0`。
- cask：在 `kenshinice-ai/homebrew-tap` 里 `git revert 90bfd31`，再改 `version` 和 `sha256`。
- README：`.github/README.md`、`docs/pwe/README.en.md` 第一段改回下载说明。

## 1.1 发版前（Claude 做，不等 Lee）

- `package.sh` 的接收端 make 行合并后要同时带 `DIRECT_LINK_ONLY=1 COMPACT_IDLE=1 OFFER_LOGIN_ITEM=1`。
- cask 的 `zap` 加上 `~/Library/LaunchAgents/com.pwegroup.pweimacdisplay.receiver.plist`。
- 给上游提 PR：发送端「重新打开」按钮只退出不重开（PWE 已在 `rebrand.py` 里修）。
- 基线里发送端的问题已在 `pwe-1.1` 修完（2026-10-19），新 2017 款 iMac 默认 5K 60。等真机复测。
- Lumen Bar 的交接在它自己仓库的分支 `claude/imac-display-handoff-8e14dc`（e27f28a），未合并。和 1.1 一起发。
- 上游 PR 草稿在 `docs/pwe/notes-2026-10-19/upstream-pr*.md`，都没开。配对相关的要等披露之后。#212–#216 已在 2026-10-16 合进上游 `maint-3.6`，上游合并后从 `pwe/PATCHES.md` 里标「已合并」。
- 测试机清单里留到下一轮的：T20 Touch Bar 亮度（没有公开事件，只加了「按住 fn」说明）、T23 Metal 计时（先用同口径重测）、T30 接收端两处疑点（要真机）、T26 接收端在 Wi‑Fi 上进解析器（1.0.1 合进来、make 行带 `DIRECT_LINK_ONLY=1` 后复查）。1.0.x 的 T2–T8 不修。
- T34 的 IPv6 快路：真机通过、并过了披露期以后，再考虑提给上游（它改到了接收端的准入规则）。
- 上游 PR（Lee 2026-10-21 定）：10-28 发布前不提新的；发布后等 #222 有回音，再一周一个，先提不涉及安全的（剪贴板卡死、拔线检测、睡眠不叫醒、网桥地址）；涉及配对和准入的等披露期过后。
- 跟进上游 PR [#222](https://github.com/swellweb/targetBridge/pull/222)（T33 的状态修复，2026-10-21 提，基于 `maint-3.6`）。合并后在 `pwe/PATCHES.md` 标「已合并」。

## 仓库规矩

- 远端：`origin` 是 `kenshinice-ai/pwe-imac-display`，`upstream` 是 `swellweb/targetBridge`。
- 跟进上游：`git fetch upstream`，再把上游的发版提交合并进 `main`。成功判据：`git diff <上游标签> main` 只列出 PWE 加的文件。
- 给上游的 PR：在单独的 worktree 里从 `upstream/main` 开分支（`git worktree add <临时目录> -b <分支> upstream/main`），推到 `origin`，再向 `swellweb/targetBridge` 开 PR。
- 看界面不用截屏：运行打包出的 `PWE Screen Encore.app/Contents/MacOS/PWE Screen Encore --pwe-snapshot <目录>`，每个状态出一张中英文 PNG；接收端设 `TB_RECEIVER_SNAPSHOT=<文件.png>` 运行。
- 自动检查全部跑一遍：运行 `pwe/verify.sh`（`pwe-1.1` 起）；检查打好的包加 `--dmg <映像>`。成功判据：末尾表格没有 FAIL；SKIP 的每一行写着原因。
- 本地打包：运行 `pwe/package.sh`。成功判据：最后打印 `pwe/dist/local/PWE-Screen-Encore-<版本>.dmg` 和它的 sha256。正式包只由 `--notarize` 写进 `pwe/dist/`。
- 无签名打包（用户自己换 FFmpeg 重新链接，见 `pwe/NOTICE.txt`）：运行 `pwe/package.sh --unsigned --deps <目录>`。成功判据：同上，App 为 ad hoc 签名。
- 检查成品：挂载 DMG 后运行 `python3 -I pwe/check-bundle.py <两个 App>`。成功判据：打印 `bundle checks passed`。打包时已自动跑一次。
- 发版打包：
  1. 提交，再在本地打标签 `git tag pwe-<版本>`（不推）。
  2. 运行 `pwe/package.sh --notarize`。它要求 HEAD 正好是这个标签。成功判据：输出里 DMG 显示 `source=Notarized Developer ID`。
- 发版：
  1. 只推这一个标签：`git push origin pwe-<版本>`（不用 `v`）。
  2. release 上传 `pwe/dist/` 里的三个文件：`PWE-Screen-Encore-<版本>.dmg`、`ffmpeg-9.0.2.tar.xz`（LGPL 要求在同一处提供源代码）、`SHA256SUMS.txt`。
  3. 改 cask 的 `version` 和 `sha256`（1.1 起是新 cask `pwe-screen-encore`）。
  成功判据：`gh release download` 回来的文件通过 `shasum -c`，`brew fetch --cask kenshinice-ai/tap/<cask>` 显示 ✔。
- 如果合并上游后 `pwe/rebrand.py` 报 `upstream text changed`，就按报错改脚本里对应的锚点，不要改上游文件。

> ⚠️ 不要推送本地分支 `security-1.0.1`。否则发布前就公开了它的内容。
> 原因：它已并进 `pwe-1.1`，随 1.1 一起公开；发布后删除它（1.1 发布步骤 9）。

> ⚠️ 不要单独推送 `pwe-1.1`。它只在发布当天合进 `main` 后一起推（1.1 发布步骤 1、4）。否则配对代码在发布前公开。
> 原因：负责任披露。Marco 2026-10-20 收到一周通知；不发 1.0.1，修复随 1.1 发布。

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

### 哪台 Mac 做什么（Lee，2026-10-20）

- 这台 MacBook（用户 `llmacbookpro`，有 Developer ID）：唯一跑 git、打包、发版的 Mac。Claude 的 worktree 只建在这台 Mac 的临时目录里，不建在 iCloud 文件夹里。
- 另一台 MacBook Pro（用户 `leeliu`）：只装 App、连 iMac、做测试。测试包从 `pwe/dist/local/` 拿。结果写进 `docs/pwe/BASELINE-iMac18,3.md` 或告诉这台 Mac 上的 Claude。

> ⚠️ 不要在另一台 Mac 上跑 git、打包，或开 Claude 的 worktree。否则 iCloud 会生成「… 2」冲突副本，弄坏 `.git`。
> 原因：仓库在 iCloud 里，两台 Mac 看到的是同一个 `.git`，iCloud 不懂 git 的锁。2026-10-19 已出现过两个 `tb_trace 2.h`。

打测试包（这台 Mac）：

1. 运行 `security find-identity -v -p codesigning`。成功判据：列出 `Developer ID Application: Li Liu (2SQV3H5MH9)`。
2. 用 `git worktree add <临时目录> <分支>` 取出要打的分支，在那里运行 `pwe/verify.sh`，再运行 `pwe/package.sh`。成功判据：`verify.sh` 没有 FAIL；`package.sh` 最后打印 `PWE-Screen-Encore-<版本>.dmg` 和 sha256，`bundle checks passed`。
3. 挂载 DMG，运行 `codesign -dvv "<挂载点>/PWE Screen Encore.app"`。成功判据：`Authority=Developer ID Application: Li Liu (2SQV3H5MH9)`。
4. 把 DMG 拷进 `pwe/dist/local/`，重写同目录的 `SHA256SUMS.txt`。成功判据：`shasum -c SHA256SUMS.txt` 全部 OK。
5. 确认拷好之后，再 `git worktree remove` 临时目录。否则 DMG 跟着临时目录一起删掉（2026-10-21 出过一次）。

### 升级 iMac 上的接收端

iMac 开了文件共享。访客登录被拒绝（2026-10-19 实测），要用 iMac 的账号登录。

1. 在 MacBook 的 Finder 里，点侧栏「网络」里的 LL-iMac-2017，点「连接身份」，用 iMac 的账号登录（Lee 输密码）。成功判据：`ls /Volumes` 里出现 iMac 的共享。
2. 把新的「PWE Screen Encore Receiver.app」拷到共享里 iMac 用户的「桌面」。
3. 在 iMac 上退出接收端（`⌘Q`）。
4. 在 iMac 上把桌面上的 App 拖进「应用程序」，选「替换」。
5. 在 iMac 上打开接收端。成功判据：发送端几秒内自动连上；「关于」里显示新的构建号。

> ⚠️ 换成别的签名（ad hoc ↔ Developer ID）后，要在 iMac 上重新给接收端授权辅助功能和输入监控。否则键鼠共享不工作。
> 原因：这两项权限绑定 App 的签名。发送端的录屏权限同理。
