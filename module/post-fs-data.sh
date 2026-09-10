#!/system/bin/sh
# Baihu Panel - post-fs-data
# Runs early (right after /data is mounted), cleans stale container mounts and
# ensures the baihu command is on the system PATH.

MODDIR=${0%/*}

# Bundled commands first (modified ROMs may lack system tools)
export PATH=$MODDIR/bin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

DATA_DIR=/data/baihu

# Unmount any stale container mounts left from a previous session (exact match).
if grep -q " $DATA_DIR " /proc/mounts 2>/dev/null; then
  umount -l "$DATA_DIR/rootfs" 2>/dev/null || true
  umount -l "$DATA_DIR" 2>/dev/null || true
fi

# Ensure baihu is on the system PATH (shared helper: magic mount on Magisk,
# bind mount fallback on KernelSU).
. "$MODDIR/boot-common.sh"
ensure_baihu_path "$MODDIR"

exit 0
