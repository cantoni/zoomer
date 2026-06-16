# ZoomStupidWorkplaceAutominimizer

A tiny macOS background agent that automatically minimizes the **Zoom Workplace**
window whenever Zoom launches. Meeting windows are left alone — only the window
titled exactly `Zoom Workplace` is touched.

It is event-driven (no polling loop): it watches Zoom launch, activation, and
window events via `NSWorkspace` and an `AXObserver`, and minimizes the window
through the Accessibility API. Because it reacts to window events, it keeps the
Workplace window minimized even if you reopen it (e.g. from the Dock) or Zoom
restores it when a meeting ends.

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
Zoom; the Workplace window should minimize on its own.

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

## Troubleshooting

**`--status` says NOT granted, but the window still gets minimized.**
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
`com.nicemohawk.ZoomStupidWorkplaceAutominimizer`):

```sh
log stream --predicate 'subsystem == "com.nicemohawk.ZoomStupidWorkplaceAutominimizer"'
```

stdout/stderr also go to `/tmp/ZoomStupidWorkplaceAutominimizer.stdout.log` and
`.stderr.log`.

## Behavior notes

- The Workplace window is kept minimized **whenever it appears** — including if you
  reopen it from the Dock. That's intentional (the window is treated as useless).
- **Snooze:** if you want the window to stay open, **reopen it a second time within
  5 seconds** of the first reopen. That suspends auto-minimizing for 15 minutes;
  afterwards it resumes and minimizes the window again. (Quitting/relaunching Zoom
  also clears the snooze.) Tune `reopenDoubleTapWindow` / `snoozeDuration` in
  `Sources/main.swift`.
- Only the window titled exactly `Zoom Workplace` is ever touched. The meeting
  window (`Zoom Meeting`) is never minimized.
- Title matching is exact, so non-English Zoom UIs are not yet handled.

## Uninstall

```sh
./install.sh uninstall
```
