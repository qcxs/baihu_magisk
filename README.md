# 白虎面板 Magisk 模块

在 Android 设备上通过 Magisk/KernelSU/APatch 运行 [白虎面板](https://github.com/engigu/baihu-panel)。

## 环境要求

- **设备**: ARM64 或 amd64 架构, 2GB+ 内存推荐
- **存储**: 需要 1.5GB+ 可用空间
- **管理器**: Magisk v24+ / KernelSU / APatch (KernelSU 需安装 hybrid_mount 元模块)

## 安装方法

1. 下载模块 zip 包 (从 [Releases](../../releases) 或自行构建)
2. 打开管理器 -> 模块 -> 从本地安装
3. 选择 zip 包, 等待安装完成 (会自动下载白虎镜像并解包, 首次约 2-5 分钟)
4. 安装完成后即可启动面板

## 管理命令

安装后可在终端 (需 root) 直接使用 `baihu` 命令:

```
# 生命周期
baihu start                启动面板
baihu stop                 停止面板
baihu status               查看运行状态
baihu update               更新镜像并重启面板

# 镜像与数据
baihu init                 初始化 /data/baihu/ 目录和配置
baihu pull                 拉取镜像并解包 rootfs
baihu provision            配置面板环境
baihu clean                删除镜像缓存 (释放空间, 保留用户数据)

# 面板访问
baihu shell                进入容器 shell
baihu panel <命令>         透传官方面板命令 (如 baihu panel version)
baihu password             查看管理员初始密码
baihu resetpwd             重置管理员密码 (交互式)
baihu ssh                  安装并启动 SSH 服务 (端口 8022)
baihu log [-f]             查看日志 (默认 50 行, -f 持续跟踪)

# 配置与信息
baihu port <端口号>        修改面板监听端口 (运行中会自动重启生效)
baihu version              显示版本信息
baihu help                 显示帮助 (未知命令也会显示)
```

面板默认监听 `127.0.0.1:18052`。首次启动约需 1 分钟生成管理员密码, 之后用 `baihu password` 查看。
更高级的配置 (镜像源、日志保留天数等) 在 `/data/baihu/baihu.conf`。

## 自行构建

> 需要 Python 3.8+ 和 Node.js 20+。

```bash
python scripts/build.py          # 构建前端 + 打包, 产物在 dist/baihu_qcxs.zip
python scripts/build.py --install  # 构建并通过 ksud 安装到已连接的设备
```

完整构建参数、发布流程见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 项目结构

```
├── webui/          # Vue 3 + Vite 前端源码
├── module/         # 模块文件 (打包进 zip)
│   └── bin/lib/    # baihu 脚本源码片段 (按 manifest.txt 顺序合并为 bin/baihu)
├── scripts/        # 构建脚本
├── docs/           # 开发者文档
├── dist/           # 构建产物 (zip 包, 不入库)
└── .github/
    └── workflows/  # GitHub Actions 工作流
```

## 开发者文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 内部原理: 模块布局、生命周期、OCI 拉取、ruri 容器、兼容性
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — 开发约定与经验: 脚本拆分与合并、构建发布、已知坑位

---

**致敬**: 感谢酷安望月古川的启发与分享
