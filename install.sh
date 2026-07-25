#!/bin/bash
set -euo pipefail

BINARY_NAME="ZoomStupidWorkplaceAutominimizer"
DEFAULT_IDENTIFIER="com.example.ZoomStupidWorkplaceAutominimizer"
STATE_DIR="$HOME/.config/${BINARY_NAME}"
STATE_FILE="${STATE_DIR}/bundle-id"
WORKPLACE_MODE_FILE="${STATE_DIR}/workplace-mode"
CHAT_PREVIEWS_FILE="${STATE_DIR}/show-chat-previews"
DEFAULT_WORKPLACE_MODE="close-during-meetings"
DEFAULT_SHOW_CHAT_PREVIEWS="no"

valid_workplace_mode() {
    case "$1" in
        close-during-meetings|minimize-during-meetings|minimize-always|leave-alone)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

valid_yes_no() {
    case "$1" in
        yes|no) return 0 ;;
        *)      return 1 ;;
    esac
}

# Bundle identifier, resolved as: ZWAM_BUNDLE_ID override > the id chosen at the
# last install > the placeholder default. Brand your own build with, e.g.:
#   ZWAM_BUNDLE_ID="com.yourorg.ZoomStupidWorkplaceAutominimizer" ./install.sh install
if [ -n "${ZWAM_BUNDLE_ID:-}" ]; then
    IDENTIFIER="$ZWAM_BUNDLE_ID"
elif [ -f "$STATE_FILE" ]; then
    IDENTIFIER="$(cat "$STATE_FILE")"
else
    IDENTIFIER="$DEFAULT_IDENTIFIER"
fi

if [ -n "${ZWAM_WORKPLACE_MODE:-}" ]; then
    WORKPLACE_MODE="$ZWAM_WORKPLACE_MODE"
elif [ -f "$WORKPLACE_MODE_FILE" ]; then
    WORKPLACE_MODE="$(cat "$WORKPLACE_MODE_FILE")"
else
    WORKPLACE_MODE="$DEFAULT_WORKPLACE_MODE"
fi

if [ -n "${ZWAM_SHOW_CHAT_PREVIEWS:-}" ]; then
    SHOW_CHAT_PREVIEWS="$ZWAM_SHOW_CHAT_PREVIEWS"
elif [ -f "$CHAT_PREVIEWS_FILE" ]; then
    SHOW_CHAT_PREVIEWS="$(cat "$CHAT_PREVIEWS_FILE")"
else
    SHOW_CHAT_PREVIEWS="$DEFAULT_SHOW_CHAT_PREVIEWS"
fi

if ! valid_workplace_mode "$WORKPLACE_MODE"; then
    echo "Invalid Workplace mode: ${WORKPLACE_MODE}" >&2
    exit 1
fi
if ! valid_yes_no "$SHOW_CHAT_PREVIEWS"; then
    echo "Show Chat Previews must be 'yes' or 'no' (got: ${SHOW_CHAT_PREVIEWS})" >&2
    exit 1
fi

# Per-user install dir so no sudo is needed (/usr/local/bin is root-owned).
INSTALL_DIR="$HOME/.local/bin"
INSTALLED_BINARY="$INSTALL_DIR/$BINARY_NAME"
PLIST_SRC="Resources/${BINARY_NAME}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${IDENTIFIER}.plist"
# User-owned logs (not /tmp, which is world-readable/writable).
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="${LOG_DIR}/${BINARY_NAME}.stdout.log"
STDERR_LOG="${LOG_DIR}/${BINARY_NAME}.stderr.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
BUILD_BINARY="${BUILD_DIR}/${BINARY_NAME}"

daemon_pid() {
    # A missing service is the normal "not running" case. Keep the pipeline from
    # terminating the script under `set -o pipefail`.
    launchctl print "gui/$(id -u)/$IDENTIFIER" 2>/dev/null |
        awk '/[^a-z]pid =/{print $3; exit}' || true
}

print_configuration() {
    echo "Configuration:"
    echo "  Workplace window:   ${WORKPLACE_MODE}"
    echo "  Show Chat Previews: ${SHOW_CHAT_PREVIEWS}"
}

save_configuration() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$WORKPLACE_MODE" > "$WORKPLACE_MODE_FILE"
    printf '%s\n' "$SHOW_CHAT_PREVIEWS" > "$CHAT_PREVIEWS_FILE"
}

set_plist_environment_value() {
    local key="$1"
    local value="$2"
    if ! /usr/libexec/PlistBuddy \
        -c "Set :EnvironmentVariables:${key} ${value}" "$PLIST_DST" 2>/dev/null; then
        /usr/libexec/PlistBuddy \
            -c "Add :EnvironmentVariables:${key} string ${value}" "$PLIST_DST"
    fi
}

cd "$SCRIPT_DIR"

# Signing identity. Ad-hoc ("-") works fine for a binary you install once, but
# every rebuild changes its code hash and invalidates the Accessibility grant.
# Set ZWAM_SIGN_IDENTITY to a stable code-signing identity (e.g. a self-signed
# cert — see README) to keep the grant across rebuilds.
SIGN_IDENTITY="${ZWAM_SIGN_IDENTITY:--}"

build() {
    echo "Building…"
    mkdir -p "$BUILD_DIR"
    swiftc -module-cache-path "${BUILD_DIR}/ModuleCache" \
        -O -o "$BUILD_BINARY" Sources/main.swift

    echo "Signing (identity: ${SIGN_IDENTITY})…"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" "$BUILD_BINARY"
}

case "${1:-install}" in
    install)
        build

        echo "Installing binary to ${INSTALLED_BINARY}…"
        mkdir -p "$INSTALL_DIR"
        cp "$BUILD_BINARY" "$INSTALLED_BINARY"

        echo "Installing LaunchAgent (bundle id: ${IDENTIFIER})…"
        mkdir -p "$(dirname "$PLIST_DST")" "$LOG_DIR" "$STATE_DIR"
        # Use PlistBuddy (not sed) so paths with shell/sed metacharacters are safe.
        cp "$PLIST_SRC" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :Label ${IDENTIFIER}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${INSTALLED_BINARY}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :StandardOutPath ${STDOUT_LOG}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${STDERR_LOG}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:ZWAM_BUNDLE_ID ${IDENTIFIER}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:ZWAM_WORKPLACE_MODE ${WORKPLACE_MODE}" "$PLIST_DST"
        /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:ZWAM_SHOW_CHAT_PREVIEWS ${SHOW_CHAT_PREVIEWS}" "$PLIST_DST"

        # Remember the chosen id and behavior so later subcommands target the
        # same install and future installs retain the selected configuration.
        printf '%s\n' "$IDENTIFIER" > "$STATE_FILE"
        save_configuration

        # Reload (ignore errors if not already loaded).
        launchctl bootout "gui/$(id -u)/$IDENTIFIER" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

        echo ""
        echo "Installed and running."
        print_configuration
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
            print_configuration
            if [ -x "$INSTALLED_BINARY" ]; then
                echo "(No daemon to ask. A direct '--status' below reflects THIS"
                echo " terminal's Accessibility grant, not the installed binary's.)"
                ZWAM_WORKPLACE_MODE="$WORKPLACE_MODE" \
                    ZWAM_SHOW_CHAT_PREVIEWS="$SHOW_CHAT_PREVIEWS" \
                    "$INSTALLED_BINARY" --status
            else
                echo "Not installed. Run './install.sh install' first."
            fi
            exit 0
        fi

        echo "Daemon: running (pid ${PID})"
        print_configuration

        # Authoritative: ask the running daemon, which has the real launchd TCC
        # context. A fresh '--status' from a terminal reports the *terminal's*
        # grant instead, so it can wrongly say NOT granted while the daemon works.
        # Only inspect bytes written in response to this signal; otherwise a
        # non-responsive daemon could make us report a stale result from an old
        # process as though it were current.
        LOG_BYTES=0
        if [ -f "$STDOUT_LOG" ]; then
            LOG_BYTES="$(wc -c < "$STDOUT_LOG" | tr -d ' ')"
        fi
        kill -USR1 "$PID" 2>/dev/null || true
        sleep 0.4
        NEW_LOG="$(tail -c "+$((LOG_BYTES + 1))" "$STDOUT_LOG" 2>/dev/null || true)"
        TRUSTED_STATE="$(printf '%s\n' "$NEW_LOG" | grep -oE 'trusted=(true|false)' | tail -n1 || true)"
        case "$TRUSTED_STATE" in
            trusted=true)  echo "Accessibility (daemon): granted" ;;
            trusted=false) echo "Accessibility (daemon): NOT granted — grant ${INSTALLED_BINARY}" ;;
            *)             echo "Accessibility (daemon): unknown (daemon did not respond)" ;;
        esac
        ;;

    configure)
        shift
        REQUESTED_WORKPLACE_MODE=""
        REQUESTED_SHOW_CHAT_PREVIEWS=""

        while [ "$#" -gt 0 ]; do
            case "$1" in
                --workplace-mode)
                    if [ "$#" -lt 2 ]; then
                        echo "--workplace-mode requires a value" >&2
                        exit 1
                    fi
                    REQUESTED_WORKPLACE_MODE="$2"
                    shift 2
                    ;;
                --show-chat-previews)
                    if [ "$#" -lt 2 ]; then
                        echo "--show-chat-previews requires yes or no" >&2
                        exit 1
                    fi
                    REQUESTED_SHOW_CHAT_PREVIEWS="$2"
                    shift 2
                    ;;
                *)
                    echo "Unknown configure option: $1" >&2
                    exit 1
                    ;;
            esac
        done

        if [ -z "$REQUESTED_WORKPLACE_MODE" ]; then
            echo "Workplace window:"
            echo "  1. Close during meetings (default)"
            echo "  2. Minimize during meetings"
            echo "  3. Minimize always"
            echo "  4. Leave alone"
            printf "Choose 1-4 [current: %s]: " "$WORKPLACE_MODE"
            read -r MODE_CHOICE
            case "$MODE_CHOICE" in
                "")  REQUESTED_WORKPLACE_MODE="$WORKPLACE_MODE" ;;
                1)   REQUESTED_WORKPLACE_MODE="close-during-meetings" ;;
                2)   REQUESTED_WORKPLACE_MODE="minimize-during-meetings" ;;
                3)   REQUESTED_WORKPLACE_MODE="minimize-always" ;;
                4)   REQUESTED_WORKPLACE_MODE="leave-alone" ;;
                *)   REQUESTED_WORKPLACE_MODE="$MODE_CHOICE" ;;
            esac
        fi

        if [ -z "$REQUESTED_SHOW_CHAT_PREVIEWS" ]; then
            printf "Show Chat Previews? [yes/no, current: %s]: " "$SHOW_CHAT_PREVIEWS"
            read -r CHAT_CHOICE
            case "$CHAT_CHOICE" in
                "")      REQUESTED_SHOW_CHAT_PREVIEWS="$SHOW_CHAT_PREVIEWS" ;;
                y|Y)     REQUESTED_SHOW_CHAT_PREVIEWS="yes" ;;
                n|N)     REQUESTED_SHOW_CHAT_PREVIEWS="no" ;;
                yes|no)  REQUESTED_SHOW_CHAT_PREVIEWS="$CHAT_CHOICE" ;;
                *)       REQUESTED_SHOW_CHAT_PREVIEWS="$CHAT_CHOICE" ;;
            esac
        fi

        if ! valid_workplace_mode "$REQUESTED_WORKPLACE_MODE"; then
            echo "Invalid Workplace mode: ${REQUESTED_WORKPLACE_MODE}" >&2
            exit 1
        fi
        if ! valid_yes_no "$REQUESTED_SHOW_CHAT_PREVIEWS"; then
            echo "Show Chat Previews must be 'yes' or 'no'" >&2
            exit 1
        fi

        WORKPLACE_MODE="$REQUESTED_WORKPLACE_MODE"
        SHOW_CHAT_PREVIEWS="$REQUESTED_SHOW_CHAT_PREVIEWS"
        save_configuration

        if [ -f "$PLIST_DST" ]; then
            RUNNING_PID="$(daemon_pid)"
            set_plist_environment_value "ZWAM_WORKPLACE_MODE" "$WORKPLACE_MODE"
            set_plist_environment_value "ZWAM_SHOW_CHAT_PREVIEWS" "$SHOW_CHAT_PREVIEWS"
            if [ -n "$RUNNING_PID" ]; then
                launchctl bootout "gui/$(id -u)/$IDENTIFIER" 2>/dev/null || true
                launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
                echo "Restarted the agent with the new configuration."
            else
                echo "Saved to the installed LaunchAgent; it will apply when the agent starts."
            fi
        else
            echo "Saved; it will apply on the next install."
        fi
        print_configuration
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
        # bootout, not kill: with KeepAlive the LaunchAgent would otherwise just respawn.
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

        rm -f "$STATE_FILE" "$WORKPLACE_MODE_FILE" "$CHAT_PREVIEWS_FILE"
        rmdir "$STATE_DIR" 2>/dev/null || true

        echo "Done. Uninstalled."
        ;;

    *)
        echo "Usage: $0 [install|configure|start|quit|status|dump|logs|reset-permission|uninstall]"
        echo "Configure noninteractively:"
        echo "  $0 configure --workplace-mode MODE --show-chat-previews yes|no"
        exit 1
        ;;
esac
