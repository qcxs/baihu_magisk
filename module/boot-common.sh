#!/system/bin/sh
# boot-common.sh - shared helpers for service.sh / post-fs-data.sh
# Sourced by both boot scripts so the "ensure baihu is in system PATH" logic
# lives in one place instead of being duplicated (and drifting) across files.

# Bind the module's bin/baihu into a location that is on the system PATH.
# Magisk mounts module system/ via magic mount automatically.
# KernelSU 3.0+ requires a metamodule (e.g. meta-overlayfs) for that; if it has
# not mounted, fall back to bind-mounting into a writable system path.
ensure_baihu_path() {
  local moddir="$1"
  [ -n "$moddir" ] || moddir=${0%/*}
  [ -f "$moddir/bin/baihu" ] || return 0

  command -v baihu >/dev/null 2>&1 && return 0

  # Try /system/bin first (Magisk, KernelSU with metamodule — OverlayFS makes
  # /system writable), then /sbin (read-only /system on KernelSU without it).
  if touch /system/bin/baihu 2>/dev/null; then
    mount -o bind "$moddir/bin/baihu" /system/bin/baihu 2>/dev/null || true
    chmod 0755 /system/bin/baihu 2>/dev/null || true
    return 0
  fi
  if [ -d /sbin ] && touch /sbin/baihu 2>/dev/null; then
    mount -o bind "$moddir/bin/baihu" /sbin/baihu 2>/dev/null || true
    chmod 0755 /sbin/baihu 2>/dev/null || true
  fi
}
