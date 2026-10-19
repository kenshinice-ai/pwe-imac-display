# PWE iMac Display 1.1：真机测试清单

> 2026-10-19 汇总。对象：`pwe-1.1` 8bfcfcf（1.1 的全部改动）。所有项目都**未在真机上验证**。
> 设备：发送端 MacBook Pro M1，接收端 iMac18,3（macOS 13.7.8）。基线数据在 `BASELINE-iMac18,3.md`。
> 各线的原始说明在 `docs/pwe/notes-2026-10-19/`（不入库，iCloud 会同步）。

## 准备

1. 在有 Developer ID 的 Mac 上，按 HANDOFF「八」节打 1.1 的包。成功判据：两个 App 都是 `Authority=Developer ID Application: Li Liu (2SQV3H5MH9)`。
2. 在 MacBook 上把发送端装进「应用程序」。签名换了，要重新给录屏权限。
3. 按 HANDOFF「八」节把接收端装进 iMac 的「应用程序」，替换桌面上那份。成功判据：iMac 上「关于」显示 1.1.0 和新的构建号。
4. 在 MacBook 上开事件记录，和基线同一条 `log stream` 命令。

## A 拔线、睡眠、重开（对照基线）

| # | 做什么 | 通过判据 |
|---|---|---|
| A1 | 显示中拔插线 5 次 | 插回后几秒内出画面（基线 22.6–35.8 秒）；日志里没有从 bridge0 拨 Wi‑Fi 地址 |
| A2 | 拔一次线，看日志 | 约 0.2 秒后出现 `connect: no route … closing in 2 s`（基线 18.3–18.6 秒） |
| A3 | iMac 上退出再打开接收端 | 自动重连，不用「刷新 IP」，不用拔插线 |
| A4 | 选「画面 › 5K · 60 Hz」，再拔线、睡眠、重开发送端 | 每次回来都是 60 Hz（`preset=native5k60Experimental`） |
| A5 | 苹果菜单 › 睡眠，5 次 | Mac 真的睡着：`pmset -g log` 有 Sleep，没有「PWE iMac Display capture requested」的 UserIsActive；醒来后出画面 |
| A6 | 系统设置 › 显示器 | 名字是「PWE iMac Display」 |

## B 声音

| # | 做什么 | 通过判据 |
|---|---|---|
| B1 | 播放有声视频，声音选「只在 iMac」（默认） | 只有 iMac 响，Mac 的音量图标是静音 |
| B2 | 断开，再退出发送端 | 两次之后 Mac 的扬声器都恢复 |
| B3 | 选「两边都播放」，再选「只在这台 Mac」 | 前者两边响；后者 iMac 不响 |

## C 菜单栏和设置窗口

| # | 做什么 | 通过判据 |
|---|---|---|
| C1 | 显示中看菜单栏 | 状态一行、亮度滑块；iMac 报了才出现夜览和原彩 |
| C2 | 显示中从菜单换画面、换声音 | 几秒重连，按新设置工作 |
| C3 | 显示中在设置里改显示模式、大指针、压缩、渲染匹配 | 自动重连，有一句提示 |
| C4 | 把 iMac 从 `pwe.pictures` 删掉（当新 iMac） | 第一次连接就是 5K 60 |
| C5 | 关主窗口，再从菜单打开主窗口和设置 | 都能打开 |
| C6 | 隐藏菜单栏图标、关窗口、从访达打开 App | 窗口回来 |
| C7 | 设置 › 高级 › 存储报告 | 文件里有日志 |
| C8 | 语言 | 这台 en-AU 的 Mac 上是英文 |

## D 亮度键和 Lumen Bar

| # | 做什么 | 通过判据 |
|---|---|---|
| D1 | 设置里打开亮度键（没给辅助功能权限时） | 弹系统提示和说明；授权后不用重开就能用 |
| D2 | 指针在 iMac 上，按 F1/F2（MacBook、Touch Bar、妙控键盘、第三方键盘） | iMac 背光按 16 档变，iMac 上有提示框，Mac 自己的屏不变 |
| D3 | 按住 ⇧⌥ 再按 | 64 档 |
| D4 | 指针回到 Mac 屏上按 F1/F2 | 调的是 Mac 自己的屏 |
| D5 | 打开「减少动态效果」「降低透明度」 | 提示框不淡入、不透明 |
| D6 | 窗口关着时运行 `open -g "pweimacdisplay://brightness?step=-1"` | iMac 上出提示框，不弹窗口 |
| D7 | 装上 Lumen Bar 的交接分支，拖 Lumen Bar 里 iMac 那张卡的亮度 | iMac 背光变；Lumen Bar 不再对 iMac 做软件调暗 |

## E 渲染（Metal、iMac 自己画指针）

照 `docs/pwe/TEST-render-1.1-2026-10-19.md`（在 `pwe-1.1` 分支上）做：在 iMac 上运行 `pwe/tools/pwe-imac-perf.command`，再用手机 240 fps 拍四组（OpenGL 5K48、OpenGL 5K60、Metal 5K60、Metal 5K60 + iMac 画指针）。

通过判据：Metal 的 CPU 不高于 OpenGL；帧率不低于 OpenGL；颜色正确，不闪；iMac 画的指针跟手。
出问题时在 iMac 上运行 `defaults write com.pwegroup.pweimacdisplay.receiver TBReceiverRenderDriver opengl` 退回 OpenGL。

## F 配对与加密

19 项，照 `docs/pwe/notes-2026-10-19/pairing-r2-imac-tests-2026-10-19.md` 做（不入库）。要点：首次配对出码、重插不再要码、码错和过期、两边「忘记」、上游发送端只传画面声音、iMac 上关掉「允许未加密连接」、重启后不弹钥匙串、i5 上的加密测速（第 10 项）。

## G 等 Lee 定的事

1. **画面默认值**：新 2017 款 iMac 默认 5K 60（已按此做）。你这台 iMac 记着 48，要在菜单里选一次 60。2014、2015 款等实测。
2. **指针默认由 iMac 画吗**：E 测完再定。开关是 `fd.tbdisplaysender.receiverDrawnPointer`。
3. **配对界面的文字**：标 DRAFT 的几条在 `notes-2026-10-19/pairing-ui-2026-10-19.md`「Open strings for Lee」。
4. **重设计里替你定的几条**：最后一屏问「登录时打开」和「自动连接」；选画面会删掉上游的按 iMac 配置；语言每次启动跟随系统。见 `notes-2026-10-19/settings-redesign-2026-10-19.md`。
5. **登录时只出菜单栏图标、不弹主窗口吗**：现在每次登录都弹主窗口。
6. **Network Link 的接收端开关**：现在要在 iMac 上用 `defaults write … AllowLocalNetwork` 打开，iMac 的界面上没有开关。
