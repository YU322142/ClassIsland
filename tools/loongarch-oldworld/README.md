# ClassIsland LoongArch old-world ABI1.0 packaging

This directory contains the dynamic packaging path for the two misha test branches:

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

It is intentionally kept under `tools/loongarch-oldworld` so the fork can follow upstream ClassIsland with minimal source churn. The build script downloads or checks out the requested branch into an isolated build directory, applies temporary patches there, publishes the app, injects the verified old-world native libraries, and writes a tarball.

The repository `master` branch is not used for this adaptation.

## What is patched dynamically

`Build-ClassIsland-LoongArchOldWorld.ps1` applies temporary changes during packaging:

- adds the `loongarch64` platform constant/name for publish output;
- upgrades the requested Avalonia version, defaulting to `12.0.4`;
- keeps GPT-SoVITS internal preset signing optional, so missing signing secrets do not block builds;
- applies Linux/X11 stability fixes needed by the old-world VM;
- adds Linux audio fallback through `ffplay`, `paplay`, or `aplay` when MiniAudio cannot open the default device;
- installs the self-built old-world `libSkiaSharp.so` and `libHarfBuzzSharp.so` into `runtimes/linux-loongarch64/native`.

The upstream source files are not committed with these patches. They are changed only in the temporary build tree.

## Native libraries

The bundled native libraries live in:

```text
tools/loongarch-oldworld/native/linux-loongarch64/oldworld/
```

They are built from `mono/SkiaSharp` `v3.119.4` with an old-world LoongArch cross toolchain and are checked for:

- ELF machine: LoongArch
- ELF flags: LP64
- GLIBC symbol versions: `GLIBC_2.28` or older

The matching online build sources are:

- `YU322142/SkiaSharp-Loongarch-ABI1.0` `master`
- `YU322142/harfbuzz-Loongarch-ABI1.0` `master`

Those repositories default to the `loong64/cross-tools` `baseline` toolchain and use its bundled sysroot. A separate sysroot upload is not required unless a future dependency needs a different Loongnix sysroot; the native build scripts have optional `SYSROOT_URL` and `SYSROOT_SHA256` overrides for that case.

## Build packages locally

From the ClassIsland fork root:

```powershell
pwsh tools/loongarch-oldworld/Build-ClassIsland-LoongArchOldWorld.ps1 `
  -RepoUrl https://github.com/YU322142/ClassIsland.git `
  -Branches develop/v2/misha-alpha,develop/v2/misha-alpha-ci
```

The output tarballs are written to:

```text
artifacts/loongarch-oldworld/out/
```

Each package contains a `run.sh`, bundled Loongnix .NET 10 runtime, native asset manifest, and runtime manifest.

## Optional native rebuild

The local Windows cross-build helper is:

```powershell
pwsh tools/loongarch-oldworld/Build-NativeLibs.ps1 `
  -SkiaSharpRoot C:\path\to\SkiaSharp-3.119.4 `
  -ToolchainRoot C:\path\to\loongarch64-unknown-linux-gnu
```

If these parameters are omitted, the helper looks under `artifacts/loongarch-oldworld/src` and `artifacts/loongarch-oldworld/toolchains`.

For online native library builds, use the two support-library fork workflows instead of rebuilding native code inside the ClassIsland workflow.

## Test matrix already covered

The packages were tested in a visible QEMU LoongArch old-world ABI1.0 Loongnix 20 X11 VM with network and PulseAudio enabled.

Verified manually:

- `develop/v2/misha-alpha`: rendering normal, tray menu normal, network available, sound audible.
- `develop/v2/misha-alpha-ci`: rendering normal, tray menu normal, network available, sound audible.

Known non-blocking issue: the white rectangle in the editor/tutorial area also appears on other platforms and is not treated as a LoongArch adaptation regression.
