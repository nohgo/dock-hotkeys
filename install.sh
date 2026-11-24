#!/bin/bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
label=io.github.nohgo.dock-hotkeys
support_dir="$HOME/Library/Application Support/Dock Hotkeys"
app_dir="$support_dir/Dock Hotkeys.app"
agent_dir="$HOME/Library/LaunchAgents"
agent_plist="$agent_dir/$label.plist"

if [[ -e "$app_dir" || -e "$agent_plist" ]]; then
    printf '%s\n' 'Dock Hotkeys is already installed. Uninstall it before reinstalling.' >&2
    exit 1
fi

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/dock-hotkeys.XXXXXX")
trap 'rm -rf -- "$stage_dir"' EXIT
stage_app="$stage_dir/Dock Hotkeys.app"
stage_plist="$stage_dir/$label.plist"
mkdir -p "$stage_app/Contents/MacOS"

cat > "$stage_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.nohgo.dock-hotkeys</string>
    <key>CFBundleName</key>
    <string>Dock Hotkeys</string>
    <key>CFBundleExecutable</key>
    <string>dock-hotkeys</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/swiftc -O -module-cache-path "$stage_dir/module-cache" \
    "$source_dir/dock-hotkeys.swift" -o "$stage_app/Contents/MacOS/dock-hotkeys"
/usr/bin/codesign --force --sign - "$stage_app"
/usr/bin/codesign --verify --strict "$stage_app"

/usr/bin/plutil -create xml1 "$stage_plist"
/usr/bin/plutil -insert Label -string "$label" "$stage_plist"
/usr/bin/plutil -insert ProgramArguments -array "$stage_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$app_dir/Contents/MacOS/dock-hotkeys" "$stage_plist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$stage_plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$stage_plist"
/usr/bin/plutil -insert KeepAlive -bool YES "$stage_plist"
/usr/bin/plutil -insert ThrottleInterval -integer 30 "$stage_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$support_dir/dock-hotkeys.log" "$stage_plist"

mkdir -p "$support_dir" "$agent_dir"
if ! mkdir "$app_dir"; then
    printf '%s\n' 'Could not create the Dock Hotkeys app directory.' >&2
    exit 1
fi

if ! /usr/bin/ditto --noextattr "$stage_app" "$app_dir" ||
   ! /usr/bin/codesign --verify --strict "$app_dir" ||
   ! /usr/bin/install -m 0644 "$stage_plist" "$agent_plist" ||
   ! /bin/launchctl bootstrap "gui/$(id -u)" "$agent_plist"; then
    rm -f -- "$agent_plist"
    rm -rf -- "$app_dir"
    printf '%s\n' 'Dock Hotkeys could not be installed.' >&2
    exit 1
fi

printf '%s\n' 'Dock Hotkeys is installed. Hold Control–Option to show the Dock numbers.'
