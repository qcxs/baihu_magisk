#!/system/bin/sh
# Baihu Panel Control Script
# Usage: baihu <command> [options]
# Commands: init, pull, provision, start, stop, status, update,
#           shell, password, resetpwd, ssh, log, version
#
# NOTE: this is a source fragment. The module ships a single merged bin/baihu
# that scripts/build.py produces by concatenating lib/*.sh in manifest.txt order.
# Edit the fragments here, not bin/baihu directly.

# BAIHU_SCRIPT_DIR is set by customize.sh when this file is sourced
SCRIPT_DIR=${BAIHU_SCRIPT_DIR:-${0%/*}}
MODDIR=${SCRIPT_DIR%/bin}

# Prefer bundled commands (busybox applets + static tools) over host system ones:
# modified ROMs may ship stripped or missing toybox binaries.
case ":$PATH:" in
  *":$SCRIPT_DIR:"*) ;;
  *) PATH="$SCRIPT_DIR:$PATH"; export PATH ;;
esac
DATA_DIR=/data/baihu
ROOTFS=$DATA_DIR/rootfs
HOME_DIR=$DATA_DIR/home
LAYERS_DIR=$DATA_DIR/layers
CONFIG_FILE=$DATA_DIR/baihu.conf
SECRET_FILE=$DATA_DIR/secret.key
LOG_FILE=$DATA_DIR/run.log
PASSWORD_FILE=$DATA_DIR/.admin_password
MANIFEST_FILE=$DATA_DIR/manifest.json
CONFIG_BLOB=$DATA_DIR/config.json
LAYER_LIST=$DATA_DIR/layers.txt
ROOTFS_SIZE_FILE=$DATA_DIR/.rootfs.size

# Default mirrors (ordered by priority)
MIRROR_NJU="https://ghcr.nju.edu.cn"
MIRROR_GHCR="https://ghcr.io"

# Android devices have no /etc/ssl/certs/ca-certificates.crt (and no
# /etc/resolv.conf), so the bundled musl curl cannot validate TLS or resolve
# hostnames on its own. TLS verification is intentionally skipped (-k): image
# integrity is guaranteed by the per-layer sha256 hash check in download_layers,
# not by the transport certificate, so we don't need a bundled CA store nor risk
# breakage when a mirror rotates/expires its certificate.

BAIHU_REPO="engigu/baihu"
BAIHU_TAG="latest"
BAIHU_ARCH=""

# Full PATH used inside the container (mise-based toolchain). Shared by launch
# and by shell/panel/ssh/resetpwd so the value can't drift between call sites.
BAIHU_PATH="/app/envs/mise/shims:/app/envs/mise/bin:/opt/mise-base/shims:/opt/mise-base/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Load config
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Panel listening settings. Default: a high port bound to loopback only so the
# panel is not exposed to the LAN/WAN. Override via PANEL_PORT / PANEL_HOST in
# /data/baihu/baihu.conf; both are injected into the container as BH_SERVER_*.
PANEL_PORT=${PANEL_PORT:-18052}
PANEL_HOST=${PANEL_HOST:-127.0.0.1}

# Log retention. run.log grows unbounded while the panel is up (module UI +
# panel stdout both append to it), and there is no built-in rotation, so it can
# fill the data partition over time. On every `baihu start` we rotate run.log
# once it exceeds LOG_MAX_SIZE_MB and delete archives older than
# LOG_RETENTION_DAYS. All three are configurable in baihu.conf.
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-3}
LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB:-20}
LOG_MAX_ARCHIVES=${LOG_MAX_ARCHIVES:-5}
