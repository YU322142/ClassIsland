# ClassIsland 龙芯旧世界 ABI1.0 打包说明

本目录用于给以下两个 misha 测试分支生成龙芯旧世界 ABI1.0 包：

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

适配逻辑集中放在 `tools/loongarch-oldworld` 下，避免直接修改上游主源码，便于后续继续跟进上游。
ClassIsland 的 `master` 分支不参与本次适配。

## 动态修补内容

`Build-ClassIsland-LoongArchOldWorld.ps1` 会在临时构建目录中动态修补：

- 增加 `loongarch64` 平台常量和平台名。
- 将 Avalonia 版本提升到指定版本，默认 `12.0.4`。
- GPT-SoVITS 内置预设签名改为可选；没有私钥时不阻塞普通构建。
- 应用旧世界 X11 环境所需的稳定性修补。
- 当 MiniAudio 无法打开默认设备时，使用 `ffplay`、`paplay` 或 `aplay` 进行 Linux 音频 fallback。
- 将自编译的 `libSkiaSharp.so` 和 `libHarfBuzzSharp.so` 注入到 `runtimes/linux-loongarch64/native`。

这些修改只发生在临时源码树中，不提交到 ClassIsland 主源码文件。

## 原生库来源

内置原生库位于：

```text
tools/loongarch-oldworld/native/linux-loongarch64/oldworld/
```

在线构建方案分别在：

- `YU322142/SkiaSharp-Loongarch-ABI1.0` 的 `main`
- `YU322142/harfbuzz-Loongarch-ABI1.0` 的 `main`

默认使用 `loong64/cross-tools` 的 `baseline` 工具链和其内置 sysroot。正常情况下不需要单独上传 sysroot。

## 本地打包

在 ClassIsland fork 根目录执行：

```powershell
pwsh tools/loongarch-oldworld/Build-ClassIsland-LoongArchOldWorld.ps1 `
  -RepoUrl https://github.com/YU322142/ClassIsland.git `
  -Branches develop/v2/misha-alpha,develop/v2/misha-alpha-ci
```

输出位置：

```text
artifacts/loongarch-oldworld/out/
```

## 已验证项目

已在可视化 QEMU LoongArch 旧世界 ABI1.0 Loongnix 20 X11 虚拟机中验证：

- `develop/v2/misha-alpha`：渲染正常，托盘菜单正常，网络可用，声音可听见。
- `develop/v2/misha-alpha-ci`：渲染正常，托盘菜单正常，网络可用，声音可听见。

已知非阻塞问题：编辑/教学窗口中的白色矩形问题在其他平台也存在，不作为本次龙芯适配回归处理。
