import ApplicationServices
import AppKit
import os

// Subsystem follows the configured bundle id (set by the LaunchAgent via
// ZWAM_BUNDLE_ID); falls back to the placeholder for direct CLI runs.
let bundleIdentifier = ProcessInfo.processInfo.environment["ZWAM_BUNDLE_ID"]
    ?? "com.example.ZoomStupidWorkplaceAutominimizer"
let logger = Logger(subsystem: bundleIdentifier, category: "main")
let zoomBundleID = "us.zoom.xos"
let targetWindowTitle = "Zoom Workplace"
let meetingWindowTitles = ["Zoom Meeting", "Zoom Webinar"]
let chatPreviewCheckboxLabel = "Show chat previews"
let screenShareControlLabels = [
    "Stop Share",
    "Stop Sharing",
    "You are screen sharing",
]

// MARK: - Configuration

enum WorkplaceMode: String {
    case closeDuringMeetings = "close-during-meetings"
    case minimizeDuringMeetings = "minimize-during-meetings"
    case minimizeAlways = "minimize-always"
    case leaveAlone = "leave-alone"

    var description: String {
        switch self {
        case .closeDuringMeetings: return "close during meetings"
        case .minimizeDuringMeetings: return "minimize during meetings"
        case .minimizeAlways: return "minimize always"
        case .leaveAlone: return "leave alone"
        }
    }
}

struct Settings {
    let workplaceMode: WorkplaceMode
    let showChatPreviews: Bool
}

func loadSettings() -> Settings {
    let environment = ProcessInfo.processInfo.environment
    let mode = WorkplaceMode(
        rawValue: environment["ZWAM_WORKPLACE_MODE"] ?? ""
    ) ?? .closeDuringMeetings
    let showChatPreviews = environment["ZWAM_SHOW_CHAT_PREVIEWS"]?
        .caseInsensitiveCompare("yes") == .orderedSame
    return Settings(
        workplaceMode: mode,
        showChatPreviews: showChatPreviews
    )
}

let settings = loadSettings()

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

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &ref
    ) == .success else {
        return []
    }
    return (ref as? [AXUIElement]) ?? []
}

func axElement(_ lhs: AXUIElement?, isSameAs rhs: AXUIElement?) -> Bool {
    guard let lhs, let rhs else { return false }
    return CFEqual(lhs, rhs)
}

func axElement(_ element: AXUIElement, hasLabel expected: String) -> Bool {
    let attributes = [
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
        kAXIdentifierAttribute,
    ]
    return attributes.contains { attribute in
        axString(element, attribute as String)?
            .caseInsensitiveCompare(expected) == .orderedSame
    }
}

/// Breadth-first AX descendant search with a hard cap so an unexpected Zoom UI
/// hierarchy can never make us walk indefinitely.
func findAXElement(
    below root: AXUIElement,
    role expectedRole: String? = nil,
    label expectedLabel: String,
    limit: Int = 2_000
) -> AXUIElement? {
    var queue = [root]
    var index = 0

    while index < queue.count && index < limit {
        let element = queue[index]
        index += 1

        let roleMatches = expectedRole == nil
            || axString(element, kAXRoleAttribute as String) == expectedRole
        if roleMatches, axElement(element, hasLabel: expectedLabel) {
            return element
        }

        queue.append(contentsOf: axChildren(element))
    }
    return nil
}

func titledMeetingWindow(in windows: [AXUIElement]) -> AXUIElement? {
    windows.first { window in
        guard let title = axString(window, kAXTitleAttribute as String) else {
            return false
        }
        return meetingWindowTitles.contains(title)
    }
}

/// With Zoom's default screen-sharing settings, the normal meeting window is
/// replaced by floating sharing controls. Treat the window containing those
/// controls as active meeting UI so that transition cannot look like a meeting
/// ending.
func screenSharingWindow(in windows: [AXUIElement]) -> AXUIElement? {
    windows.first { window in
        screenShareControlLabels.contains { label in
            findAXElement(
                below: window,
                label: label,
                limit: 2_000
            ) != nil
        }
    }
}

func activeMeetingWindow(in windows: [AXUIElement]) -> AXUIElement? {
    titledMeetingWindow(in: windows) ?? screenSharingWindow(in: windows)
}

func activeMeetingWindow(pid: pid_t) -> AXUIElement? {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else { return nil }
    return activeMeetingWindow(in: windows)
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
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
    // Full detail (incl. titles) -> user-only local log file only.
    print(lines.joined(separator: "\n"))
    fflush(stdout)
    // Unified log -> title-free summary (it's broadly readable and persisted).
    logger.notice("\(summary, privacy: .public) (window details in local log only)")
}

/// On chat-preview automation failure, print only AX elements that look related
/// to chat or preview controls. Details stay in the user-owned stdout log because
/// arbitrary Accessibility labels could contain private meeting text.
func dumpChatAXCandidates(window: AXUIElement, reason: String) {
    var queue = [window]
    var index = 0
    var lines = ["[chat-ax:\(reason)] candidate controls:"]

    while index < queue.count && index < 2_000 {
        let element = queue[index]
        index += 1
        let role = axString(element, kAXRoleAttribute as String) ?? ""
        let title = axString(element, kAXTitleAttribute as String) ?? ""
        let description = axString(element, kAXDescriptionAttribute as String) ?? ""
        let help = axString(element, kAXHelpAttribute as String) ?? ""
        let identifier = axString(element, kAXIdentifierAttribute as String) ?? ""
        let searchable = [title, description, help, identifier]
            .joined(separator: " ")
            .lowercased()

        if searchable.contains("chat")
            || searchable.contains("preview")
            || searchable.contains("toolbar") {
            lines.append(
                "  role=\(role) title=\"\(title)\" description=\"\(description)\" "
                    + "help=\"\(help)\" identifier=\"\(identifier)\" "
                    + "actions=\(axActionNames(element))"
            )
        }
        queue.append(contentsOf: axChildren(element))
    }

    print(lines.joined(separator: "\n"))
    fflush(stdout)
    logger.notice("[chat-ax:\(reason, privacy: .public)] wrote \(lines.count - 1, privacy: .public) candidates to local log")
}

// MARK: - Window handling

enum CloseWorkplaceAttempt {
    case done
    case waiting
    case noMeeting
}

var handledWorkplaceCloseMeetingWindow: AXUIElement?
var requestedWorkplaceCloseMeetingWindow: AXUIElement?

/// Closes only the window titled exactly "Zoom Workplace", and only while an
/// exact meeting or webinar window is present.
func closeWorkplaceWindowIfMeetingStarted(pid: pid_t, reason: String) -> CloseWorkplaceAttempt {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else {
        logger.notice("Could not read windows (AXError: \(error.rawValue, privacy: .public))")
        return .waiting
    }
    guard let meetingWindow = titledMeetingWindow(in: windows) else {
        handledWorkplaceCloseMeetingWindow = nil
        requestedWorkplaceCloseMeetingWindow = nil
        return .noMeeting
    }

    observeMeetingEnd(for: meetingWindow)

    if axElement(meetingWindow, isSameAs: handledWorkplaceCloseMeetingWindow) {
        return .done
    }

    guard let workplaceWindow = windows.first(where: {
        axString($0, kAXTitleAttribute as String) == targetWindowTitle
    }) else {
        if axElement(meetingWindow, isSameAs: requestedWorkplaceCloseMeetingWindow) {
            emit("Meeting started; closed \"\(targetWindowTitle)\"")
        }
        handledWorkplaceCloseMeetingWindow = meetingWindow
        requestedWorkplaceCloseMeetingWindow = nil
        return .done
    }

    var closeButtonRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        workplaceWindow,
        kAXCloseButtonAttribute as CFString,
        &closeButtonRef
    ) == .success,
    let closeButtonRef else {
        logger.notice("Could not find the Workplace window close button (\(reason, privacy: .public))")
        return .waiting
    }
    let closeButton = closeButtonRef as! AXUIElement

    guard AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
        logger.notice("Failed to close the Workplace window (\(reason, privacy: .public))")
        return .waiting
    }

    if !axElement(meetingWindow, isSameAs: requestedWorkplaceCloseMeetingWindow) {
        requestedWorkplaceCloseMeetingWindow = meetingWindow
        emit("Meeting started; closing \"\(targetWindowTitle)\"")
    }
    return .waiting
}

// A single shared retry timer. Zoom can send its window-created event before
// titles and controls are populated, so retry briefly after each trigger.
var closeWorkplaceTimer: Timer?

func scheduleCloseWorkplace(pid: pid_t, reason: String, maxAttempts: Int, interval: TimeInterval) {
    if closeWorkplaceWindowIfMeetingStarted(pid: pid, reason: reason) == .done { return }
    if closeWorkplaceTimer?.isValid == true { return }

    logger.debug("Scheduling close retries (\(reason, privacy: .public))")
    var attempts = 0
    closeWorkplaceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
        attempts += 1
        let result = closeWorkplaceWindowIfMeetingStarted(pid: pid, reason: reason)
        if result == .done || attempts >= maxAttempts {
            if attempts >= maxAttempts && result == .waiting {
                emit("Could not close \"\(targetWindowTitle)\" after \(attempts) attempts")
            }
            timer.invalidate()
            closeWorkplaceTimer = nil
        }
    }
}

// MARK: - Workplace minimize handling

enum MinimizeWorkplaceAttempt {
    case done
    case waiting
    case noMeeting
}

var handledWorkplaceMinimizeMeetingWindow: AXUIElement?
var minimizeWorkplaceDuringMeetingTimer: Timer?
var minimizeWorkplaceAlwaysTimer: Timer?

enum SetWorkplaceMinimizedOutcome {
    case absent
    case unchanged
    case changed
    case failed
}

func setWorkplaceMinimized(
    in windows: [AXUIElement],
    minimized: Bool,
    reason: String
) -> SetWorkplaceMinimizedOutcome {
    guard let workplaceWindow = windows.first(where: {
        axString($0, kAXTitleAttribute as String) == targetWindowTitle
    }) else {
        return .absent
    }

    if axBool(workplaceWindow, kAXMinimizedAttribute as String) == minimized {
        return .unchanged
    }

    let value = (minimized ? kCFBooleanTrue : kCFBooleanFalse)!
    guard AXUIElementSetAttributeValue(
        workplaceWindow,
        kAXMinimizedAttribute as CFString,
        value
    ) == .success else {
        let action = minimized ? "minimize" : "restore"
        logger.notice("Failed to \(action, privacy: .public) the Workplace window (\(reason, privacy: .public))")
        return .failed
    }
    return .changed
}

func minimizeWorkplaceIfMeetingStarted(
    pid: pid_t,
    reason: String
) -> MinimizeWorkplaceAttempt {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else {
        logger.notice("Could not read windows (AXError: \(error.rawValue, privacy: .public))")
        return .waiting
    }
    guard let meetingWindow = titledMeetingWindow(in: windows) else {
        handledWorkplaceMinimizeMeetingWindow = nil
        return .noMeeting
    }

    observeMeetingEnd(for: meetingWindow)

    if axElement(meetingWindow, isSameAs: handledWorkplaceMinimizeMeetingWindow) {
        return .done
    }

    switch setWorkplaceMinimized(
        in: windows,
        minimized: true,
        reason: reason
    ) {
    case .absent, .unchanged:
        handledWorkplaceMinimizeMeetingWindow = meetingWindow
        return .done
    case .changed:
        handledWorkplaceMinimizeMeetingWindow = meetingWindow
        emit("Meeting started; minimized \"\(targetWindowTitle)\"")
        return .done
    case .failed:
        return .waiting
    }
}

func scheduleMinimizeWorkplaceDuringMeeting(
    pid: pid_t,
    reason: String,
    maxAttempts: Int,
    interval: TimeInterval
) {
    if minimizeWorkplaceIfMeetingStarted(pid: pid, reason: reason) == .done { return }
    if minimizeWorkplaceDuringMeetingTimer?.isValid == true { return }

    var attempts = 0
    minimizeWorkplaceDuringMeetingTimer = Timer.scheduledTimer(
        withTimeInterval: interval,
        repeats: true
    ) { timer in
        attempts += 1
        let result = minimizeWorkplaceIfMeetingStarted(pid: pid, reason: reason)
        if result == .done || attempts >= maxAttempts {
            if attempts >= maxAttempts && result == .waiting {
                emit("Could not minimize \"\(targetWindowTitle)\" after \(attempts) attempts")
            }
            timer.invalidate()
            minimizeWorkplaceDuringMeetingTimer = nil
        }
    }
}

func minimizeWorkplace(pid: pid_t, reason: String) -> Bool {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else {
        logger.notice("Could not read windows (AXError: \(error.rawValue, privacy: .public))")
        return false
    }
    switch setWorkplaceMinimized(
        in: windows,
        minimized: true,
        reason: reason
    ) {
    case .absent, .failed:
        return false
    case .unchanged:
        return true
    case .changed:
        emit("Minimized \"\(targetWindowTitle)\"")
        return true
    }
}

func scheduleMinimizeWorkplaceAlways(
    pid: pid_t,
    reason: String,
    maxAttempts: Int,
    interval: TimeInterval
) {
    if minimizeWorkplace(pid: pid, reason: reason) { return }
    if minimizeWorkplaceAlwaysTimer?.isValid == true { return }

    var attempts = 0
    minimizeWorkplaceAlwaysTimer = Timer.scheduledTimer(
        withTimeInterval: interval,
        repeats: true
    ) { timer in
        attempts += 1
        if minimizeWorkplace(pid: pid, reason: reason) || attempts >= maxAttempts {
            timer.invalidate()
            minimizeWorkplaceAlwaysTimer = nil
        }
    }
}

// MARK: - Workplace reopen handling

enum ReopenWorkplaceAttempt {
    case done
    case waiting
    case unconfirmedEnd
    case meetingActive
    case zoomNotRunning
}

var reopenWorkplaceRequested = false
var reopenWorkplaceTimer: Timer?

func reopenWorkplaceIfMeetingEnded(
    pid: pid_t,
    meetingEndConfirmed: Bool
) -> ReopenWorkplaceAttempt {
    guard let zoom = zoomApplication(),
          !zoom.isTerminated,
          zoom.processIdentifier == pid else {
        reopenWorkplaceRequested = false
        return .zoomNotRunning
    }

    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else { return .waiting }

    if let meetingWindow = activeMeetingWindow(in: windows) {
        observeMeetingEnd(for: meetingWindow)
        return .meetingActive
    }

    if windows.contains(where: {
        axString($0, kAXTitleAttribute as String) == targetWindowTitle
    }) {
        if reopenWorkplaceRequested {
            emit("Meeting ended; reopened \"\(targetWindowTitle)\"")
        }
        reopenWorkplaceRequested = false
        return .done
    }

    guard meetingEndConfirmed else { return .unconfirmedEnd }
    guard !reopenWorkplaceRequested else { return .waiting }
    guard let zoomURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: zoomBundleID
    ) else {
        emit("Meeting ended; could not find the Zoom application")
        return .done
    }

    reopenWorkplaceRequested = true
    emit("Meeting ended; reopening \"\(targetWindowTitle)\"")

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(
        at: zoomURL,
        configuration: configuration
    ) { _, error in
        if let error {
            DispatchQueue.main.async {
                reopenWorkplaceRequested = false
                logger.notice("Failed to ask Zoom to reopen (\(error.localizedDescription, privacy: .public))")
            }
        }
    }
    return .waiting
}

func scheduleReopenWorkplaceAfterMeeting(
    pid: pid_t,
    maxAttempts: Int = 20,
    interval: TimeInterval = 0.5
) {
    if reopenWorkplaceTimer?.isValid == true { return }

    var attempts = 0
    var consecutiveAbsentChecks = 0
    reopenWorkplaceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
        attempts += 1
        let result = reopenWorkplaceIfMeetingEnded(
            pid: pid,
            meetingEndConfirmed: consecutiveAbsentChecks >= 3
        )
        switch result {
        case .unconfirmedEnd:
            consecutiveAbsentChecks += 1
        case .meetingActive, .done, .zoomNotRunning:
            timer.invalidate()
            reopenWorkplaceTimer = nil
        case .waiting:
            break
        }

        if timer.isValid, attempts >= maxAttempts {
            if attempts >= maxAttempts && result == .waiting {
                emit("Meeting ended; could not reopen \"\(targetWindowTitle)\"")
            }
            timer.invalidate()
            reopenWorkplaceTimer = nil
        }
    }
}

enum RestoreMinimizedWorkplaceAttempt {
    case done
    case waiting
    case unconfirmedEnd
    case meetingActive
    case zoomNotRunning
}

var restoreMinimizedWorkplaceTimer: Timer?

func restoreMinimizedWorkplaceIfMeetingEnded(
    pid: pid_t,
    meetingEndConfirmed: Bool
) -> RestoreMinimizedWorkplaceAttempt {
    guard let zoom = zoomApplication(),
          !zoom.isTerminated,
          zoom.processIdentifier == pid else {
        return .zoomNotRunning
    }

    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else { return .waiting }

    if let meetingWindow = activeMeetingWindow(in: windows) {
        observeMeetingEnd(for: meetingWindow)
        return .meetingActive
    }

    guard let workplaceWindow = windows.first(where: {
        axString($0, kAXTitleAttribute as String) == targetWindowTitle
    }) else {
        return .waiting
    }

    if axBool(workplaceWindow, kAXMinimizedAttribute as String) != true {
        return .done
    }

    guard meetingEndConfirmed else { return .unconfirmedEnd }
    guard AXUIElementSetAttributeValue(
        workplaceWindow,
        kAXMinimizedAttribute as CFString,
        kCFBooleanFalse
    ) == .success else {
        return .waiting
    }

    emit("Meeting ended; restored \"\(targetWindowTitle)\"")
    return .done
}

func scheduleRestoreMinimizedWorkplaceAfterMeeting(
    pid: pid_t,
    maxAttempts: Int = 20,
    interval: TimeInterval = 0.5
) {
    if restoreMinimizedWorkplaceTimer?.isValid == true { return }

    var attempts = 0
    var consecutiveAbsentChecks = 0
    restoreMinimizedWorkplaceTimer = Timer.scheduledTimer(
        withTimeInterval: interval,
        repeats: true
    ) { timer in
        attempts += 1
        let result = restoreMinimizedWorkplaceIfMeetingEnded(
            pid: pid,
            meetingEndConfirmed: consecutiveAbsentChecks >= 3
        )
        switch result {
        case .unconfirmedEnd:
            consecutiveAbsentChecks += 1
        case .meetingActive, .done, .zoomNotRunning:
            timer.invalidate()
            restoreMinimizedWorkplaceTimer = nil
        case .waiting:
            break
        }

        if timer.isValid, attempts >= maxAttempts {
            if attempts >= maxAttempts && result == .waiting {
                emit("Meeting ended; could not restore \"\(targetWindowTitle)\"")
            }
            timer.invalidate()
            restoreMinimizedWorkplaceTimer = nil
        }
    }
}

// MARK: - Chat preview handling

// Zoom deliberately resets "Show chat previews" for every meeting and exposes
// no persistent preference for it. Use the labels Zoom publishes to macOS
// Accessibility rather than fragile screen coordinates.
var handledChatPreviewWindow: AXUIElement?
var pressedChatPreviewCheckboxWindow: AXUIElement?
var chatPreviewTimer: Timer?

func meetingWindow(pid: pid_t) -> AXUIElement? {
    let (error, windows) = copyZoomWindows(pid: pid)
    guard error == .success else { return nil }
    return titledMeetingWindow(in: windows)
}

enum ChatPreviewAttempt {
    case done
    case waiting
    case noMeeting
}

func disableChatPreviewsIfNeeded(pid: pid_t, reason: String) -> ChatPreviewAttempt {
    guard let window = meetingWindow(pid: pid) else {
        handledChatPreviewWindow = nil
        pressedChatPreviewCheckboxWindow = nil
        return .noMeeting
    }

    if axElement(window, isSameAs: handledChatPreviewWindow) {
        return .done
    }

    // Zoom exposes the setting directly in the meeting window's AX tree, even
    // when its settings panel is not visible.
    if let checkbox = findAXElement(
        below: window,
        role: kAXCheckBoxRole as String,
        label: chatPreviewCheckboxLabel
    ) {
        switch axBool(checkbox, kAXValueAttribute as String) {
        case true:
            if !axElement(window, isSameAs: pressedChatPreviewCheckboxWindow) {
                guard AXUIElementPerformAction(
                    checkbox,
                    kAXPressAction as CFString
                ) == .success else {
                    logger.notice("Failed to press the chat preview checkbox (\(reason, privacy: .public))")
                    return .waiting
                }
                pressedChatPreviewCheckboxWindow = window
                emit("Found Zoom meeting; disabling chat previews (checkbox)")
            }
            // Confirm the value on the next retry rather than assuming Zoom
            // applied an asynchronous checkbox action.
            return .waiting

        case false:
            if axElement(window, isSameAs: pressedChatPreviewCheckboxWindow) {
                emit("Disabled Zoom chat previews for this meeting")
            } else {
                emit("Zoom chat previews already disabled for this meeting")
            }
            handledChatPreviewWindow = window
            pressedChatPreviewCheckboxWindow = nil
            return .done

        case nil:
            logger.notice("Could not read the chat preview checkbox value")
            return .waiting
        }
    }

    return .waiting
}

func scheduleDisableChatPreviews(
    pid: pid_t,
    reason: String,
    maxAttempts: Int,
    interval: TimeInterval
) {
    if disableChatPreviewsIfNeeded(pid: pid, reason: reason) == .done { return }
    if chatPreviewTimer?.isValid == true { return }

    var attempts = 0
    chatPreviewTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
        attempts += 1
        let result = disableChatPreviewsIfNeeded(pid: pid, reason: reason)
        if result == .done || attempts >= maxAttempts {
            if attempts >= maxAttempts && result != .noMeeting {
                if let window = meetingWindow(pid: pid) {
                    dumpChatAXCandidates(window: window, reason: "timeout")
                }
                emit("Could not disable Zoom chat previews after \(attempts) attempts")
            }
            timer.invalidate()
            chatPreviewTimer = nil
        }
    }
}

// MARK: - AX window observer

// Catches meeting-window creation without continuous polling. Retained for the
// process' lifetime; re-registered whenever Zoom relaunches with a new pid.
var axObserver: AXObserver?
var observedPID: pid_t = 0
var observedMeetingEndWindow: AXUIElement?

// All application-level notifications (reliably delivered when registered on
// the app element). Creation/focus/activation can each expose the meeting after
// a slightly different stage of Zoom's window setup.
let observedNotifications: [CFString] = [
    kAXWindowCreatedNotification as CFString,
    kAXFocusedWindowChangedNotification as CFString,
    kAXApplicationActivatedNotification as CFString,
]

func observeMeetingEnd(for meetingWindow: AXUIElement) {
    if axElement(meetingWindow, isSameAs: observedMeetingEndWindow) { return }
    guard let observer = axObserver else { return }

    let error = AXObserverAddNotification(
        observer,
        meetingWindow,
        kAXUIElementDestroyedNotification as CFString,
        nil
    )
    if error == .success || error == .notificationAlreadyRegistered {
        observedMeetingEndWindow = meetingWindow
    } else {
        logger.notice("Could not observe meeting end (AXError: \(error.rawValue, privacy: .public))")
    }
}

func scheduleConfiguredWorkplaceAction(
    pid: pid_t,
    reason: String,
    maxAttempts: Int,
    interval: TimeInterval
) {
    switch settings.workplaceMode {
    case .closeDuringMeetings:
        scheduleCloseWorkplace(
            pid: pid,
            reason: reason,
            maxAttempts: maxAttempts,
            interval: interval
        )
    case .minimizeDuringMeetings:
        scheduleMinimizeWorkplaceDuringMeeting(
            pid: pid,
            reason: reason,
            maxAttempts: maxAttempts,
            interval: interval
        )
    case .minimizeAlways:
        scheduleMinimizeWorkplaceAlways(
            pid: pid,
            reason: reason,
            maxAttempts: maxAttempts,
            interval: interval
        )
    case .leaveAlone:
        break
    }
}

func scheduleConfiguredChatPreviewAction(
    pid: pid_t,
    reason: String,
    maxAttempts: Int,
    interval: TimeInterval
) {
    guard !settings.showChatPreviews else { return }
    scheduleDisableChatPreviews(
        pid: pid,
        reason: reason,
        maxAttempts: maxAttempts,
        interval: interval
    )
}

func scheduleConfiguredMeetingEndAction(pid: pid_t) {
    switch settings.workplaceMode {
    case .closeDuringMeetings:
        scheduleReopenWorkplaceAfterMeeting(pid: pid)
    case .minimizeDuringMeetings:
        scheduleRestoreMinimizedWorkplaceAfterMeeting(pid: pid)
    case .minimizeAlways, .leaveAlone:
        break
    }
}

func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard observedPID != 0 else { return }
    logger.debug("AX event: \(notification as String, privacy: .public)")

    if CFEqual(notification, kAXUIElementDestroyedNotification as CFString) {
        observedMeetingEndWindow = nil
        scheduleConfiguredMeetingEndAction(pid: observedPID)
        return
    }

    // Some Zoom versions focus another window before destroying the meeting
    // window. Treat all meeting UI disappearing as the same transition, while
    // allowing the normal window to become floating screen-sharing controls.
    if observedMeetingEndWindow != nil,
       activeMeetingWindow(pid: observedPID) == nil {
        observedMeetingEndWindow = nil
        scheduleConfiguredMeetingEndAction(pid: observedPID)
    }

    scheduleConfiguredWorkplaceAction(
        pid: observedPID,
        reason: "ax:\(notification as String)",
        maxAttempts: 20,
        interval: 0.4
    )
    scheduleConfiguredChatPreviewAction(
        pid: observedPID,
        reason: "ax:\(notification as String)",
        maxAttempts: 20,
        interval: 0.4
    )
}

func registerAXObserver(pid: pid_t) {
    if let existing = axObserver {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(existing), .defaultMode)
        axObserver = nil
        observedMeetingEndWindow = nil
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

func installDiagnosticSignalHandler() {
    // Install this before any AX work or permission waiting. That guarantees
    // status/dump cannot terminate the daemon even if Zoom is currently holding
    // an Accessibility call open.
    signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { dumpZoomWindows(reason: "SIGUSR1") }
    source.resume()
    sigusr1Source = source
}

func handleZoom(pid: pid_t, reason: String) {
    dumpZoomWindows(reason: reason)
    registerAXObserver(pid: pid)
    scheduleConfiguredWorkplaceAction(
        pid: pid,
        reason: reason,
        maxAttempts: 45,
        interval: 1.0
    )
    scheduleConfiguredChatPreviewAction(
        pid: pid,
        reason: reason,
        maxAttempts: 45,
        interval: 1.0
    )
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

    center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == zoomBundleID else { return }
        reopenWorkplaceTimer?.invalidate()
        reopenWorkplaceTimer = nil
        reopenWorkplaceRequested = false
        restoreMinimizedWorkplaceTimer?.invalidate()
        restoreMinimizedWorkplaceTimer = nil
        minimizeWorkplaceDuringMeetingTimer?.invalidate()
        minimizeWorkplaceDuringMeetingTimer = nil
        minimizeWorkplaceAlwaysTimer?.invalidate()
        minimizeWorkplaceAlwaysTimer = nil
        observedMeetingEndWindow = nil
    }

    // Zoom brought to the front — a newly created meeting window may now have
    // its final title and controls.
    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == zoomBundleID else { return }
        scheduleConfiguredWorkplaceAction(
            pid: app.processIdentifier,
            reason: "activate",
            maxAttempts: 12,
            interval: 0.4
        )
        scheduleConfiguredChatPreviewAction(
            pid: app.processIdentifier,
            reason: "activate",
            maxAttempts: 12,
            interval: 0.4
        )
    }

    // Zoom already running when we start (e.g. at login).
    if let zoomApp = zoomApplication() {
        emit("Zoom already running (pid \(zoomApp.processIdentifier))")
        handleZoom(pid: zoomApp.processIdentifier, reason: "startup-scan")
    }

    emit(
        "Configuration: workplace=\(settings.workplaceMode.rawValue), "
            + "show-chat-previews=\(settings.showChatPreviews ? "yes" : "no")"
    )
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
    print("  workplace:     \(settings.workplaceMode.description)")
    print("  chat previews: \(settings.showChatPreviews ? "yes" : "no")")
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

installDiagnosticSignalHandler()

if AXIsProcessTrusted() {
    startWatching()
} else {
    // Don't exit — that would make launchd respawn us in a loop. Instead wait
    // for the user to grant permission and start the moment it lands.
    emit("Accessibility not granted; waiting for permission")
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
        if AXIsProcessTrusted() {
            emit("Accessibility granted; starting")
            timer.invalidate()
            startWatching()
        }
    }
}

RunLoop.main.run()
