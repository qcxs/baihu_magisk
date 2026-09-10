# 开发经验与约定

本文档沉淀本项目开发过程中的关键决策、踩坑与约定, 供后续维护者快速上手, 避免重复踩坑。

## 构建: baihu 是合并产物, 别直接改它

- `bin/baihu` 是 `module/bin/lib/*.sh` 片段经 `scripts/build.py` 拼接而成的**构建产物**。
- **改代码一律改 `lib/` 下的片段**, 然后运行 `python scripts/build.py --module-only` 重新合并。
- 合并顺序由 `bin/lib/manifest.txt` 显式声明, **不按文件名推断**。这样在中间插入新片段时无需重命名已有文件。
- 新增独立功能时: 新建 `lib/<name>.sh`, 在 `manifest.txt` 对应位置登记一行, 并在 `main.sh` 的 `case` 里注册命令、更新帮助文本。

## CRLF 坑 (Windows 必碰)

`build.py` 在 Windows 上 `open()` 默认会把 `\n` 写成 `\r\n`, 而 toybox sh / bash 解析带 `\r` 的脚本会报:

```
syntax error near unexpected token $'\r'
```

所以 `combine_baihu()` 读写都用 `open(..., newline='')` 保持 LF。**新增读写文件的代码务必保留 `newline=''`。**

## `.rurienv` 与 `-N` (容器启动)

rootfs 内持久化的 `.rurienv` 可能带 `drop_caplist`, 会剥离 `CAP_SYS_ADMIN`, 导致 `-m` 绑定挂载和 `-e` 环境注入**静默失效**。

- `cmd_start` / `cmd_shell` / `cmd_panel` / `cmd_resetpwd` 统一追加 `-N` (跳过 `.rurienv`), 才能让面板绑定到配置的 `host:port`。
- 判断 `-p -S -A` 或 `-f` 的逻辑统一放在 `container.sh` 的 `ruri_flags()`, 别在各自命令里复制。

## 面板进程识别 (别用 pidof baihu)

`pidof baihu` 会把控制脚本自身进程误判为面板 (它的 `comm=baihu`, 真实 exe 是 `/system/bin/sh`)。

正确做法: 遍历 `/proc/<pid>/exe`, 取 basename 等于 `baihu`。见 `common.sh` 的 `panel_pids()`。

## 命令设计: 分层, 不重复造轮子

- **应用层 = 官方面板二进制** (`/app/baihu`), 业务逻辑都在容器内。
- **宿主层 = 模块脚本**, 只做容器管理 (生命周期/拉取/挂载/端口/PID/日志/密码)。
- 对官方已有命令 (task/reposync/restore/resetpwd 等) 用 `baihu panel <cmd>` **透传**, 避免重复实现导致与上游漂移。
- 模块自己新增的是宿主侧管理命令: `port` (改端口), `clean` (删镜像缓存), `password` (读密码)。

## 面板端口 / 日志可配置

- `PANEL_PORT` / `PANEL_HOST` 会在启动前经 `write_panel_config()` 写入 `/data/baihu/data/config.ini`, 再以 `BH_SERVER_*` 注入容器, 否则面板会用内置默认地址。
- `LOG_RETENTION_DAYS` / `LOG_MAX_SIZE_MB` / `LOG_MAX_ARCHIVES` 控制 `run.log` 轮转与清理 (见 `log.sh` 的 `run_log_maintenance()`)。

## 其他约定

- `main.sh` 顶部 `BAIHU_SOURCED` 守卫: 被 `customize.sh` source 时跳过入口, 只复用函数。改入口逻辑时别破坏该守卫。
- `customize.sh` 会在安装时 source `bin/baihu` 复用函数, 因此新增函数要能被独立 source。
- 日志统一走 `log()` / `ui_print()`; 密码从 `run.log` 提取后持久化到 `.admin_password`, 避免日志轮转丢失。
- 面板 PID 的 `comm=baihu` 与 `/app/baihu` 二进制同名的坑, 也适用于任何"按名字找进程"的逻辑。

## 构建与发布

前置: Python 3.8+ / Node.js 20+ (前端构建需要)。

| 命令 | 作用 |
|------|------|
| `python scripts/build.py` | 完整构建: 前端 → 同步 `module/webroot/` → 合并 baihu → 打包在线版 zip |
| `python scripts/build.py --version v1.2.3` | 先写入 `module.prop` 的 version/versionCode, 再完整构建 |
| `python scripts/build.py --module-only` | 只合并 `lib/` 片段 + 打包 zip (跳过前端, 改脚本时用这个) |
| `python scripts/build.py --webui-only` | 只构建前端并同步到 `module/webroot/` |
| `python scripts/build.py --push` | 构建后 adb push zip 到 `/data/local/tmp/` |
| `python scripts/build.py --install` | 构建 + push + 通过 ksud 安装到设备 |
| `python scripts/build.py --push-webui` | 重建前端并直接推送 webroot 到已安装模块 (无需重启) |
| `python scripts/build.py --offline-bundle` | 构建内置版: 下载 arm64 OCI 层 → 打包为 `dist/baihu_qcxs_offline.zip` |
| `python scripts/build.py --offline-bundle --offline-mirror https://ghcr.nju.edu.cn` | 指定镜像源下载离线层 (不指定则默认 ghcr.io) |
| `python scripts/build.py --module-only --offline-bundle` | 跳过前端构建, 只打包内置版 (CI 中用, 复用在线版 webroot) |

产物说明:

| 文件 | 说明 |
|------|------|
| `dist/baihu_qcxs.zip` | 在线安装版, 不含镜像层 (~5-8 MB), 安装时需联网 |
| `dist/baihu_qcxs_offline.zip` | 内置镜像版, 含 arm64 OCI 全部层 (~200+ MB), 安装无需联网 |

### manifest 校验行为

`combine_baihu()` 在合并前会做三项检查, 便于尽早暴露清单与文件不一致:

| 情况 | 结果 |
|------|------|
| 条目不是裸文件名 (含路径) | ERROR 退出 |
| 清单引用了不存在的片段 | ERROR 退出 |
| 磁盘有 `.sh` 但未登记进清单 | WARNING (该片段**不会**被合并) |

### 改完脚本的自检

```bash
python scripts/build.py --module-only
bash -n module/bin/baihu          # 语法检查, 同时可暴露 CRLF 问题
```

### 发布

仓库配置了工作流 [package.yml](../.github/workflows/package.yml): Actions → **Package & Release** → Run workflow。

- **输入版本号 (如 `v1.2.3`)**: 创建/更新 tag 并发布 GitHub Release, 同时附带在线版 + 内置版两个 zip。
- **留空**: 仅打包并上传为 Artifact (两个 zip), 不发布。

> 重复发布同版本号会自动覆盖已有 tag 和 Release (通过 `git tag -f` + `--force push` + `update: true`)。这在构建部分失败时可直接重跑, 无需递增版本号。

#### 离线内置版

在线构建完成后, CI 会额外执行 `python scripts/build.py --module-only --offline-bundle` 从 ghcr.io 下载 arm64 侧的 OCI 层并打包为 `baihu_qcxs_offline.zip`。该步使用了 `continue-on-error: true`, 因网络问题下载失败不会阻断在线版发布。

内置版 zip 内的 `module/offline/` 目录包含:
- `manifest.json` / `config.json` — OCI 镜像元数据
- `layers.txt` — 层列表
- `.image_digest` — 镜像摘要标记
- `bundle.info` — 来源信息 (仓库、tag、架构、下载源、打包时的模块版本号)
- `layers/layer-001 ... layer-NNN` — 各层 gzip 压缩包

安装时 `customize.sh` 检测到该目录后跳过网络下载, 直接从模块目录复制层文件 → `extract_rootfs` 解包 → `bundle.info` 写入 `/data/baihu/.bundle.info` → 部署完成后删除 `$MODPATH/offline/` 释放模块分区空间。

本地构建可使用镜像源加速:
```bash
# 国内用户指定 NJU 镜像
python scripts/build.py --offline-bundle --offline-mirror https://ghcr.nju.edu.cn

# CI 中不指定则默认 ghcr.io
python scripts/build.py --offline-bundle
```
