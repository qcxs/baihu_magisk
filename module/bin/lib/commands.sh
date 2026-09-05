# ============================================================
# Commands
# ============================================================

cmd_init() {
  ui_print "初始化 /data/baihu/ 目录..."
  mkdir -p "$DATA_DIR" "$HOME_DIR/data" "$HOME_DIR/configs" "$HOME_DIR/envs" \
    "$LAYERS_DIR" "$DATA_DIR/.tmp"

  # Generate secret key if not exists
  if [ ! -f "$SECRET_FILE" ]; then
    local secret
    secret=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom 2>/dev/null | head -c 32)
    echo -n "$secret" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ui_print "  已生成密钥: $secret"
  fi

  # Write default config. BAIHU_ARCH is already detected in the common header,
  # so reuse it instead of re-running detect_arch here.
  cat > "$CONFIG_FILE" << CONFEOF
# Baihu Panel Configuration
# This file is sourced by the baihu control script

# Mirror configuration
# MIRROR_ORDER: space-separated list of mirror names, tried in order.
# For each name, define MIRROR_<name>_URL and MIRROR_<name>_AUTH.
# AUTH values: "none" (no token needed), "ghcr" (get token from ghcr.io)
MIRROR_ORDER="nju official milu"

MIRROR_nju_URL="https://ghcr.nju.edu.cn"
MIRROR_nju_AUTH="none"

MIRROR_official_URL="https://ghcr.io"
MIRROR_official_AUTH="ghcr"

MIRROR_milu_URL="https://ghcr.milu.moe"
MIRROR_milu_AUTH="ghcr"

# Repository
BAIHU_REPO="engigu/baihu"
BAIHU_TAG="latest"
BAIHU_ARCH="$BAIHU_ARCH"

# Container settings
TZ="Asia/Shanghai"

# Panel listening settings (change port/host here)
PANEL_PORT="18052"
PANEL_HOST="127.0.0.1"

# Log retention (run.log is rotated/pruned on every baihu start)
LOG_RETENTION_DAYS="3"
LOG_MAX_SIZE_MB="20"
LOG_MAX_ARCHIVES="5"
CONFEOF

  set_perm "$CONFIG_FILE" 644 0 0
  ui_print "  配置文件: $CONFIG_FILE"
  ui_print "初始化完成"
}

# Resolve a mirror's URL and auth type by name.
# Usage: mirror_resolve <name> <var_prefix>
# Sets <var_prefix>_URL and <var_prefix>_AUTH in the caller's scope.
mirror_resolve() {
  local name="$1" prefix="$2"
  eval "${prefix}_URL=\"\$MIRROR_${name}_URL\""
  eval "${prefix}_AUTH=\"\$MIRROR_${name}_AUTH\""
}

# Get ghcr.io bearer token, cached so we only fetch once per pull.
ghcr_token() {
  local token_url="https://ghcr.io/token?scope=repository:$BAIHU_REPO:pull&service=ghcr.io"
  if [ -z "$_GHCR_TOKEN" ]; then
    _GHCR_TOKEN=$(fetch_token "$token_url")
  fi
  echo "$_GHCR_TOKEN"
}

cmd_pull() {
  need_bin curl
  need_bin jq

  ui_print "拉取白虎镜像..."
  ui_print "  仓库: $BAIHU_REPO:$BAIHU_TAG"
  ui_print "  架构: $BAIHU_ARCH"

  # Build mirror list: ordered by MIRROR_ORDER, each with URL + auth type.
  # If MIRROR env is set, use it as a single URL (overrides everything).
  local mirror_names=""
  if [ -n "$MIRROR" ]; then
    # Single URL override — wrap it as a nameless entry
    mirror_names="__override"
    MIRROR___override_URL="$MIRROR"
    MIRROR___override_AUTH="ghcr"
  else
    mirror_names="$MIRROR_ORDER"
  fi

  # A source is only accepted when BOTH its manifest and its layers download.
  # Manifest + layers are pulled per source, so switching sources re-pulls the
  # manifest too: a mirror may cache a different digest for the same tag, and
  # reusing the previous source's layer list would make every sha256 check fail.
  local token=""
  local ok=0
  for name in $mirror_names; do
    local url="" auth=""
    mirror_resolve "$name" "M"
    url="$M_URL"
    auth="$M_AUTH"

    [ -z "$url" ] && continue

    ui_print "  尝试源: $name ($url)"

    # Get token if auth type requires it (ghcr_token caches, so we fetch once)
    if [ "$auth" = "ghcr" ] && [ -z "$token" ]; then
      ui_print "    获取认证token..."
      token=$(ghcr_token)
      if [ -n "$token" ]; then
        ui_print "    认证成功"
      else
        ui_print "    认证失败, 尝试匿名访问"
      fi
    fi

    # Fetch manifest and layers for this source
    if pull_manifest "$url" "$token" "$BAIHU_ARCH"; then
      if download_layers "$url" "$token"; then
        ok=1
        break
      fi
      ui_print "  源层下载失败, 切换下一个..."
    else
      ui_print "  源不可用, 切换下一个..."
    fi
  done

  [ $ok -eq 0 ] && abort "所有镜像源均不可用, 请检查网络"

  # Extract rootfs
  extract_rootfs

  ui_print "拉取完成"
}

cmd_provision() {
  ui_print "配置白虎面板..."

  # Ensure home directories have data
  local src_data="$ROOTFS/app/data"
  local src_envs="$ROOTFS/app/envs"
  local src_configs="$ROOTFS/app/configs"

  # Copy example data if home dirs are empty
  if [ -d "$src_data" ] && [ -z "$(ls -A "$HOME_DIR/data" 2>/dev/null)" ]; then
    cp -r "$src_data"/* "$HOME_DIR/data/" 2>/dev/null || true
  fi
  if [ -d "$src_envs" ] && [ -z "$(ls -A "$HOME_DIR/envs" 2>/dev/null)" ]; then
    cp -r "$src_envs"/* "$HOME_DIR/envs/" 2>/dev/null || true
  fi
  if [ -d "$src_configs" ] && [ -z "$(ls -A "$HOME_DIR/configs" 2>/dev/null)" ]; then
    cp -r "$src_configs"/* "$HOME_DIR/configs/" 2>/dev/null || true
  fi

  # Write resolv.conf
  echo "nameserver 223.5.5.5" > "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
  echo "nameserver 114.114.114.114" >> "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

  set_perm "$ROOTFS/etc/resolv.conf" 644 0 0

  ui_print "配置完成"
}

cmd_start() {
  need_bin rurima

  # Check if already running
  local pid
  pid=$(panel_pids)
  if [ -n "$pid" ]; then
    ui_print "白虎面板已在运行 (PID: $pid)"
    return 0
  fi

  # Check prerequisites
  if [ ! -f "$ROOTFS/app/baihu" ] || [ ! -f "$ROOTFS/app/docker-entrypoint.sh" ]; then
    abort "rootfs 不完整, 请先执行 baihu pull"
  fi
  if [ ! -f "$SECRET_FILE" ]; then
    abort "缺少密钥, 请先执行 baihu init"
  fi

  ui_print "启动白虎面板容器..."

  # Rotate/prune run.log first (panel is not running yet, so the fd is free).
  # Keeps the log from filling the data partition over time.
  run_log_maintenance

  # run.log holds the auto-generated admin password: keep it root-only
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  # 容器与宿主共享网络, 启动面板不依赖外网连通性, 无需预探测网络.
  # 面板应用自行处理网络重试, 外网功能失败不影响本地面板服务.

  # Generate the panel TOML config from PANEL_PORT/PANEL_HOST before launch,
  # so the panel binds to the configured address instead of its built-in default.
  write_panel_config

  # Start container; capture panel stdout so the generated password lands in run.log
  ruri_run >>"$LOG_FILE" 2>&1 &
  local job=$!

  # Wait for startup, then look up the panel process itself: $job is only the
  # wrapper shell, and rurima execs into the container init under a new PID.
  sleep 5
  local pid
  pid=$(panel_pids)
  if [ -z "$pid" ] && kill -0 $job 2>/dev/null; then
    sleep 5
    pid=$(panel_pids)
  fi

  if [ -n "$pid" ]; then
    echo "$pid" > "$DATA_DIR/container.pid"
    ui_print "容器已启动 (PID: $pid)"
    ui_print "面板地址: http://${PANEL_HOST:-127.0.0.1}:${PANEL_PORT:-18052}"
    local pass
    pass=$(get_admin_password)
    save_admin_password
    if [ -n "$pass" ]; then
      ui_print "管理员账号: admin"
      ui_print "初始密码:   $pass"
    else
      ui_print "首次启动约需 1 分钟, 之后执行 baihu password 查看初始密码"
    fi
  else
    abort "容器启动失败, 查看日志: baihu log"
  fi
}

cmd_stop() {
  need_bin rurima
  ui_print "停止白虎面板..."

  # Kill container process (pidof may list more than one PID)
  local pid
  pid=$(panel_pids)
  if [ -z "$pid" ] && [ -f "$DATA_DIR/container.pid" ]; then
    pid=$(cat "$DATA_DIR/container.pid" 2>/dev/null)
  fi
  if [ -n "$pid" ]; then
    kill $pid 2>/dev/null
    sleep 2
    kill -9 $pid 2>/dev/null
    ui_print "  已停止进程 (PID: $pid)"
  fi

  # Umount rootfs
  export ruri_rexec=1
  "$(ruri_bin)" -U "$ROOTFS" 2>/dev/null || true

  rm -f "$DATA_DIR/container.pid"
  ui_print "已停止"
}

cmd_status() {
  local pid
  pid=$(panel_pids)

  echo "白虎面板状态"
  echo "===================="
  if [ -n "$pid" ]; then
    local first=${pid%% *}
    echo "  运行状态: 运行中 (PID: $pid)"
    echo "  运行时间: $(proc_uptime "$first")"
    echo "  内存占用: $(proc_rss "$first")"
  else
    echo "  运行状态: 已停止"
  fi
  echo "  rootfs: $(rootfs_size)"
  echo "  数据目录: $(du -sh "$HOME_DIR" 2>/dev/null | cut -f1)"
  echo "  配置文件: $CONFIG_FILE"
  echo "  日志文件: $LOG_FILE"
  echo "  面板地址: http://${PANEL_HOST:-127.0.0.1}:${PANEL_PORT:-18052}"

  # Check port (ss preferred, fallback to netstat)
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT:-18052}" && echo "  端口 ${PANEL_PORT:-18052}: 监听中"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep -q ":${PANEL_PORT:-18052}" && echo "  端口 ${PANEL_PORT:-18052}: 监听中"
  fi
  echo "===================="
}

cmd_update() {
  ui_print "更新白虎镜像..."

  # Save current digest
  local old_digest=""
  [ -f "$DATA_DIR/.image_digest" ] && old_digest=$(cat "$DATA_DIR/.image_digest")

  # Stop container
  cmd_stop

  # Re-pull
  cmd_pull

  # Check if digest changed
  local new_digest=""
  [ -f "$DATA_DIR/.image_digest" ] && new_digest=$(cat "$DATA_DIR/.image_digest")

  if [ "$old_digest" = "$new_digest" ] && [ -n "$old_digest" ]; then
    ui_print "镜像无变化, 跳过更新"
  else
    ui_print "镜像已更新"
    # Re-provision (keeps home data)
    cmd_provision
  fi

  # Restart
  cmd_start
}

cmd_shell() {
  if [ ! -d "$ROOTFS" ]; then
    abort "rootfs 不存在"
  fi
  export ruri_rexec=1
  local ns_flags
  ns_flags=$(ruri_flags)
  exec "$(ruri_bin)" $ns_flags $(ruri_env) \
    -e "LANG" "C.UTF-8" \
    -e "LC_ALL" "C.UTF-8" \
    -e "MISE_DATA_DIR" "/app/envs/mise" \
    -e "MISE_CONFIG_DIR" "/app/envs/mise" \
    -e "TERM" "xterm-256color" \
    "$ROOTFS" /bin/bash -l "$@"
}

# Passthrough for official panel commands: baihu panel <cmd> [args...].
# The panel binary (/app/baihu) already owns the business logic (task, reposync,
# restore, builtininstall, depinstall, completion, version, resetpwd ...).
# Reimplementing them here would duplicate and diverge from upstream, so forward
# the remaining args straight into the container. exec keeps stdio attached so
# --help output and interactive commands behave exactly as on a normal host.
cmd_panel() {
  if [ ! -d "$ROOTFS" ]; then
    abort "rootfs 不存在, 请先执行 baihu pull"
  fi
  if [ $# -eq 0 ]; then
    echo "用法: baihu panel <官方命令> [参数...]"
    echo "官方命令: server task reposync resetpwd restore builtininstall depinstall version completion"
    echo "示例: baihu panel version | baihu panel task --help"
    return 1
  fi

  export ruri_rexec=1
  local ns_flags
  ns_flags=$(ruri_flags)

  exec "$(ruri_bin)" $ns_flags $(ruri_env) \
    -e "LANG" "C.UTF-8" \
    -e "LC_ALL" "C.UTF-8" \
    "$ROOTFS" /app/baihu "$@"
}

# Change the panel listening port. Updates PANEL_PORT in baihu.conf, regenerates
# the panel TOML, and restarts the container so the new port binds immediately.
cmd_port() {
  local new_port="$1"
  if [ -z "$new_port" ]; then
    echo "用法: baihu port <端口号>"
    echo "示例: baihu port 18053"
    return 1
  fi
  case "$new_port" in
    *[!0-9]*|"")
      echo "! 端口必须是数字 (1-65535)"
      return 1
      ;;
  esac
  if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo "! 端口必须在 1-65535 之间"
    return 1
  fi

  echo "原端口: ${PANEL_PORT:-18052}"
  if [ -f "$CONFIG_FILE" ]; then
    if grep -q '^PANEL_PORT=' "$CONFIG_FILE" 2>/dev/null; then
      sed "s|^PANEL_PORT=.*|PANEL_PORT=\"$new_port\"|" "$CONFIG_FILE" \
        > "$CONFIG_FILE.tmp" 2>/dev/null && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" \
        || { echo "! 写入配置失败"; return 1; }
    else
      echo "PANEL_PORT=\"$new_port\"" >> "$CONFIG_FILE"
    fi
  else
    echo "PANEL_PORT=\"$new_port\"" > "$CONFIG_FILE"
  fi

  # Reload config to pick up the new value, then regenerate the panel TOML.
  . "$CONFIG_FILE" 2>/dev/null || true
  PANEL_PORT="$new_port"
  write_panel_config
  echo "端口已修改为: ${PANEL_PORT} (host: ${PANEL_HOST:-127.0.0.1})"

  # Apply immediately if the panel is running, otherwise on next start.
  local pid
  pid=$(panel_pids)
  if [ -n "$pid" ]; then
    echo "面板运行中, 正在重启以生效..."
    cmd_stop
    cmd_start
  else
    echo "面板未运行, 下次 baihu start 时生效"
  fi
}

# Delete the image cache (rootfs + layers + metadata) to free space and force
# a fresh download next time. User data under HOME_DIR, the config and the
# secret key are preserved.
cmd_clean() {
  local force=0
  case "$1" in
    -y|--yes) force=1 ;;
  esac

  local before
  before=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)

  echo "即将删除白虎镜像缓存 (rootfs 约 700MB + layers) 以清理空间。"
  echo "  删除: rootfs / layers / 镜像元数据"
  echo "  保留: 用户数据 (home, 配置, 密钥)"
  echo "  下次需重新下载镜像 (baihu pull 或重装模块)"
  if [ "$force" -eq 0 ]; then
    printf "确认清理? 输入 yes 继续: "
    local ans
    read ans || ans=""
    [ "$ans" = "yes" ] || [ "$ans" = "y" ] || { echo "已取消"; return 0; }
  fi

  # Stop container first so nothing holds the rootfs/layers open.
  local pid
  pid=$(panel_pids)
  if [ -n "$pid" ]; then
    ui_print "正在停止面板..."
    cmd_stop
  fi

  # Purge image cache; keep $HOME_DIR, $CONFIG_FILE and $SECRET_FILE.
  rm -rf "$ROOTFS" "$LAYERS_DIR" 2>/dev/null || true
  rm -f "$DATA_DIR/.image_digest" "$DATA_DIR/.rootfs.meta" \
        "$MANIFEST_FILE" "$CONFIG_BLOB" "$LAYER_LIST" 2>/dev/null || true

  local after
  after=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
  ui_print "清理完成 (数据目录: $before -> $after)"
  ui_print "下次请执行 baihu pull 或重新安装模块以下载镜像"
}

cmd_log() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "日志文件不存在"
    return 1
  fi
  if [ "$1" = "-f" ] || [ "$1" = "--follow" ]; then
    shift
    tail -f "$LOG_FILE" 2>/dev/null || true
  else
    tail -n "${1:-50}" "$LOG_FILE" 2>/dev/null
  fi
}

cmd_version() {
  echo "白虎面板 Magisk 模块"
  echo "  版本: $(grep 'version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 || echo 'unknown')"
  echo "  模块路径: $MODDIR"
  echo "  数据路径: $DATA_DIR"
  # rurima --version opens with a banner whose first line is empty; the real
  # value lives on the "rurima version ............: 0.9.2" line.
  local ruri_ver
  ruri_ver=$("$(ruri_bin)" --version 2>/dev/null | awk -F: '/version/ {gsub(/[ \t]/, "", $NF); print $NF; exit}')
  [ -n "$ruri_ver" ] || ruri_ver="unknown"
  echo "  ruri: $ruri_ver"
}

cmd_password() {
  local pass
  pass=$(get_admin_password)
  if [ -n "$pass" ]; then
    echo "管理员账号: admin"
    echo "密    码: $pass"
  else
    echo "密码尚未生成, 请先启动面板 (baihu start)"
    echo "首次启动约需 1 分钟生成密码"
  fi
}

cmd_resetpwd() {
  if [ ! -d "$ROOTFS" ]; then
    abort "rootfs 不存在"
  fi
  export ruri_rexec=1
  local ns_flags
  ns_flags=$(ruri_flags)
  echo "正在进入密码重置界面..."
  echo "用户名: admin"
  echo "------------------------"
  exec "$(ruri_bin)" $ns_flags $(ruri_env) \
    "$ROOTFS" /app/baihu resetpwd admin
}


