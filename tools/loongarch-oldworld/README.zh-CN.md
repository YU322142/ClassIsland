# ClassIsland 龙芯旧世界 ABI1.0 打包说明

本目录用于给以下两个 misha 测试分支生成龙芯旧世界 ABI1.0 包：

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

适配逻辑集中放在 `tools/loongarch-oldworld` 下，避免直接修改上游主源码，便于后续继续跟进上游。
ClassIsland 的 `master` 分支不参与本次适配。

## 与 `master` 主分支构建方式的区别

ClassIsland `master` 分支继续使用项目原本的构建、发布和 CI 流程，不使用本目录中的 LoongArch 旧世界动态修补脚本，也不会被本 workflow 自动打包。

本目录和 `.github/workflows/build-loongarch-oldworld.yml` 只服务于 `develop/v2/misha-alpha` 与 `develop/v2/misha-alpha-ci` 两个 misha 测试分支。它们的 LoongArch 旧世界包需要额外完成以下工作：

- 在临时源码树中动态补充 `loongarch64` 平台识别、X11 稳定性和音频 fallback 修补。
- 使用 Loongnix 的 .NET 10 LoongArch 运行时组成可直接测试的 folderClassic 包。
- 注入已经过 Loongnix 20 旧世界 ABI1.0 VM 验证的 `libSkiaSharp.so` 和 `libHarfBuzzSharp.so`。
- 记录 native/runtime manifest，便于后续确认原生库来源、GLIBC 上限和运行库版本。

这些差异是为了验证 misha 测试分支在龙芯旧世界 ABI1.0 上的可运行性，不代表 `master` 主分支的常规发布方式发生变化。

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

默认使用 `YU322142/loongarch-oldworld-sysroot` 发布的 Linux x64 旧世界 GCC 14 工具链和完整旧世界开发 sysroot。支持库 workflow 会直接把 `--sysroot` 指向该上传的 sysroot，正常在线构建不再依赖公开 cross-tools 自带 sysroot。

ClassIsland workflow 默认使用仓库内已经过 VM 验证的预编译 `.so`。如需重新验证线上 Actions 产物，可在手动运行 workflow 时将 `useOnlineNativeAssets` 设为 `true`，workflow 会下载这两个仓库最新成功的线上 Actions artifact 并用它们打包。线上产物在 VM 中测试没问题后，再把通过验证的 `.so` 固化回 `tools/loongarch-oldworld/native/linux-loongarch64/oldworld/` 作为新的预编译默认版本。

当前预编译默认版本来自以下已验证的线上构建：

```text
SkiaSharp: YU322142/SkiaSharp-Loongarch-ABI1.0 run 27100071183
libSkiaSharp.so SHA256: 8E6420772C0AE0E5D61F84D34800D88455D425EF941591117C1E1A86600C7246

HarfBuzzSharp: YU322142/harfbuzz-Loongarch-ABI1.0 run 27099940796
libHarfBuzzSharp.so SHA256: D94A261287A0A21E84C2F01FA2D1F5B5F461A9704103061C4ABD63280AEFD1FE
```

## 手动 workflow 输入

`.github/workflows/build-loongarch-oldworld.yml` 的手动输入尽量与主分支 `Build` workflow 的发布入口保持一致：

- `release_tag`：要打包的源码 ref/tag。这里应填写 misha 测试分支或其它 misha ref，不要填写 `master`。
- `primary_version`：写入程序集和 manifest 的应用/包版本。
- `is_test_mode`：保留为与主 workflow 对齐的测试发布开关。misha 旧世界测试包建议保持启用。
- `package_label`：可选的 tar 包名标签；留空时使用 misha ref 的 slug，例如 `misha-alpha-ci`。
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

## 已验证项目

已在可视化 QEMU LoongArch 旧世界 ABI1.0 Loongnix 20 X11 虚拟机中验证：

- `develop/v2/misha-alpha`：渲染正常，托盘菜单正常，网络可用，声音可听见。
- `develop/v2/misha-alpha-ci`：渲染正常，托盘菜单正常，网络可用，声音可听见。

已知非阻塞问题：编辑/教学窗口中的白色矩形问题在其他平台也存在，不作为本次龙芯适配回归处理。
