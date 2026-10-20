# 长时间办公模拟（soak test）

在 Mac（发送端）上跑，把 iMac 当扩展屏，模拟一个人连续办公：在 iMac 上打字、浏览网页并滚动、在两块屏之间挪窗口、鼠标跨屏、偶尔放视频，中间穿插 1–3 分钟的「阅读时间」。
每 30 秒记录一次：iMac 这块屏还在不在、发送端的处理器和内存；同时记下发送端自己的连接日志。结束时写 `summary.md`，按发布门槛给出通过或不通过。

不改任何设置。只打开自己的笔记文件、几个 Safari 页面和你指定的视频，结束时不保存、关掉。运行期间 Mac 保持唤醒。

## 准备（测试机，一次）

1. 给跑脚本的程序开「辅助功能」：系统设置 › 隐私与安全性 › 辅助功能，加上「终端」（或运行脚本的那个 App）。成功判据：下面第 3 步的检查不报「not allowed to send keystrokes」。
2. Mac 上打开 PWE Screen Encore，连上 iMac，画面出来。
3. 先跑 2 分钟检查：

   ```bash
   "/Users/<你>/Library/Mobile Documents/com~apple~CloudDocs/PARADISE PRODUCTION/07 TOOLS/PWE iMac Display/pwe/tools/soak/soak.sh" --check
   ```

   成功判据：最后打印 `summary.md` 的路径，里面第一道门「iMac display never disappeared」是 PASS。

可选：
- 想同时记 iMac 上接收端的处理器和内存，在 iMac 上打开「系统设置 › 通用 › 共享 › 远程登录」，在 Mac 上配好 SSH 密钥（`ssh-copy-id 用户名@LL-iMac-2017.local`），运行时加 `--imac 用户名@LL-iMac-2017.local`。
- 想放真实视频，加 `--video /路径/片子.mov`（E 组用过的那段就行）。不加时用 testufo.com 的动画页代替。

## 正式跑

```bash
".../pwe/tools/soak/soak.sh" --hours 2
```

- `--hours 8`：跑 8 小时；`--hours 0`：一直跑，按 `Ctrl-C` 停。停下时同样会收尾并写汇总。
- 跑的时候可以在旁边看、也可以离开；不要在 Mac 上干别的事，键盘鼠标会被脚本用到。
- 结果在 `docs/pwe/test-mac-<日期>/soak-<时间>/`。测试机只读这些文件、把结论写进 `BASELINE-iMac18,3.md`，不跑 git。

## 看结果

`summary.md` 的三道门：

| 门 | 判据 |
|---|---|
| iMac 屏一直在 | 没有任何一次采样里 iMac 这块屏消失 |
| 发送端没崩 | 进程号没变，也没有哪次采样里它不在 |
| 内存不持续涨 | 前 10 分钟之后，内存趋势低于 50 MB/小时 |

还要人看的：
- 跑的过程中画面有没有卡顿、花屏、声音断续（脚本测不到）。
- `events.log` 里除第一次以外的每一次 `dialing`、`no route`、`closing`：没拔线却出现，就是一次掉线，记下时间点。
- `workload.log` 里 `"ok":false` 的步骤：多半是窗口没找到或权限不够，不一定是 App 的问题。

## 文件

| 文件 | 作用 |
|---|---|
| `soak.sh` | 总控：检查、记录、按顺序做办公动作、收尾 |
| `workload.js` | 一个办公动作（打字、浏览、挪窗口、鼠标、视频、收尾），JavaScript for Automation |
| `screens.js` | 列出屏幕，认出哪块是 iMac |
| `summarize.py` | 写 `summary.md` |
