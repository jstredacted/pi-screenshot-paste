# Pi Screenshot Paste

A tiny native macOS helper that makes screenshot pasting work reliably in Ghostty/Pi.

When Ghostty is frontmost and your clipboard contains an image, `Cmd+V` is intercepted. The image is saved as a PNG file, and the file path is typed into Ghostty as plain text. This avoids Ghostty/Pi's flaky direct image paste behavior while still letting Pi consume screenshots by path.

## What it does

- Watches for `Cmd+V` only in configured target apps.
- Detects whether the clipboard contains an image.
- Saves the image to `~/Desktop/.ghostty_paste` by default.
- Types the saved file path into the frontmost app.
- Optionally prepends a prefix such as `@` for Pi-style file references.
- Keeps saved screenshots on disk by default, so pasted paths stay valid later in the Pi session.
- Can optionally clean up old saved screenshots if you configure a retention window.
- Runs as a menu bar app and can start at login via LaunchAgent.

## Requirements

- macOS 14 or newer
- Swift 6 toolchain
- [mise](https://mise.jdx.dev/) recommended for consistent local tool execution
- Ghostty, or another terminal app configured as a target bundle ID

## Install

Clone the repo:

```bash
git clone https://github.com/jstredacted/pi-screenshot-paste.git
cd pi-screenshot-paste
```

Build and install the app bundle plus LaunchAgent:

```bash
./scripts/install-launch-agent.sh
```

The installer creates:

- App bundle: `~/Applications/PiScreenshotPaste.app`
- LaunchAgent: `~/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist`
- Logs: `~/Library/Logs/PiScreenshotPaste.log` and `~/Library/Logs/PiScreenshotPaste.err.log`
- State log: `~/Library/Logs/PiScreenshotPaste.state.log`

## Permissions

The app needs macOS privacy permissions because it intercepts `Cmd+V` and types the generated path.

Grant these to `PiScreenshotPaste.app`:

1. System Settings → Privacy & Security → Accessibility
2. System Settings → Privacy & Security → Input Monitoring

Then restart the app:

```bash
launchctl unload ~/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist
```

If macOS keeps asking again after rebuilds, remove old/stale `PiScreenshotPaste` entries from Accessibility and Input Monitoring, run `./scripts/install-launch-agent.sh` again, then grant permissions to the app at `~/Applications/PiScreenshotPaste.app`. The installer signs the app bundle with a stable bundle identifier so TCC has a consistent target.

## Usage

1. Copy a screenshot or image to the clipboard.
2. Focus Ghostty.
3. Press `Cmd+V`.
4. A path like this will be typed into Ghostty:

```text
/Users/you/Desktop/.ghostty_paste/clipboard_20260430_012300_1234.png
```

If you configure `pastePrefix` to `@`, it will type:

```text
@/Users/you/Desktop/.ghostty_paste/clipboard_20260430_012300_1234.png
```

## Configuration

Settings are stored with macOS `defaults`. Restart the app after changing them.

### Target apps

Ghostty is the default target:

```bash
defaults write com.justin.PiScreenshotPaste targetBundleIDs -array com.mitchellh.ghostty
```

Add more apps by bundle ID:

```bash
defaults write com.justin.PiScreenshotPaste targetBundleIDs -array \
  com.mitchellh.ghostty \
  com.apple.Terminal
```

### Paste prefix

Empty by default:

```bash
defaults write com.justin.PiScreenshotPaste pastePrefix ""
```

Use `@` for Pi-style file references:

```bash
defaults write com.justin.PiScreenshotPaste pastePrefix "@"
```

### Output directory

Default:

```bash
defaults write com.justin.PiScreenshotPaste outputDirectory "~/Desktop/.ghostty_paste"
```

### Cleanup age

Default is disabled (`0`), meaning screenshots persist:

```bash
defaults write com.justin.PiScreenshotPaste cleanupAfterSeconds -float 0
```

Set a positive value to enable automatic cleanup. Example: delete saved screenshots older than one day:

```bash
defaults write com.justin.PiScreenshotPaste cleanupAfterSeconds -float 86400
```

## Menu bar controls

The menu bar item lets you:

- Check permission status
- Request Accessibility permission
- Request Input Monitoring permission
- Open the output folder
- Copy the output folder path
- Restart the event tap
- Quit the app

## Manual build/run

Build:

```bash
mise exec -- swift build -c release
```

Run directly:

```bash
.build/release/PiScreenshotPaste
```

For daily use, prefer `./scripts/install-launch-agent.sh` so macOS permissions attach to the stable app bundle in `~/Applications`.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist
rm -rf ~/Applications/PiScreenshotPaste.app
rm -rf ~/Desktop/.ghostty_paste
```

You can also remove `PiScreenshotPaste` from Accessibility and Input Monitoring in System Settings.

## License

MIT
