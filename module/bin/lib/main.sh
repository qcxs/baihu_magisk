# ============================================================
# Main
# ============================================================

# Sourced by the installer (customize.sh): expose the functions above and let
# the caller handle everything else. Without this guard the usage text below
# is printed in the middle of the install log.
if [ -n "$BAIHU_SOURCED" ]; then
  return 0 2>/dev/null || true
fi

print_help() {
  cat <<'HELP'
用法: baihu <命令> [选项]

命令:
  init       初始化 /data/baihu/ 目录和配置
  pull       拉取白虎镜像并解包 rootfs
  provision  配置面板环境
  start      启动容器
  stop       停止容器
  status     查看运行状态
  update     更新镜像 (stop + pull + provision + start)
  shell      进入容器 shell
  panel      透传官方面板命令 (baihu panel <官方命令> [参数...])
  port       修改面板端口 (baihu port <端口号>)
  clean      删除镜像缓存并重装 (保留用户数据)
  password   查看管理员初始密码
  resetpwd   重置管理员密码 (交互式)
  log        查看日志 (默认50行, -f 持续跟踪)
  version    显示版本信息
HELP
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
  help|-h|--help)
    print_help
    ;;
  init)      cmd_init "$@" ;;
  pull)      cmd_pull "$@" ;;
  provision) cmd_provision "$@" ;;
  start)     cmd_start "$@" ;;
  stop)      cmd_stop "$@" ;;
  status)    cmd_status "$@" ;;
  update)    cmd_update "$@" ;;
  shell)     cmd_shell "$@" ;;
  panel)     cmd_panel "$@" ;;
  port)      cmd_port "$@" ;;
  clean)     cmd_clean "$@" ;;
  password)  cmd_password "$@" ;;
  resetpwd)  cmd_resetpwd "$@" ;;
  log)       cmd_log "$@" ;;
  version)   cmd_version "$@" ;;
  *)
    echo "未知命令: $cmd"
    echo ""
    print_help
    ;;
esac
