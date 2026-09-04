# 白虎面板 Magisk 模块

在 Android 设备上通过 Magisk/KernelSU/APatch 运行 [白虎面板](https://github.com/engigu/baihu-panel)。

## 环境要求

- **设备**: ARM64 或 amd64 架构, 2GB+ 内存推荐
- **存储**: 需要 1.5GB+ 可用空间
- **管理器**: Magisk v24+ / KernelSU / APatch (KernelSU 需安装 hybrid_mount 元模块)

## 安装方法

1. 下载模块 zip 包 (从 [Releases](../../releases) 或自行构建)
2. 打开管理器 -> 模块 -> 从本地安装
3. 选择 zip 包, 等待安装完成
4. 模块会自动下载最新白虎镜像并解压
5. 安装完成后即可启动面板

## 构建

```bash
# 完整构建 (Vue 前端 + 模块打包)
python scripts/build.py

# 构建并推送到设备
python scripts/build.py --push

# 构建、推送并安装到设备
python scripts/build.py --install

# 仅更新 WebUI (无需重启设备)
python scripts/build.py --push-webui
```

## 项目结构

```
├── webui/          # Vue 3 + Vite 前端源码
├── module/         # 模块文件 (打包进 zip)
├── scripts/        # 构建脚本
│   └── build.py    # 一键构建
├── dist/           # 构建产物 (zip 包)
└── .gitignore
```

## 管理命令

```
baihu start     启动面板
baihu stop      停止面板
baihu status    查看状态
baihu update    更新镜像
baihu shell     进入容器
baihu password  查看密码
baihu log       查看日志
```