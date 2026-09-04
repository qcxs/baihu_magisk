#!/system/bin/sh
# Baihu Panel - post-fs-data
# Ensures /data/baihu is in a clean state before module mounts
# Also ensures baihu command is available in system PATH

MODDIR=${0%/*}

# Bundled commands first (modified ROMs may lack system tools)
PATH=$MODDIR/bin:$PATH
export PATH

DATA_DIR=/data/baihu

# Check for stale mounts from previous container (exact match)
if grep -q " $DATA_DIR " /proc/mounts 2>/dev/null; then
  umount -l "$DATA_DIR/rootfs" 2>/dev/null || true
  umount -l "$DATA_DIR" 2>/dev/null || true
fi

# === Ensure baihu command is in system PATH ===
# Magisk mounts system/bin/ automatically via magic mount.
# KernelSU 3.0+ requires a metamodule (e.g. meta-overlayfs) for module
# system/ mounting.  If the framework hasn't (or won't) mount it, bind
# mount the baihu script to a writable location in PATH manually.
if [ -f "$MODDIR/bin/baihu" ] && [ ! -f /system/bin/baihu ] && [ ! -f /sbin/baihu ]; then
  # Try /system/bin (Magisk, KernelSU with metamodule)
  if touch /system/bin/baihu 2>/dev/null; then
    mount -o bind "$MODDIR/bin/baihu" /system/bin/baihu 2>/dev/null || true
  else
    # /system is read-only (KernelSU without metamodule).
    # /sbin is typically a writable tmpfs on KernelSU.
    if [ -d /sbin ] && touch /sbin/baihu 2>/dev/null; then
      mount -o bind "$MODDIR/bin/baihu" /sbin/baihu 2>/dev/null || true
    fi
  fi
fi

exit 0