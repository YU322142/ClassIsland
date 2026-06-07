param(
    [string]$Root,
    [string]$SkiaSharpRoot,
    [string]$ToolchainRoot,
    [string]$NativeAssetsDir,
    [int]$Jobs = 8,
    [string]$MaxGlibc = "2.28",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $SkiaSharpRoot) {
    $SkiaSharpRoot = Join-Path $Root "artifacts\loongarch-oldworld\src\SkiaSharp-3.119.4"
}
if (-not $ToolchainRoot) {
    $ToolchainRoot = Join-Path $Root "artifacts\loongarch-oldworld\toolchains\mingw\loongarch64-unknown-linux-gnu"
}
if (-not $NativeAssetsDir) {
    $NativeAssetsDir = Join-Path $PSScriptRoot "native\linux-loongarch64\oldworld"
}

function Convert-ToGnPath([string]$Path) {
    return $Path.Replace("\", "/")
}

function Invoke-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

function Ensure-Python3Shim {
    param([string]$ShimDir)

    New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
    $shim = Join-Path $ShimDir "python3.exe"
    if (Test-Path $shim) {
        return $shim
    }

    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    )
    $python = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $python) {
        throw "Could not find python.exe for python3 shim."
    }
    Copy-Item -Force $python $shim
    return $shim
}

function Compare-VersionString {
    param([string]$Left, [string]$Right)

    $l = $Left.Split(".") | ForEach-Object { [int]$_ }
    $r = $Right.Split(".") | ForEach-Object { [int]$_ }
    $n = [Math]::Max($l.Count, $r.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $lv = if ($i -lt $l.Count) { $l[$i] } else { 0 }
        $rv = if ($i -lt $r.Count) { $r[$i] } else { 0 }
        if ($lv -gt $rv) { return 1 }
        if ($lv -lt $rv) { return -1 }
    }
    return 0
}

function Get-VersionTokens {
    param([string]$ReadElf, [string]$SoPath)

    $text = & $ReadElf --version-info $SoPath
    $joined = $text -join "`n"
    return [regex]::Matches($joined, "(?:GLIBC|GLIBCXX|CXXABI)_[0-9]+(?:\.[0-9]+)*") |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
}

function Assert-GlibcMax {
    param([string]$ReadElf, [string]$SoPath, [string]$Max)

    $tokens = Get-VersionTokens -ReadElf $ReadElf -SoPath $SoPath
    foreach ($token in $tokens) {
        if ($token -match "^GLIBC_([0-9.]+)$") {
            if ((Compare-VersionString $Matches[1] $Max) -gt 0) {
                throw "$SoPath requires $token, above GLIBC_$Max"
            }
        }
    }
    return $tokens
}

function Assert-LoongArchOldWorldElf {
    param([string]$ReadElf, [string]$SoPath)

    $header = & $ReadElf -h $SoPath
    $machine = ($header | Select-String "Machine:").Line
    $flags = ($header | Select-String "Flags:").Line
    if ($machine -notmatch "LoongArch") {
        throw "$SoPath is not LoongArch: $machine"
    }
    if ($flags -notmatch "LP64") {
        throw "$SoPath is not LP64 old-world style ELF: $flags"
    }
}

function Write-GnArgs {
    param(
        [string]$OutDir,
        [string]$Sysroot,
        [string]$Gcc,
        [string]$Gxx,
        [string]$Ar,
        [string]$Map,
        [string]$Soname,
        [ValidateSet("SkiaSharp", "HarfBuzzSharp")]
        [string]$Target
    )

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $DummyVc = Join-Path $Root "artifacts\loongarch-oldworld\dummy-vc"
    $DummySdk = Join-Path $Root "artifacts\loongarch-oldworld\dummy-sdk"
    New-Item -ItemType Directory -Force -Path $DummyVc, $DummySdk | Out-Null
    $DummyVcGn = Convert-ToGnPath $DummyVc
    $DummySdkGn = Convert-ToGnPath $DummySdk

    if ($Target -eq "SkiaSharp") {
        $extra = @"
skia_enable_ganesh=true
skia_use_harfbuzz=false
skia_use_icu=false
skia_use_piex=true
skia_use_sfntly=false
skia_use_system_expat=false
skia_use_system_freetype2=false
skia_use_system_libjpeg_turbo=false
skia_use_system_libpng=false
skia_use_system_libwebp=false
skia_use_system_zlib=false
skia_enable_skottie=true
skia_use_vulkan=true
skia_use_gl=true
skia_use_x11=true
skia_use_fontconfig=true
skia_use_freetype=true
extra_cflags=[ "--sysroot=$Sysroot", "-DSKIA_C_DLL", "-DHAVE_SYSCALL_GETRANDOM", "-DXML_DEV_URANDOM" ]
"@
    } else {
        $extra = @"
visibility_hidden=false
extra_cflags=[ "--sysroot=$Sysroot" ]
"@
    }

    $args = @"
is_official_build=true
skia_enable_tools=false
target_os="linux"
target_cpu="loong64"
$extra
extra_asmflags=[]
extra_ldflags=[ "--sysroot=$Sysroot", "-static-libstdc++", "-static-libgcc", "-Wl,-rpath-link,$Sysroot/usr/lib64", "-Wl,-rpath-link,$Sysroot/lib64", "-Wl,--version-script=$Map" ]
cc="$Gcc"
cxx="$Gxx"
ar="$Ar"
linux_soname_version="$Soname"
link_pool_depth=1
win_vc="$DummyVcGn"
win_toolchain_version="14.00.00000"
win_vcvars_version="14.0"
win_sdk="$DummySdkGn"
win_sdk_version="10.0.00000.0"
"@

    Set-Content -Encoding ASCII -Path (Join-Path $OutDir "args.gn") -Value $args
}

$skia = Join-Path $SkiaSharpRoot "externals\skia"
$gn = Join-Path $skia "bin\gn.exe"
$ninja = Join-Path $skia "third_party\ninja\ninja.exe"
$bin = Join-Path $ToolchainRoot "bin"
$sysroot = Join-Path $ToolchainRoot "loongarch64-unknown-linux-gnu\sysroot"
$gcc = Join-Path $bin "loongarch64-unknown-linux-gnu-gcc.exe"
$gxx = Join-Path $bin "loongarch64-unknown-linux-gnu-g++.exe"
$ar = Join-Path $bin "loongarch64-unknown-linux-gnu-ar.exe"
$readelf = Join-Path $bin "loongarch64-unknown-linux-gnu-readelf.exe"

foreach ($path in @($gn, $ninja, $gcc, $gxx, $ar, $readelf, $sysroot)) {
    if (-not (Test-Path $path)) {
        throw "Missing required path: $path"
    }
}

$pythonShim = Ensure-Python3Shim -ShimDir (Join-Path $Root "tools\python-shim")
$env:PATH = "$(Split-Path $pythonShim -Parent);$env:PATH"

$sysrootGn = Convert-ToGnPath $sysroot
$gccGn = Convert-ToGnPath $gcc
$gxxGn = Convert-ToGnPath $gxx
$arGn = Convert-ToGnPath $ar
$skiaMap = Convert-ToGnPath (Join-Path $SkiaSharpRoot "native\linux\libSkiaSharp\libSkiaSharp.map")
$harfbuzzMap = Convert-ToGnPath (Join-Path $SkiaSharpRoot "native\linux\libHarfBuzzSharp\libHarfBuzzSharp.map")

$skiaOut = Join-Path $skia "out\oldworld-loong64-skiasharp"
$harfbuzzOut = Join-Path $skia "out\oldworld-loong64-harfbuzz"

Write-GnArgs -OutDir $skiaOut -Sysroot $sysrootGn -Gcc $gccGn -Gxx $gxxGn -Ar $arGn -Map $skiaMap -Soname "119.0.0" -Target SkiaSharp
Write-GnArgs -OutDir $harfbuzzOut -Sysroot $sysrootGn -Gcc $gccGn -Gxx $gxxGn -Ar $arGn -Map $harfbuzzMap -Soname "0.60831.0" -Target HarfBuzzSharp

Push-Location $skia
try {
    Invoke-Checked { & $gn gen "out/oldworld-loong64-skiasharp" }
    Invoke-Checked { & $gn gen "out/oldworld-loong64-harfbuzz" }
    if (-not $SkipBuild) {
        Invoke-Checked { & $ninja -C "out/oldworld-loong64-skiasharp" "SkiaSharp" -j $Jobs -k 1 }
        Invoke-Checked { & $ninja -C "out/oldworld-loong64-harfbuzz" "HarfBuzzSharp" -j $Jobs -k 1 }
    }
} finally {
    Pop-Location
}

$skiaSo = Join-Path $skiaOut "libSkiaSharp.so.119.0.0"
$harfbuzzSo = Join-Path $harfbuzzOut "libHarfBuzzSharp.so.0.60831.0"
foreach ($so in @($skiaSo, $harfbuzzSo)) {
    if (-not (Test-Path $so)) {
        throw "Missing output: $so"
    }
    Assert-LoongArchOldWorldElf -ReadElf $readelf -SoPath $so
    Assert-GlibcMax -ReadElf $readelf -SoPath $so -Max $MaxGlibc | Out-Null
}

New-Item -ItemType Directory -Force -Path $NativeAssetsDir | Out-Null
Copy-Item -Force $skiaSo (Join-Path $NativeAssetsDir "libSkiaSharp.so")
Copy-Item -Force $harfbuzzSo (Join-Path $NativeAssetsDir "libHarfBuzzSharp.so")
Copy-Item -Force $skiaSo (Join-Path $NativeAssetsDir "libSkiaSharp.so.119.0.0")
Copy-Item -Force $harfbuzzSo (Join-Path $NativeAssetsDir "libHarfBuzzSharp.so.0.60831.0")

$skiaCommit = (& git -C $SkiaSharpRoot rev-parse HEAD).Trim()
$skiaStatus = (& git -C $SkiaSharpRoot status --short) -join "`n"
$hashes = Get-FileHash -Algorithm SHA256 (Join-Path $NativeAssetsDir "libSkiaSharp.so"), (Join-Path $NativeAssetsDir "libHarfBuzzSharp.so")
$skiaVersions = Get-VersionTokens -ReadElf $readelf -SoPath $skiaSo
$harfbuzzVersions = Get-VersionTokens -ReadElf $readelf -SoPath $harfbuzzSo

$manifest = @"
LoongArch old-world ABI1.0 native library build
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")

Source:
  SkiaSharp root: $SkiaSharpRoot
  SkiaSharp commit: $skiaCommit
  SkiaSharp status:
$skiaStatus

Toolchain:
  Root: $ToolchainRoot
  Target: loongarch64-unknown-linux-gnu oldworld
  GCC: $(& $gcc --version | Select-Object -First 1)
  Sysroot: $sysroot

GN feature intent:
  target_os=linux
  target_cpu=loong64
  skia_enable_ganesh=true
  skia_use_gl=true
  skia_use_x11=true
  skia_use_vulkan=true
  skia_use_fontconfig=true
  skia_use_freetype=true
  skia_enable_skottie=true
  bundled codecs: expat/freetype/libjpeg-turbo/libpng/libwebp/zlib
  libstdc++/libgcc: static linked

Outputs:
$($hashes | ForEach-Object { "  $($_.Hash)  $($_.Path)" } | Out-String)
ABI checks:
  libSkiaSharp.so: LoongArch LP64, max GLIBC <= $MaxGlibc, versions: $($skiaVersions -join ", ")
  libHarfBuzzSharp.so: LoongArch LP64, max GLIBC <= $MaxGlibc, versions: $($harfbuzzVersions -join ", ")

Build directories:
  $skiaOut
  $harfbuzzOut
"@

Set-Content -Encoding UTF8 -Path (Join-Path $NativeAssetsDir "native-build-manifest.txt") -Value $manifest
Write-Host "Native libraries copied to $NativeAssetsDir"
