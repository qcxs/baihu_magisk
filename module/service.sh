#!/system/bin/sh
# Baihu Panel - Boot service
# This script runs after system boot, starts the Baihu container

# Bundled commands first (modified ROMs may lack system tools)
export PATH=${0%/*}/bin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

MODDIR=${0%/*}
DATA_DIR=/data/baihu
LOG_FILE=$DATA_DIR/run.log

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log "=== Baihu service starting ==="

# Ensure baihu command is in system PATH (shared helper: magic mount on Magisk,
# bind mount fallback on KernelSU).
. "$MODDIR/boot-common.sh"
ensure_baihu_path "$MODDIR"

# Prevent suspend (released when the panel stops, see cmd_stop)
echo "noSuspend" > /sys/power/wake_lock 2>/dev/null || true
dumpsys deviceidle disable 2>/dev/null || true

# 容器与宿主共享网络, 开机自启面板不依赖外网连通性, 无需等待网络.
# Check if data exists
if [ ! -f "$DATA_DIR/rootfs/app/baihu" ]; then
  log "rootfs not found, skipping autostart"
  log "Run: baihu pull  to download the image"
  exit 0
fi

# Start container
log "Starting Baihu container..."
nohup sh "$MODDIR/bin/baihu" start >> "$LOG_FILE" 2>&1 &
log "Baihu service started"
