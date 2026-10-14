# PWE 对上游文件的改动

`main` 以 TargetBridge 的上游 `main`（3.6.0，`11b156f`）为基线。PWE 自己的文件在 `pwe/`、`docs/pwe/`、
`HANDOFF.md`、`.github/README.md`、`.github/SECURITY.md`，不在这张表里。

这张表只记**改了上游文件**的提交：改了什么、为什么、上游状态。

- 新增一条：先给上游提 PR，再把 PR 号写进这里。
- 上游合并后：在「状态」一栏写「已合并」和上游的提交号。下次合并上游时，冲突应当自动消失。
- 上游拒绝：写明原因，以及 PWE 是否继续保留。

| 提交 | 改了什么 | 为什么 | 上游 | 状态（2026-10-15） |
|---|---|---|---|---|
| `3ee1bff`（经 `2a5319b` 合并） | 简体中文：`zh.json` 和发送端 Swift 里的中文 | 夹杂英文、术语不统一、用词与 macOS 不一致 | [#212](https://github.com/swellweb/targetBridge/pull/212) | 等审阅 |
| `081c7a5` | 接收端连接画面按字宽居中；新键 `receiver.splash.role`（五种语言） | 文字偏离中心，「RECEIVER」没有翻译 | [#214](https://github.com/swellweb/targetBridge/pull/214) | 等审阅 |
| `3e9915f` | 接收端：详情画面方向修正；连接画面用 App 自己的图标、窗口标题用 App 名；`TB_RECEIVER_SNAPSHOT` 截图钩子；可选的安静等待画面（`COMPACT_IDLE`）和开机自启询问（`OFFER_LOGIN_ITEM`），默认都关 | 详情画面一直是上下颠倒的；PWE 1.1 要安静画面和开机自启 | 方向修正：[#215](https://github.com/swellweb/targetBridge/pull/215)；其余待提 | 方向修正等审阅 |
| `3055222` | 删除 `.github/FUNDING.yml` | Lee 2026-10-14 定：本仓库不显示上游的赞助按钮 | 不提交（只属于 PWE） | 保留 |

打包时的改名（`pwe/rebrand.py`）不改仓库里的文件，所以不在这张表里。它的锚点由脚本自己检查：上游改了对应的文字，脚本就会停下。

另有一条跟进中的上游 PR，不改本仓库文件：
[#213](https://github.com/swellweb/targetBridge/pull/213)，发送端第一次打开时跟随系统语言。PWE 现在是由 `rebrand.py` 在打包时做到这一点的；上游合并后，删掉 `rebrand.py` 里的 `LANGUAGE_FALLBACK`。
