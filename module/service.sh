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

# === Ensure baihu command is in system PATH ===
# Magisk mounts the module's system/bin/ automatically via magic mount.
# KernelSU 3.0+ requires a metamodule (e.g. meta-overlayfs) for system/
# mounting.  If that hasn't happened, bind mount manually.
if ! command -v baihu >/dev/null 2>&1; then
  if [ -f "$MODDIR/bin/baihu" ]; then
    log "baihu not in PATH, attempting bind mount..."
    # Try /system/bin (Magisk, KernelSU with metamodule — OverlayFS
    # makes /system writable).
    if touch /system/bin/baihu 2>/dev/null; then
      mount -o bind "$MODDIR/bin/baihu" /system/bin/baihu 2>/dev/null && \
        log "bind mount /system/bin/baihu OK" || \
        log "bind mount /system/bin/baihu failed"
      chmod 0755 /system/bin/baihu 2>/dev/null || true
    else
      # /system is read-only (KernelSU without metamodule).
      # /sbin is typically a writable tmpfs on KernelSU.
      log "/system is read-only, trying /sbin..."
      if touch /sbin/baihu 2>/dev/null; then
        mount -o bind "$MODDIR/bin/baihu" /sbin/baihu 2>/dev/null && \
          log "bind mount /sbin/baihu OK" || \
          log "bind mount /sbin/baihu failed"
        chmod 0755 /sbin/baihu 2>/dev/null || true
      else
        log "cannot bind mount baihu to any system path"
      fi
    fi
  fi
fi

# Prevent suspend
echo "noSuspend" > /sys/power/wake_lock 2>/dev/null || true
dumpsys deviceidle disable 2>/dev/null || true

# Wait for network
log "Waiting for network..."
for i in $(seq 1 15); do
  if curl -sS --max-time 2 http://connect.rom.miui.com/generate_204 >/dev/null 2>&1; then
    log "Network ready"
    break
  fi
  sleep 5
done

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