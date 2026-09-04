#!/system/bin/sh
# Baihu Panel - Uninstall
# Only removes module files, preserves /data/baihu/ user data

# Bundled commands first (modified ROMs may lack system tools)
PATH=${0%/*}/bin:$PATH
export PATH

# Stop container if running: track the panel process itself, the pid file can
# point at the wrapper shell (or be stale) instead.
PIDS=$(pidof baihu 2>/dev/null)
if [ -z "$PIDS" ] && [ -f "/data/baihu/container.pid" ]; then
  PIDS=$(cat /data/baihu/container.pid 2>/dev/null)
fi
for p in $PIDS; do
  kill "$p" 2>/dev/null || true
done
sleep 1
for p in $PIDS; do
  kill -9 "$p" 2>/dev/null || true
done

# Umount rootfs
export ruri_rexec=1
RURI_BIN="${0%/*}/bin/ruri"
[ -f "$RURI_BIN" ] || RURI_BIN="${0%/*}/bin/rurima"
if [ -f "$RURI_BIN" ]; then
  "$RURI_BIN" -U "/data/baihu/rootfs" 2>/dev/null || true
fi

# Remove wake lock
echo "" > /sys/power/wake_lock 2>/dev/null || true

echo ""
echo "=============================="
echo "  白虎面板已卸载"
echo "=============================="
echo ""
echo "  模块文件已删除"
echo "  用户数据保留在: /data/baihu/"
echo "  如需彻底删除数据, 请手动执行:"
echo "    rm -rf /data/baihu"
echo "=============================="