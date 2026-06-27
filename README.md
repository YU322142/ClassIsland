# ClassIsland - LoongArch old-world ABI1.0

![Build Status](https://github.com/YU322142/ClassIsland/actions/workflows/build-loongarch.yml/badge.svg)
![Platform](https://img.shields.io/badge/Platform-LoongArch64%20old--world-blue)
![.NET](https://img.shields.io/badge/.NET-8.0-purple)

本仓库是 [ClassIsland](https://github.com/ClassIsland/ClassIsland) 的龙芯旧世界适配 fork，面向银河麒麟 V10、Loongnix 等 LoongArch old-world ABI1.0 X11 桌面环境。这个 README 只作为入口索引和 `master` 分支说明，避免把 .NET 8 主分支、.NET 10 misha 测试分支、QEMU 测试环境混在一起。

## 构建入口

| 目标 | 分支 | Workflow | 运行库 | 原生库来源 |
| --- | --- | --- | --- | --- |
| 主分支旧世界包 | `master` | [Build ClassIsland for LoongArch](https://github.com/YU322142/ClassIsland/actions/workflows/build-loongarch.yml) | .NET 8 | 本分支内置的 `LoongArch-Runtime/` 与 `LoongArch-NativeLibs/` |
| misha CI 旧世界测试包 | `develop/v2/misha-alpha-ci` | [Build ClassIsland misha LoongArch old-world ABI1.0 package](https://github.com/YU322142/ClassIsland/actions/workflows/build-loongarch-oldworld.yml) | Loongnix .NET 10 | 独立的 SkiaSharp/HarfBuzzSharp old-world 支持库构建 |
| misha 非 CI 测试包 | `develop/v2/misha-alpha` | 同上 | Loongnix .NET 10 | 同上 |

`master` 是旧版 .NET 8 旧世界构建；misha 分支是 .NET 10 测试构建。两套流程不要互相套用。misha 分支的完整说明在对应分支的 `tools/loongarch-oldworld/README.zh-CN.md` 和 `tools/loongarch-oldworld/README.md`。

## 下载和运行 master 包

1. 打开 [Actions](https://github.com/YU322142/ClassIsland/actions/workflows/build-loongarch.yml)。
2. 选择最新一次成功的 `Build ClassIsland for LoongArch`。
3. 在页面底部下载 artifact：`ClassIsland-LoongArch-OldWorld`。
4. 传到龙芯旧世界 X11 桌面环境后解压并运行：

```bash
tar -xzf ClassIsland-LoongArch.tar.gz -C ~/ClassIsland
cd ~/ClassIsland
bash run.sh
```

默认后台启动，日志写入 `logs/classisland.log`。需要前台观察输出时使用：

```bash
bash run.sh --foreground
```

## 运行依赖

建议先安装音频后备播放器：

```bash
sudo apt update
sudo apt install ffmpeg
```

本包面向 X11 桌面环境，不面向 Wayland/XWayland。托盘、置顶、透明窗口、声音、天气、插件等功能都应按完整应用功能测试，龙芯适配不应以牺牲功能为代价。

## 输入法自动探测

`run.sh` 默认设置：

```bash
CLASSISLAND_X11_ENABLE_IME=auto
```

在 LoongArch 上，程序会自动检查当前用户 DBus 会话里是否存在 Fcitx/Fcitx5 服务：

- 检测到 Fcitx/Fcitx5 时启用 Avalonia X11 IME，不影响中文输入法。
- 未检测到 Fcitx/Fcitx5 时，仅对 ClassIsland 禁用 IME，避免 Avalonia 反复访问不存在的 Fcitx DBus 服务导致刷日志和卡顿。
- 需要强制启用时执行 `CLASSISLAND_X11_ENABLE_IME=1 bash run.sh`。
- 需要强制禁用时执行 `CLASSISLAND_X11_ENABLE_IME=0 bash run.sh`。

.NET 8 `master` 和 .NET 10 misha 旧世界包采用相同的自动探测策略，但实现分别位于各自分支的构建流程中，互不混用。

## 构建说明

`master` 的 `.github/workflows/build-loongarch.yml` 会在线完成以下工作：

1. 准备 .NET 8 SDK，并把项目配置调整到可构建状态。
2. 生成空的 GPT-SoVITS 私钥占位文件，本 fork 不内置该语音服务私钥。
3. 修补 Linux 音频播放逻辑，优先使用原生音频引擎，失败时回退到 `ffplay`/`paplay`/`aplay`。
4. 修补 Linux 重启逻辑，保证随包内 .NET runtime 重新启动。
5. 修补 Linux X11 IME 自动探测逻辑。
6. 注入 `LoongArch-NativeLibs/` 中的 SkiaSharp/HarfBuzzSharp 原生库。
7. 解包 `LoongArch-Runtime/` 中的 .NET 8 LoongArch runtime。
8. 生成 `run.sh` 并上传 `ClassIsland-LoongArch-OldWorld` artifact。

手动触发 workflow 时可填写 `version_tag`，留空则基于仓库已有数字 tag 自动递增。

## 相关项目

- QEMU 旧世界测试环境：[YU322142/loongarch-oldworld-qemu-vm](https://github.com/YU322142/loongarch-oldworld-qemu-vm)
- SkiaSharp old-world 支持库：[YU322142/SkiaSharp-Loongarch-ABI1.0](https://github.com/YU322142/SkiaSharp-Loongarch-ABI1.0)
- HarfBuzzSharp old-world 支持库：[YU322142/harfbuzz-Loongarch-ABI1.0](https://github.com/YU322142/harfbuzz-Loongarch-ABI1.0)
- 上游 ClassIsland：[ClassIsland/ClassIsland](https://github.com/ClassIsland/ClassIsland)

## 许可证

本 fork 继承上游 ClassIsland 的开源协议。ClassIsland.PluginSdk、ClassIsland.Core、ClassIsland.Shared.Ipc、ClassIsland.Shared 基于 LGPL-3.0；其余应用本体代码基于 GPL-3.0。详见仓库内 `LICENSE.txt` 与上游项目说明。
