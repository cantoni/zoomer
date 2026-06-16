import ApplicationServices
import AppKit
import os

let logger = Logger(subsystem: "com.example.ZoomStupidWorkplaceAutominimizer", category: "main")
let zoomBundleID = "us.zoom.xos"
let targetWindowTitle = "Zoom Workplace"

// MARK: - Accessibility helpers

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    return ref as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    return ref as? Bool
}

func zoomApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == zoomBundleID }
}

/// Returns the AXError from the windows query plus whatever windows we got.
func copyZoomWindows(pid: pid_t) -> (error: AXError, windows: [AXUIElement]) {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    return (result, (windowsRef as? [AXUIElement]) ?? [])
}

// MARK: - Diagnostics

/// Emits to both stdout (captured in the user-only log file for a LaunchAgent)
/// and the unified log at notice level (persisted, visible via `log show`).
/// Only pass non-sensitive, operational text here — unified-log entries are
/// `.public`. Window titles must NOT go through this; see `dumpZoomWindows`.
func emit(_ text: String) {
    print(text)
    fflush(stdout)
    logger.notice("\(text, privacy: .public)")
}

/// Read-only snapshot of every Zoom window and its key attributes. Never mutates
/// anything, so it's safe to trigger during a live call. Window titles can carry
/// sensitive content (meeting topics, document names), so full detail is written
/// only to the user-owned local log file; the unified log gets a title-free
/// summary.
func dumpZoomWindows(reason: String) {
    let trusted = AXIsProcessTrusted()
    guard let app = zoomApplication() else {
        emit("[dump:\(reason)] trusted=\(trusted) — Zoom not running")
        return
    }
    let (error, windows) = copyZoomWindows(pid: app.processIdentifier)
    let summary = "[dump:\(reason)] trusted=\(trusted) pid=\(app.processIdentifier) "
        + "AXError=\(error.rawValue) windowCount=\(windows.count)"
    var lines = [summary]
    for (index, window) in windows.enumerated() {
        let title = axString(window, kAXTitleAttribute as String) ?? "<nil>"
        let role = axString(window, kAXRoleAttribute as String) ?? "<nil>"
        let subrole = axString(window, kAXSubroleAttribute as String) ?? "<nil>"
        let minimized = axBool(window, kAXMinimizedAttribute as String).map(String.init(describing:)) ?? "<nil>"
        let main = axBool(window, kAXMainAttribute as String).map(String.init(describing:)) ?? "<nil>"
        lines.append("  [\(index)] title=\"\(title)\" role=\(role) subrole=\(subrole) "
            + "minimized=\(minimized) main=\(main)")
    }
    if let until = snoozeUntil, Date() < until {
        lines.append("  snoozed (auto-minimize paused for \(Int(until.timeIntervalSinceNow)) more seconds)")
    }

    // Full detail (incl. titles) -> user-only local log file only.
    print(lines.joined(separator: "\n"))
    fflush(stdout)
    // Unified log -> title-free summary (it's broadly readable and persisted).
    logger.notice("\(summary, privacy: .public) (window details in local log only)")
}

// MARK: - Window handling

// Only ever touches a window titled *exactly* "Zoom Workplace", so the meeting
// window ("Zoom Meeting") is never affected.
enum WorkplaceWindowState {
    case absent              // no Workplace window right now
    case minimized           // present and already minimized
    case open(AXUIElement)   // present and visible
}

func workplaceWindowState(pid: pid_t) -> WorkplaceWindowState {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else {
        logger.notice("Could not read windows (AXError: \(error.rawValue, privacy: .public))")
        return .absent
    }
    for window in windows {
        guard axString(window, kAXTitleAttribute as String) == targetWindowTitle else { continue }
        if axBool(window, kAXMinimizedAttribute as String) == true { return .minimized }
        return .open(window)
    }
    return .absent
}

// MARK: - Snooze (double-reopen escape hatch)

// Reopening the Workplace window a second time within `reopenDoubleTapWindow`
// seconds suspends auto-minimizing for `snoozeDuration`. State below is only ever
// touched on the main run loop, so no locking is needed.
let reopenDoubleTapWindow: TimeInterval = 5.0
let snoozeDuration: TimeInterval = 15 * 60

var hasMinimizedThisSession = false   // distinguishes the first open from a reopen
var lastReopenAt: Date?               // when we last minimized a genuine reopen
var pendingMinimize = false           // we asked to minimize but haven't confirmed it applied
var snoozeUntil: Date?
var snoozeTimer: Timer?

func isSnoozing() -> Bool {
    if let until = snoozeUntil, Date() < until { return true }
    return false
}

func resetSessionState() {
    hasMinimizedThisSession = false
    lastReopenAt = nil
    pendingMinimize = false
    snoozeUntil = nil
    snoozeTimer?.invalidate()
    snoozeTimer = nil
}

func beginSnooze(pid: pid_t) {
    let until = Date().addingTimeInterval(snoozeDuration)
    snoozeUntil = until
    lastReopenAt = nil
    snoozeTimer?.invalidate()
    snoozeTimer = Timer.scheduledTimer(withTimeInterval: snoozeDuration, repeats: false) { _ in
        snoozeUntil = nil
        snoozeTimer = nil
        lastReopenAt = nil
        emit("Snooze ended; auto-minimize resumed")
        _ = processWorkplaceWindow(pid: pid, reason: "snooze-end")
    }
    emit("Snooze: leaving \"\(targetWindowTitle)\" open for \(Int(snoozeDuration / 60)) min (double reopen)")
}

/// Inspects the Workplace window and minimizes it, unless a quick second reopen
/// asks us to snooze. Returns true when this attempt reached a terminal state
/// (minimized, snoozed, or already minimized) so the retry loop can stop;
/// returns false when the window isn't present yet and we should keep trying.
func processWorkplaceWindow(pid: pid_t, reason: String) -> Bool {
    if isSnoozing() { return true }

    switch workplaceWindowState(pid: pid) {
    case .absent:
        return false
    case .minimized:
        pendingMinimize = false   // confirmed minimized
        return true
    case .open(let window):
        let now = Date()

        // If our own previous minimize hasn't applied yet, this `.open` is that
        // window still settling — not a user reopen. Re-issue and wait; don't let
        // a single physical reopen get double-counted into a snooze.
        let reissuingPendingMinimize = pendingMinimize

        if !reissuingPendingMinimize,
           hasMinimizedThisSession,
           let last = lastReopenAt,
           now.timeIntervalSince(last) < reopenDoubleTapWindow {
            beginSnooze(pid: pid)
            return true
        }

        guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else {
            logger.notice("Failed to minimize (\(reason, privacy: .public))")
            return false
        }

        // Confirm whether the minimize took effect synchronously.
        if case .minimized = workplaceWindowState(pid: pid) {
            pendingMinimize = false
        } else {
            pendingMinimize = true
        }

        // Only classify a real, newly-observed open — not a re-issue of a minimize
        // that simply hadn't applied yet.
        if !reissuingPendingMinimize {
            if hasMinimizedThisSession {
                lastReopenAt = now   // a genuine reopen; arms the double-tap window
                emit("Re-minimized \"\(targetWindowTitle)\" (reopen)")
            } else {
                hasMinimizedThisSession = true
                emit("Minimized \"\(targetWindowTitle)\"")
            }
        }
        return true
    }
}

// A single shared retry timer. The Workplace window often isn't present the
// instant an event fires, so we try immediately and then poll briefly. The
// debounce prevents overlapping events from stacking timers.
var minimizeTimer: Timer?

func scheduleMinimize(pid: pid_t, reason: String, maxAttempts: Int, interval: TimeInterval) {
    if processWorkplaceWindow(pid: pid, reason: reason) { return }
    if minimizeTimer?.isValid == true { return }

    logger.debug("Scheduling minimize retries (\(reason, privacy: .public))")
    var attempts = 0
    minimizeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
        attempts += 1
        if processWorkplaceWindow(pid: pid, reason: reason) || attempts >= maxAttempts {
            timer.invalidate()
            minimizeTimer = nil
        }
    }
}

// MARK: - AX window observer

// Catches the Workplace window reappearing (reopened from the Dock, or restored
// by Zoom when a meeting ends) without polling. Retained for the process'
// lifetime; re-registered whenever Zoom relaunches with a new pid.
var axObserver: AXObserver?
var observedPID: pid_t = 0

// All application-level notifications (reliably delivered when registered on the
// app element). kAXFocusedWindowChangedNotification covers the Workplace window
// being restored from the Dock, since restoring a window focuses it.
let observedNotifications: [CFString] = [
    kAXWindowCreatedNotification as CFString,
    kAXFocusedWindowChangedNotification as CFString,
    kAXApplicationActivatedNotification as CFString,
]

func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard observedPID != 0 else { return }
    logger.debug("AX event: \(notification as String, privacy: .public)")
    scheduleMinimize(pid: observedPID, reason: "ax:\(notification as String)", maxAttempts: 8, interval: 0.4)
}

func registerAXObserver(pid: pid_t) {
    if let existing = axObserver {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(existing), .defaultMode)
        axObserver = nil
    }

    var observer: AXObserver?
    guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let created = observer else {
        logger.notice("AXObserverCreate failed for pid \(pid, privacy: .public)")
        return
    }

    let appElement = AXUIElementCreateApplication(pid)
    for notification in observedNotifications {
        let err = AXObserverAddNotification(created, appElement, notification, nil)
        if err != .success && err != .notificationAlreadyRegistered {
            logger.notice("AddNotification \(notification as String, privacy: .public) -> \(err.rawValue, privacy: .public)")
        }
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    axObserver = created
    observedPID = pid
    logger.debug("AX observer registered for pid \(pid, privacy: .public)")
}

// MARK: - Watching

// Signal source must be retained for the lifetime of the process.
var sigusr1Source: DispatchSourceSignal?

func handleZoom(pid: pid_t, reason: String) {
    resetSessionState()   // a (re)launched Zoom is a fresh session: clear snooze/reopen tracking
    dumpZoomWindows(reason: reason)
    registerAXObserver(pid: pid)
    scheduleMinimize(pid: pid, reason: reason, maxAttempts: 30, interval: 1.0)
}

func startWatching() {
    let center = NSWorkspace.shared.notificationCenter

    // Cold launch of Zoom.
    center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == zoomBundleID else { return }
        emit("Zoom launched (pid \(app.processIdentifier))")
        handleZoom(pid: app.processIdentifier, reason: "launch")
    }

    // Zoom brought to the front (Dock click, Cmd-Tab) — the Workplace window may
    // have just been restored.
    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == zoomBundleID else { return }
        scheduleMinimize(pid: app.processIdentifier, reason: "activate", maxAttempts: 8, interval: 0.4)
    }

    // Zoom already running when we start (e.g. at login).
    if let zoomApp = zoomApplication() {
        emit("Zoom already running (pid \(zoomApp.processIdentifier))")
        handleZoom(pid: zoomApp.processIdentifier, reason: "startup-scan")
    }

    // SIGUSR1 -> read-only window dump on demand (safe during a live call).
    signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { dumpZoomWindows(reason: "SIGUSR1") }
    source.resume()
    sigusr1Source = source

    emit("Watching for Zoom (launch + activate + window events); SIGUSR1 dumps windows")
}

// MARK: - Status

func resolvedExecutablePath() -> String {
    guard let raw = CommandLine.arguments.first else { return "unknown" }
    return (raw as NSString).resolvingSymlinksInPath
}

func printStatus() {
    let trusted = AXIsProcessTrusted()
    let zoomRunning = zoomApplication() != nil

    print("ZoomStupidWorkplaceAutominimizer")
    print("  executable:    \(resolvedExecutablePath())")
    print("  accessibility: \(trusted ? "granted" : "NOT granted")")
    print("  zoom running:  \(zoomRunning ? "yes" : "no")")
    print("  note: run from a terminal, 'accessibility' reflects the terminal's")
    print("        grant, not this binary's. The launchd daemon is authoritative;")
    print("        use './install.sh status' to read the daemon's real state.")

    if !trusted {
        print("")
        print("To fix, grant Accessibility access to this exact binary:")
        print("  \(resolvedExecutablePath())")
        print("in System Settings ▸ Privacy & Security ▸ Accessibility.")
        print("If it is already listed, remove it (–) and re-add it (+).")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--status") || arguments.contains("--check") {
    printStatus()
    exit(0)
}

if arguments.contains("--windows") {
    // Note: when run from a terminal, the Accessibility grant may be attributed
    // to the terminal rather than this binary. The daemon's SIGUSR1 dump is the
    // authoritative one. This is a convenience for quick checks.
    dumpZoomWindows(reason: "cli")
    exit(0)
}

if AXIsProcessTrusted() {
    startWatching()
} else {
    // Don't exit — that would make launchd respawn us in a loop. Instead wait
    // for the user to grant permission and start the moment it lands.
    logger.warning("Accessibility not granted yet; waiting for permission…")
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
        if AXIsProcessTrusted() {
            emit("Accessibility granted; starting")
            timer.invalidate()
            startWatching()
        }
    }
}

RunLoop.main.run()
