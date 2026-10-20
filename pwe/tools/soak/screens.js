// Prints the Mac's screens as JSON: name, Cocoa frame, and which one is the
// iMac (PWE Screen Encore's virtual display). Used by soak.sh and workload.js.
//
//   osascript -l JavaScript screens.js
//
// Read-only.
ObjC.import('AppKit');

function screens() {
  const list = $.NSScreen.screens.js;
  return list.map((s, i) => {
    const f = s.frame;
    const name = s.localizedName ? s.localizedName.js : `screen ${i}`;
    return {
      index: i,
      name: name,
      x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height,
      // The virtual display's name comes from rebrand.py (displayNamePrefix).
      isIMac: /PWE Screen Encore|PWE iMac Display/.test(name),
      isMain: i === 0,
    };
  });
}

function run() {
  return JSON.stringify(screens());
}
