# PWE Screen Encore user guide

Bring your 5K iMac back on stage: use a 2014–2020 27-inch 5K iMac as a display for a newer Mac. For PWE Screen Encore 1.1 and later.
Before 1.1 the app was called PWE iMac Display.

> This guide covers the PWE-signed version only. The `README.md` at the repository root is the upstream TargetBridge readme; its download links and `xattr` steps do not apply to this version.

## What you need

| | Requirement |
|---|---|
| Newer Mac (sender) | Apple silicon, macOS 14 or later. Intel Macs are untested; upstream TargetBridge says they are not supported. |
| iMac (receiver) | 27-inch 5K iMac, macOS 11 or later |
| Cable | Any Thunderbolt 3, 4 or 5 cable. A passive cable of 1 m or shorter is usually the most reliable. |
| Adapter | 2014 and 2015 iMacs only: Apple's Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter |

> ⚠️ Don't use an ordinary USB-C to Mini DisplayPort adapter. It carries only a video signal, not Thunderbolt data, so the two Macs can't connect.

> We have tested fully on a 2017 27-inch 5K iMac (iMac18,3). Other 2014–2020 models should work by design, and we're collecting results. If you try one, please open a "Model report" issue with the iMac model and macOS version.

## Install

> ⚠️ If you installed PWE iMac Display (this app's old name), move the old copies to the Trash first: one on the newer Mac and one on the iMac. If both copies stay, macOS may open the old one. Settings and pairings are kept, and the new version uses them.

1. On the newer Mac, open `PWE-Screen-Encore-<version>.dmg`.
2. Drag PWE Screen Encore into Applications.
3. Copy PWE Screen Encore Receiver into the iMac's Applications folder. A USB drive, AirDrop or file sharing all work.
4. On the iMac, open PWE Screen Encore Receiver from Applications.
   Check: the screen shows the PWE Screen Encore icon, its name and "Waiting for your Mac".
5. The first time it opens, the receiver asks "Open the receiver when this Mac starts?". We recommend Open at Login.
   It asks only when opened from Applications, not when opened straight from the disk image.
6. On the newer Mac, open PWE Screen Encore.
7. The first time, the main window shows "Allow Screen & System Audio Recording". Click Open System Settings and allow PWE Screen Encore under Privacy & Security.
   On macOS 14 the setting is called Screen Recording.
8. Go back to PWE Screen Encore. Check: the main window changes to "Looking for your iMac".
   If it still asks for permission, click Reopen PWE Screen Encore.

Both apps are notarized by Apple, so they normally open without a security warning. If you see "is damaged" or "can't be opened because Apple cannot check it":

1. Make sure the file came from the GitHub release page or Homebrew.
2. In Terminal, run `shasum -a 256 PWE-Screen-Encore-<version>.dmg` and compare the result with the value in `SHA256SUMS.txt` on the release page.
3. If they match and the warning remains, please open an issue with your macOS version and a screenshot of the warning. Don't use `xattr` to get around the check.

With Homebrew, run these on the newer Mac. You need the first line only once: from Homebrew 7, you must trust PWE's tap before installing.

```bash
brew trust kenshinice-ai/tap
brew install --cask kenshinice-ai/tap/pwe-screen-encore
```

This installs both apps in Applications. You still need to copy the receiver to the iMac.

## Connect

1. Connect the two Macs with the Thunderbolt cable.
2. Watch PWE Screen Encore's main window on the newer Mac. After a few seconds the iMac appears.
   - With one iMac, click Use as Display.
   - With several, choose one under "Choose your iMac", then click Use as Display.
3. The first time, the iMac shows a 6-digit code and the Mac asks you to "Enter the code shown on your iMac". Type it and click Pair.
   You do this once per Mac and iMac; after that they connect without a code.
4. Check: after a few seconds the iMac shows the newer Mac's screen, and the main window says "… is a display".
5. Click Arrange Displays… and, in System Settings › Displays, drag the iMac to where it actually sits.

If the iMac never appears, you can enter its IP address: from the menu bar icon choose Settings…, go to Advanced, click Open… next to Full Console, choose Manual entry under the receiver, and type the iMac's IP address.
The IP address is in the small text at the bottom of the iMac's screen; press I there for full details.

## Everyday use

- **Connect automatically when the cable goes in:** after the first successful connection, PWE Screen Encore remembers the iMac. Whenever it appears on the Thunderbolt cable, it becomes a display again.
  If you click Disconnect in the main window or the menu bar, or stop in the Full Console, it won't reconnect by itself this time. Unplugging and replugging the cable, or quitting and reopening the app, turns automatic connection back on.
  To turn this off, go to Settings… › General and turn off "Connect automatically when the cable goes in".
- **Open at login on the newer Mac:** the first time you connect, "Open at login" in the main window is on by default; change it later in Settings… › General. If "Allow in Login Items & Extensions…" appears below it, click it and allow the app in System Settings.
- **Open the receiver when the iMac starts:** on the iMac's receiver screen, press I for details, then press A to switch. The details show OPEN AT LOGIN as On or Off.
- **The receiver screen:** while waiting it shows only the name and one line of help. Press I for the IP address, status and permissions; press I again to go back.
- **Brightness, picture and sound:** all under the menu bar icon.
- **Adjust the iMac with the brightness keys:** in Settings… › General, turn on "Brightness keys adjust the iMac". With the pointer on the iMac, press F1 or F2 to change the iMac's brightness.
  On a Mac with a Touch Bar, hold fn and press F1 or F2. The Touch Bar's brightness buttons change only that Mac (measured on a MacBook Pro M1, 2026-10-20).
- **Keyboard, mouse and clipboard:** choose in Settings… › Keyboard & Mouse.
  "Control the iMac from this Mac": the clipboard goes from the Mac to the iMac.
  "Control this Mac from the iMac": the first time, the iMac asks for Input Monitoring and Accessibility; click Allow. The clipboard goes from the iMac to the Mac.
  Off: no keyboard, mouse or clipboard sharing.
- **Full Console:** Full Console in Settings… › Advanced opens TargetBridge's own console, where you can adjust bitrate, encoding, several receivers and more.

## Keyboard shortcuts

**On the Mac**

| Keys | What it does | When it works |
|---|---|---|
| ⌘D | Disconnect the iMac | The menu bar menu is open and the iMac is connected |
| ⌘, | Open Settings | The menu bar menu is open |
| ⌘Q | Quit PWE Screen Encore | The menu bar menu is open |
| F1, F2 or the brightness keys | Adjust the iMac's brightness | "Brightness keys adjust the iMac" is on and the pointer is on the iMac (hold fn on a Mac with a Touch Bar) |

**While sharing the keyboard and mouse**

| Keys | What it does | Which keyboard |
|---|---|---|
| ⌃⌥⌘K | Stop sharing at once | The one doing the controlling: the Mac's keyboard for "Control the iMac from this Mac", the iMac's keyboard for "Control this Mac from the iMac" |

⌃⌥⌘K stops sharing for this connection only; the next connection follows your settings again. To turn sharing off for good, choose Off in Settings… › Keyboard & Mouse.

**On the iMac's receiver screen** (while waiting for a connection)

| Keys | What it does |
|---|---|
| I | Show or hide details (IP address, status, permissions) |
| A | Turn OPEN AT LOGIN on or off (press I for details first) |
| L | Change the receiver's language |
| Esc twice | Quit the receiver (press it again within 2 seconds) |
| ⌘Q | Quit the receiver |

## Recommended settings

- Under Picture in the menu bar, choose Extend Display to use the iMac as a second screen. Mirror Display shows the same content as the main screen.
- Choose where sound plays under Sound in the menu bar: Only on the iMac, On both, or Only on this Mac.
- Choose the picture under Picture in the menu bar; each iMac remembers its own choice. The default is 5K · 60 Hz. If fast motion isn't smooth, choose Smooth · 4K 60: the desktop stays the same size and text is slightly softer.

## Troubleshooting

**The iMac doesn't appear**
1. Make sure the receiver is open on the iMac and shows "Waiting for your Mac".
2. If the iMac runs macOS 15 or later: in the iMac's System Settings › Privacy & Security › Local Network, turn on PWE Screen Encore Receiver.
3. Under Diagnostics in Settings… › Advanced, click Check Setup and follow its advice.
4. In the Full Console, use Manual entry with the iMac's IP address.

**The picture stutters or looks blurry**
1. In the Full Console, click Run Cable Test. If the rate is well below what the cable is rated for, try another cable or another port.
2. Under Picture in the menu bar, choose a lighter setting, such as Standard · 1440p.

**Permission is on, but the app says it's missing**

This can happen after switching from a test build or from TargetBridge: the switch in System Settings is on, but it belongs to the old app. You may not be able to connect, or the pointer moves on the iMac but clicks do nothing.

1. Press `⌘Q` to quit System Settings. Closing its window isn't enough; it writes the old entry back.
2. Reopen System Settings › Privacy & Security. Under Screen & System Audio Recording (for the receiver: Accessibility and Input Monitoring), select the app and click −.
3. Click + and add the app from Applications again, then turn it on.
4. Quit the app and open it again.

Check: the app no longer reports a missing permission and the iMac shows the picture; with keyboard and mouse sharing, clicks work on the iMac.

**Text on the iMac is too small or too large**
On the newer Mac, select the iMac in System Settings › Displays and choose another resolution.

**The iMac's screen is in another language**
Press L on the iMac's receiver screen to change the language.

**The Mac locks while someone watches it with Screen Sharing and you change the picture**

When you change the picture or plug and unplug the Thunderbolt cable, the iMac display disconnects and reconnects. In our tests, if another computer was watching this Mac through Screen Sharing at that moment, that Screen Sharing session ended and macOS locked the screen. The system log shows Screen Sharing started the lock, not this app.

1. Unlock this Mac.
2. To watch remotely while testing, end Screen Sharing before changing the picture or the cable, or let Screen Sharing use Wi‑Fi instead of the Thunderbolt cable.

**Anything else**
Please open an issue at https://github.com/kenshinice-ai/pwe-imac-display/issues or write to support@pwestudio.site. Include three things: both Macs' models, their macOS versions, and what you did just before the problem.

## Local network mode

By default, the receiver accepts only a Mac connected through the Thunderbolt cable (or a direct USB cable). Other computers on the same Wi‑Fi or local network can't connect to it.

If you do want to connect over Wi‑Fi or Ethernet (Network Link, an experimental sender feature):

1. Connect with the Thunderbolt cable first, so this Mac and the iMac pair once. Pairing works only over the cable.
2. In Terminal on the iMac, run:

   ```bash
   defaults write com.pwegroup.pweimacdisplay.receiver AllowLocalNetwork -bool true
   ```

3. Quit and reopen the receiver.
4. Unplug the Thunderbolt cable and connect to the iMac with Network Link on the newer Mac. Check: the iMac shows the picture.

Connections over Wi‑Fi or a local network are always encrypted, and only a paired Mac can connect. "Allow unencrypted connections" applies only to the cable.

To go back to the default, run the command below, then quit and reopen the receiver.

```bash
defaults delete com.pwegroup.pweimacdisplay.receiver AllowLocalNetwork
```

> ⚠️ Turn on local network mode only on a network you trust. Otherwise every computer on that network can find this iMac and may stop your Mac from connecting to it. The reason: the receiver takes one Mac at a time, and it has to accept a connection before it can tell whether that Mac is paired.

## Updating

Both Macs must run the same version. If they differ, the app on the Mac asks you to update both to the same version.

1. On the newer Mac: choose Check for Updates in About, or run `brew upgrade --cask pwe-screen-encore`. Check: the version in About is the new one.
2. On the iMac: download the same new disk image, open it, and drag PWE Screen Encore Receiver into Applications, choosing Replace. Check: the version at the bottom of the waiting screen is the new one.
3. Plug the cable in again. Check: the picture appears after a few seconds, and the Mac no longer reports different versions.

The receiver on the iMac doesn't update itself; copy it across like this for each update.

## Uninstalling

1. On the newer Mac, turn off "Open at login" in Settings… › General, then quit PWE Screen Encore.
2. On the iMac's receiver screen, press I and make sure OPEN AT LOGIN is Off; if it's On, press A. Then quit the receiver.
3. Move each app from Applications to the Trash on its Mac.

If you deleted the receiver first, the iMac may still try to open it at every start:
- macOS 11 and 12: delete `~/Library/LaunchAgents/com.pwegroup.pweimacdisplay.receiver.plist`.
- macOS 13 and later: remove it in System Settings › General › Login Items.

If you installed with Homebrew, run `brew uninstall --cask --zap pwe-screen-encore` on the newer Mac.

## About

PWE Screen Encore is built and signed by PWE Group. It's based on the open-source project TargetBridge (by Marco Caciotti and the community, MIT License). It isn't an official TargetBridge release, so please bring any problems to us.
