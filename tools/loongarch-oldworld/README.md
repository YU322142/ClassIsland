# ClassIsland LoongArch old-world ABI1.0 packaging

中文说明见 [README.zh-CN.md](README.zh-CN.md).

This directory contains the dynamic packaging path for these two misha test branches:

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

The adaptation is intentionally kept under `tools/loongarch-oldworld` so the fork can continue following upstream ClassIsland with minimal source churn. The ClassIsland `master` branch is not used for this adaptation.

## Difference From The `master` Build

The ClassIsland `master` branch keeps using the project's regular build, publish, and CI flow. It does not use the LoongArch old-world dynamic patch script in this directory, and this workflow does not package `master` automatically.

This directory and `.github/workflows/build-loongarch-oldworld.yml` are only for the `develop/v2/misha-alpha` and `develop/v2/misha-alpha-ci` misha test branches. Their LoongArch old-world packages need extra packaging work:

- Apply temporary `loongarch64` platform detection, X11 stability, and Linux audio fallback patches inside an isolated source tree.
- Bundle the Loongnix .NET 10 LoongArch runtime into a directly testable folderClassic package.
- Inject the VM-verified old-world `libSkiaSharp.so` and `libHarfBuzzSharp.so` files.
- Write native/runtime manifests so later checks can confirm native asset source, GLIBC ceiling, and runtime versions.

These differences exist to validate the misha test branches on LoongArch old-world ABI1.0. They do not change the regular publishing path for the `master` branch.

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

The ClassIsland workflow uses the bundled, VM-verified prebuilt `.so` files by default. To re-test online Actions artifacts, manually run the workflow with `useOnlineNativeAssets` set to `true`; the workflow then downloads the latest successful online artifacts from the two support-library repositories and uses them for packaging. After those online artifacts pass VM testing, copy the verified `.so` files back into `tools/loongarch-oldworld/native/linux-loongarch64/oldworld/` as the new prebuilt default.

The manual workflow input is intentionally close to the main `Build` workflow:

- `release_tag`: the source ref/tag to package. Use one of the misha test branches or another misha ref; do not use `master`.
- `primary_version`: the app/package version written into assembly and manifest metadata.
- `is_test_mode`: kept for parity with the main workflow. Keep it enabled for misha old-world test packages.
- `package_label`: optional label used in the tarball name. Leave it blank to use the misha ref slug, such as `misha-alpha-ci`.
- `artifact_name`: GitHub Actions artifact name for the uploaded package.
- `useOnlineNativeAssets` plus the native repo/artifact inputs: download Actions artifacts from your selected support-library forks instead of the bundled prebuilt `.so` files.

The current prebuilt default comes from these verified online builds:

```text
SkiaSharp: YU322142/SkiaSharp-Loongarch-ABI1.0 run 27100071183
libSkiaSharp.so SHA256: 8E6420772C0AE0E5D61F84D34800D88455D425EF941591117C1E1A86600C7246

HarfBuzzSharp: YU322142/harfbuzz-Loongarch-ABI1.0 run 27099940796
libHarfBuzzSharp.so SHA256: D94A261287A0A21E84C2F01FA2D1F5B5F461A9704103061C4ABD63280AEFD1FE
```

## Local packaging

From the ClassIsland fork root:

```powershell
pwsh tools/loongarch-oldworld/Build-ClassIsland-LoongArchOldWorld.ps1 `
  -RepoUrl https://github.com/YU322142/ClassIsland.git `
  -Branches develop/v2/misha-alpha,develop/v2/misha-alpha-ci `
  -AppVersion 2.0.0.0
```

Output directory:

```text
artifacts/loongarch-oldworld/out/
```

Each package contains `run.sh`, the bundled Loongnix .NET 10 runtime, the native asset manifest, and the runtime manifest.

Use `-PackageLabel <name>` when you want a custom tarball label. If more than one branch is packaged in one run, the branch slug is appended to avoid name collisions.

## Bundled `ClassIsland/shared`

The extracted package contains `ClassIsland/shared`. This is not a disposable shared-data directory; it is the bundled .NET runtime shared-framework directory required by the Loongnix .NET host. It currently contains:

- `Microsoft.NETCore.App/10.0.5`
- `Microsoft.AspNetCore.App/10.0.5`

Keep this directory with `ClassIsland/dotnet`, `ClassIsland/host`, and the application files. Removing it makes the package unable to start on the old-world VM unless a compatible system runtime is installed and selected manually.

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
