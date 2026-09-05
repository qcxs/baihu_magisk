# ============================================================
# OCI Download Functions
# ============================================================

fetch_token() {
  local url="$1"
  local response
  local resolve_arg
  resolve_arg=$(resolv_args "$url")
  # shellcheck disable=SC2086
  response=$(curl -sS -L $resolve_arg "$url" 2>/dev/null)
  echo "$response" | jq -r '.token // .access_token // empty' 2>/dev/null
}

# Resolve a hostname to an IP using the system resolver (getprop/ping/getent).
# Android has no /etc/resolv.conf, so the bundled musl curl cannot resolve DNS
# on its own; using the OS resolver works identically on every device.
resolve_host() {
  local host="$1"
  local ip=""
  # getent may already return an IP (most reliable on running systems)
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$ip" ]; then
    ip=$(ping -c 1 -W 3 "$host" 2>/dev/null | grep -oE '\([0-9]+(\.[0-9]+){3}\)' | head -1 | tr -d '()')
  fi
  [ -n "$ip" ] && echo "$ip"
}

# Build curl --resolve argument(s) for every host used by a URL, so DNS is
# resolved by the OS (works without /etc/resolv.conf). Output: space-separated
# --resolve host:port:ip pairs, or empty if unresolved.
resolv_args() {
  local url="$1" hostport host port ip out=""
  # strip scheme and path -> "host[:port]"
  hostport=$(printf '%s' "$url" | sed 's#^[a-z]*://##; s#[/?#].*##')
  # port = text after last colon if it's all digits, else 443
  case "$hostport" in
    *:[0-9]*) host="${hostport%:*}"; port="${hostport##*:}";;
    *)        host="$hostport"; port=443;;
  esac
  ip=$(resolve_host "$host")
  if [ -n "$ip" ]; then
    out="--resolve $host:$port:$ip"
  fi
  echo "$out"
}

# curl wrapper with optional bearer token + DNS bypass + skip TLS verification.
# -k: TLS verification is skipped on purpose (see note near MIRROR_NJU); image
# integrity comes from the per-layer sha256 hash check, not the certificate.
# NOTE: never build "-H Authorization: Bearer $token" into an unquoted string:
# shell word-splitting turns "Bearer"/token into extra URLs (curl: Could not
# resolve host: Bearer) and ghcr.io then answers 401.
curl_get() {
  local url="$1" out="$2" auth="$3"
  shift 3
  # resolve host via OS to bypass missing /etc/resolv.conf
  local resolve_arg
  resolve_arg=$(resolv_args "$url")
  if [ -n "$auth" ]; then
    # shellcheck disable=SC2086
    curl -sS -L -k --fail $resolve_arg -o "$out" "$@" -H "Authorization: Bearer $auth" "$url" 2>/dev/null
  else
    # shellcheck disable=SC2086
    curl -sS -L -k --fail $resolve_arg -o "$out" "$@" "$url" 2>/dev/null
  fi
}

pull_manifest() {
  local mirror="$1" token="$2" arch="$3"
  local tmp_dir="$DATA_DIR/.tmp"
  local index_file="$tmp_dir/index.json"
  local arch_file="$tmp_dir/arch.json"

  mkdir -p "$tmp_dir"

  # Fetch index manifest (both Accept headers required: the image is published
  # as an OCI index, a Docker-only Accept gets MANIFEST_UNKNOWN)
  ui_print "  获取镜像索引..."
  local index_url="$mirror/v2/$BAIHU_REPO/manifests/$BAIHU_TAG"
  curl_get "$index_url" "$index_file" "$token" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" || return 1

  # Check if it's an index or direct manifest
  local media_type
  media_type=$(jq -r '.mediaType // empty' "$index_file" 2>/dev/null)

  if echo "$media_type" | grep -qi "index\|list" 2>/dev/null || jq -e '.manifests' "$index_file" >/dev/null 2>&1; then
    # Find the matching arch manifest digest
    local arch_digest
    arch_digest=$(jq -r ".manifests[] | select(.platform.architecture == \"$arch\") | .digest" "$index_file" 2>/dev/null | head -1)
    [ -z "$arch_digest" ] && return 1

    # Fetch the arch-specific manifest
    ui_print "  获取架构清单 ($arch)..."
    curl_get "$mirror/v2/$BAIHU_REPO/manifests/$arch_digest" "$arch_file" "$token" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" || return 1
    cp "$arch_file" "$MANIFEST_FILE"
  else
    cp "$index_file" "$MANIFEST_FILE"
  fi

  # Parse config and layers
  local config_digest
  config_digest=$(jq -r '.config.digest' "$MANIFEST_FILE" 2>/dev/null)
  [ -z "$config_digest" ] && return 1

  # Fetch config blob
  ui_print "  获取配置..."
  curl_get "$mirror/v2/$BAIHU_REPO/blobs/$config_digest" "$CONFIG_BLOB" "$token" || return 1

  # Write layer list
  jq -r '.layers[] | [.digest, .size, .mediaType] | @tsv' "$MANIFEST_FILE" > "$LAYER_LIST" 2>/dev/null
  local layer_count
  layer_count=$(wc -l < "$LAYER_LIST")
  ui_print "  共 $layer_count 层"

  # Save digest for upgrade detection
  local total_digest
  total_digest=$(jq -r '.layers[].digest' "$MANIFEST_FILE" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
  echo "IMAGE_DIGEST=$total_digest" > "$DATA_DIR/.image_digest"

  return 0
}

download_layers() {
  local mirror="$1" token="$2"
  local total=0 success=0 fail=0
  local line_num=0

  mkdir -p "$LAYERS_DIR"

  total=$(wc -l < "$LAYER_LIST")
  ui_print "  开始下载 $total 层..."

  while IFS=$'\t' read -r digest size media_type; do
    line_num=$((line_num + 1))
    local layer_name="layer-$(printf '%03d' $line_num)"
    local layer_file="$LAYERS_DIR/$layer_name"
    local sha_expected="${digest#sha256:}"

    # Check if already downloaded and valid
    if [ -f "$layer_file" ]; then
      local file_size
      file_size=$(stat -c%s "$layer_file" 2>/dev/null || echo 0)
      if [ "$file_size" -eq "$size" ] 2>/dev/null; then
        local file_sha
        file_sha=$(sha256sum "$layer_file" 2>/dev/null | cut -d' ' -f1)
        if [ "$file_sha" = "$sha_expected" ]; then
          ui_print "  [$line_num/$total] $layer_name 已存在, 跳过"
          success=$((success + 1))
          continue
        fi
      fi
    fi

    ui_print "  [$line_num/$total] $layer_name ($(human_size $size))"
    rm -f "$layer_file"

    # Single download attempt: on a network failure the whole pull fails so the
    # user can simply re-run `baihu pull`. No auto-retry loop here -- a broken
    # mirror/connection just wastes time retrying.
    local layer_url="$mirror/v2/$BAIHU_REPO/blobs/$digest"
    curl_get "$layer_url" "$layer_file" "$token"

    local file_sha
    file_sha=$(sha256sum "$layer_file" 2>/dev/null | cut -d' ' -f1)
    if [ "$file_sha" = "$sha_expected" ]; then
      success=$((success + 1))
    else
      fail=$((fail + 1))
      ui_print "  ! $layer_name 下载失败 (网络错误或校验失败), 请重试 baihu pull"
    fi
  done < "$LAYER_LIST"

  ui_print "  下载完成: $success 成功, $fail 失败"
  [ $fail -gt 0 ] && return 1
  return 0
}

human_size() {
  local bytes=$1
  if [ $bytes -ge 1048576 ]; then
    echo "$((bytes / 1048576))MB"
  elif [ $bytes -ge 1024 ]; then
    echo "$((bytes / 1024))KB"
  else
    echo "${bytes}B"
  fi
}
