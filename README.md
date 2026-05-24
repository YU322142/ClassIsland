# ClassIsland - LoongArch (旧世界) 适配版

![Build Status](https://github.com/YU322142/ClassIsland/actions/workflows/build-loongarch.yml/badge.svg)
![Platform](https://img.shields.io/badge/Platform-LoongArch64%20(Old%20World)-blue)
![.NET](https://img.shields.io/badge/.NET-8.0-purple)

本仓库是 [ClassIsland](https://github.com/ClassIsland/ClassIsland) 的分支版本，专为运行在 **LoongArch 架构（龙芯）的旧世界系统**（如银河麒麟 V10 教育版、Loongnix 等采用 16K 内存页的系统）上深度定制和编译。

## 🎯 解决了什么问题？

原版 ClassIsland 及相关插件在龙芯旧世界电脑上（尤其是通过 LATX 等转译器）运行时会遇到以下致命问题，本分支已将其全部修复：

1. **底层崩溃修复**：彻底放弃 x86 转译，采用原生编译。避开了旧世界 Linux 16KB 内存页导致的 .NET JIT `mprotect` 权限分配崩溃问题。
2. **图形渲染修复**：官方 NuGet 源缺失 LoongArch 的原生 UI 依赖。本分支内建了提取自原生系统的 `libSkiaSharp.so` 和 `libHarfBuzzSharp.so`，彻底解决黑屏/闪退问题。
3. **音频引擎重构**：原版使用的 `MiniAudio` 缺少龙芯原生实现会导致启动崩溃。本分支重写了 `AudioService`，智能调用系统底层的 `ffplay`，完美恢复了 EdgeTTS 语音播报及上下课铃声。
4. **插件完美兼容**：同步深度修改了 [IslandCaller 随机点名插件](https://github.com/YU322142/IslandCaller-linux/tree/loongarch-support)，去除了对 Windows 注册表的依赖（改为 JSON 存储），重写了 Linux X11 协议的悬浮窗置顶逻辑（`_NET_WM_STATE_ABOVE`）及手动拖拽映射，使插件在 Linux 下体验与 Windows 完全一致。

## 📥 安装与运行

本仓库已配置自动化构建，你无需在本地折腾复杂的交叉编译环境。

### 1. 下载发行版
前往本仓库的 **[Actions](https://github.com/YU322142/ClassIsland/actions)** 页面，点击最新一次成功的 Workflow，在底部的 **Artifacts** 处下载 `ClassIsland-LoongArch-OldWorld` 压缩包。

### 2. 准备依赖
本版本使用 `ffmpeg` 作为音频后备播放器，请确保龙芯系统内已安装：
```bash
sudo apt update
sudo apt install ffmpeg
```

### 3. 一键运行
将下载的压缩包传至龙芯电脑，解压后直接执行：
```bash
# 解压文件
tar -xzf ClassIsland-LoongArch.tar.gz -C ~/ClassIsland
cd ~/ClassIsland

# 执行一键启动脚本
bash run.sh
```
*脚本会自动完成运行时关联、依赖注入，并在后台静默启动 ClassIsland，不遗留任何多余的终端窗口。*

如果需要查看运行日志，可以执行：
```bash
tail -f logs/classisland.log
```

## 🛠️ 开发者：关于构建系统

如果你想自己 Fork 此仓库并进行二次开发，本仓库的 `.github/workflows/build-loongarch.yml` 已经为你做好了所有脏活累活。

云端 Action 会自动执行以下步骤，输出一个“零配置”的绿色包：
1. 自动对 `global.json` 等配置降级，以适配可用的 .NET 8 龙芯 SDK。
2. 自动修正子模块（如 EdgeTtsSharp）在跨平台环境下的语法版本冲突。
3. 将仓库内 `LoongArch-NativeLibs/` 下的原生 `.so` 库硬注入编译产物。
4. 将仓库内 `LoongArch-Runtime/` 下的龙芯 .NET 运行时与主程序**合并在同一目录**，彻底消灭 Linux 桌面环境常见的符号链接与相对路径死链问题。

## 📜 鸣谢与协议

- **核心程序**：[ClassIsland](https://github.com/ClassIsland/ClassIsland)
- 本分支代码继承原项目的开源协议，仅供学习、交流与教育场景使用。
```