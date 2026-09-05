# ============================================================
# Container Management
# ============================================================

# Resolve the ruri runner. The module ships rurima and creates a `ruri` symlink
# to it (argv0 dispatch); prefer the symlink if present.
ruri_bin() {
  if [ -f "$SCRIPT_DIR/ruri" ]; then
    echo "$SCRIPT_DIR/ruri"
  else
    echo "$SCRIPT_DIR/rurima"
  fi
}

# Detect whether network namespaces are usable and emit the ruri flags needed to
# run a container. An optional extra flag (e.g. "N" to skip the persisted
# .rurienv) is appended verbatim so callers can special-case without re-probing.
ruri_flags() {
  local extra="${1:-}"
  if "$(ruri_bin)" -p "$ROOTFS" /bin/true 2>/dev/null; then
    echo "-p -S -A $extra"
  else
    echo "-f $extra"
  fi
}

# Common ruri flags to enter/manage the container: working dir, container PATH
# and HOME. Shared by shell/panel/resetpwd/ssh; callers append extra flags and
# the command. Emitted as an unquoted string so it splices into a command line
# exactly like $(ruri_flags).
ruri_env() {
  printf ' -W /app -e PATH %s -e HOME /root' "$BAIHU_PATH"
}

ruri_run() {
  export ruri_rexec=1

  # -N (--no-rurienv) is mandatory: the persisted .rurienv inside the rootfs
  # holds a drop_caplist that strips CAP_SYS_ADMIN, which silently breaks the
  # -m bind mounts and -e env injection below. Skipping it restores the panel's
  # ability to bind to the configured host:port via BH_CONFIG_PATH.
  local ns_flags ruri_bin_path
  ns_flags=$(ruri_flags "-N")
  ruri_bin_path=$(ruri_bin)

  # Full path from container ENV (BAIHU_PATH defined in the common header).

  "$ruri_bin_path" $ns_flags \
    -W /app \
    -m "$HOME_DIR/data" /app/data \
    -m "$HOME_DIR/configs" /app/configs \
    -m "$HOME_DIR/envs" /app/envs \
    -e "PATH" "$BAIHU_PATH" \
    -e "HOME" "/root" \
    -e "TZ" "${TZ:-Asia/Shanghai}" \
    -e "LANG" "C.UTF-8" \
    -e "LC_ALL" "C.UTF-8" \
    -e "MISE_DATA_DIR" "/app/envs/mise" \
    -e "MISE_CONFIG_DIR" "/app/envs/mise" \
    -e "MISE_TRUSTED_CONFIG_PATHS" "/app/data/scripts" \
    -e "BAIHU_SECRET_KEY" "$(cat "$SECRET_FILE" 2>/dev/null)" \
    -e "BH_CONFIG_PATH" "/app/data/config.ini" \
    -e "BH_SERVER_PORT" "${PANEL_PORT:-18052}" \
    -e "BH_SERVER_HOST" "${PANEL_HOST:-127.0.0.1}" \
    "$ROOTFS" ./docker-entrypoint.sh
}

# The panel reads its own TOML config (BH_CONFIG_PATH -> /app/data/config.ini,
# bind-mounted from $HOME_DIR/data/config.ini). This generates that file from
# the module's PANEL_PORT/PANEL_HOST settings so the panel actually listens on
# the configured address:port instead of its built-in default.
write_panel_config() {
  ensure_panel_config_keys
  mkdir -p "$HOME_DIR/data"
  cat > "$HOME_DIR/data/config.ini" << INIEOF
[server]
port = ${PANEL_PORT:-18052}
host = ${PANEL_HOST:-127.0.0.1}
INIEOF
  chmod 644 "$HOME_DIR/data/config.ini" 2>/dev/null || true
}

# Ensure baihu.conf carries the panel listening keys. Older config files written
# before panel settings existed lack them; append defaults once so the user has a
# place to edit PANEL_PORT/PANEL_HOST (and the panel stops silently falling back
# to its built-in default address).
ensure_panel_config_keys() {
  [ -f "$CONFIG_FILE" ] || return 0
  if ! grep -qE '^PANEL_(PORT|HOST)=' "$CONFIG_FILE" 2>/dev/null; then
    printf '\n# Panel listening settings (change port/host here)\nPANEL_PORT="%s"\nPANEL_HOST="%s"\n' \
      "${PANEL_PORT:-18052}" "${PANEL_HOST:-127.0.0.1}" >> "$CONFIG_FILE"
  fi
  # Older configs predate log retention keys; append defaults so the user has a
  # place to tune them instead of relying on the script's built-in defaults.
  if ! grep -qE '^LOG_(RETENTION_DAYS|MAX_SIZE_MB|MAX_ARCHIVES)=' "$CONFIG_FILE" 2>/dev/null; then
    printf '\n# Log retention (run.log is rotated/pruned on every baihu start)\nLOG_RETENTION_DAYS="%s"\nLOG_MAX_SIZE_MB="%s"\nLOG_MAX_ARCHIVES="%s"\n' \
      "${LOG_RETENTION_DAYS:-3}" "${LOG_MAX_SIZE_MB:-20}" "${LOG_MAX_ARCHIVES:-5}" >> "$CONFIG_FILE"
  fi
}
