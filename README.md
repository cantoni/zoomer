# ZoomStupidWorkplaceAutominimizer

A tiny macOS LaunchAgent that automatically closes the **Zoom Workplace**
window when a meeting or webinar starts. The meeting window is left alone. The
Workplace window is reopened when the meeting ends. The agent also turns off
Zoom's **Show chat previews** option for that session.

It is event-driven (no polling loop): it watches Zoom launch, activation, and
window events via `NSWorkspace` and an `AXObserver`. When it sees an exact
`Zoom Meeting` or `Zoom Webinar` window, it closes the window titled exactly
`Zoom Workplace` through the Accessibility API. It uses that same API to inspect
Zoom's in-meeting chat preview checkbox and toggles it only when it is enabled.

> Status: **beta**. Built for personal use; English window titles only.

## Requirements

- macOS with the Swift toolchain (`swiftc` — comes with Xcode or the Command Line
  Tools: `xcode-select --install`).
- Accessibility permission for the installed binary (the installer walks you
  through granting it).

## Install

```sh
./install.sh install
```

This builds the binary, code-signs it, installs it to `~/.local/bin` (no `sudo`
needed), and loads a LaunchAgent so it starts at login and stays running. The
installer then opens **System Settings ▸ Privacy & Security ▸ Accessibility** and
reveals the binary in Finder.

**Grant Accessibility access** to:

```
~/.local/bin/ZoomStupidWorkplaceAutominimizer
```

Drag the revealed binary into the Accessibility list (or use the `+` button), and
make sure its toggle is on. The agent picks up the permission within a couple of
seconds — no restart needed.

Verify everything is healthy:

```sh
./install.sh status
```

You want to see `accessibility: granted` and a running LaunchAgent. Then launch
Zoom and start a meeting; the Workplace window should close on its own.

## Commands

| Command | What it does |
| --- | --- |
| `./install.sh install` | Build, sign, install, load the agent, open the grant UI |
| `./install.sh quit` | Stop the running agent (it restarts at next login) |
| `./install.sh start` | Start the installed agent again (no rebuild, keeps the grant) |
| `./install.sh status` | Print accessibility status + LaunchAgent state |
| `./install.sh dump` | Trigger a read-only dump of Zoom's current windows (safe during a call) |
| `./install.sh logs` | Show the daemon's recent activity log |
| `./install.sh reset-permission` | Clear the Accessibility grant (use after a rebuild) |
| `./install.sh uninstall` | Stop and remove the agent, binary, and permission entry |

You can also run the binary directly for a one-off check:

```sh
ZoomStupidWorkplaceAutominimizer --status
```

### Using your own bundle id

The default bundle id is the placeholder `com.example.ZoomStupidWorkplaceAutominimizer`.
To brand your own build, set `ZWAM_BUNDLE_ID` when installing:

```sh
ZWAM_BUNDLE_ID="com.yourorg.ZoomStupidWorkplaceAutominimizer" ./install.sh install
```

The id drives the code-signing identifier, the LaunchAgent label, and the
`os.Logger` subsystem. It's remembered (in `~/.config/ZoomStupidWorkplaceAutominimizer/`),
so later `status`/`quit`/`uninstall` target the same install without re-setting
the variable.

## Troubleshooting

**`--status` says NOT granted, but the window still gets closed.**
That's expected and not a bug. When you run the binary from a terminal,
`AXIsProcessTrusted()` reflects the *terminal's* Accessibility grant (the terminal
is the "responsible process" for tools it launches), not the installed binary's.
The actual daemon is launched by `launchd`, is its own responsible process, and
uses the binary's grant — so it's trusted and works. Always check the authoritative
state with `./install.sh status`, which asks the running daemon directly.

**`accessibility: NOT granted` even though the toggle is on.**
The binary is **ad-hoc signed**, so macOS keys the Accessibility grant to the
binary's exact code hash. That hash changes every time the binary is rebuilt, which
silently invalidates an existing grant — the toggle still shows "on" but points at
the old build. Fix it:

```sh
./install.sh reset-permission   # clears the stale entry
./install.sh install            # reinstall, then re-add it in System Settings
```

**Keeping the grant across rebuilds (developers).**
If you rebuild often, sign with a stable identity instead of ad-hoc so the grant
survives. Create a self-signed **Code Signing** certificate once via *Keychain
Access ▸ Certificate Assistant ▸ Create a Certificate…* (Identity Type:
*Self-Signed Root*, Certificate Type: *Code Signing*), then:

```sh
ZWAM_SIGN_IDENTITY="Your Cert Name" ./install.sh install
```

With a stable signing identity, TCC matches by the certificate rather than the
code hash, so you grant access once and rebuilds keep working.

**Logs.** The agent logs via `os.Logger` (subsystem
`com.example.ZoomStupidWorkplaceAutominimizer`):

```sh
log stream --predicate 'subsystem == "com.example.ZoomStupidWorkplaceAutominimizer"'
```

Full detail (including the diagnostic window dumps) is written only to the
user-owned log file `~/Library/Logs/ZoomStupidWorkplaceAutominimizer.stdout.log`
(and `.stderr.log`). The unified log gets only a title-free summary, so Zoom
window titles aren't exposed there.

## Behavior notes

- The Workplace window is closed once when each meeting or webinar starts. It is
  not closed merely because Zoom launches, and reopening it during the meeting
  leaves it open.
- When the meeting or webinar ends, the agent asks Zoom to reopen the Workplace
  window. It does nothing if Zoom already reopened it, and it does not relaunch
  Zoom if the application itself was quit.
- Only the window titled exactly `Zoom Workplace` is ever closed. The meeting
  and webinar windows are never closed.
- Zoom does not persist **Show chat previews** between meetings, so the agent
  turns it off once for each new meeting or webinar. If it is already off, the
  agent leaves it off.
- Title matching is exact, so non-English Zoom UIs are not yet handled.

## Uninstall

```sh
./install.sh uninstall
```

## License

Copyright © 2026 Nice Mohawk Limited. Released under the [MIT License](LICENSE).

The bundle identifier (`com.example.ZoomStupidWorkplaceAutominimizer`) is a
deliberate placeholder — change it to your own reverse-DNS identifier if you
build and distribute your own copy.
