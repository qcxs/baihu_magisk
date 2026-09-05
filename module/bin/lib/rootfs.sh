# ============================================================
# Rootfs Extraction
# ============================================================

# Marker recording which arch+image-digest a rootfs dir was extracted for.
# Stored next to (not inside) the rootfs so it survives rootfs re-creation.
rootfs_meta() {
  echo "$(dirname "${ROOTFS%/}")/.rootfs.meta"
}

# rootfs is immutable after extraction (all writes go to the bind-mounted
# HOME_DIR), so its size is constant. Cache it at extract time instead of
# re-running du -sh (several seconds on a ~1GB tree) on every baihu status.
rootfs_size() {
  local s
  s=$(cat "$ROOTFS_SIZE_FILE" 2>/dev/null | head -1)
  [ -n "$s" ] && { echo "$s"; return 0; }
  du -sh "$ROOTFS" 2>/dev/null | cut -f1
}

extract_rootfs() {
  local meta new_digest
  meta=$(rootfs_meta)
  new_digest=$(cut -d= -f2 "$DATA_DIR/.image_digest" 2>/dev/null)

  # Skip only when files exist AND marker matches current arch + digest
  # (existence alone would keep a stale rootfs of the wrong architecture)
  if [ -f "$ROOTFS/app/baihu" ] && [ -f "$ROOTFS/app/docker-entrypoint.sh" ] \
    && [ -f "$meta" ] \
    && grep -qx "ARCH=$BAIHU_ARCH" "$meta" \
    && grep -qx "DIGEST=$new_digest" "$meta"; then
    local old_size
    old_size=$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)
    printf '%s' "$old_size" > "$ROOTFS_SIZE_FILE" 2>/dev/null || true
    ui_print "    rootfs 已是当前版本 ($old_size), 跳过解包"
    return 0
  fi

  # Stale or incomplete rootfs: clean up for fresh extract
  if [ -d "$ROOTFS" ]; then
    ui_print "    rootfs 缺失或版本不匹配, 清理后重新解包..."
    rm -rf "$ROOTFS" 2>/dev/null || true
  fi

  ui_print "  解包 rootfs..."
  mkdir -p "$ROOTFS"

  local total=0
  total=$(ls "$LAYERS_DIR"/layer-* 2>/dev/null | wc -l)
  if [ "$total" -eq 0 ]; then
    ui_print "    找不到层文件"
    return 1
  fi

  local count=0
  for layer in $(ls "$LAYERS_DIR"/layer-* 2>/dev/null | sort); do
    count=$((count + 1))
    local name
    name=$(basename "$layer")
    ui_print "    [$count/$total] $name"
    # Use gzip -dc | tar -xf to avoid relying on any single binary's gzip support
    if ! gzip -dc "$layer" 2>/dev/null | tar -xpf - -C "$ROOTFS" 2>/dev/null; then
      # Fallback: try tar -zpxf directly
      if ! tar -zpxf "$layer" -C "$ROOTFS" 2>/dev/null; then
        ui_print "    解包失败: $name"
        return 1
      fi
    fi
  done

  # Verify
  if [ -f "$ROOTFS/app/baihu" ] && [ -f "$ROOTFS/app/docker-entrypoint.sh" ]; then
    printf 'ARCH=%s\nDIGEST=%s\n' "$BAIHU_ARCH" "$new_digest" > "$meta" 2>/dev/null || true
    local rootfs_size
    rootfs_size=$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)
    printf '%s' "$rootfs_size" > "$ROOTFS_SIZE_FILE" 2>/dev/null || true
    ui_print "    解包完成, rootfs=$rootfs_size"
  else
    ui_print "    解包失败: 缺少关键文件"
    ls "$ROOTFS/app/" 2>/dev/null | head -20
    return 1
  fi
}
