# PWE iMac Display

Turn a 2014–2017 5K iMac into a display for a newer Mac. No firmware hacks, no
teardown, one Thunderbolt cable. [中文](../../.github/README.md)

> **Version 1.1 is being tested on real iMacs and is coming soon.** 1.0.0 has been withdrawn:
> its sound did not work, and 1.1 fixes that. To hear when it is out, choose Watch › Custom › Releases.

## What it is

Apple dropped Target Display Mode with the 5K iMac in late 2014, and Apple silicon
Macs cannot use it at all. Those iMacs still have excellent screens.

- **PWE iMac Display** on the newer Mac creates a virtual display, encodes it and
  sends it over Thunderbolt Bridge.
- **PWE iMac Display Receiver** on the iMac decodes it and shows it full screen.

## How it relates to TargetBridge

PWE iMac Display is a build of the open-source project
[TargetBridge](https://github.com/swellweb/targetBridge) by Marco Caciotti
(swellweb) and the TargetBridge community. Its core code is TargetBridge's, used
under the MIT License. On top of it, PWE adds:

- **Signing**: Developer ID signed and notarised by Apple, so it opens with a
  double-click and no `xattr` in Terminal.
- **Older iMacs**: the receiver builds its own FFmpeg and SDL2 for macOS 11,
  which addresses upstream [#167](https://github.com/swellweb/targetBridge/issues/167).
- **Licensing**: the receiver uses a decode-only LGPL build of FFmpeg, with no
  GPL components.
- **Chinese**: the Chinese interface is reviewed against macOS's own terms, and
  the sender follows the system language.
- **Compatibility**: the wire protocol and Bonjour service are TargetBridge's, so
  either sender works with either receiver.

Fixes go to TargetBridge first, such as the
[Chinese polish, #212](https://github.com/swellweb/targetBridge/pull/212).

## Requirements

- A Mac with Apple silicon or Intel, macOS 14 or later, for the sender.
- A 5K iMac for the receiver, which targets macOS 11.
- A Thunderbolt cable. 2014 and 2015 iMacs have Thunderbolt 2 and need Apple's
  Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter.

## Licences

TargetBridge is MIT ([LICENSE](../../LICENSE)). FFmpeg is LGPL 2.1 or later and
SDL2 is zlib; see [pwe/NOTICE.txt](../../pwe/NOTICE.txt). The PWE name and icon
are not covered by the open-source licences.
