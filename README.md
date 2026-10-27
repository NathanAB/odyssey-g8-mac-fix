# Fix for the Samsung Odyssey OLED G8 black screen on Mac

If your Odyssey OLED G8 (G85SB) goes black on an Apple Silicon Mac when Game Mode is on, this background helper brings the picture back within about a second. Game Mode stays on.

## Install

You need an Apple Silicon Mac and the Xcode Command Line Tools (`xcode-select --install`).

1. Connect the monitor over USB-C, turn Game Mode off, and wait for the picture.
2. Run:

   ```
   git clone https://github.com/NathanAB/odyssey-g8-mac-fix.git
   cd odyssey-g8-mac-fix
   ./install.sh
   ```

3. Turn Game Mode on. The screen goes black for about a second, then comes back.

The install saves your monitor's working EDID and starts the helper at every login. macOS may show a notification that a background item was added. That item is this helper.

## Uninstall

From the `odyssey-g8-mac-fix` folder, run `./uninstall.sh`. It removes the helper and puts the monitor back on its own EDID.

## Check that you have this problem

From the cloned folder, build the helper and run `status` while the screen is black:

```
swiftc -O -swift-version 5 -o odyssey-g8-mac-fix odyssey-g8-mac-fix.swift
./odyssey-g8-mac-fix status
```

You have this problem if the Samsung line ends with:

```
vendor 0x4C2D product 0x72F2, Game Mode identity macOS rejects, not online
```

## Why the screen goes black

A monitor describes itself to the Mac with an EDID, which carries a product ID. The G85SB sends one of three EDIDs, depending on its settings:

| Product ID | Setting | Refresh rate up to | macOS |
| --- | --- | --- | --- |
| `0x7306` | Input Signal Plus off (likely) | 75Hz | works |
| `0x72F5` | Game Mode off | 120Hz | works |
| `0x72F2` | Game Mode on | 175Hz | never turns it on |

macOS reads the `0x72F2` EDID and picks a resolution, but never turns the display on. Why is not known. The monitor also turns Game Mode on by itself at times.

The helper watches for the monitor to connect. When the monitor sends `0x72F2`, the helper tells macOS to use the `0x72F5` EDID saved at install instead, through the private IOKit function `IOAVServiceSetVirtualEDIDMode`. macOS forgets the swap on every reconnect and restart, so the helper keeps running. It logs each swap to `~/Library/Logs/odyssey-g8-mac-fix.log`.

## Limits

- The helper relies on a private macOS function, so a macOS update can break it. If the screen stays black after an update, read the log and run `./uninstall.sh`.
- With the fix, Game Mode runs at up to 120Hz, not 175Hz.
- After a restart in Game Mode, the login screen can stay black. Log in on the Mac's own screen.
- Once, the monitor also stayed black with Game Mode off (product `0x72F5`). The helper does not fix that case yet. Turning Input Signal Plus off did.
- It was tested only on a MacBook Air M3 with macOS 26.6.2 and 26.7.2, over USB-C.

The EDID swap comes from [a gist by danii1](https://gist.github.com/danii1/99fa5f849a4d42807418259abfbf03d5). MIT license.
