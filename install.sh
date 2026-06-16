#!/bin/bash
set -euo pipefail

BINARY_NAME="ZoomStupidWorkplaceAutominimizer"
IDENTIFIER="com.example.ZoomStupidWorkplaceAutominimizer"
# Per-user install dir so no sudo is needed (/usr/local/bin is root-owned).
INSTALL_DIR="$HOME/.local/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
PLIST_SRC="Resources/${IDENTIFIER}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${IDENTIFIER}.plist"
# User-owned logs (not /tmp, which is world-readable/writable).
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="${LOG_DIR}/${BINARY_NAME}.stdout.log"
STDERR_LOG="${LOG_DIR}/${BINARY_NAME}.stderr.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

daemon_pid() {
    launchctl print "gui/$(id -u)/$IDENTIFIER" 2>/dev/null | awk '/[^a-z]pid =/{print $3; exit}'
}

cd "$SCRIPT_DIR"

# Signing identity. Ad-hoc ("-") works fine for a binary you install once, but
# every rebuild changes its code hash and invalidates the Accessibility grant.
# Set ZWAM_SIGN_IDENTITY to a stable code-signing identity (e.g. a self-signed
# cert — see README) to keep the grant across rebuilds.
SIGN_IDENTITY="${ZWAM_SIGN_IDENTITY:--}"

build() {
    echo "Building…"
    swiftc -O -o "$BINARY_NAME" Sources/main.swift

    echo "Signing (identity: ${SIGN_IDENTITY})…"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" "$BINARY_NAME"
}

case "${1:-install}" in
    install)
        build

        echo "Installing binary to ${INSTALLED_BINARY}…"
        mkdir -p "$INSTALL_DIR"
        cp "$BINARY_NAME" "$INSTALL_DIR/"

        echo "Installing LaunchAgent…"
        mkdir -p "$(dirname "$PLIST_DST")" "$LOG_DIR"
        # Use PlistBuddy (not sed) so paths with shell/sed metacharacters are safe.
        cp "$PLIST_SRC" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${INSTALLED_BINARY}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :StandardOutPath ${STDOUT_LOG}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${STDERR_LOG}" "$PLIST_DST"

        # Reload (ignore errors if not already loaded).
        launchctl bootout "gui/$(id -u)/$IDENTIFIER" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

        echo ""
        echo "Installed and running."
        echo ""
        if [ "$SIGN_IDENTITY" = "-" ]; then
            echo "NOTE: ad-hoc signed. If you rebuild later, re-grant Accessibility"
            echo "      (run './install.sh reset-permission' then re-add it)."
            echo ""
        fi
        echo "Grant Accessibility access to:"
        echo "  ${INSTALLED_BINARY}"
        echo "Opening System Settings and revealing the binary in Finder…"
        open -R "$INSTALLED_BINARY" 2>/dev/null || true
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
        echo ""
        echo "After granting, verify with:  ./install.sh status"
        ;;

    status)
        PID="$(daemon_pid)"
        if [ -z "$PID" ]; then
            echo "Daemon: not running."
            if [ -x "$INSTALLED_BINARY" ]; then
                echo "(No daemon to ask. A direct '--status' below reflects THIS"
                echo " terminal's Accessibility grant, not the installed binary's.)"
                "$INSTALLED_BINARY" --status
            else
                echo "Not installed. Run './install.sh install' first."
            fi
            exit 0
        fi

        echo "Daemon: running (pid ${PID})"

        # Authoritative: ask the running daemon, which has the real launchd TCC
        # context. A fresh '--status' from a terminal reports the *terminal's*
        # grant instead, so it can wrongly say NOT granted while the daemon works.
        kill -USR1 "$PID" 2>/dev/null || true
        sleep 0.4
        case "$(grep -oE 'trusted=(true|false)' "$STDOUT_LOG" 2>/dev/null | tail -n1)" in
            trusted=true)  echo "Accessibility (daemon): granted" ;;
            trusted=false) echo "Accessibility (daemon): NOT granted — grant ${INSTALLED_BINARY}" ;;
            *)             echo "Accessibility (daemon): unknown (no dump in log yet)" ;;
        esac
        ;;

    dump)
        PID="$(daemon_pid)"
        if [ -z "$PID" ]; then
            echo "Daemon not running. Run './install.sh install' first."
            exit 1
        fi
        echo "Sending SIGUSR1 to pid ${PID} (read-only window dump)…"
        kill -USR1 "$PID"
        sleep 0.4
        echo "--- latest window dump (${STDOUT_LOG}) ---"
        tail -n 30 "$STDOUT_LOG" 2>/dev/null || echo "(no log yet)"
        ;;

    logs)
        echo "--- ${STDOUT_LOG} ---"
        tail -n 60 "$STDOUT_LOG" 2>/dev/null || echo "(empty)"
        ;;

    quit|stop)
        if [ -z "$(daemon_pid)" ]; then
            echo "Not running."
            exit 0
        fi
        echo "Stopping ${BINARY_NAME}…"
        # bootout, not kill: with KeepAlive the agent would otherwise just respawn.
        launchctl bootout "gui/$(id -u)/$IDENTIFIER" 2>/dev/null || true
        sleep 0.3
        if [ -z "$(daemon_pid)" ]; then
            echo "Stopped. Starts again at next login; run './install.sh start' to start it now."
        else
            echo "Still running (pid $(daemon_pid)) — failed to stop."
            exit 1
        fi
        ;;

    start)
        if [ ! -f "$PLIST_DST" ]; then
            echo "Not installed. Run './install.sh install' first."
            exit 1
        fi
        if [ -n "$(daemon_pid)" ]; then
            echo "Already running (pid $(daemon_pid))."
            exit 0
        fi
        echo "Starting ${BINARY_NAME}…"
        launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
        echo "Started. Verify with './install.sh status'."
        ;;

    reset-permission)
        echo "Resetting Accessibility permission for ${IDENTIFIER}…"
        tccutil reset Accessibility "$IDENTIFIER" 2>/dev/null || true
        echo "Done. Re-add the binary in System Settings ▸ Privacy & Security ▸ Accessibility:"
        echo "  ${INSTALLED_BINARY}"
        ;;

    uninstall)
        echo "Stopping and removing LaunchAgent…"
        launchctl bootout "gui/$(id -u)/$IDENTIFIER" 2>/dev/null || true
        rm -f "$PLIST_DST"

        echo "Removing binary…"
        rm -f "$INSTALLED_BINARY"

        echo "Removing logs…"
        rm -f "$STDOUT_LOG" "$STDERR_LOG"

        echo "Removing Accessibility permission entry…"
        tccutil reset Accessibility "$IDENTIFIER" 2>/dev/null || true

        echo "Done. Uninstalled."
        ;;

    *)
        echo "Usage: $0 [install|start|quit|status|dump|logs|reset-permission|uninstall]"
        exit 1
        ;;
esac
