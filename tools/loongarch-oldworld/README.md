# ClassIsland LoongArch old-world ABI1.0 packaging

中文说明见 [README.zh-CN.md](README.zh-CN.md).

This directory contains the dynamic packaging path for these two misha test branches:

- `develop/v2/misha-alpha`
- `develop/v2/misha-alpha-ci`

The adaptation is intentionally kept under `tools/loongarch-oldworld` so the fork can continue following upstream ClassIsland with minimal source churn. The fork has two LoongArch old-world build paths: the older .NET 8 `master` workflow, and this .NET 10 misha test packaging workflow.

## Which LoongArch Build Should I Use?

Use `.github/workflows/build-loongarch.yml` (`Build ClassIsland for LoongArch`) when you want the fork `master` old-world package. That path is the older .NET 8 workflow and uses the existing prebuilt LoongArch native libraries/runtime prepared for that branch.

Use `.github/workflows/build-loongarch-oldworld.yml` (`Build ClassIsland misha LoongArch old-world ABI1.0 package`) when you want to test the misha branches on LoongArch old-world ABI1.0 with Loongnix .NET 10 and the newer native-library adaptation described here.

This directory and `.github/workflows/build-loongarch-oldworld.yml` are only for the `develop/v2/misha-alpha` and `develop/v2/misha-alpha-ci` misha test branches. Their LoongArch old-world packages need extra packaging work:

- Apply temporary `loongarch64` platform detection, X11 stability, and Linux audio fallback patches inside an isolated source tree.
- Bundle the Loongnix .NET 10 LoongArch runtime into a directly testable folderClassic package.
- Inject the VM-verified old-world `libSkiaSharp.so` and `libHarfBuzzSharp.so` files.
- Write native/runtime manifests so later checks can confirm native asset source, GLIBC ceiling, and runtime versions.

These differences exist to validate the misha test branches on LoongArch old-world ABI1.0. They do not replace the existing .NET 8 old-world build path on the fork `master` branch.

Two LoongArch workflows are intentionally kept separate:

| Workflow | Branches | Purpose | Manual version input |
| --- | --- | --- | --- |
| `.github/workflows/build-loongarch.yml` (`Build ClassIsland for LoongArch`) | fork `master` / older old-world path | .NET 8 old-world package using existing prebuilt native libraries/runtime | `version_tag` |
| `.github/workflows/build-loongarch-oldworld.yml` (`Build ClassIsland misha LoongArch old-world ABI1.0 package`) | `develop/v2/misha-alpha`, `develop/v2/misha-alpha-ci` | .NET 10 misha old-world runtime test package with VM-verified or online-built native libraries | `version_tag` plus selected misha `branch` |

## Dynamic patches

`Build-ClassIsland-LoongArchOldWorld.ps1` applies temporary patches inside an isolated build tree:

- Adds the `loongarch64` platform constant and platform name.
- Upgrades Avalonia to the requested version, defaulting to `12.0.4`.
- Keeps GPT-SoVITS internal preset signing optional so missing private keys do not block normal builds.
- Applies Linux/X11 stability patches needed by the old-world VM.
- Forces Avalonia software rendering by default on LoongArch64 Linux/X11 and keeps the CPU framebuffer retained to avoid red/white blocks on real hardware GLX/EGL paths.
- Disables Avalonia IME probing in the default test environment so a missing `org.fcitx.Fcitx` DBus service does not repeatedly log errors and slow down interaction.
- Falls back to `ffplay`, `paplay`, or `aplay` for Linux audio when MiniAudio cannot open the default device.
- Injects the self-built `libSkiaSharp.so` and `libHarfBuzzSharp.so` into `runtimes/linux-loongarch64/native`.

These patches are not committed to the upstream source files. They are applied only in the temporary build tree.

## X11 Rendering On Real Hardware

The old-world QEMU VM usually has no usable hardware GL path, and the recommended launcher disables QEMU OpenGL. Avalonia therefore tends to fall back to software rendering in the VM. Some Kylin/Loongnix real machines expose GLX/EGL instead; with the old-world ABI1.0, Mesa/GPU driver, and SkiaSharp native-library combination, that GL path can render transparent layers or backgrounds as large red/white blocks and make interaction very sluggish.

This packaging path therefore defaults LoongArch64 Linux/X11 to:

```bash
CLASSISLAND_X11_RENDERING=software
CLASSISLAND_X11_RETAINED_FRAMEBUFFER=1
CLASSISLAND_X11_ENABLE_IME=0
```

These defaults are applied both in the application entry point and in `run.sh`. For normal tests, run:

```bash
bash run.sh --foreground
```

To diagnose GPU drivers or Avalonia backends, temporarily override the renderer:

```bash
CLASSISLAND_X11_RENDERING=glx bash run.sh --foreground
CLASSISLAND_X11_RENDERING=egl bash run.sh --foreground
CLASSISLAND_X11_RENDERING=auto bash run.sh --foreground
```

If red/white blocks, incorrectly filled window backgrounds, or severe settings-window sluggishness appear, return to the default `software` mode. If the desktop really has a working Fcitx service, use `CLASSISLAND_X11_ENABLE_IME=1 bash run.sh --foreground` to temporarily enable Avalonia IME; do not enable it on sessions without the Fcitx DBus service.

## Native libraries

Bundled native libraries live in:

```text
tools/loongarch-oldworld/native/linux-loongarch64/oldworld/
```

The online build sources are:

- `YU322142/SkiaSharp-Loongarch-ABI1.0` `main`
- `YU322142/harfbuzz-Loongarch-ABI1.0` `main`

They default to the matching Linux x64 old-world GCC 14 toolchain and full old-world development sysroot published by `YU322142/loongarch-oldworld-sysroot`. The support-library workflows pass `--sysroot` directly to that uploaded sysroot, so the normal online build does not rely on public cross-tools bundled sysroots.

Toolchain/sysroot source notes:

- The toolchain is not a compiler written by this project. It is a pinned and republished third-party LoongArch old-world cross-toolchain aggregate for reproducible GitHub Actions builds. The archive contains crosstool-NG metadata at `share/loongarch64-unknown-linux-gnu-ct-ng.config.bz2` and component licenses for GCC, binutils, glibc, crosstool-NG and related packages.
- The sysroot is not a runnable VM/root filesystem. It is a development sysroot collected from an old-world Loongnix/LoongArch development environment and includes the headers and libraries required to keep desktop features enabled, such as fontconfig, FreeType, X11, OpenGL and Vulkan.
- `YU322142/loongarch-oldworld-sysroot` only fixes the exact release assets, download URLs and SHA256 values used by the native-library workflows. It does not relicense the third-party files inside those archives.
- Native library source remains `mono/SkiaSharp` `v3.119.4`; `libHarfBuzzSharp.so` is built from the HarfBuzzSharp native GN target in that source tree, not from a generic upstream `libharfbuzz.so` build.

The ClassIsland workflow uses the bundled, VM-verified prebuilt `.so` files by default. To re-test online Actions artifacts, manually run the workflow with `useOnlineNativeAssets` set to `true`; the workflow then downloads the latest successful online artifacts from the two support-library repositories and uses them for packaging. After those online artifacts pass VM testing, copy the verified `.so` files back into `tools/loongarch-oldworld/native/linux-loongarch64/oldworld/` as the new prebuilt default.

## Manual workflow input

The manual workflow input is intentionally close to the fork `master` branch `.github/workflows/build-loongarch.yml`:

- `version_tag`: same meaning as the fork `master` LoongArch workflow. Enter a version such as `2.0.4.0000`, or leave it blank to compute the next numeric version from remote tags.
- `branch`: the misha test branch to package. Use `develop/v2/misha-alpha`, `develop/v2/misha-alpha-ci`, or another misha test ref; do not use `master`.
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
