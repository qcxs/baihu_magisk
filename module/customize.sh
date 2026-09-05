# Bundled binaries take priority: the host system may be a modified ROM
# with missing or stripped toybox commands.
export PATH=$MODPATH/bin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

# Source baihu functions (BAIHU_SOURCED makes the script define functions
# only and skip its own argument handling / usage output)
BAIHU_SCRIPT="$MODPATH/bin/baihu"
if [ -f "$BAIHU_SCRIPT" ]; then
  BAIHU_SCRIPT_DIR="$MODPATH/bin"
  BAIHU_SOURCED=1
  . "$BAIHU_SCRIPT"
  unset BAIHU_SOURCED
fi

# Override ui_print for Magisk context (no log file during install)
ui_print() {
  echo "$1"
}

set_perm_recursive $MODPATH/bin 0 2000 0755 0755
# Force permissions (Magisk set_perm_recursive may not work on some versions)
chmod -R 0755 $MODPATH/bin 2>/dev/null || true
chown -R 0:2000 $MODPATH/bin 2>/dev/null || true

# === Architecture-aware binary selection ===
# Module bundles both arm64 and amd64 binaries; select the correct set.
ARCH_DIR="$MODPATH/bin/$(detect_arch)"
if [ ! -d "$ARCH_DIR" ]; then
  abort "不支持的架构: $(detect_arch), 仅支持 arm64/amd64"
fi
ui_print "- 检测到架构: $(detect_arch)"

# Copy architecture-specific binaries to bin/ root, overwriting any mismatched ones
for f in "$ARCH_DIR"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  # Skip if same file (already correct arch)
  [ "$f" -ef "$MODPATH/bin/$name" ] 2>/dev/null && continue
  cp -f "$f" "$MODPATH/bin/$name" 2>/dev/null || true
done

# rurima must exist in bin/ root now (copied above). Create the ruri ->
# rurima symlink for argv0 dispatch, then resolve the runner. Doing this
# after the copy avoids a dangling symlink, which would make ruri_bin()
# fall back to argv0=rurima and print the usage tutorial on every -U call.
ln -sf rurima "$MODPATH/bin/ruri" 2>/dev/null || true
RURI_BIN="$(ruri_bin)"

# Verify key binaries are executable
for bin in rurima curl jq; do
  if [ ! -x "$MODPATH/bin/$bin" ]; then
    abort "关键二进制缺失: $bin"
  fi
done

# Quick arch verification: check that rurima runs
if ! "$MODPATH/bin/rurima" --version >/dev/null 2>&1; then
  abort "二进制架构校验失败: rurima 无法执行"
fi

# === Provide busybox applets as standalone commands ===
# Link every needed applet into bin/ so no command relies on the host system.
BB="$MODPATH/bin/busybox"
if [ ! -x "$BB" ]; then
  abort "缺少内置 busybox"
fi
BB_APPLETS="tar gzip gunzip unzip xz unxz cat grep sed awk cut tr head tail wc sort uniq
  basename dirname date df du find mkdir rmdir rm cp mv ln chmod chown touch stat readlink
  sleep kill pidof pkill mount umount seq nohup setsid ip printf sha256sum md5sum free"
ui_print "- 链接 busybox applet..."
BB_LIST=$("$BB" --list 2>/dev/null | tr '\n' ' ')
for applet in $BB_APPLETS; do
  case " $BB_LIST " in *" $applet "*) ;; *) continue ;; esac
  link="$MODPATH/bin/$applet"
  if [ -e "$link" ] || [ -L "$link" ]; then continue; fi
  ln -sf busybox "$link" 2>/dev/null || true
done

DATA_DIR=/data/baihu

ui_print ""
ui_print "=============================="
ui_print " 白虎面板 Baihu Panel"
ui_print "=============================="
ui_print ""

# === Environment checks ===

# Check running instance using pidof (more reliable than container.pid)
PANEL_PID=$(pidof baihu 2>/dev/null)
if [ -z "$PANEL_PID" ]; then
  # Fallback: check container.pid
  if [ -f "$DATA_DIR/container.pid" ]; then
    PANEL_PID=$(cat "$DATA_DIR/container.pid" 2>/dev/null)
    kill -0 "$PANEL_PID" 2>/dev/null || PANEL_PID=""
  fi
fi
if [ -n "$PANEL_PID" ]; then
  ui_print "- 白虎面板正在运行 (PID: $PANEL_PID), 正在停止..."
  cmd_stop
  # Verify stopped
  sleep 1
  PANEL_PID=$(pidof baihu 2>/dev/null)
  if [ -n "$PANEL_PID" ]; then
    abort "无法停止白虎面板 (PID: $PANEL_PID), 请手动执行: baihu stop"
  fi
  ui_print "- 面板已停止, 继续安装"
fi

# Mount guard: check for stale mounts (exact match on /data/baihu)
if grep -q " $DATA_DIR " /proc/mounts 2>/dev/null; then
  ui_print "! $DATA_DIR 存在挂载残留, 尝试清理..."
  umount -l "$DATA_DIR" 2>/dev/null
  sleep 1
  if grep -q " $DATA_DIR " /proc/mounts 2>/dev/null; then
    abort "无法卸载 $DATA_DIR, 请重启设备后重试"
  fi
fi

# Check disk space (need 1.5GB for rootfs + layers + temp)
DATA_PART=$(df "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$DATA_PART" ] && [ "$DATA_PART" -lt 1500000 ] 2>/dev/null; then
  abort "磁盘空间不足, 需要至少 1.5GB 可用空间"
fi

# Check critical bundled commands (all self-contained, no system dependency)
for tool in busybox tar gzip sha256sum stat curl jq rurima; do
  if [ ! -x "$MODPATH/bin/$tool" ]; then
    abort "缺少内置命令: $tool"
  fi
done

# Detect install mode
IS_UPDATE=0
if [ -f "$DATA_DIR/baihu.conf" ]; then
  IS_UPDATE=1
  ui_print "- 检测到已有安装, 用户数据将保留在 $DATA_DIR/home"
else
  ui_print "- 检测到首次安装, 执行完整安装"
fi

# Initialize data directories
ui_print "- 初始化数据目录..."
mkdir -p "$DATA_DIR" "$DATA_DIR/home/data" "$DATA_DIR/home/configs" "$DATA_DIR/home/envs" \
  "$DATA_DIR/layers" "$DATA_DIR/.tmp"

if [ ! -f "$DATA_DIR/secret.key" ]; then
  SECRET=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom 2>/dev/null | head -c 32)
  echo -n "$SECRET" > "$DATA_DIR/secret.key"
  chmod 600 "$DATA_DIR/secret.key"
  ui_print "- 已生成密钥"
fi

if [ ! -f "$DATA_DIR/baihu.conf" ]; then
  cat > "$DATA_DIR/baihu.conf" << CONFEOF
# Baihu Panel Configuration
MIRROR_1="https://ghcr.nju.edu.cn"
MIRROR_2="https://ghcr.io"
BAIHU_REPO="engigu/baihu"
BAIHU_TAG="latest"
BAIHU_ARCH="$BAIHU_ARCH"
TZ="Asia/Shanghai"
CONFEOF
  chmod 644 "$DATA_DIR/baihu.conf"
  ui_print "- 检测到架构: $BAIHU_ARCH"
else
  # Fix architecture in existing config if wrong
  current_arch=$(grep '^BAIHU_ARCH=' "$DATA_DIR/baihu.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [ "$current_arch" != "$BAIHU_ARCH" ]; then
    ui_print "  ! 架构从 $current_arch 修正为 $BAIHU_ARCH"
    sed -i "s/^BAIHU_ARCH=.*/BAIHU_ARCH=\"$BAIHU_ARCH\"/" "$DATA_DIR/baihu.conf"
  fi
fi

# === Pull image to temp directory (kept across installs for hash-based skip) ===
TMP_INSTALL="$DATA_DIR/.tmp/install"

# Clean up stale mounts from previous failed installs
export ruri_rexec=1
"$RURI_BIN" -U "$TMP_INSTALL/rootfs" 2>/dev/null || true
rm -rf "$TMP_INSTALL/rootfs" 2>/dev/null || true
# Final rootfs may also carry stale ruri mounts (blocks redeploy/cleanup below)
"$RURI_BIN" -U "$DATA_DIR/rootfs" 2>/dev/null || true

mkdir -p "$TMP_INSTALL/layers"

# Override paths to use temp directory during download
LAYERS_DIR="$TMP_INSTALL/layers"
ROOTFS="$TMP_INSTALL/rootfs"

ui_print "- 检测网络..."
# 5s timeout via ping, more reliable than curl on early-boot devices
if ! ping -c 1 -W 5 www.baidu.com >/dev/null 2>&1; then
  abort "网络不可用, 请确认设备已联网后重新刷入"
fi

ui_print "- 检查镜像更新..."
ui_print ""

# Always fetch manifest and check layers; download_layers skips files with matching hash
cmd_pull || abort "镜像拉取失败, 安装未完成"

# Verify rootfs integrity (extract_rootfs skips if already complete)
ui_print "- 校验文件完整性..."
if [ ! -f "$ROOTFS/app/baihu" ] || [ ! -f "$ROOTFS/app/docker-entrypoint.sh" ]; then
  abort "rootfs 校验失败: 缺少关键文件"
fi

# Verify rootfs with dynamic linker (more reliable than ruri -p on some devices)
ui_print "- 校验 rootfs..."
ld_path=$(find "$ROOTFS" -name 'ld-linux-*' -type f 2>/dev/null | head -1)
if [ -n "$ld_path" ]; then
  lib_paths="$ROOTFS/lib/aarch64-linux-gnu:$ROOTFS/usr/lib/aarch64-linux-gnu"
  if [ "$BAIHU_ARCH" = "amd64" ]; then
    lib_paths="$ROOTFS/lib/x86_64-linux-gnu:$ROOTFS/usr/lib/x86_64-linux-gnu"
  fi
  if ! "$ld_path" --library-path "$lib_paths" "$ROOTFS/bin/true" 2>/dev/null; then
    ui_print "  ! 动态链接器校验跳过 (非致命)"
  fi
fi

# Clean up ruri mounts from previous verification (if any)
export ruri_rexec=1
"$RURI_BIN" -U "$ROOTFS" 2>/dev/null || true
sleep 1

# Deploy to final locations. Existence alone is not enough: after an
# architecture change (e.g. arm64 -> amd64) the old rootfs must be replaced,
# so compare the arch+digest markers written by extract_rootfs.
TMP_META="$TMP_INSTALL/.rootfs.meta"
DATA_META="$DATA_DIR/.rootfs.meta"
need_deploy=1
if [ -f "$DATA_DIR/rootfs/app/baihu" ] && [ -f "$TMP_META" ] \
  && cmp -s "$TMP_META" "$DATA_META"; then
  need_deploy=0
  ui_print "- rootfs 已是当前版本, 跳过部署"
fi
if [ $need_deploy -eq 1 ]; then
  ui_print "- 部署 rootfs..."
  "$RURI_BIN" -U "$DATA_DIR/rootfs" 2>/dev/null || true
  rm -rf "$DATA_DIR/rootfs" 2>/dev/null || true
  cp -r "$TMP_INSTALL/rootfs" "$DATA_DIR/rootfs" || abort "部署 rootfs 失败"
  cp "$TMP_META" "$DATA_META" 2>/dev/null || true
  # Layers of a different arch/digest reuse the same layer-NNN names: drop
  # the stale cache so the sync below copies the current set
  rm -rf "$DATA_DIR/layers" 2>/dev/null || true
fi

# Sync layers cache (copy missing files)
mkdir -p "$DATA_DIR/layers"
for f in "$TMP_INSTALL/layers"/layer-*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  if [ ! -f "$DATA_DIR/layers/$name" ]; then
    cp "$f" "$DATA_DIR/layers/" 2>/dev/null
  fi
done

# Restore paths for subsequent operations
LAYERS_DIR="$DATA_DIR/layers"
ROOTFS="$DATA_DIR/rootfs"

# Keep temp layers for next install's hash check; clean up temp rootfs (already deployed)
rm -rf "$TMP_INSTALL/rootfs"

# === Provision ===
ui_print ""
ui_print "- 配置面板环境..."
cmd_provision

# Clean up residual .rurienv mounts in temp (if any)
export ruri_rexec=1
"$RURI_BIN" -U "$DATA_DIR/.tmp/install/rootfs" 2>/dev/null || true

ui_print ""
ui_print "=============================="
ui_print "  安装完成"
ui_print "=============================="
ui_print ""
ui_print "  面板地址: http://${PANEL_HOST:-127.0.0.1}:${PANEL_PORT:-18052}"
ui_print "  初始密码: 首次启动后自动生成, 见模块页面或 baihu password"
ui_print ""
ui_print "  更多管理命令请运行: baihu help"
ui_print "  数据目录: $DATA_DIR"
ui_print "  (卸载模块不会删除数据目录)"
ui_print "=============================="

# Final cleanup: umount rootfs if mounted
export ruri_rexec=1
"$RURI_BIN" -U "$DATA_DIR/rootfs" 2>/dev/null || true