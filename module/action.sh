#!/system/bin/sh
# Baihu Panel - Magisk action.sh (executes when the module "Run" button is tapped)
#
# Goal: open the Baihu panel link in the device browser.
#
# The panel address is not hard-coded: it lives in /data/baihu/baihu.conf
# (PANEL_PORT / PANEL_HOST), falling back to 18052 / 127.0.0.1.
# Because the container shares the host network namespace (-A), the host
# loopback is the same loopback the container binds, so http://127.0.0.1:PORT
# reaches the panel from any app on the device.

MODDIR=${0%/*}
DATA_DIR=/data/baihu
CONFIG_FILE=$DATA_DIR/baihu.conf
LOG_FILE=$DATA_DIR/run.log

# Load user-overridable port/host, defaulting to loopback + 18052.
PANEL_PORT=18052
PANEL_HOST=127.0.0.1
if [ -f "$CONFIG_FILE" ]; then
  # baihu.conf is shell-sourced by the main script, so it is safe to source.
  . "$CONFIG_FILE" 2>/dev/null
fi

URL="http://${PANEL_HOST:-127.0.0.1}:${PANEL_PORT:-18052}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] action.sh: $*" >> "$LOG_FILE" 2>/dev/null || true
}

log "opening panel: $URL"

# Optional, non-fatal: warn if nothing is listening yet. The panel may still be
# binding, so we open the browser regardless.
if command -v ss >/dev/null 2>&1; then
  ss -tln 2>/dev/null | grep -q ":${PANEL_PORT:-18052}" && log "port listening" \
    || log "WARNING: port ${PANEL_PORT:-18052} not listening yet"
elif command -v netstat >/dev/null 2>&1; then
  netstat -tln 2>/dev/null | grep -q ":${PANEL_PORT:-18052}" && log "port listening" \
    || log "WARNING: port ${PANEL_PORT:-18052} not listening yet"
fi

# Open the device browser on the panel URL.
if command -v am >/dev/null 2>&1; then
  am start -a android.intent.action.VIEW -d "$URL"
else
  log "ERROR: am (Activity Manager) not found"
fi
