# ClassIsland LoongArch old-world ABI1.0 packaging

中文说明见 [README.zh-CN.md](README.zh-CN.md).

This directory contains the dynamic packaging path for these two misha test branches:

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

The adaptation is intentionally kept under `tools/loongarch-oldworld` so the fork can continue following upstream ClassIsland with minimal source churn. The ClassIsland `master` branch is not used for this adaptation.

## Dynamic patches

`Build-ClassIsland-LoongArchOldWorld.ps1` applies temporary patches inside an isolated build tree:

- Adds the `loongarch64` platform constant and platform name.
- Upgrades Avalonia to the requested version, defaulting to `12.0.4`.
- Keeps GPT-SoVITS internal preset signing optional so missing private keys do not block normal builds.
- Applies Linux/X11 stability patches needed by the old-world VM.
- Falls back to `ffplay`, `paplay`, or `aplay` for Linux audio when MiniAudio cannot open the default device.
- Injects the self-built `libSkiaSharp.so` and `libHarfBuzzSharp.so` into `runtimes/linux-loongarch64/native`.

These patches are not committed to the upstream source files. They are applied only in the temporary build tree.

## Native libraries

Bundled native libraries live in:

```text
tools/loongarch-oldworld/native/linux-loongarch64/oldworld/
```

The online build sources are:

- `YU322142/SkiaSharp-Loongarch-ABI1.0` `main`
- `YU322142/harfbuzz-Loongarch-ABI1.0` `main`

They default to the matching Linux x64 old-world GCC 14 toolchain and full old-world development sysroot published by `YU322142/loongarch-oldworld-sysroot`. The support-library workflows pass `--sysroot` directly to that uploaded sysroot, so the normal online build does not rely on public cross-tools bundled sysroots.

The ClassIsland workflow downloads the latest successful online artifacts from those two repositories and uses them for packaging. After the online artifacts pass VM testing, they can be copied back into `tools/loongarch-oldworld/native/linux-loongarch64/oldworld/` as the prebuilt default.

## Local packaging

From the ClassIsland fork root:

```powershell
pwsh tools/loongarch-oldworld/Build-ClassIsland-LoongArchOldWorld.ps1 `
  -RepoUrl https://github.com/YU322142/ClassIsland.git `
  -Branches develop/v2/misha-alpha,develop/v2/misha-alpha-ci
```

Output directory:

```text
artifacts/loongarch-oldworld/out/
```

Each package contains `run.sh`, the bundled Loongnix .NET 10 runtime, the native asset manifest, and the runtime manifest.

## Optional native rebuild

Local Windows cross-build helper:

```powershell
pwsh tools/loongarch-oldworld/Build-NativeLibs.ps1 `
  -SkiaSharpRoot C:\path\to\SkiaSharp-3.119.4 `
  -ToolchainRoot C:\path\to\loongarch64-unknown-linux-gnu
```

If these parameters are omitted, the helper looks under `artifacts/loongarch-oldworld/src` and `artifacts/loongarch-oldworld/toolchains`. For online native builds, prefer the workflows in the two support-library forks.

## Verified tests

The packages were tested in a visible QEMU LoongArch old-world ABI1.0 Loongnix 20 X11 VM:

- `develop/v2/misha-alpha`: rendering normal, tray menu normal, network available, sound audible.
- `develop/v2/misha-alpha-ci`: rendering normal, tray menu normal, network available, sound audible.

Known non-blocking issue: the white rectangle in the editor/tutorial area also appears on other platforms and is not treated as a LoongArch adaptation regression.
