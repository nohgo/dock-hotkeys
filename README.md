# Dock Hotkeys

Launch or focus pinned macOS Dock apps with **Control–Option–1 through 9**. The numbers follow the order of your pinned apps. **Control–Option–0** opens your Home folder in Finder.

Hold **Control–Option** to see the numbers above the Dock. Release either key to hide them. The overlay is designed for a visible Dock at the bottom of the main display.

## Install

With the Command Line Tools for Xcode installed, run this from the repository directory:

```sh
./install.sh
```

The installer builds a small macOS app and starts it as a per-user LaunchAgent. It starts again when you sign in. In System Settings, grant **Dock Hotkeys** Accessibility access. Some macOS versions call this **Device Control and Data Access**. The overlay uses this access to read Dock icon positions and detect the modifier hold. The numbered shortcuts also work with the overlay permission turned off.

After granting access, restart the helper once:

```sh
launchctl kickstart -k "gui/$(id -u)/io.github.nohgo.dock-hotkeys"
```

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/io.github.nohgo.dock-hotkeys"
rm "$HOME/Library/LaunchAgents/io.github.nohgo.dock-hotkeys.plist"
```

Move `Dock Hotkeys.app` from `~/Library/Application Support/Dock Hotkeys` to the Trash. You can also remove Dock Hotkeys from the Accessibility list in System Settings.
