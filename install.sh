#!/bin/bash
set -euo pipefail

BINARY_NAME="ZoomStupidWorkplaceAutominimizer"
IDENTIFIER="com.nicemohawk.ZoomStupidWorkplaceAutominimizer"
# Per-user install dir so no sudo is needed (/usr/local/bin is root-owned).
INSTALL_DIR="$HOME/.local/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
PLIST_SRC="Resources/${IDENTIFIER}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${IDENTIFIER}.plist"
STDOUT_LOG="/tmp/${BINARY_NAME}.stdout.log"
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
        mkdir -p "$(dirname "$PLIST_DST")"
        sed "s|__BINARY_PATH__|${INSTALLED_BINARY}|g" "$PLIST_SRC" > "$PLIST_DST"

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
        if [ -x "$INSTALLED_BINARY" ]; then
            "$INSTALLED_BINARY" --status
        else
            echo "Not installed at ${INSTALLED_BINARY}. Run './install.sh install' first."
            exit 1
        fi
        echo ""
        echo "LaunchAgent:"
        launchctl print "gui/$(id -u)/$IDENTIFIER" 2>/dev/null | grep -E "state|pid" | sed 's/^/  /' || echo "  not loaded"
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

        echo "Removing Accessibility permission entry…"
        tccutil reset Accessibility "$IDENTIFIER" 2>/dev/null || true

        echo "Done. Uninstalled."
        ;;

    *)
        echo "Usage: $0 [install|status|dump|logs|reset-permission|uninstall]"
        exit 1
        ;;
esac
