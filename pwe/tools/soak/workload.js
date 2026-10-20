// One step of simulated office work on the iMac's screen, for soak.sh.
//
//   osascript -l JavaScript workload.js <step> <workdir> [video-path]
//
// Steps: type, browse, windows, mouse, video, cleanup.
// Needs Accessibility for the app that runs it (Terminal, or whatever runs
// soak.sh): System Events types and scrolls. Prints one JSON line per step.
//
// Only touches what it opens itself: a notes file in <workdir>, Safari windows
// showing the pages below, and QuickTime with the given video. `cleanup`
// closes those without saving.
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
ObjC.import('Foundation');

const PAGES = [
  'https://en.wikipedia.org/wiki/IMac',
  'https://en.wikipedia.org/wiki/Retina_display',
  'https://developer.apple.com/documentation/screencapturekit',
  'https://www.apple.com/mac/',
];

const SENTENCES = [
  'Quarterly notes for the display test.',
  'The iMac shows this window while the Mac does the work.',
  'Typing should feel immediate, with no lag between key and letter.',
  'Scrolling a long page should stay smooth on the 5K panel.',
  'Windows move between the two screens without the picture tearing.',
  'This paragraph exists only to keep the encoder busy with small changes.',
];

const se = Application('System Events');

function screens() {
  return $.NSScreen.screens.js.map((s) => ({
    name: s.localizedName ? s.localizedName.js : '',
    x: s.frame.origin.x, y: s.frame.origin.y, w: s.frame.size.width, h: s.frame.size.height,
  }));
}

// Cocoa frames are bottom-left based on the main screen; window bounds and
// mouse events are top-left based. Returns the iMac's rect in top-left space.
function imacRect() {
  const all = screens();
  const main = all[0];
  const imac = all.find((s) => /PWE Screen Encore|PWE iMac Display/.test(s.name));
  if (!imac) throw new Error('no PWE Screen Encore display: is the iMac connected?');
  return { x: imac.x, y: main.h - (imac.y + imac.h), w: imac.w, h: imac.h };
}
function mainRect() {
  const m = screens()[0];
  return { x: m.x, y: 0, w: m.w, h: m.h };
}
function inset(r, f) {
  return { x: Math.round(r.x + r.w * f), y: Math.round(r.y + r.h * f + 30),
           width: Math.round(r.w * (1 - 2 * f)), height: Math.round(r.h * (1 - 2 * f) - 30) };
}
function pause(s) { delay(s); }

function notesPath(workdir) { return `${workdir}/soak-notes.txt`; }

function ensureNotes(workdir) {
  const fm = $.NSFileManager.defaultManager;
  const p = notesPath(workdir);
  if (!fm.fileExistsAtPath(p)) $(`Soak test notes\n`).writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null);
  return p;
}

function textEditDoc(workdir) {
  const te = Application('TextEdit');
  const p = ensureNotes(workdir);
  te.open(Path(p));
  pause(1.5);
  te.activate();
  return te;
}

const steps = {
  type(workdir) {
    const where = inset(imacRect(), 0.12); // fails before opening anything without the iMac
    const te = textEditDoc(workdir);
    te.windows[0].bounds = where;
    pause(0.5);
    se.keyCode(125, { using: 'command down' }); // to the end
    for (let i = 0; i < 8; i++) {
      const line = SENTENCES[Math.floor(Math.random() * SENTENCES.length)];
      for (const word of line.split(' ')) { se.keystroke(word + ' '); pause(0.08 + Math.random() * 0.12); }
      se.keyCode(36); // return
      pause(0.6 + Math.random());
    }
    return 'typed 8 lines on the iMac';
  },

  browse() {
    const where = inset(imacRect(), 0.05);
    const safari = Application('Safari');
    const url = PAGES[Math.floor(Math.random() * PAGES.length)];
    safari.activate();
    const doc = safari.Document().make();
    pause(0.5);
    doc.url = url;
    pause(4);
    safari.windows[0].bounds = where;
    pause(1);
    for (let i = 0; i < 12; i++) { se.keyCode(121); pause(0.8 + Math.random() * 0.8); } // page down
    for (let i = 0; i < 6; i++) { se.keyCode(116); pause(0.6); } // page up
    return `browsed ${url}`;
  },

  windows(workdir) {
    const imac = imacRect();
    const te = textEditDoc(workdir);
    const w = te.windows[0];
    for (let i = 0; i < 3; i++) {
      w.bounds = inset(mainRect(), 0.15); pause(2);
      w.bounds = inset(imac, 0.2); pause(2);
      w.bounds = inset(imac, 0.05); pause(2);
    }
    return 'moved a window between the screens 3 times';
  },

  mouse() {
    const a = mainRect(), b = imacRect();
    const from = { x: a.x + a.w / 2, y: a.y + a.h / 2 }, to = { x: b.x + b.w / 2, y: b.y + b.h / 2 };
    const glide = (p, q) => {
      for (let i = 0; i <= 60; i++) {
        const t = i / 60;
        const pt = { x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t };
        const ev = $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, pt, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, ev);
        pause(0.016);
      }
    };
    for (let i = 0; i < 4; i++) { glide(from, to); pause(1); glide(to, from); pause(1); }
    return 'moved the pointer across both screens 8 times';
  },

  video(workdir, videoPath) {
    const imac = imacRect();
    if (videoPath) {
      const qt = Application('QuickTime Player');
      qt.activate();
      const doc = qt.open(Path(videoPath));
      pause(2);
      qt.windows[0].bounds = inset(imac, 0.1);
      try { doc.looping = true; } catch (e) { /* older QuickTime */ }
      doc.play();
      pause(120);
      doc.pause();
      return `played ${videoPath} for 120 s`;
    }
    const safari = Application('Safari');
    safari.activate();
    const doc = safari.Document().make();
    doc.url = 'https://www.testufo.com/';
    pause(4);
    safari.windows[0].bounds = inset(imac, 0.0);
    pause(120);
    return 'moving test page on the iMac for 120 s (no --video given)';
  },

  cleanup(workdir) {
    const closed = [];
    try {
      const te = Application('TextEdit');
      if (te.running()) {
        const p = notesPath(workdir);
        te.documents().forEach((d) => { if (d.path() === p) { d.close({ saving: 'no' }); closed.push('notes'); } });
      }
    } catch (e) { closed.push('notes: ' + e); }
    try {
      const safari = Application('Safari');
      if (safari.running()) {
        safari.windows().forEach((w) => {
          try {
            const u = w.currentTab().url() || '';
            if (PAGES.includes(u) || u.startsWith('https://www.testufo.com')) { w.close(); closed.push('safari'); }
          } catch (e) { /* window without tabs */ }
        });
      }
    } catch (e) { closed.push('safari: ' + e); }
    return `closed ${closed.length} window(s)`;
  },
};

function run(argv) {
  const [step, workdir, videoPath] = argv;
  const started = new Date();
  try {
    if (!steps[step]) throw new Error(`unknown step ${step}`);
    const note = steps[step](workdir, videoPath);
    return JSON.stringify({ t: started.toISOString(), step, ok: true, note });
  } catch (e) {
    return JSON.stringify({ t: started.toISOString(), step, ok: false, error: String(e) });
  }
}
