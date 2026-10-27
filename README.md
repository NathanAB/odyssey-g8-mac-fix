# Odyssey G8 black screen on Mac in Game Mode

The Samsung Odyssey OLED G8 (model G85SB) shows a black screen on an Apple Silicon Mac, such as a MacBook Air, when the monitor's Game Mode is on. This repository has a small background helper that makes macOS add the monitor, with Game Mode still on.

## The monitor stays black when Game Mode is on

The monitor is connected to the Mac over USB-C. With Game Mode off, it works. With Game Mode on, the screen stays black. macOS sees the monitor at a low level but never adds it as a screen, so it looks as if the Mac does not detect the monitor. The monitor sometimes turns Game Mode on by itself, so the screen can go black without you touching anything.

Updating macOS, restarting, resetting the display preferences, using a different cable, and forcing 60Hz did not help. The problem showed up on a MacBook Air M3 with macOS 26.6.2 and 26.7.2.

## Check that you have this problem

If the screen went black in the last day, run this in Terminal. Keep the full path `/usr/bin/log`, because zsh, the default shell on macOS, has its own `log` command.

```
/usr/bin/log show --last 1d --style compact --predicate 'process == "WindowServer" AND eventMessage CONTAINS "v: 0x00004c2d"'
```

It takes about 30 seconds. Each line names a Samsung monitor that macOS saw. The `m:` value is the monitor's product ID. A line with `m: 0x000072f2` is the Game Mode identity that macOS rejects:

```
2026-10-27 09:56:33.800 Df WindowServer[605:118b] [com.apple.SkyLight:display] [ Display:Persist    ] v: 0x00004c2d m: 0x000072f2 s: 0x00000000 y: 0x000007e6 w: 0x00000008 asn: <private> p: 0xdeadbeef
```

To check the monitor's state right now, build the helper and run `status` while the screen is black in Game Mode. Building needs the Xcode Command Line Tools. To install them, run `xcode-select --install`.

```
git clone https://github.com/nathanab/odyssey-g8-mac-fix.git
cd odyssey-g8-mac-fix
swiftc -O -o odyssey-g8-mac-fix odyssey-g8-mac-fix.swift
./odyssey-g8-mac-fix status
```

You have this problem if the Samsung line ends like this:

```
vendor 0x4C2D product 0x72F2, Game Mode identity macOS rejects, not online
```

"Online" means macOS added the display as a screen.

## Why it happens

Every monitor sends the Mac a short description of itself, called an EDID. Each EDID carries a vendor ID and a product ID. Over USB-C, the G85SB sends one of three EDIDs, all with Samsung's vendor ID `0x4C2D`:

| Product ID | Refresh rate up to | macOS |
| --- | --- | --- |
| `0x7306` | 75Hz | works |
| `0x72F5`, Game Mode off | 120Hz | works |
| `0x72F2`, Game Mode on | 175Hz | never adds it as a screen |

Turning Game Mode on or off makes the monitor disconnect and connect again with the other EDID. macOS reads the `0x72F2` EDID and builds a list of display modes for it, but it never adds the display as a screen. Why macOS rejects this EDID is not known.

## What the fix does

A LaunchAgent starts the helper when you log in. The helper watches for displays that connect. When one connects with vendor `0x4C2D` and product `0x72F2`, the helper tells macOS to use the `0x72F5` EDID saved from the same monitor instead. It does this with `IOAVServiceSetVirtualEDIDMode`, a private IOKit function. macOS then sees product `0x72F5` and adds the monitor within about a second. Game Mode stays on.

macOS forgets the replacement each time the monitor reconnects and each time the Mac restarts, so the helper keeps watching. It leaves every other display alone.

Each time the helper replaces the EDID, it writes lines like these to `~/Library/Logs/odyssey-g8-mac-fix.log`:

```
11:55:36 service 0x1000015a3: vendor 0x4C2D product 0x72F2, Game Mode identity macOS rejects
11:55:37 service 0x1000015a3: applied replacement EDID, IOReturn 0x00000000
```

`IOReturn 0x00000000` means it worked. Any other code means it failed.

## Install

You need an Apple Silicon Mac and the Xcode Command Line Tools. To install the tools, run `xcode-select --install`.

1. If you have not cloned this repository yet, run:

   ```
   git clone https://github.com/nathanab/odyssey-g8-mac-fix.git
   ```

2. Connect the monitor and turn Game Mode off in the monitor's menu. Wait for the picture.
3. In Terminal, run:

   ```
   cd odyssey-g8-mac-fix
   ./install.sh
   ```

The first install saves the monitor's Game-Mode-off EDID to `~/Library/Application Support/odyssey-g8-mac-fix/replacement-edid.bin`. If Game Mode is on, or the Mac finds no Samsung monitor or more than one, the install stops and says what to do.

macOS may show a notification that a background item was added. That item is this helper.

To test the fix, turn Game Mode on. The screen comes back a moment after the monitor reconnects. To read the log, run:

```
tail ~/Library/Logs/odyssey-g8-mac-fix.log
```

To see the monitor's state at any time, run:

```
"$HOME/Library/Application Support/odyssey-g8-mac-fix/odyssey-g8-mac-fix" status
```

Running `./install.sh` again rebuilds the helper and restarts it. It keeps the saved EDID. To save a new one, delete `replacement-edid.bin`, turn Game Mode off, and run `./install.sh`.

## Uninstall

From the `odyssey-g8-mac-fix` folder, run:

```
./uninstall.sh
```

This stops and removes the helper, puts the monitor back on its own EDID, and deletes `~/Library/Application Support/odyssey-g8-mac-fix`. The log stays. If Game Mode is on, the screen goes black again.

## Limits

- The helper uses a private macOS function that Apple does not document. A macOS update can change or remove it. If the screen goes black in Game Mode after an update, read the log and run `./uninstall.sh`. Until there is a new fix, use the monitor with Game Mode off.
- The helper starts when you log in. After a restart with Game Mode on, the login screen can stay black. Log in on the Mac's own screen.
- With the fix, the monitor runs at up to 120Hz in Game Mode, not 175Hz, because macOS uses the modes in the `0x72F5` EDID.
- The fix was tested only on a MacBook Air M3 with macOS 26.6.2 and 26.7.2, with the monitor connected over USB-C.
- Another monitor that switches to an EDID macOS rejects could get the same fix. Add its vendor and product IDs to `identitiesToReplace` in `odyssey-g8-mac-fix.swift`. The `capture` command, which saves the EDID during install, looks only for Samsung monitors. A monitor from another vendor needs that check changed too.

## Credit

The approach of replacing the EDID through `IOAVService` comes from [a gist by danii1](https://gist.github.com/danii1/99fa5f849a4d42807418259abfbf03d5).

## License

MIT. See [LICENSE](LICENSE).
