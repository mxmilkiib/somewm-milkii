#!/bin/bash
# xephyr testing script for awesomewm configuration validation
# usage: ./test_xephyr.sh [config_path]

set -e

# configuration
XEPHYR_DISPLAY=":1"
XEPHYR_GEOMETRY="1024x768"
CONFIG_PATH="${1:-$HOME/.config/awesome/rc.lua}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-10}"

# logging
LOG_DIR="/tmp/awesome_xephyr_test"
LOG_XEPHYR="$LOG_DIR/xephyr.log"
LOG_AWESOME="$LOG_DIR/awesome.log"
LOG_CLIENT="$LOG_DIR/client.log"

# colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # no color

log() {
    echo -e "${GREEN}[xephyr-test]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[xephyr-test]${NC} $1"
}

error() {
    echo -e "${RED}[xephyr-test]${NC} $1"
}

cleanup() {
    log "cleaning up test environment"
    
    # kill awesome if running
    if [ ! -z "$AWESOME_PID" ]; then
        kill $AWESOME_PID 2>/dev/null || true
        wait $AWESOME_PID 2>/dev/null || true
    fi
    # kill clients if running
    if [ ! -z "$CLIENT_PID" ]; then
        kill $CLIENT_PID 2>/dev/null || true
        wait $CLIENT_PID 2>/dev/null || true
    fi
    if [ ! -z "$CLIENT_PID2" ]; then
        kill $CLIENT_PID2 2>/dev/null || true
        wait $CLIENT_PID2 2>/dev/null || true
    fi
    # kill any additional clients from array
    for pid in "${CLIENT_PIDS[@]}"; do
        if [ ! -z "$pid" ]; then
            kill $pid 2>/dev/null || true
            wait $pid 2>/dev/null || true
        fi
    done
    
    # kill xephyr if running
    if [ ! -z "$XEPHYR_PID" ]; then
        kill $XEPHYR_PID 2>/dev/null || true
        wait $XEPHYR_PID 2>/dev/null || true
    fi
}

# trap cleanup on exit
trap cleanup EXIT INT TERM

main() {
    log "starting xephyr test for awesomewm configuration"
    log "config: $CONFIG_PATH"
    log "display: $XEPHYR_DISPLAY"
    log "geometry: $XEPHYR_GEOMETRY"
    mkdir -p "$LOG_DIR"
    : >"$LOG_XEPHYR"; : >"$LOG_AWESOME"; : >"$LOG_CLIENT"
    
    # check if config exists
    if [ ! -f "$CONFIG_PATH" ]; then
        error "configuration file not found: $CONFIG_PATH"
        exit 1
    fi
    
    # syntax check first
    log "performing syntax check..."
    if ! awesome -k -c "$CONFIG_PATH"; then
        error "configuration syntax check failed"
        exit 1
    fi
    log "syntax check passed"
    
    # check if display is already in use
    if xdpyinfo -display "$XEPHYR_DISPLAY" >/dev/null 2>&1; then
        warn "display $XEPHYR_DISPLAY already in use, attempting to use it anyway"
    fi
    
    # start xephyr
    log "starting xephyr server... (logs: $LOG_XEPHYR)"
    Xephyr "$XEPHYR_DISPLAY" -screen "$XEPHYR_GEOMETRY" -ac -br >"$LOG_XEPHYR" 2>&1 &
    XEPHYR_PID=$!
    
    # wait for xephyr to start
    sleep 2
    
    # verify xephyr is running
    if ! kill -0 $XEPHYR_PID 2>/dev/null; then
        error "xephyr failed to start"
        exit 1
    fi
    
    # start awesome in xephyr
    log "starting awesome in xephyr... (logs: $LOG_AWESOME)"
    DISPLAY="$XEPHYR_DISPLAY" awesome -c "$CONFIG_PATH" >"$LOG_AWESOME" 2>&1 &
    AWESOME_PID=$!
    
    # wait a moment for awesome to initialize
    sleep 3
    
    # check if awesome is still running
    if ! kill -0 $AWESOME_PID 2>/dev/null; then
        error "awesome failed to start or crashed immediately"
        exit 1
    fi
    
    log "awesome started successfully in xephyr"

    # optionally spawn a browser inside Xephyr for heavier title churn
    if [ "${BROWSER_TEST:-0}" = "1" ]; then
        for B in google-chrome-stable google-chrome chromium chromium-browser brave-browser vivaldi-stable; do
            if command -v "$B" >/dev/null 2>&1; then
                BROWSER_CMD="$B"
                break
            fi
        done
        if [ -n "$BROWSER_CMD" ]; then
            log "spawning browser: $BROWSER_CMD (temp profile)"
            mkdir -p "$LOG_DIR/chrome-profile"
            DISPLAY="$XEPHYR_DISPLAY" "$BROWSER_CMD" --no-first-run --no-default-browser-check \
                --user-data-dir="$LOG_DIR/chrome-profile" --new-window "about:blank" \
                >"$LOG_CLIENT" 2>&1 &
            CLIENT_PID=$!
            sleep 2
        else
            warn "no browser found; falling back to terminal"
        fi
    fi

    # spawn two terminals inside Xephyr to ensure focused task entries exist (if none yet)
    # prefer urxvt, fallback to xterm or xclock
    CLIENT_CMD=""
    if [ -z "$CLIENT_PID" ] && command -v urxvt >/dev/null 2>&1; then
        CLIENT_CMD="urxvt"
    elif [ -z "$CLIENT_PID" ] && command -v xterm >/dev/null 2>&1; then
        CLIENT_CMD="xterm"
    elif [ -z "$CLIENT_PID" ] && command -v xclock >/dev/null 2>&1; then
        CLIENT_CMD="xclock"
    else
        warn "no terminal found (urxvt/xterm). install one for better test coverage"
    fi
    
    CLIENT_PIDS=()
    if [ -z "$CLIENT_PID" ] && [ -n "$CLIENT_CMD" ]; then
        # spawn first terminal
        log "spawning first terminal: $CLIENT_CMD (logs: $LOG_CLIENT)"
        DISPLAY="$XEPHYR_DISPLAY" $CLIENT_CMD >"$LOG_CLIENT" 2>&1 &
        CLIENT_PID=$!
        CLIENT_PIDS+=($CLIENT_PID)
        sleep 1
        
        # spawn second terminal
        log "spawning second terminal: $CLIENT_CMD"
        DISPLAY="$XEPHYR_DISPLAY" $CLIENT_CMD >>"$LOG_CLIENT" 2>&1 &
        CLIENT_PID2=$!
        CLIENT_PIDS+=($CLIENT_PID2)
        sleep 1
        
        # cycle through shimmer presets in reverse after terminals are open
        if command -v awesome-client >/dev/null 2>&1; then
            log "cycling through shimmer presets in reverse"
            sleep 2  # give terminals time to fully initialize
            
            # send key combinations to cycle through presets
            # assuming mod4+shift+s cycles presets in reverse
            for i in {1..3}; do
                DISPLAY="$XEPHYR_DISPLAY" awesome-client 'awesome.emit_signal("shimmer::cycle_preset", "reverse")' 2>/dev/null || true
                sleep 0.5
            done
        else
            warn "awesome-client not found, skipping shimmer preset cycling"
        fi
    fi

    log "test environment running for $TIMEOUT_SECONDS seconds..."
    log "xephyr pid: $XEPHYR_PID"
    log "awesome pid: $AWESOME_PID"
    if [ -n "$CLIENT_PID" ]; then
        log "terminal 1 pid: $CLIENT_PID"
    fi
    if [ -n "$CLIENT_PID2" ]; then
        log "terminal 2 pid: $CLIENT_PID2"
    fi
    
    # run up to TIMEOUT_SECONDS, or exit early if Xephyr terminates or trackback detected
    SECONDS_WAITED=0
    while [ $SECONDS_WAITED -lt $TIMEOUT_SECONDS ]; do
        if ! kill -0 $XEPHYR_PID 2>/dev/null; then
            log "xephyr terminated by user before timeout ($SECONDS_WAITED s)"
            break
        fi
        
        # check for trackback in awesome log
        if grep -i "trackback" "$LOG_AWESOME" >/dev/null 2>&1; then
            error "trackback detected in awesome log, auto-exiting in 0.5 seconds"
            sleep 0.5
            break
        fi
        
        sleep 1
        SECONDS_WAITED=$((SECONDS_WAITED+1))
    done
    
    # check if awesome is still running at finish
    if kill -0 $AWESOME_PID 2>/dev/null; then
        log "awesome is still running at test end"
    else
        warn "awesome exited during test period"
    fi

    # show last debug lines to stdout for quick inspection
    echo ""; log "last 80 lines of awesome debug log:"; echo ""
    tail -n 80 "$LOG_AWESOME" || true
}

# show usage if help requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "usage: $0 [config_path]"
    echo ""
    echo "test awesomewm configuration in xephyr environment"
    echo ""
    echo "options:"
    echo "  config_path    path to awesome config (default: ~/.config/awesome/rc.lua)"
    echo "  -h, --help     show this help"
    echo ""
    echo "environment variables:"
    echo "  XEPHYR_DISPLAY    x display for xephyr (default: :1)"
    echo "  XEPHYR_GEOMETRY   window geometry (default: 1024x768)"
    echo "  TIMEOUT_SECONDS   test duration (default: 10)"
    exit 0
fi

main "$@"
