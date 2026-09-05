# ============================================================
# Log Maintenance
# ============================================================
# run.log has no built-in rotation and is appended to by both log()/ui_print()
# and the panel's own stdout (ruri_run >> run.log), so it would grow without
# bound. On every `baihu start` (before the panel launches) we:
#   1. rotate run.log into run.log.1 ... run.log.N once it exceeds LOG_MAX_SIZE_MB
#   2. delete run.log* archives older than LOG_RETENTION_DAYS
# Rotation only happens while the panel is not running: once ruri_run holds
# run.log open with `>>`, rotating the name would make the panel keep writing to
# the renamed inode, so the active log must stay put during a session.
run_log_maintenance() {
  [ -d "$DATA_DIR" ] || return 0

  # Prune expired archives first (safe to do at any time; the active run.log is
  # being written so its mtime stays current and -mtime will not match it).
  # Toybox find may lack -delete on older Android, so iterate and rm instead.
  if [ "$LOG_RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
    find "$DATA_DIR" -maxdepth 1 -name 'run.log*' -type f \
      -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null | while read -r f; do
        rm -f "$f" 2>/dev/null || true
      done
  fi

  # Rotate the current log if it exceeds the size cap.
  [ -f "$LOG_FILE" ] || return 0
  [ "$LOG_MAX_SIZE_MB" -gt 0 ] 2>/dev/null || return 0
  local size max_bytes i
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
  [ "$size" -le "$max_bytes" ] && return 0

  # Shift archives .N -> .N+1, then move the current log to .1 and start fresh.
  [ "$LOG_MAX_ARCHIVES" -gt 0 ] 2>/dev/null || LOG_MAX_ARCHIVES=5
  i=$(( LOG_MAX_ARCHIVES - 1 ))
  while [ "$i" -ge 1 ]; do
    if [ -f "$LOG_FILE.$i" ]; then
      mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))" 2>/dev/null || true
    fi
    i=$((i - 1))
  done
  mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  : > "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  log "run.log 超过 ${LOG_MAX_SIZE_MB}MB, 已轮转 (最近 ${LOG_MAX_ARCHIVES} 份)"
}
