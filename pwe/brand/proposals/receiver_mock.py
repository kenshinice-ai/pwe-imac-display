"""Receiver screen proposals as HTML: 1280 x 720 css px, one px = one display.c design unit
(min_side / 720). A picture of the proposal, not the receiver's code (BRAND doc, spec R1-R3).

    python3 -I receiver_mock.py "<01 BRAND ASSETS/source>" <out dir>
    "Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1280,720 \
        --screenshot=<out.png> file://<out dir>/zh-idle.html
"""
import sys, os
sys.path.insert(0, sys.argv[1]); OUT = sys.argv[2]
import wing_gen as W
paths, _t, _a, _top, bb = W.build(W.SOLID)
bw, bh = bb[2] - bb[0], bb[3] - bb[1]

def wing_svg(width, color):
    h = width * bh / bw
    ps = "".join('<path d="%s"/>' % paths[4 - i] for i in range(5))
    return ('<svg width="%.1f" height="%.1f" viewBox="%f %f %f %f" fill="%s" aria-hidden="true">%s</svg>'
            % (width, h, bb[0], bb[1], bw, bh, color, ps))

def spinner(r, color):
    import math
    ticks = []
    for i in range(12):
        a = math.radians(i * 30)
        op = 0.25 + 0.75 * (i / 11)
        x1, y1 = r * 0.55 * math.sin(a), -r * 0.55 * math.cos(a)
        x2, y2 = r * math.sin(a), -r * math.cos(a)
        ticks.append('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke-opacity="%.2f"/>' % (x1, y1, x2, y2, op))
    return ('<svg width="%d" height="%d" viewBox="%d %d %d %d" stroke="%s" stroke-width="%.1f" stroke-linecap="round">%s</svg>'
            % (2 * r, 2 * r, -r, -r, 2 * r, 2 * r, color, r * 0.16, "".join(ticks)))

CSS = """
:root{--night:#0E1729;--night2:#16233D;--label:#F7F5F2;--label2:rgba(247,245,242,.66);--label3:rgba(247,245,242,.40);
--label4:rgba(247,245,242,.20);--line:rgba(247,245,242,.12);--signal:#F5B335;--alert:#E8654E}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1280px;height:720px;background:var(--night);color:var(--label);overflow:hidden;
 font-family:system-ui,-apple-system,"PingFang SC",sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}
.stage{position:absolute;left:0;right:0;top:0;bottom:0}
.block{position:absolute;left:0;right:0;top:calc(47% - var(--half));display:flex;flex-direction:column;align-items:center;text-align:center}
.name{font-size:28px;font-weight:600;margin-top:55px;letter-spacing:0}
:lang(en) .name{letter-spacing:.007em}
.state{font-size:22px;color:var(--label);margin-top:21px;font-weight:400}
.hint{font-size:15px;color:var(--label2);margin-top:8px;line-height:1.5}
.code{font-size:34px;font-weight:600;letter-spacing:.08em;margin-top:21px;font-feature-settings:"tnum"}
.warn{color:var(--signal)}
.foot{position:absolute;left:0;right:0;bottom:34px;text-align:center;font-size:12px;color:var(--label2)}
.spin{margin-top:21px}
"""

STR = {
 "zh": dict(state="等待 Mac 连接", hint="在 Mac 上打开 PWE iMac Display，接上雷雳线。", foot="1.1.0　·　按 I 查看详情",
            enter="在 Mac 上输入这 6 位数字", notyou="不是你在配对？拔掉线即可。", conn="正在连接你的 Mac", first="正在等待第一帧…",
            unenc="未加密：只传画面和声音。", unenc2="可在 Mac 的设置里关闭不加密连接。"),
 "en": dict(state="Waiting for your Mac", hint="Open PWE iMac Display on your Mac and connect a Thunderbolt cable.",
            foot="1.1.0  ·  Press I for details", enter="Enter these 6 digits on your Mac", notyou="Not you? Unplug the cable.",
            conn="Connecting to your Mac", first="Waiting for the first frame…",
            unenc="Not encrypted: picture and sound only.", unenc2="You can turn off unencrypted connections in Settings on your Mac."),
}

def page(lang, mode):
    s = STR[lang]
    wing = wing_svg(144, "var(--label)")
    if mode == "idle":
        body = '<div class="state">%s</div><div class="hint">%s</div>' % (s["state"], s["hint"]); half = 120
    elif mode == "code":
        body = ('<div class="code">482&ensp;913</div><div class="hint" style="color:var(--label);font-size:17px;margin-top:13px">%s</div>'
                '<div class="hint">%s</div>' % (s["enter"], s["notyou"])); half = 140
    elif mode == "connecting":
        body = ('<div class="state">%s</div><div class="hint">%s</div><div class="spin">%s</div>'
                % (s["conn"], s["first"], spinner(14, "rgba(247,245,242,.40)"))); half = 140
    elif mode == "warn":
        body = ('<div class="state">%s</div><div class="hint">%s</div><div class="hint warn" style="margin-top:21px">%s</div>'
                % (s["conn"], s["first"], s["unenc"])); half = 140
    html = ('<!doctype html><html lang="%s"><head><meta charset="utf-8"><style>%s</style></head><body><div class="stage">'
            '<div class="block" style="--half:%dpx">%s<div class="name">PWE iMac Display</div>%s</div>'
            '<div class="foot">%s</div></div></body></html>' % ("zh-Hans" if lang == "zh" else "en", CSS, half, wing, body, s["foot"]))
    return html

DCSS = CSS + """
.panel{position:absolute;left:48px;right:48px;top:52px;bottom:52px}
.head{display:flex;justify-content:space-between;align-items:baseline;padding:0 0 21px;border-bottom:1px solid var(--line)}
.title{font-size:28px;font-weight:600}.sub{font-size:15px;color:var(--label2);margin-top:4px}
.ver{font-size:15px;color:var(--label2);text-align:right}.ver small{display:block;font-size:12px;margin-top:4px}
.cap{font-size:13px;color:var(--label2);font-weight:600;letter-spacing:.02em}
.ip{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:28px;font-weight:600;margin-top:4px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:13px;margin-top:21px}
.card{background:var(--night2);border-radius:13px;padding:21px}
.card .cap{margin-top:13px}.card .cap:first-child{margin-top:0}
.val{font-size:20px;margin-top:4px}.dim{color:var(--label2)}
.help{position:absolute;bottom:0;left:0;font-size:15px;color:var(--label2);line-height:1.6}
"""

DSTR = {"zh": dict(title="PWE iMac Display 接收端", sub="等待 Mac 连接", ipcap="雷雳网桥地址", status="状态", sv="等待 Mac 连接",
                   sender="Mac", senderv="—", disp="显示器", dispv="iMac 27 英寸 · 5120 × 2880", mode="画面", modev="5K · 60 Hz",
                   langc="语言", langv="自动", login="登录时打开", loginv="开", logint="按 A 切换", perm="权限", permv="齐全",
                   help=["在 Mac 上打开 PWE iMac Display，接上雷雳线即可。", "按 L 切换语言 · 按 I 返回"]),
        "en": dict(title="PWE iMac Display Receiver", sub="Waiting for your Mac", ipcap="Thunderbolt Bridge address", status="Status",
                   sv="Waiting for your Mac", sender="Mac", senderv="—", disp="Display", dispv="iMac 27-inch · 5120 × 2880",
                   mode="Picture", modev="5K · 60 Hz", langc="Language", langv="Automatic", login="Open at Login", loginv="On",
                   logint="Press A to change", perm="Permissions", permv="All granted",
                   help=["Open PWE iMac Display on your Mac and connect a Thunderbolt cable.", "L language · I back"])}

def details(lang):
    d = DSTR[lang]
    return ('<!doctype html><html lang="%s"><head><meta charset="utf-8"><style>%s</style></head><body><div class="panel">'
            '<div class="head"><div><div class="title">%s</div><div class="sub">%s</div></div><div class="ver">1.1.0<small>20261020000000</small></div></div>'
            '<div style="margin-top:21px"><div class="cap">%s</div><div class="ip">169.254.6.224</div></div>'
            '<div class="grid"><div class="card"><div class="cap">%s</div><div class="val">%s</div><div class="cap">%s</div><div class="val">%s</div></div>'
            '<div class="card"><div class="cap">%s</div><div class="val">%s</div><div class="cap">%s</div><div class="val">%s</div></div>'
            '<div class="card"><div class="cap">%s</div><div class="val">%s</div><div class="cap">%s</div><div class="val">%s</div></div>'
            '<div class="card"><div class="cap">%s</div><div class="val">%s <span class="dim">· %s</span></div></div></div>'
            '<div class="help">%s</div></div></body></html>'
            % ("zh-Hans" if lang == "zh" else "en", DCSS, d["title"], d["sub"], d["ipcap"], d["status"], d["sv"], d["sender"], d["senderv"],
               d["disp"], d["dispv"], d["mode"], d["modev"], d["langc"], d["langv"], d["perm"], d["permv"], d["login"], d["loginv"], d["logint"],
               "<br>".join(d["help"])))

os.makedirs(OUT, exist_ok=True)
for lang in ("zh", "en"):
    for mode in ("idle", "code", "connecting", "warn"):
        open(os.path.join(OUT, "%s-%s.html" % (lang, mode)), "w").write(page(lang, mode))
    open(os.path.join(OUT, "%s-details.html" % lang), "w").write(details(lang))
