# Auto-detect architecture - always override to match device hardware
# Uses getprop ro.product.cpu.abi (reflects actual ABI) with uname -m fallback.
# uname -m can report aarch64 on x86_64 devices through translation layers
# (e.g. Houdini), but glibc-based rootfs binaries won't run in that case.
detect_arch() {
  local arch
  if command -v getprop >/dev/null 2>&1; then
    arch=$(getprop ro.product.cpu.abi 2>/dev/null)
  fi
  if [ -z "$arch" ]; then
    arch=$(uname -m 2>/dev/null)
  fi
  case "$arch" in
    aarch64|arm64|arm64-v8a) echo "arm64" ;;
    x86_64|amd64)            echo "amd64" ;;
    armv7l|armv8l|armeabi-v7a) echo "arm" ;;
    i686|i386|x86)           echo "386" ;;
    *)                       echo "amd64" ;;
  esac
}
BAIHU_ARCH=$(detect_arch)

# ============================================================
# Utility Functions
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

ui_print() {
  echo "$*"
  log "$*"
}

abort() {
  ui_print "! $*"
  exit 1
}

set_perm() {
  local file="$1" mode="$2" owner="$3" group="$4"
  chown "$owner:$group" "$file" 2>/dev/null || true
  chmod "$mode" "$file" 2>/dev/null || true
}

need_bin() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    local fallback="$SCRIPT_DIR/$cmd"
    if [ -f "$fallback" ]; then
      export PATH="$SCRIPT_DIR:$PATH"
    else
      abort "缺少依赖: $cmd"
    fi
  fi
}

# Panel generates the admin password on first boot and prints it to its stdout,
# which cmd_start / service.sh redirect into run.log. Extract it from there.
# Because run.log is rotated/pruned (see run_log_maintenance), the password is
# also persisted to PASSWORD_FILE so it survives rotation. The password is
# always on the 3rd [Init] line (line 3 of grep output).
get_admin_password() {
  if [ -f "$PASSWORD_FILE" ]; then
    local saved
    saved=$(cat "$PASSWORD_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9')
    [ -n "$saved" ] && { echo "$saved"; return 0; }
  fi
  [ -f "$LOG_FILE" ] || return 0
  grep -a '\[Init\]' "$LOG_FILE" 2>/dev/null | tr -d '\033' | head -3 | tail -1 \
    | tr ':' '\n' | tail -1 | tr -cd 'A-Za-z0-9'
}

# Persist the admin password once we've read it, so log rotation/pruning cannot
# lose it. No-op if the panel has not generated one yet.
save_admin_password() {
  local pass
  pass=$(get_admin_password)
  [ -n "$pass" ] || return 0
  printf '%s' "$pass" > "$PASSWORD_FILE" 2>/dev/null || true
  chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
}

# Panel process(es): the real baihu server binary. The wrapper shell that runs
# "baihu start" and the ruri runner are different processes and must not match.
panel_pids() {
  # Distinguish the real panel binary from the control script and the ruri
  # runner. The panel runs as `baihu server` with its resolved executable being
  # the container binary (basename "baihu"); the control script's EXE is a shell
  # (/system/bin/sh) and the container runner is "rurima". Using pidof baihu
  # would falsely match the control script's own process (comm=baihu), so match
  # on the resolved /proc/<pid>/exe instead.
  local p exe name
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
    name=$(basename "$exe" 2>/dev/null)
    [ "$name" = "baihu" ] && echo "$p"
  done
}

# Process age, read from /proc: modified ROMs may ship no usable ps applet.
proc_uptime() {
  local pid="$1" start upt secs d h m
  start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
  upt=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  [ -n "$start" ] && [ -n "$upt" ] || { echo "unknown"; return 0; }
  # starttime is expressed in clock ticks, USER_HZ is 100 on Android
  secs=$(( ${upt%.*} - start / 100 ))
  [ "$secs" -gt 0 ] 2>/dev/null || secs=0
  d=$((secs / 86400)); h=$(((secs % 86400) / 3600)); m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then
    echo "${d}d ${h}h ${m}m"
  else
    echo "${h}h ${m}m"
  fi
}

proc_rss() {
  local pid="$1" kb
  kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
  [ -n "$kb" ] || { echo "unknown"; return 0; }
  awk "BEGIN {printf \"%.1fMB\", $kb / 1024}"
}
