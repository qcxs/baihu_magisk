# 架构说明

本文档详细介绍白虎面板 Magisk 模块的内部工作原理, 面向希望理解、修改或扩展本模块的开发者。

## 整体架构

```
+------------------+       +------------------+       +------------------+
|  Magisk 管理器   |       |  终端 (ADB)      |       |  Web 浏览器      |
|  (模块 WebUI)    |       |  (baihu 命令)    |       |  (端口 18052)     |
+--------+---------+       +--------+---------+       +--------+---------+
         |                          |                          |
         |  exec() 桥接             |  su -c                    |  HTTP
         v                          v                          v
+------------------------------------------------------------------+
|                     Android 宿主机                                |
|  +------------------------------------------------------------+  |
|  |  Magisk 模块: /data/adb/modules/baihu_qcxs/                |  |
|  |  - bin/baihu       (主控脚本, 由 lib/ 片段合并生成)         |  |
|  |  - bin/rurima      (容器运行时, 静态编译)                   |  |
|  |  - bin/curl, jq, tar 等 (静态工具集)                       |  |
|  |  - webroot/index.html      (WebUI 面板)                    |  |
|  |  - system/bin/baihu        (PATH 包装脚本)                 |  |
|  +------------------------------------------------------------+  |
|  +------------------------------------------------------------+  |
|  |  ruri 容器: /data/baihu/rootfs                             |  |
|  |  - Debian 12 根文件系统 (~1GB)                              |  |
|  |  - /app/baihu          (白虎面板 Go 二进制)                 |  |
|  |  - /app/docker-entrypoint.sh  (容器启动脚本)                |  |
|  |  - /app/envs/mise/     (Mise 版本管理器)                    |  |
|  |  - /app/example/       (默认脚本模板)                       |  |
|  +------------------------------------------------------------+  |
|  +------------------------------------------------------------+  |
|  |  持久化数据: /data/baihu/                                   |  |
|  |  - home/data/         (用户脚本、面板数据)                  |  |
|  |  - home/configs/      (面板配置)                            |  |
|  |  - home/envs/         (Mise 管理的运行时)                   |  |
|  |  - layers/            (OCI 层缓存)                          |  |
|  |  - secret.key         (JWT 签名密钥, 600 权限)              |  |
|  |  - baihu.conf         (镜像源、架构、时区配置)              |  |
|  |  - run.log            (运行日志, root 只读)                 |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

## 源码目录结构 (重构后)

```
项目根目录/
  webui/                  # Vue 3 + Vite 前端源码
    src/
      App.vue             # 主布局 + 状态管理 + 轮询
      main.js             # 入口
      kernelsu.js         # ksu bridge 封装 (callback API)
      components/         # EnvCard / ContainerCard / PasswordCard / ControlCard / LogCard
    index.html
    package.json
    vite.config.js        # base: '' 使路径相对, 适配各处 WebView
  module/                 # 模块源文件 (打包进 zip)
    META-INF/             # 安装器
    bin/                  # baihu 主控脚本 + amd64/arm64 二进制
    bin/lib/              # baihu 的源码片段 (8 个 .sh), 开发时改这里
      manifest.txt        # 合并顺序清单 (build.py 按此顺序拼接成 bin/baihu)
      head.sh common.sh log.sh oci.sh rootfs.sh container.sh commands.sh main.sh
    system/               # system/bin/baihu PATH 包装脚本
    webroot/              # 构建时从 webui/dist/ 自动生成
    customize.sh / module.prop / post-fs-data.sh / service.sh / system.prop / uninstall.sh
  scripts/
    build.py              # 一键构建脚本 (按 manifest.txt 合并 baihu + 打包 zip)
  docs/                   # 开发者文档 (架构、开发经验)
  dist/                   # 构建产物 (baihu_qcxs.zip)
```

### baihu 源码组织 (lib/ 片段 + manifest.txt)

开发时 `baihu` 不直接写单文件, 而是拆成 `module/bin/lib/` 下的一组片段, 按功能划分:

| 片段 | 职责 |
|------|------|
| `head.sh` | shebang、变量、PATH 注入、默认配置 |
| `common.sh` | 架构探测、工具函数 (log/ui_print/abort/密码提取/PID 探测) |
| `log.sh` | run.log 轮转与按天清理 |
| `oci.sh` | OCI 镜像拉取 (token/manifest/layer/校验) |
| `rootfs.sh` | rootfs 解包与大小缓存 |
| `container.sh` | ruri 相关公共函数 (`ruri_bin`/`ruri_flags`/`ruri_env`) + 面板 TOML 生成 |
| `commands.sh` | 各 `cmd_*` 子命令实现 |
| `main.sh` | 入口分发 `case`、帮助文本、`BAIHU_SOURCED` 守卫 |

`build.py` 的 `combine_baihu()` 按 `manifest.txt` 声明的顺序拼接片段, 也按相同顺序生成 `bin/baihu`。顺序必须在 `manifest.txt` 中显式声明, **不按文件名推断**, 这样在中间插入新片段时无需重命名。

`main.sh` 顶部有 `BAIHU_SOURCED` 守卫: 被 `customize.sh` source 时跳过入口, 只复用函数。

### 构建产物结构 (安装到设备后)

```
/data/adb/modules/baihu_qcxs/
  META-INF/com/google/android/update-binary   # 模块安装器
  bin/
    baihu                 # 主控脚本 (POSIX sh, 由 lib/ 片段按 manifest.txt 合并)
    rurima  + bin/ruri    # ruri 容器运行时
    curl / jq             # 静态工具集
    amd64/  arm64/        # 架构特定二进制源
  system/bin/baihu        # PATH 包装脚本
  webroot/                # 打包进 zip 的构建产物 (index.html + assets/)
  customize.sh            # 安装脚本
  module.prop             # 模块元信息
  post-fs-data.sh         # 开机挂载守卫
  service.sh              # 开机自启服务
  uninstall.sh            # 卸载脚本 (保留数据)
  system.prop             # 系统属性覆盖
```

## 生命周期

### 安装流程

1. Magisk 将 zip 解压到临时目录
2. 执行 `customize.sh`:
   - 引用 `bin/baihu` 复用其函数
   - 设置 `bin/` 目录权限 (chmod 0755 + chown 0:2000)
   - 创建 `/data/baihu/` 目录结构
   - 如不存在则生成 `secret.key` 和 `baihu.conf`
   - 检测安装模式 (首次安装/升级)
   - **在线版**: 调用 `cmd_pull()` 下载 OCI 镜像 (需联网)
   - **内置版**: `customize.sh` 检测到 `$MODPATH/offline/` 中有预置层 → 直接复制 → `extract_rootfs` (无需联网)
   - 调用 `cmd_provision()` 配置环境
   - **内置版清理**: 部署成功后删除 `$MODPATH/offline/` (释放模块分区空间)
3. 安装成功后, Magisk 将临时目录移到 `/data/adb/modules/baihu_qcxs/`

### 开机流程

1. `post-fs-data.sh` (早期启动):
   - 检查是否存在残留容器挂载
   - 如已挂载则卸载 `/data/baihu/rootfs`

2. `service.sh` (后期启动):
   - 确保 `baihu` 在 PATH 中: magic mount 未生效时 (如 KernelSU 无元模块), 手动 bind mount 到 `/system/bin/baihu`, 只读则回退 `/sbin/baihu`
   - 阻止设备休眠 (wake_lock + dumpsys deviceidle)
   - 检查 rootfs 是否存在 (不存在则跳过自启, 提示 `baihu pull`)
   - 通过 nohup 启动 `baihu start`, 输出重定向到 run.log
   - **不等待网络**: 容器与宿主共享网络, 面板应用自行处理重试

### 容器启动 (`cmd_start`)

1. 设置环境变量
2. 日志轮转: 调用 `run_log_maintenance()` 先清理旧日志 (面板未运行时 fd 可用)
3. 生成面板 TOML: 调用 `write_panel_config()` 把 `PANEL_PORT`/`PANEL_HOST` 写入 `/data/baihu/data/config.ini`
4. 启动 ruri 容器:
   - 标志: `$(ruri_flags)` → 命名空间可用时 `-p -S -A`, 否则回退 `-f`; 统一追加 `-N` 跳过 `.rurienv`
   - 工作目录: `-W /app`
   - 绑定挂载: `home/data -> /app/data`, `home/configs -> /app/configs`, `home/envs -> /app/envs`
   - 环境变量: PATH, HOME, TZ, LANG, MISE_*, BAIHU_SECRET_KEY, BH_CONFIG_PATH, BH_SERVER_PORT, BH_SERVER_HOST
   - 启动命令: `./docker-entrypoint.sh`
5. 输出重定向到 run.log (自动生成的密码会出现在这里)
6. 等待 5s 后按 `/proc/<pid>/exe` basename 匹配面板 PID, 显示容器 PID 和管理员密码

> 说明: **不等待外网连通**。容器与宿主共享网络, 面板应用自行处理网络重试, 外网失败不影响本地面板服务。

### 关键坑位: `.rurienv` 与 `-N`

rootfs 内持久化的 `.rurienv` 可能含 `drop_caplist`, 会剥离 `CAP_SYS_ADMIN`, 从而静默破坏 `-m` 绑定挂载和 `-e` 环境注入。因此 `cmd_start` / `cmd_shell` / `cmd_panel` / `cmd_resetpwd` 统一带 `-N` (跳过 `.rurienv`), 恢复面板绑定到配置 `host:port` 的能力。

### 面板进程识别 (PID 匹配)

不能直接用 `pidof baihu`——它会把控制脚本自身的进程 (`comm=baihu`, 实际 exe 是 `/system/bin/sh`) 误判为面板。正确做法是遍历 `/proc/<pid>/exe`, 取 basename 等于 `baihu` (面板 Go 二进制的可执行文件名)。见 `common.sh` 的 `panel_pids()`。

### 日志轮转 (`run_log_maintenance`)

`run.log` 无内置轮转, 会无限增长; 面板 stdout 与 `log()` 都在追加。每次 `baihu start` 前执行:
1. 删除超过 `LOG_RETENTION_DAYS` 天的 `run.log*` 归档
2. 当前日志超过 `LOG_MAX_SIZE_MB` 时轮转为 `run.log.1`…`run.log.N` (最多 `LOG_MAX_ARCHIVES` 份)

三项均可通过 `/data/baihu/baihu.conf` 配置。轮转只在面板未运行时发生 (面板持有打开的 fd, 改名会导致它写入改名后的 inode)。

### 容器入口点 (docker-entrypoint.sh)

Debian 根文件系统内的入口脚本执行以下操作:
1. 设置语言环境 (C.UTF-8)
2. 创建 /app 子目录 (data, scripts, configs, envs)
3. 复制示例脚本和 mise 基础环境 (rsync --ignore-existing)
4. 设置 PATH 包含 mise shims 和 bin
5. 配置 NODE_OPTIONS (max-old-space-size=256MB)
6. 设置 PYTHONPATH
7. 将 baihu 补全安装到 bashrc
8. **exec 执行** `baihu server` (替换 PID 1, 确保信号正确处理)

## OCI 镜像下载 (`cmd_pull`)

下载过程手动实现 OCI 分发规范:

```
1. fetch_token()      -> GET /v2/token?scope=repository:engigu/baihu:pull
2. pull_manifest()    -> GET /v2/engigu/baihu/manifests/latest (索引 manifest)
3. 解析 manifest      -> 按 BAIHU_ARCH 选择平台特定 manifest
4. 获取 config blob   -> 解析 config, 写出 layers.txt (digest/size/mediaType)
5. download_layers()  -> GET /v2/engigu/baihu/blobs/sha256:<digest>, 逐层校验 sha256
6. extract_rootfs()   -> 按 layer-001..N 顺序流式解包到 rootfs
```

> **离线内置版**: 当使用 `baihu_qcxs_offline.zip` 安装时, OCI 层已预置在 `module/offline/layers/` 下, `customize.sh` 跳过以上步骤 1-5, 直接执行 `extract_rootfs`。详见 [DEVELOPMENT.md 离线内置版](../docs/DEVELOPMENT.md#离线内置版)。

### 镜像源回退与重试

```
MIRROR_1 (ghcr.nju.edu.cn) -> MIRROR_2 (ghcr.io)
```

- 每个 URL **单次**请求, 不做退避重试: 失败即判定该源不可用, 切换到下一个源; 全部失败则整体失败, 由用户重跑 `baihu pull`。
- 已下载且 size + sha256 均匹配的层会跳过, 因此重跑可断点续传。
- 镜像完整性靠**逐层 sha256 校验**保证, 因此 curl 用 `-k` 跳过 TLS 验证 (Android 无系统 CA), 同时用 `--resolve` (getent/ping 走系统解析器) 绕过缺失的 `/etc/resolv.conf`。

### rootfs 解包与增量跳过

`extract_rootfs()` 逐层执行 `gzip -dc layer | tar -xpf - -C $ROOTFS`, 失败时回退 `tar -zpxf`。

为避免每次重复解包 (~1GB), 解包成功后在 rootfs **同级**写入 `.rootfs.meta` 记录 `ARCH=` / `DIGEST=`:

- 只有「关键文件存在 **且** meta 的架构与镜像 digest 都匹配当前值」才跳过解包;
- 仅有文件不足以判定新鲜, 否则可能保留一个错误架构的旧 rootfs。

rootfs 解包后不可变 (写入都落在 bind mount 的 home 目录), 因此大小被缓存进 `.rootfs.size`, `baihu status` 不再每次跑 `du -sh`。

## ruri 容器运行时

### 什么是 ruri?

ruri (通过 rurima 二进制) 是一个轻量级 Linux 容器运行时。与 Docker 不同:
- 单一静态二进制, 无需守护进程
- 使用 Linux namespace 进行隔离
- 支持绑定挂载、环境变量、能力管理
- 专为 Android 环境设计

### 标志说明

| 标志 | 含义 | 白虎面板使用 |
|------|------|-------------|
| `-p` | 特权模式 | 是 |
| `-S` | 宿主机运行时 (挂载 /dev, /sys, /proc) | 是 |
| `-A` | 取消屏蔽 /proc 和 /sys 中的目录 | 是 |
| `-W` | 设置工作目录 | 是 (`/app`) |
| `-e` | 设置环境变量 | 是 |
| `-m` | 绑定挂载宿主机路径到容器路径 | 是 |
| `-f` | fork 模式 (无 namespace 支持时的回退) | 条件使用 |
| `-N` | 跳过 .rurienv (允许并发实例) | SSH 使用 |
| `-U` | 卸载容器 | 清理时使用 |

### 架构说明: ruri 与 rurima

`rurima` 是一个包装器, 提供 OCI 仓库客户端功能 (pull, unpack)。它也内嵌了 `ruri` 运行时。当通过符号链接调用为 `ruri` 时, 直接分发到内嵌的 ruri 运行时。

## 环境兼容性

### Magisk v27+

- 支持 WebUI (通过 `webroot/index.html`)
- 提供 `window.ksu` 桥接 (与 KernelSU 相同 API)
- `exec()` 以 root 权限运行命令

### Magisk v24-v26

- 不支持 WebUI (无 ksu 桥接)
- 所有操作通过终端完成

### KernelSU

- 完整 WebUI 支持 (通过 `window.ksu`)
- **bridge API**: `ksu.exec(cmd, optionsJSON, callbackName)` — callback 挂载在 `window[callbackName]`, 以 `callback(errno, stdout, stderr)` 被调用。**不是** Promise 或 `exec(cmd, callback)`。
- **需要元模块**: KernelSU 3.x 中模块的 `system/` 目录需安装 metamodule (如 Hybrid Mount) 才会挂载。
- Webroot 由管理器读取模块目录的 `webroot/` 展开, 前端使用相对路径 (`base: ''`)。

### APatch

- WebUI 通过 `window.apatch` (映射到 ksu 桥接)
- 与 KernelSU 相同 API

## 密码机制

白虎面板没有固定默认密码。首次执行 `baihu server` 时:

1. 二进制程序生成 12 位随机字母数字密码
2. 输出到 stdout: `[Init] 密  码: <password>`
3. stdout 被重定向到 `/data/baihu/run.log`
4. `get_admin_password()` 优先读 `/data/baihu/.admin_password`, 否则从 run.log 提取 (第 3 条 [Init] 行)
5. `save_admin_password()` 把密码持久化到 `.admin_password` (600), 使其不受日志轮转/清理影响

`baihu password` 命令读取上述来源。`baihu resetpwd` 命令在容器内执行 `baihu resetpwd admin` (交互式)。

## 扩展模块

### 添加新命令

1. 在 `module/bin/lib/commands.sh` 中添加函数 (不要直接改 `bin/baihu`, 它是构建产物):
   ```sh
   cmd_mycommand() {
     # 实现代码
   }
   ```
2. 在 `module/bin/lib/main.sh` 的 `case` 分支中注册:
   ```sh
   mycommand)  cmd_mycommand "$@" ;;
   ```
3. 更新 `main.sh` 的帮助文本
4. 重新构建: `python scripts/build.py --module-only`

> 新增独立功能片段时, 新建 `lib/<name>.sh` 并在 `manifest.txt` 对应位置登记一行即可, 无需改动已有文件名。

### 更换镜像

编辑 `/data/baihu/baihu.conf`:

```ini
BAIHU_REPO="your-registry/your-image"
BAIHU_TAG="your-tag"
BAIHU_ARCH="arm64"
```

然后执行 `baihu update`。

### 添加内置二进制

将静态编译的二进制放入 `bin/`, 并在 `customize.sh` 中设置权限:

```sh
chmod 0755 $MODPATH/bin/your-binary
```

### 构建自定义 rootfs

模块从 OCI 仓库拉取镜像。要使用自定义 rootfs:

1. 构建包含所需内容的 Docker 镜像
2. 推送到任意 OCI 兼容仓库
3. 在 baihu.conf 中设置 `BAIHU_REPO`
4. 执行 `baihu pull`

### 自定义 WebUI

前端源码在 `webui/` (Vue 3 + Vite)。修改后运行:

```bash
python scripts/build.py --webui-only   # 重建前端 + 同步到 module/webroot/
python scripts/build.py --push-webui   # 重建并直接推送到设备 (无需重启)
```

前端通过封装在 `webui/src/kernelsu.js` 的 `execCmd()` 调用 root 命令, 正确 signature 为
`ksu.exec(cmd, '{}', callbackName)`。API 参考见 [KernelSU WebUI 文档](https://kernelsu.org/guide/module-webui.html)。

## 已知限制

| 限制 | 原因 | 影响 |
|------|------|------|
| ~1GB 磁盘占用 | Debian 12 根文件系统 + Mise + Python + Node | 需要 1.5GB 可用空间 |
| 首次启动慢 | OCI 下载 + rootfs 解包 | 首次安装约 2-5 分钟 |
| 阻止休眠 | wake_lock 保持设备唤醒 | 运行时增加耗电 |
| 无 PID 隔离 | ruri -p -S -A 共享宿主机 PID 命名空间 | `ps` 可见容器进程 |
| 无网络隔离 | 同上 | 容器共享宿主机网络 |
| 密码明文存储 | stdout 被捕获到 run.log, 并持久化到 .admin_password | 两处均 chmod 600 缓解 |
| 下载无自动重试 | 单次请求即判定源失败 | 网络抖动需重跑 `baihu pull` (可续传) |
| `set_perm_recursive` 可能失效 | Magisk R 版本缺陷 | customize.sh 中 chmod -R 回退 |

## 安全说明

- `secret.key` (JWT 签名密钥) 以 `chmod 600` 存储
- `run.log` (含明文密码) 与 `.admin_password` 均以 `chmod 600` 存储
- WebUI exec() 以 root 运行, 但仅授权管理器 App 可访问
- 容器以特权模式运行 (-p), 未附加 seccomp 策略
- 卸载模块不会删除用户数据 (有意设计)

---

**致敬**: 感谢酷安望月古川的启发与分享