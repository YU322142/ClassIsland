# ClassIsland 龙芯旧世界 ABI1.0 打包说明

本目录用于给以下两个 misha 测试分支生成龙芯旧世界 ABI1.0 包：

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

适配逻辑集中放在 `tools/loongarch-oldworld` 下，避免直接修改上游主源码，便于后续继续跟进上游。
本 fork 有两条龙芯旧世界编译路径：`master` 主分支的旧版 .NET 8 workflow，以及这里的 .NET 10 misha 测试打包 workflow。

## 应该使用哪一个龙芯旧世界编译入口

如果要编译 fork `master` 主分支的旧世界包，请使用 `.github/workflows/build-loongarch.yml`（`Build ClassIsland for LoongArch`）。这条路径是旧版 .NET 8 workflow，使用已经为该分支准备好的预编译 LoongArch 原生库/运行库。

如果要测试 misha 分支在龙芯旧世界 ABI1.0 上的运行情况，请使用 `.github/workflows/build-loongarch-oldworld.yml`（`Build ClassIsland misha LoongArch old-world ABI1.0 package`）。这条路径使用 Loongnix .NET 10，并配合这里记录的新原生库适配方案。

本目录和 `.github/workflows/build-loongarch-oldworld.yml` 只服务于 `develop/v2/misha-alpha` 与 `develop/v2/misha-alpha-ci` 两个 misha 测试分支。它们的 LoongArch 旧世界包需要额外完成以下工作：

- 在临时源码树中动态补充 `loongarch64` 平台识别、X11 稳定性和音频 fallback 修补。
- 使用 Loongnix 的 .NET 10 LoongArch 运行时组成可直接测试的 folderClassic 包。
- 注入已经过 Loongnix 20 旧世界 ABI1.0 VM 验证的 `libSkiaSharp.so` 和 `libHarfBuzzSharp.so`。
- 记录 native/runtime manifest，便于后续确认原生库来源、GLIBC 上限和运行库版本。

这些差异是为了验证 misha 测试分支在龙芯旧世界 ABI1.0 上的可运行性，不会替换 fork `master` 主分支已有的 .NET 8 旧世界编译方式。

两个龙芯编译入口请区分使用：

| Workflow | 分支范围 | 用途 | 手动版本输入 |
| --- | --- | --- | --- |
| `.github/workflows/build-loongarch.yml`（`Build ClassIsland for LoongArch`） | fork `master` / 旧版旧世界路径 | .NET 8 旧世界包，使用已有预编译原生库/运行库 | `version_tag` |
| `.github/workflows/build-loongarch-oldworld.yml`（`Build ClassIsland misha LoongArch old-world ABI1.0 package`） | `develop/v2/misha-alpha`、`develop/v2/misha-alpha-ci` | .NET 10 misha 旧世界运行测试包，使用 VM 验证预编译库或线上重编支持库 | `version_tag` 加 misha `branch` |

## 动态修补内容

`Build-ClassIsland-LoongArchOldWorld.ps1` 会在临时构建目录中动态修补：

- 增加 `loongarch64` 平台常量和平台名。
- 将 Avalonia 版本提升到指定版本，默认 `12.0.4`。
- GPT-SoVITS 内置预设签名改为可选；没有私钥时不阻塞普通构建。
- 应用旧世界 X11 环境所需的稳定性修补。
- 在 LoongArch64 Linux/X11 上默认强制 Avalonia 使用软件渲染，并保留 CPU framebuffer，避免实机 GLX/EGL 路径出现红色/白色色块。
- 默认自动探测 Fcitx/Fcitx5 DBus 服务；存在时启用 Avalonia IME，不存在时关闭 IME 探测，避免反复报错导致交互卡顿。
- 当 MiniAudio 无法打开默认设备时，使用 `ffplay`、`paplay` 或 `aplay` 进行 Linux 音频 fallback。
- 将自编译的 `libSkiaSharp.so` 和 `libHarfBuzzSharp.so` 注入到 `runtimes/linux-loongarch64/native`。

这些修改只发生在临时源码树中，不提交到 ClassIsland 主源码文件。

## X11 实机渲染策略

旧世界 VM 测试环境的 QEMU 显示通常没有可用的硬件 GL 路径，并且推荐启动参数会关闭 QEMU OpenGL，因此 Avalonia 往往自动落到软件渲染。部分 Kylin/Loongnix 实机则会暴露 GLX/EGL；在旧世界 ABI1.0、Mesa/显卡驱动和 SkiaSharp 原生库组合不稳定时，GL 路径可能把透明层或背景区域渲染成大面积红色/白色色块，并伴随明显交互卡顿。

本打包方案因此对 LoongArch64 Linux/X11 默认采用：

```bash
CLASSISLAND_X11_RENDERING=software
CLASSISLAND_X11_RETAINED_FRAMEBUFFER=1
CLASSISLAND_X11_ENABLE_IME=auto
```

这些默认值已经写入程序入口和 `run.sh`。正常测试请直接运行：

```bash
bash run.sh --foreground
```

如需排查显卡驱动或 Avalonia 后端，可临时覆盖渲染模式：

```bash
CLASSISLAND_X11_RENDERING=glx bash run.sh --foreground
CLASSISLAND_X11_RENDERING=egl bash run.sh --foreground
CLASSISLAND_X11_RENDERING=auto bash run.sh --foreground
```

如果出现红色/白色色块、窗口背景被整块刷错、或设置页拖动明显卡顿，请恢复默认 `software`。`CLASSISLAND_X11_ENABLE_IME=auto` 会检测 session DBus 中的 `org.fcitx.Fcitx` / `org.fcitx.Fcitx5`；如需强制开关，可用 `CLASSISLAND_X11_ENABLE_IME=1 bash run.sh --foreground` 或 `CLASSISLAND_X11_ENABLE_IME=0 bash run.sh --foreground`。

## 原生库来源

内置原生库位于：

```text
tools/loongarch-oldworld/native/linux-loongarch64/oldworld/
```

在线构建方案分别在：

- `YU322142/SkiaSharp-Loongarch-ABI1.0` 的 `main`
- `YU322142/harfbuzz-Loongarch-ABI1.0` 的 `main`

默认使用 `YU322142/loongarch-oldworld-sysroot` 发布的 Linux x64 旧世界 GCC 14 工具链和完整旧世界开发 sysroot。支持库 workflow 会直接把 `--sysroot` 指向该上传的 sysroot，正常在线构建不再依赖公开 cross-tools 自带 sysroot。

工具链/sysroot 来源说明：

- 工具链不是本项目自研的编译器。它是为了让 GitHub Actions 可复现构建而固定并重新发布的第三方 LoongArch 旧世界交叉工具链聚合包；压缩包内包含 `share/loongarch64-unknown-linux-gnu-ct-ng.config.bz2`，以及 GCC、binutils、glibc、crosstool-NG 等组件的许可证文件。
- sysroot 不是可启动的虚拟机或根文件系统，而是从旧世界 Loongnix/LoongArch 开发环境整理出的开发 sysroot，包含保留桌面功能所需的 fontconfig、FreeType、X11、OpenGL、Vulkan 等头文件和库。
- `YU322142/loongarch-oldworld-sysroot` 只负责固定支持库 workflow 使用的 Release 资产、下载地址和 SHA256，不会也不能重新授权压缩包内的第三方文件。
- 原生库源码仍来自 `mono/SkiaSharp` `v3.119.4`；`libHarfBuzzSharp.so` 是从该源码树中的 HarfBuzzSharp native GN target 构建出来的，不是普通上游 `libharfbuzz.so`。

ClassIsland workflow 默认使用仓库内已经过 VM 验证的预编译 `.so`。如需重新验证线上 Actions 产物，可在手动运行 workflow 时将 `useOnlineNativeAssets` 设为 `true`，workflow 会下载这两个仓库最新成功的线上 Actions artifact 并用它们打包。线上产物在 VM 中测试没问题后，再把通过验证的 `.so` 固化回 `tools/loongarch-oldworld/native/linux-loongarch64/oldworld/` 作为新的预编译默认版本。

当前预编译默认版本来自以下已验证的线上构建：

```text
SkiaSharp: YU322142/SkiaSharp-Loongarch-ABI1.0 run 27100071183
libSkiaSharp.so SHA256: 8E6420772C0AE0E5D61F84D34800D88455D425EF941591117C1E1A86600C7246

HarfBuzzSharp: YU322142/harfbuzz-Loongarch-ABI1.0 run 27099940796
libHarfBuzzSharp.so SHA256: D94A261287A0A21E84C2F01FA2D1F5B5F461A9704103061C4ABD63280AEFD1FE
```

## 手动 workflow 输入

`.github/workflows/build-loongarch-oldworld.yml` 的手动输入尽量与 fork `master` 主分支 `.github/workflows/build-loongarch.yml` 保持一致：

- `version_tag`：含义与 fork `master` 的 LoongArch workflow 一致。可填写 `2.0.4.0000` 这类版本号；留空时会基于远端最新数字 tag 自动计算。
- `branch`：要打包的 misha 测试分支。这里应填写 `develop/v2/misha-alpha`、`develop/v2/misha-alpha-ci` 或其它 misha 测试 ref，不要填写 `master`。
- `package_label`：可选的 tar 包名标签；留空时使用 misha 分支名 slug，例如 `misha-alpha-ci`。
- `artifact_name`：上传到 GitHub Actions 的打包 artifact 名称。
- `useOnlineNativeAssets` 以及两个支持库的 repo/artifact 输入：用于从你指定的支持库 fork 下载线上 Actions artifact，而不是使用仓库内置的预编译 `.so`。

## 本地打包

在 ClassIsland fork 根目录执行：

```powershell
pwsh tools/loongarch-oldworld/Build-ClassIsland-LoongArchOldWorld.ps1 `
  -RepoUrl https://github.com/YU322142/ClassIsland.git `
  -Branches develop/v2/misha-alpha,develop/v2/misha-alpha-ci `
  -AppVersion 2.0.0.0
```

输出位置：

```text
artifacts/loongarch-oldworld/out/
```

需要自定义 tar 包名标签时，可以增加 `-PackageLabel <name>`。如果一次打包多个分支，脚本会自动追加分支 slug，避免包名冲突。

## 打包产物中的 `ClassIsland/shared`

解压后的包里会有 `ClassIsland/shared`。它不是可以删除的共享数据目录，而是 Loongnix .NET host 需要的 .NET 共享运行库目录。目前包含：

- `Microsoft.NETCore.App/10.0.5`
- `Microsoft.AspNetCore.App/10.0.5`

这个目录需要和 `ClassIsland/dotnet`、`ClassIsland/host` 以及应用文件一起保留。删除后，旧世界虚拟机里除非另行安装并手动选中了兼容运行库，否则软件无法启动。

## 可选本地原生库重编

Windows 本地交叉编译辅助脚本：

```powershell
pwsh tools/loongarch-oldworld/Build-NativeLibs.ps1 `
  -SkiaSharpRoot C:\path\to\SkiaSharp-3.119.4 `
  -ToolchainRoot C:\path\to\loongarch64-unknown-linux-gnu
```

如果省略这些参数，脚本会在 `artifacts/loongarch-oldworld/src` 和 `artifacts/loongarch-oldworld/toolchains` 下查找。线上原生库构建仍建议优先使用两个支持库 fork 中的 workflow。

## 已验证项目

已在可视化 QEMU LoongArch 旧世界 ABI1.0 Loongnix 20 X11 虚拟机中验证：

- `develop/v2/misha-alpha`：渲染正常，托盘菜单正常，网络可用，声音可听见。
- `develop/v2/misha-alpha-ci`：渲染正常，托盘菜单正常，网络可用，声音可听见。

已知非阻塞问题：编辑/教学窗口中的白色矩形问题在其他平台也存在，不作为本次龙芯适配回归处理。
