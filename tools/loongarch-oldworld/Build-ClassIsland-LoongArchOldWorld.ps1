[CmdletBinding()]
param(
    [string[]]$Branches = @("develop/v2/misha-alpha", "develop/v2/misha-alpha-ci"),
    [string]$RepoUrl = "https://github.com/ClassIsland/ClassIsland.git",
    [ValidateSet("archive", "auto", "git")]
    [string]$SourceMode = "archive",
    [string]$OutDir,
    [string]$ApiSigningKey = $env:API_SIGNING_KEY,
    [string]$ApiSigningKeyPassPhrase = $env:API_SIGNING_KEY_PS,
    [string]$AvaloniaVersion = "12.0.4",
    [string]$AppVersion = "2.0.0.0",
    [string]$AssemblyVersion,
    [string]$PackageLabel,
    [string]$SkiaSharpNativeAssetsVersionOverride,
    [string]$HarfBuzzSharpNativeAssetsVersionOverride,
    [string]$NativeAssetsDir,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [switch]$RequireGptSovitsSigningKey
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $OutDir) {
    $OutDir = Join-Path $Root "artifacts\loongarch-oldworld\out"
}

$BuildRoot = Join-Path $Root "artifacts\loongarch-oldworld\build\ClassIsland"
$RuntimeDir = Join-Path $BuildRoot "Loongnix-DotNet10"
$NuGetCacheDir = Join-Path $BuildRoot "nuget-packages"
if (-not $NativeAssetsDir) {
    $NativeAssetsDir = Join-Path $PSScriptRoot "native\linux-loongarch64\oldworld"
}
$TargetRid = "linux-loongarch64"

$LoongnixDotNetRelease = "https://ftp.loongnix.cn/dotnet/10.0.5/10.0.5-1/pkg"
$DotnetRuntimeArchive = "dotnet-runtime-10.0.5-linux-loongarch64.tar.gz"
$AspnetRuntimeArchive = "aspnetcore-runtime-10.0.5-linux-loongarch64.tar.gz"
$ExpectedDotNetMajor = "10"
$ExpectedDotNetFrameworkVersion = "10.0.0"
$ExpectedBundledDotNetRuntimeVersion = "10.0.5"

New-Item -ItemType Directory -Force -Path $BuildRoot, $RuntimeDir, $NuGetCacheDir, $OutDir | Out-Null
$env:NUGET_PACKAGES = $NuGetCacheDir
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

if ([string]::IsNullOrWhiteSpace($ApiSigningKey) -or [string]::IsNullOrWhiteSpace($ApiSigningKeyPassPhrase)) {
    if ($RequireGptSovitsSigningKey) {
        throw "API_SIGNING_KEY and API_SIGNING_KEY_PS are required when -RequireGptSovitsSigningKey is used."
    }
    Write-Warning "API_SIGNING_KEY/API_SIGNING_KEY_PS are not set. The package will disable signed internal GPT-SoVITS presets only."
}

function Get-NumericAssemblyVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    if ($Version -match '^(?<major>\d+)(?:\.(?<minor>\d+))?(?:\.(?<build>\d+))?(?:\.(?<revision>\d+))?$') {
        $Parts = @(
            $Matches.major,
            $(if ($Matches.minor) { $Matches.minor } else { "0" }),
            $(if ($Matches.build) { $Matches.build } else { "0" }),
            $(if ($Matches.revision) { $Matches.revision } else { "0" })
        )
        return ($Parts -join ".")
    }

    return "2.0.0.0"
}

if ([string]::IsNullOrWhiteSpace($AssemblyVersion)) {
    $AssemblyVersion = Get-NumericAssemblyVersion -Version $AppVersion
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE"
    }
}

function Save-Download {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Part = "$Path.part"
    Remove-Item -LiteralPath $Part -Force -ErrorAction SilentlyContinue
    curl.exe --fail --silent --show-error --location --ipv4 --retry 8 --retry-all-errors --retry-delay 2 --connect-timeout 30 --max-time 600 --ssl-no-revoke --output $Part $Uri
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Uri with code $LASTEXITCODE"
    }
    Move-Item -LiteralPath $Part -Destination $Path -Force
}

function Ensure-Download {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        Save-Download -Uri $Uri -Path $Path
    }
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Args = @(
        "--fail", "--silent", "--show-error", "--location", "--ipv4",
        "--retry", "8", "--retry-all-errors", "--retry-delay", "2",
        "--connect-timeout", "30", "--max-time", "120", "--ssl-no-revoke",
        "-H", "X-GitHub-Api-Version: 2022-11-28"
    )
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $Args += @("-H", "Authorization: Bearer $GitHubToken")
    }
    $Args += $Uri

    $Json = curl.exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API request failed for $Uri with code $LASTEXITCODE"
    }

    return $Json | ConvertFrom-Json
}

function Set-TextIfChanged {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    if ((Test-Path -LiteralPath $Path) -and (Read-Utf8Text -Path $Path) -eq $Content) {
        return
    }

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-Utf8Text {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-GitHubRepoPath {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl
    )

    if ($RepoUrl -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    throw "Only GitHub repository URLs are supported by the curl archive fallback: $RepoUrl"
}

function Get-GitHubBranchCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [Parameter(Mandatory)]
        [string]$Branch
    )

    $Refs = Invoke-GitHubApi -Uri "https://api.github.com/repos/$RepoPath/git/matching-refs/heads/$Branch"
    $Match = @($Refs | Where-Object { $_.ref -eq "refs/heads/$Branch" } | Select-Object -First 1)
    if (-not $Match) {
        throw "Could not resolve branch $Branch in $RepoPath."
    }

    return [string]$Match.object.sha
}

function Expand-GitHubArchive {
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$TargetDir
    )

    $ExtractDir = "$TargetDir.extract"
    Remove-Item -LiteralPath $TargetDir, $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir -Force

    $RootDir = Get-ChildItem -LiteralPath $ExtractDir -Directory | Select-Object -First 1
    if (-not $RootDir) {
        throw "Archive $ArchivePath did not contain a source root."
    }

    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Get-ChildItem -LiteralPath $RootDir.FullName -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $TargetDir -Force
    }
    Remove-Item -LiteralPath $ExtractDir -Recurse -Force
}

function Install-EdgeTtsSharpArchive {
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [Parameter(Mandatory)]
        [string]$Commit,

        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string]$CacheDir
    )

    $Tree = Invoke-GitHubApi -Uri "https://api.github.com/repos/$RepoPath/git/trees/$Commit`?recursive=1"
    $Submodule = @($Tree.tree | Where-Object { $_.path -eq "vendors/EdgeTtsSharp" -and $_.type -eq "commit" } | Select-Object -First 1)
    if (-not $Submodule) {
        throw "Could not resolve vendors/EdgeTtsSharp submodule for $RepoPath@$Commit."
    }

    $SubmoduleCommit = [string]$Submodule.sha
    $ArchivePath = Join-Path $CacheDir "EdgeTtsSharp-$SubmoduleCommit.zip"
    Ensure-Download -Uri "https://codeload.github.com/ClassIsland/EdgeTtsSharp/zip/$SubmoduleCommit" -Path $ArchivePath
    Expand-GitHubArchive -ArchivePath $ArchivePath -TargetDir (Join-Path $RepoDir "vendors\EdgeTtsSharp")
}

function Install-GitHubArchiveSource {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string]$CacheDir
    )

    $RepoPath = Get-GitHubRepoPath -RepoUrl $RepoUrl
    $Commit = Get-GitHubBranchCommit -RepoPath $RepoPath -Branch $Branch
    $ArchivePath = Join-Path $CacheDir "ClassIsland-$($Branch -replace '[^A-Za-z0-9._-]+','-')-$Commit.zip"
    Ensure-Download -Uri "https://codeload.github.com/$RepoPath/zip/$Commit" -Path $ArchivePath
    Expand-GitHubArchive -ArchivePath $ArchivePath -TargetDir $RepoDir
    Install-EdgeTtsSharpArchive -RepoPath $RepoPath -Commit $Commit -RepoDir $RepoDir -CacheDir $CacheDir
    return $Commit
}

function Try-PrepareGitSource {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    try {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) {
            Remove-Item -LiteralPath $RepoDir -Recurse -Force -ErrorAction SilentlyContinue
            $null = Invoke-Native git clone $RepoUrl $RepoDir
        }

        $null = Invoke-Native git -C $RepoDir fetch --all --tags --prune
        $null = Invoke-Native git -C $RepoDir checkout --force $Branch
        $Commit = (& git -C $RepoDir rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not resolve HEAD for $Branch."
        }

        $null = Invoke-Native git -C $RepoDir config url.https://github.com/.insteadOf git@github.com:
        $null = Invoke-Native git -C $RepoDir config -f .gitmodules submodule.vendors/EdgeTtsSharp.url https://github.com/ClassIsland/EdgeTtsSharp.git
        $null = Invoke-Native git -C $RepoDir submodule sync --recursive -- vendors/EdgeTtsSharp
        $null = Invoke-Native git -C $RepoDir submodule update --init --recursive -- vendors/EdgeTtsSharp
        return $Commit
    }
    catch {
        Write-Warning "Git source preparation failed for $Branch; falling back to GitHub zip archive. $($_.Exception.Message)"
        return $null
    }
}

function Patch-EdgeTtsSharp {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $ProjectPath = Join-Path $RepoDir "vendors\EdgeTtsSharp\Edge_tts_sharp\Edge_tts_sharp.csproj"
    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        return
    }

    $Text = Read-Utf8Text -Path $ProjectPath
    $Text = $Text -replace "(?m)(<!--[^\r\n]*?)\?->", '$1-->'
    $Text = $Text -replace "<LangVersion>13</LangVersion>", "<LangVersion>preview</LangVersion>"
    $Text = $Text -replace "<LangVersion>latest</LangVersion>", "<LangVersion>preview</LangVersion>"
    Set-TextIfChanged -Path $ProjectPath -Content $Text
}

function Replace-RequiredLiteral {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Search,

        [Parameter(Mandatory)]
        [string]$Replacement,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $Text = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $Search = $Search -replace "`r`n", "`n" -replace "`r", "`n"
    $Replacement = $Replacement -replace "`r`n", "`n" -replace "`r", "`n"

    if (-not $Text.Contains($Search)) {
        throw "Could not patch $Description. Upstream ClassIsland source may have changed."
    }

    return $Text.Replace($Search, $Replacement)
}

function Patch-ClassIslandAssemblyInfo {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string]$InfoVersion,

        [Parameter(Mandatory)]
        [string]$AssemblyVersion
    )

    $AssemblyInfoPath = Join-Path $RepoDir "AssemblyInfo.cs"
    $Text = (Read-Utf8Text -Path $AssemblyInfoPath) -replace "`r`n", "`n"
    if ($Text -match [regex]::Escape($InfoVersion)) {
        return
    }

    $Pattern = '(?s)#if NIX\s*(?:\[assembly: AssemblyVersion\("[^"]*"\)\]\s*)?(?:\[assembly: AssemblyFileVersion\("[^"]*"\)\]\s*)?\[assembly: AssemblyInformationalVersion\("[^"]*"\)\]\s*#else'
    $Replacement = @"
#if NIX
[assembly: AssemblyVersion("$AssemblyVersion")]
[assembly: AssemblyFileVersion("$AssemblyVersion")]
[assembly: AssemblyInformationalVersion("$InfoVersion")]
#else
"@

    if ($Text -notmatch $Pattern) {
        throw "Could not patch AssemblyInfo.cs NIX version block. Upstream ClassIsland source may have changed."
    }

    $Text = [regex]::Replace($Text, $Pattern, { param($m) $Replacement }, 1)
    Set-TextIfChanged -Path $AssemblyInfoPath -Content $Text
}

function Patch-ClassIslandRestartLogic {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $AppCode = Join-Path $RepoDir "ClassIsland\App.axaml.cs"
    $Text = (Read-Utf8Text -Path $AppCode) -replace "`r`n", "`n"
    if ($Text -match "var restartTarget = restartToLauncher \? ExecutingEntrance : replaced;") {
        return
    }

    $Search = @'
        var replaced = path.Replace(".dll", PlatformExecutableExtension);
        var startInfo = new ProcessStartInfo(restartToLauncher ? ExecutingEntrance : replaced);
        foreach (var i in parameters)
        {
            startInfo.ArgumentList.Add(i);
        }
        Process.Start(startInfo);
'@
    $Replacement = @'
        var replaced = path.Replace(".dll", PlatformExecutableExtension);
        var restartTarget = restartToLauncher ? ExecutingEntrance : replaced;
        var startInfo = new ProcessStartInfo(restartTarget);
        if (string.Equals(Path.GetFileNameWithoutExtension(restartTarget), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            var appDir = Path.GetDirectoryName(path) ?? Environment.CurrentDirectory;
            startInfo.WorkingDirectory = appDir;
            startInfo.ArgumentList.Add(Path.Combine(appDir, "ClassIsland.Desktop.dll"));
        }
        foreach (var i in parameters)
        {
            startInfo.ArgumentList.Add(i);
        }
        Process.Start(startInfo);
'@

    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "ClassIsland Linux restart logic"
    Set-TextIfChanged -Path $AppCode -Content $Text
}

function Patch-ClassIslandAudioService {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $AudioServicePath = Join-Path $RepoDir "ClassIsland\Services\AudioService.cs"
    $Text = (Read-Utf8Text -Path $AudioServicePath) -replace "`r`n", "`n"
    if ($Text -match "FindSystemPlayer") {
        return
    }

    if ($Text -notmatch "using System\.Diagnostics;") {
        $Text = Replace-RequiredLiteral -Text $Text -Search "using System;`n" -Replacement "using System;`nusing System.Diagnostics;`n" -Description "AudioService diagnostics using"
    }
    if ($Text -notmatch "using System\.Runtime\.InteropServices;") {
        $Text = Replace-RequiredLiteral -Text $Text -Search "using System.Linq;`n" -Replacement "using System.Linq;`nusing System.Runtime.InteropServices;`n" -Description "AudioService runtime using"
    }

    $Text = Replace-RequiredLiteral -Text $Text `
        -Search "    private readonly AudioEngine _audioEngine = Task.Run((() => new MiniAudioEngine())).Result;`n" `
        -Replacement "    private readonly AudioEngine? _audioEngine = InitAudioEngine();`n" `
        -Description "AudioService MiniAudio initialization"

    $Search = @'
    private object _audioPlaybackDeviceInitializeLock = new();

'@
    $Replacement = @'
    private object _audioPlaybackDeviceInitializeLock = new();

    private static AudioEngine? InitAudioEngine()
    {
        try
        {
            return Task.Run(() => new MiniAudioEngine()).Result;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[AudioService] MiniAudio init failed; system-player fallback enabled: {ex.InnerException?.Message ?? ex.Message}");
            return null;
        }
    }

    private static string? FindSystemPlayer()
    {
        foreach (var player in new[] { "ffplay", "paplay", "aplay" })
        {
            try
            {
                using var process = Process.Start(new ProcessStartInfo
                {
                    FileName = "which",
                    Arguments = player,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                process?.WaitForExit(1000);
                if (process?.ExitCode == 0)
                {
                    return player;
                }
            }
            catch
            {
            }
        }

        return null;
    }

'@
    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "AudioService system-player helpers"

    $Search = @'
            return _audioEngine;
'@
    $Replacement = @'
            if (_audioEngine == null)
            {
                throw new PlatformNotSupportedException("MiniAudio is not available on this platform.");
            }

            return _audioEngine;
'@
    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "AudioService nullable engine guard"

    $Search = @'
        try
        {
            var deviceInfo = AudioEngine.PlaybackDevices.FirstOrDefault(x => x.IsDefault);
'@
    $Replacement = @'
        try
        {
            if (_audioEngine == null)
            {
                return null;
            }

            var deviceInfo = AudioEngine.PlaybackDevices.FirstOrDefault(x => x.IsDefault);
'@
    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "AudioService playback device fallback"

    $Search = @'
        using var audioStream = audio;
        cancellationToken ??= CancellationToken.None;
        using var lease = await TryInitializeDefaultPlaybackDeviceSafeAsync();
        if (lease == null)
        {
            return;
        }
'@
    $Replacement = @'
        using var audioStream = audio;
        cancellationToken ??= CancellationToken.None;
        using var lease = await TryInitializeDefaultPlaybackDeviceSafeAsync();
        if (lease == null)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                await PlayStreamViaSystemAsync(audioStream, volume, cancellationToken.Value);
            }

            return;
        }
'@
    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "AudioService stream fallback"

    $Search = @'
    public async Task PlayAudioAsync(string filePath, float volume, CancellationToken? cancellationToken = null)
    {
        using var audio = File.OpenRead(filePath);
        await PlayAudioAsync(audio, volume, cancellationToken);
    }

'@
    $Replacement = @'
    private async Task PlayStreamViaSystemAsync(Stream audio, float volume, CancellationToken cancellationToken)
    {
        var playerName = FindSystemPlayer();
        if (playerName == null)
        {
            Logger.LogWarning("No Linux system audio player found; install ffplay, paplay, or aplay.");
            return;
        }

        var tempFile = Path.Combine(Path.GetTempPath(), $"ci_audio_{Guid.NewGuid():N}.wav");
        try
        {
            await using (var fs = File.Create(tempFile))
            {
                await audio.CopyToAsync(fs, cancellationToken);
            }

            await RunPlayerAsync(playerName, tempFile, volume, cancellationToken);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Logger.LogWarning(ex, "Linux system audio playback failed.");
        }
        finally
        {
            try
            {
                File.Delete(tempFile);
            }
            catch
            {
            }
        }
    }

    public async Task PlayAudioAsync(string filePath, float volume, CancellationToken? cancellationToken = null)
    {
        cancellationToken ??= CancellationToken.None;
        if (_audioEngine == null && !RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var playerName = FindSystemPlayer();
            if (playerName == null)
            {
                Logger.LogWarning("No Linux system audio player found; install ffplay, paplay, or aplay.");
                return;
            }

            await RunPlayerAsync(playerName, filePath, volume, cancellationToken.Value);
            return;
        }

        using var audio = File.OpenRead(filePath);
        await PlayAudioAsync(audio, volume, cancellationToken);
    }

    private async Task RunPlayerAsync(string playerName, string filePath, float volume, CancellationToken cancellationToken)
    {
        var escapedPath = filePath.Replace("\"", "\\\"");
        var args = playerName switch
        {
            "ffplay" => $"-nodisp -autoexit -volume {Math.Clamp((int)Math.Round(volume * 100), 0, 100)} \"{escapedPath}\"",
            "paplay" => $"--volume {Math.Clamp((int)Math.Round(volume * 65536), 0, 65536)} \"{escapedPath}\"",
            _ => $"\"{escapedPath}\""
        };

        Logger.LogDebug("Using {Player} for Linux audio playback: {File}", playerName, filePath);

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = playerName,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        });
        if (process != null)
        {
            await process.WaitForExitAsync(cancellationToken);
        }
    }

'@
    $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "AudioService system-player playback"

    $Text = Replace-RequiredLiteral -Text $Text `
        -Search "        AudioEngine.Dispose();`n" `
        -Replacement "        _audioEngine?.Dispose();`n" `
        -Description "AudioService nullable dispose"

    Set-TextIfChanged -Path $AudioServicePath -Content $Text
}

function Patch-ClassIslandAvaloniaVersion {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string]$Version
    )

    $PropsPath = Join-Path $RepoDir "AvaloniaShared.props"
    $Text = Read-Utf8Text -Path $PropsPath
    if ($Text -notmatch "<AvaloniaVersion>[^<]+</AvaloniaVersion>") {
        throw "Could not patch AvaloniaShared.props. Upstream ClassIsland source may have changed."
    }

    $Text = [regex]::Replace($Text, "<AvaloniaVersion>[^<]+</AvaloniaVersion>", "<AvaloniaVersion>$Version</AvaloniaVersion>", 1)
    Set-TextIfChanged -Path $PropsPath -Content $Text
}

function Patch-ClassIslandNativeAssetOverrides {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $Overrides = @()
    if (-not [string]::IsNullOrWhiteSpace($SkiaSharpNativeAssetsVersionOverride)) {
        $Overrides += "        <PackageReference Include=`"SkiaSharp.NativeAssets.Linux`" Version=`"$SkiaSharpNativeAssetsVersionOverride`" />"
    }
    if (-not [string]::IsNullOrWhiteSpace($HarfBuzzSharpNativeAssetsVersionOverride)) {
        $Overrides += "        <PackageReference Include=`"HarfBuzzSharp.NativeAssets.Linux`" Version=`"$HarfBuzzSharpNativeAssetsVersionOverride`" />"
    }
    if (-not $Overrides) {
        return
    }

    $ProjectPath = Join-Path $RepoDir "ClassIsland.Desktop\ClassIsland.Desktop.csproj"
    $Text = (Read-Utf8Text -Path $ProjectPath) -replace "`r`n", "`n"
    $Block = @"
    <ItemGroup Condition="'`$(ClassIsland_PlatformTarget)'=='loongarch64'" Label="ClassIsland_LoongArchNativeAssetOverrides">
$($Overrides -join "`n")
    </ItemGroup>

"@

    $Pattern = '(?s)\s*<ItemGroup[^>]*Label="ClassIsland_LoongArchNativeAssetOverrides"[^>]*>.*?</ItemGroup>\s*'
    if ($Text -match $Pattern) {
        $Text = [regex]::Replace($Text, $Pattern, "`n$Block", 1)
    } else {
        $Text = Replace-RequiredLiteral -Text $Text -Search "    <Import Project=`"../Global.props`"/>`n" -Replacement "$Block    <Import Project=`"../Global.props`"/>`n" -Description "ClassIsland native asset overrides"
    }

    Set-TextIfChanged -Path $ProjectPath -Content $Text
}

function Patch-ClassIslandLinuxX11Stability {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $ProgramPath = Join-Path $RepoDir "ClassIsland.Desktop\Program.cs"
    $ProgramText = (Read-Utf8Text -Path $ProgramPath) -replace "`r`n", "`n"

    if ($ProgramText -notmatch "ConfigureLinuxX11Environment") {
        $ProgramText = Replace-RequiredLiteral -Text $ProgramText `
            -Search "#endif`n        var stopTokenSource = new CancellationTokenSource();`n" `
            -Replacement "#endif`n#if Platforms_Linux`n        ConfigureLinuxX11Environment();`n#endif`n        var stopTokenSource = new CancellationTokenSource();`n" `
            -Description "Linux X11 process environment setup"

        $ProgramText = Replace-RequiredLiteral -Text $ProgramText `
            -Search "            })`n#if DEBUG`n" `
            -Replacement "            })`n#if Platforms_Linux`n            .With(BuildX11PlatformOptions())`n#endif`n#if DEBUG`n" `
            -Description "Linux X11 platform options"

        $Search = @'
#endif
    }

    private static IReadOnlyList<Win32RenderingMode> BuildRenderingMode(int userValue)
'@
        $Replacement = @'
#endif
    }

#if Platforms_Linux
    private static void ConfigureLinuxX11Environment()
    {
        if (!ShouldEnableLinuxIme())
        {
            Environment.SetEnvironmentVariable("XMODIFIERS", "@im=none");
            Environment.SetEnvironmentVariable("GTK_IM_MODULE", "xim");
            Environment.SetEnvironmentVariable("QT_IM_MODULE", "xim");
        }
    }

    private static X11PlatformOptions BuildX11PlatformOptions()
    {
        return new X11PlatformOptions
        {
            RenderingMode = BuildX11RenderingMode(),
            EnableIme = ShouldEnableLinuxIme(),
            UseRetainedFramebuffer = ShouldUseRetainedFramebuffer()
        };
    }

    private static IReadOnlyList<X11RenderingMode> BuildX11RenderingMode()
    {
        var requested = Environment.GetEnvironmentVariable("CLASSISLAND_X11_RENDERING")
                        ?? Environment.GetEnvironmentVariable("CLASSISLAND_X11_RENDERING_MODE");

        return NormalizeSwitch(requested) switch
        {
            "auto" => [X11RenderingMode.Glx, X11RenderingMode.Software],
            "glx" => [X11RenderingMode.Glx, X11RenderingMode.Software],
            "egl" => [X11RenderingMode.Egl, X11RenderingMode.Software],
            "vulkan" => [X11RenderingMode.Vulkan, X11RenderingMode.Software],
            "software" => [X11RenderingMode.Software],
            _ when IsLoongArch64() => [X11RenderingMode.Software],
            _ => [X11RenderingMode.Glx, X11RenderingMode.Software]
        };
    }

    private static bool ShouldUseRetainedFramebuffer()
    {
        var requested = Environment.GetEnvironmentVariable("CLASSISLAND_X11_RETAINED_FRAMEBUFFER");
        return ParseBooleanSwitch(requested) ?? IsLoongArch64();
    }

    private static bool ShouldEnableLinuxIme()
    {
        var requested = Environment.GetEnvironmentVariable("CLASSISLAND_X11_ENABLE_IME");
        return ParseBooleanSwitch(requested) ?? !IsLoongArch64();
    }

    private static bool IsLoongArch64()
    {
        return string.Equals(RuntimeInformation.OSArchitecture.ToString(), "LoongArch64", StringComparison.OrdinalIgnoreCase)
               || string.Equals(RuntimeInformation.ProcessArchitecture.ToString(), "LoongArch64", StringComparison.OrdinalIgnoreCase);
    }

    private static bool? ParseBooleanSwitch(string? value)
    {
        return NormalizeSwitch(value) switch
        {
            "1" or "true" or "yes" or "on" or "enable" or "enabled" => true,
            "0" or "false" or "no" or "off" or "disable" or "disabled" => false,
            _ => null
        };
    }

    private static string NormalizeSwitch(string? value)
    {
        return value?.Trim().ToLowerInvariant() ?? "";
    }

#endif

    private static IReadOnlyList<Win32RenderingMode> BuildRenderingMode(int userValue)
'@
        $ProgramText = Replace-RequiredLiteral -Text $ProgramText -Search $Search -Replacement $Replacement -Description "Linux X11 software rendering helpers"
        Set-TextIfChanged -Path $ProgramPath -Content $ProgramText
    }

    $WindowPlatformServicePath = Join-Path $RepoDir "platforms\ClassIsland.Platforms.Linux\Services\WindowPlatformService.cs"
    $Text = (Read-Utf8Text -Path $WindowPlatformServicePath) -replace "`r`n", "`n"

    if ($Text -notmatch "actualFormat != 32") {
        $Search = @'
                var winId = Marshal.ReadIntPtr(propPtr);
                XFree(propPtr);
'@
        $Replacement = @'
                if (result != 0 || propPtr == IntPtr.Zero || nitems == 0 || actualFormat != 32)
                {
                    if (propPtr != IntPtr.Zero)
                    {
                        XFree(propPtr);
                    }
                    continue;
                }

                var winId = Marshal.ReadIntPtr(propPtr);
                XFree(propPtr);
'@
        $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "Linux _NET_ACTIVE_WINDOW XGetWindowProperty guard"
    }

    if ($Text -notmatch "LoongArch old-world topmost") {
        $Search = @'
                XUnmapWindow(_display, handle);
                XChangeWindowAttributes(_display, handle, CWOverrideRedirect, ref attributes);
                Dispatcher.UIThread.InvokeAsync(() =>
                {
                    XMapWindow(_display, handle);
                    XFlush(_display);
                });
'@
        $Replacement = @'
                XUnmapWindow(_display, handle);
                XChangeWindowAttributes(_display, handle, CWOverrideRedirect, ref attributes);
                XMapWindow(_display, handle);
                if (state)
                {
                    // LoongArch old-world topmost relies on override_redirect.
                    // Re-assert ABOVE after remap so Avalonia 12/X11 does not lose stacking.
                    ChangeWMAtoms(handle, true, XInternAtom(_display, "_NET_WM_STATE_ABOVE", true));
                    XRaiseWindow(_display, handle);
                }
                XFlush(_display);
'@
        $Text = Replace-RequiredLiteral -Text $Text -Search $Search -Replacement $Replacement -Description "Linux LoongArch X11 topmost remap"
    }

    Set-TextIfChanged -Path $WindowPlatformServicePath -Content $Text

    $XExtensionsPath = Join-Path $RepoDir "platforms\ClassIsland.Platforms.Linux\XExtensions.cs"
    $XExtensions = @'
using System.Runtime.InteropServices;
using Avalonia.Controls;
using static ClassIsland.Platforms.Linux.X;

namespace ClassIsland.Platforms.Linux;

public static class XExtensions
{
    private static IntPtr _atomNetWmState;
    private static IntPtr _atomNetWmStateMaximizedVert;
    private static IntPtr _atomNetWmStateMaximizedHorz;
    private static IntPtr _atomNetWmStateHidden;
    private static IntPtr _atomNetWmStateFullscreen;

    private static nint _display;

    public static void Init(nint display)
    {
        _display = display;
        _atomNetWmState = XInternAtom(display, "_NET_WM_STATE", false);
        _atomNetWmStateMaximizedVert = XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_VERT", false);
        _atomNetWmStateMaximizedHorz = XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_HORZ", false);
        _atomNetWmStateHidden = XInternAtom(display, "_NET_WM_STATE_HIDDEN", false);
        _atomNetWmStateFullscreen = XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", false);
    }

    public static WindowState GetWindowState(IntPtr window)
    {
        var maxVert = false;
        var maxHorz = false;
        var minimized = false;
        var fullscreen = false;
        IntPtr prop = IntPtr.Zero;

        try
        {
            var result = XGetWindowProperty(
                _display, window, _atomNetWmState,
                0, 1024, false, IntPtr.Zero,
                out _, out var actualFormat,
                out var nitems, out _, out prop);

            if (result != 0 || prop == IntPtr.Zero || nitems == 0 || actualFormat != 32)
            {
                return WindowState.Normal;
            }

            var atoms = new IntPtr[(int)nitems];
            Marshal.Copy(prop, atoms, 0, (int)nitems);

            foreach (var atom in atoms)
            {
                if (atom == _atomNetWmStateMaximizedVert)
                {
                    maxVert = true;
                }
                else if (atom == _atomNetWmStateMaximizedHorz)
                {
                    maxHorz = true;
                }
                else if (atom == _atomNetWmStateHidden)
                {
                    minimized = true;
                }
                else if (atom == _atomNetWmStateFullscreen)
                {
                    fullscreen = true;
                }
            }
        }
        finally
        {
            if (prop != IntPtr.Zero)
            {
                XFree(prop);
            }
        }

        if (maxHorz && maxVert)
        {
            return WindowState.Maximized;
        }

        if (fullscreen)
        {
            return WindowState.FullScreen;
        }

        if (minimized)
        {
            return WindowState.Minimized;
        }

        return WindowState.Normal;
    }
}
'@
    Set-TextIfChanged -Path $XExtensionsPath -Content $XExtensions
}

function Get-ClassIslandDependencyVersion {
    param(
        [Parameter(Mandatory)]
        [object]$DepsJson,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    $Prefix = "$PackageId/"
    $Matches = @($DepsJson.libraries.PSObject.Properties | Where-Object {
        $_.Name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($Matches.Count -ne 1) {
        throw "Native asset verification failed; expected one dependency for $PackageId, found $($Matches.Count)."
    }

    return $Matches[0].Name.Substring($Prefix.Length)
}

function Get-LoongArchElfInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x7f -or $Bytes[1] -ne 0x45 -or $Bytes[2] -ne 0x4c -or $Bytes[3] -ne 0x46) {
        throw "Native asset verification failed; $Path is not an ELF file."
    }
    if ($Bytes[4] -ne 2 -or $Bytes[5] -ne 1) {
        throw "Native asset verification failed; $Path is not a 64-bit little-endian ELF file."
    }

    $Machine = [BitConverter]::ToUInt16($Bytes, 18)
    $Flags = [BitConverter]::ToUInt32($Bytes, 48)
    $FloatAbi = switch ($Flags -band 0x7) {
        1 { "soft-float" }
        2 { "single-float" }
        3 { "double-float" }
        default { "unknown" }
    }
    $ObjAbi = if (($Flags -band 0x40) -ne 0) { "objabi-v1" } else { "objabi-unspecified" }

    if ($Machine -ne 0x102) {
        throw "Native asset verification failed; $Path machine is 0x$($Machine.ToString("X4")), expected LoongArch 0x0102."
    }
    if (($Flags -band 0x7) -ne 3) {
        throw "Native asset verification failed; $Path is $FloatAbi, expected double-float lp64d."
    }

    return [pscustomobject]@{
        Machine = ('0x{0:X4}' -f $Machine)
        Flags = ('0x{0:X8}' -f $Flags)
        FloatAbi = $FloatAbi
        ObjectAbi = $ObjAbi
    }
}

function Get-NativeSymbolVersionInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Path))
    $GlibcVersions = [regex]::Matches($Text, 'GLIBC_(\d+(?:\.\d+)+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    $GlibcxxVersions = [regex]::Matches($Text, 'GLIBCXX_(\d+(?:\.\d+)+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    $CxxAbiVersions = [regex]::Matches($Text, 'CXXABI_(\d+(?:\.\d+)+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique

    $MaxGlibc = $null
    foreach ($Version in $GlibcVersions) {
        $Parsed = [System.Version]$Version
        if ($null -eq $MaxGlibc -or $Parsed -gt $MaxGlibc) {
            $MaxGlibc = $Parsed
        }
    }

    if ($MaxGlibc -and $MaxGlibc -gt ([System.Version]"2.28")) {
        throw "Native asset verification failed; $Path requires GLIBC_$MaxGlibc, expected GLIBC_2.28 or older for Loongnix old-world ABI1."
    }

    return [pscustomobject]@{
        GlibcVersions = @($GlibcVersions)
        GlibcxxVersions = @($GlibcxxVersions)
        CxxAbiVersions = @($CxxAbiVersions)
        MaxGlibc = if ($MaxGlibc) { $MaxGlibc.ToString() } else { "" }
    }
}

function Install-ClassIslandNativeAssets {
    param(
        [Parameter(Mandatory)]
        [string]$PackageWork,

        [Parameter(Mandatory)]
        [string]$AppDir,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Commit
    )

    $DepsPath = Join-Path $AppDir "ClassIsland.Desktop.deps.json"
    if (-not (Test-Path -LiteralPath $DepsPath)) {
        throw "Native asset verification failed; missing $DepsPath"
    }

    $DepsJson = Read-Utf8Text -Path $DepsPath | ConvertFrom-Json
    $NativeOut = Join-Path $AppDir "runtimes\$TargetRid\native"
    New-Item -ItemType Directory -Force -Path $NativeOut | Out-Null

    $Assets = @(
        [pscustomobject]@{ ManagedPackageId = "SkiaSharp"; NativePackageId = "SkiaSharp.NativeAssets.Linux"; FileName = "libSkiaSharp.so" },
        [pscustomobject]@{ ManagedPackageId = "HarfBuzzSharp"; NativePackageId = "HarfBuzzSharp.NativeAssets.Linux"; FileName = "libHarfBuzzSharp.so" }
    )

    $NativeBuildManifest = Join-Path $NativeAssetsDir "native-build-manifest.txt"
    $NativeAssetSourceKind = if (Test-Path -LiteralPath $NativeBuildManifest) {
        "old-world ABI1 native assets with build manifest"
    } else {
        "old-world ABI1 native assets"
    }
    $Records = @()
    foreach ($Asset in $Assets) {
        $ManagedVersion = Get-ClassIslandDependencyVersion -DepsJson $DepsJson -PackageId $Asset.ManagedPackageId
        $NativeVersion = Get-ClassIslandDependencyVersion -DepsJson $DepsJson -PackageId $Asset.NativePackageId
        $Source = Join-Path $NativeAssetsDir $Asset.FileName
        if (-not (Test-Path -LiteralPath $Source)) {
            throw "Native asset verification failed; missing old-world ABI1 native asset $Source. Build or download libSkiaSharp.so and libHarfBuzzSharp.so first."
        }

        $Destination = Join-Path $NativeOut $Asset.FileName
        Copy-Item -LiteralPath $Source -Destination $Destination -Force

        $SourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
        $DestinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
        if ($SourceHash -ne $DestinationHash) {
            throw "Native asset verification failed; copied hash mismatch for $($Asset.FileName)."
        }

        $Elf = Get-LoongArchElfInfo -Path $Destination
        $Symbols = Get-NativeSymbolVersionInfo -Path $Destination
        $Records += [pscustomobject]@{
            ManagedPackageId = $Asset.ManagedPackageId
            ManagedVersion = $ManagedVersion
            NativePackageId = $Asset.NativePackageId
            NativeVersion = $NativeVersion
            FileName = $Asset.FileName
            SourceKind = $NativeAssetSourceKind
            Source = $Source
            Destination = $Destination
            Size = (Get-Item -LiteralPath $Destination).Length
            Sha256 = $DestinationHash
            ElfMachine = $Elf.Machine
            ElfFlags = $Elf.Flags
            ElfFloatAbi = $Elf.FloatAbi
            ElfObjectAbi = $Elf.ObjectAbi
            MaxGlibc = $Symbols.MaxGlibc
            GlibcVersions = ($Symbols.GlibcVersions -join ", ")
            GlibcxxVersions = ($Symbols.GlibcxxVersions -join ", ")
            CxxAbiVersions = ($Symbols.CxxAbiVersions -join ", ")
        }
    }

    $ManifestLines = @(
        "ClassIsland LoongArch native asset manifest",
        "Branch: $Branch",
        "Commit: $Commit",
        "TargetRid: $TargetRid",
        "AppVersion requested: $AppVersion",
        "AssemblyVersion used: $AssemblyVersion",
        "AvaloniaVersion requested: $AvaloniaVersion",
        "SkiaSharpNativeAssetsVersionOverride: $SkiaSharpNativeAssetsVersionOverride",
        "HarfBuzzSharpNativeAssetsVersionOverride: $HarfBuzzSharpNativeAssetsVersionOverride",
        "NativeAssetsDir: $NativeAssetsDir",
        "NativeBuildManifest: $(if (Test-Path -LiteralPath $NativeBuildManifest) { $NativeBuildManifest } else { '(missing)' })",
        ""
    )
    foreach ($Record in $Records) {
        $ManifestLines += @(
            "ManagedPackage: $($Record.ManagedPackageId) $($Record.ManagedVersion)",
            "NativePackage: $($Record.NativePackageId) $($Record.NativeVersion)",
            "FileName: $($Record.FileName)",
            "SourceKind: $($Record.SourceKind)",
            "Source: $($Record.Source)",
            "Destination: $($Record.Destination)",
            "Size: $($Record.Size)",
            "SHA256: $($Record.Sha256)",
            "ELF: machine=$($Record.ElfMachine) flags=$($Record.ElfFlags) floatAbi=$($Record.ElfFloatAbi) objectAbi=$($Record.ElfObjectAbi)",
            "GLIBC max: $($Record.MaxGlibc)",
            "GLIBC versions: $($Record.GlibcVersions)",
            "GLIBCXX versions: $($Record.GlibcxxVersions)",
            "CXXABI versions: $($Record.CxxAbiVersions)",
            ""
        )
    }
    if (Test-Path -LiteralPath $NativeBuildManifest) {
        $ManifestLines += @(
            "Embedded native build manifest:",
            "--------------------------------",
            (Read-Utf8Text -Path $NativeBuildManifest)
        )
    }

    Set-TextIfChanged -Path (Join-Path $PackageWork "native-manifest.txt") -Content ($ManifestLines -join "`n")
    return $Records
}

function Assert-ClassIslandRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$PackageWork,

        [Parameter(Mandatory)]
        [string]$AppDir,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Commit
    )

    $RuntimeConfigPath = Join-Path $AppDir "ClassIsland.Desktop.runtimeconfig.json"
    if (-not (Test-Path -LiteralPath $RuntimeConfigPath)) {
        throw "Runtime verification failed; missing $RuntimeConfigPath"
    }

    $RuntimeConfig = Read-Utf8Text -Path $RuntimeConfigPath | ConvertFrom-Json
    if ($RuntimeConfig.runtimeOptions.tfm -ne "net$ExpectedDotNetMajor.0") {
        throw "Runtime verification failed; ClassIsland target framework is $($RuntimeConfig.runtimeOptions.tfm), expected net$ExpectedDotNetMajor.0."
    }
    if ($RuntimeConfig.runtimeOptions.framework.name -ne "Microsoft.NETCore.App" -or $RuntimeConfig.runtimeOptions.framework.version -ne $ExpectedDotNetFrameworkVersion) {
        throw "Runtime verification failed; ClassIsland requires $($RuntimeConfig.runtimeOptions.framework.name) $($RuntimeConfig.runtimeOptions.framework.version), expected Microsoft.NETCore.App $ExpectedDotNetFrameworkVersion."
    }

    $RequiredRuntimePaths = @(
        (Join-Path $AppDir "dotnet"),
        (Join-Path $AppDir "host\fxr\$ExpectedBundledDotNetRuntimeVersion"),
        (Join-Path $AppDir "shared\Microsoft.NETCore.App\$ExpectedBundledDotNetRuntimeVersion"),
        (Join-Path $AppDir "shared\Microsoft.AspNetCore.App\$ExpectedBundledDotNetRuntimeVersion")
    )
    foreach ($Path in $RequiredRuntimePaths) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Runtime verification failed; missing $Path"
        }
    }

    $UnexpectedRuntimeDirs = Get-ChildItem -LiteralPath (Join-Path $AppDir "shared") -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and $_.Name -notlike "$ExpectedDotNetMajor.*" }
    if ($UnexpectedRuntimeDirs) {
        throw "Runtime verification failed; unexpected non-net$ExpectedDotNetMajor runtime directories: $($UnexpectedRuntimeDirs.FullName -join '; ')"
    }

    $Manifest = @"
ClassIsland LoongArch runtime manifest
Branch: $Branch
Commit: $Commit
AppVersion requested: $AppVersion
AssemblyVersion used: $AssemblyVersion
TargetFramework: $($RuntimeConfig.runtimeOptions.tfm)
Framework: $($RuntimeConfig.runtimeOptions.framework.name) $($RuntimeConfig.runtimeOptions.framework.version)
BundledRuntimeVersion: $ExpectedBundledDotNetRuntimeVersion
LoongnixRelease: $LoongnixDotNetRelease
DotnetRuntimeArchive: $DotnetRuntimeArchive
AspnetRuntimeArchive: $AspnetRuntimeArchive
RID/native ABI: linux-loongarch64 old-world ABI 1.0
GPT-SoVITS internal signing enabled: $(-not [string]::IsNullOrWhiteSpace($ApiSigningKey) -and -not [string]::IsNullOrWhiteSpace($ApiSigningKeyPassPhrase))
"@
    Set-TextIfChanged -Path (Join-Path $PackageWork "runtime-manifest.txt") -Content $Manifest
}

function Apply-LoongArchPatch {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $GlobalProps = Join-Path $RepoDir "Global.props"
    $AppCode = Join-Path $RepoDir "ClassIsland\App.axaml.cs"

    $PropsText = (Read-Utf8Text -Path $GlobalProps) -replace "`r`n", "`n"
    if ($PropsText -notmatch "PLATFORM_LOONGARCH64") {
        $Pattern = "\s*<PropertyGroup Condition=`"'\$\(ClassIsland_PlatformTarget\)'=='arm'`">\s*<DefineConstants>\$\(DefineConstants\);PLATFORM_ARM</DefineConstants>\s*</PropertyGroup>"
        if ($PropsText -notmatch $Pattern) {
            throw "Could not patch Global.props LoongArch platform constants. Upstream ClassIsland source may have changed."
        }
        $PropsText = [regex]::Replace($PropsText, $Pattern, {
            param($m)
            $m.Value + "`n`t<PropertyGroup Condition=`"'" + '$(ClassIsland_PlatformTarget)' + "'=='loongarch64'`">`n`t`t<DefineConstants>" + '$(DefineConstants)' + ";PLATFORM_LOONGARCH64</DefineConstants>`n`t</PropertyGroup>"
        }, 1)
        Set-TextIfChanged -Path $GlobalProps -Content $PropsText
    }

    $AppText = (Read-Utf8Text -Path $AppCode) -replace "`r`n", "`n"
    if ($AppText -notmatch "PLATFORM_LOONGARCH64") {
        $Pattern = '(?m)^#elif\s+PLATFORM_ARM\s*\n\s*"arm"\s*$'
        if ($AppText -notmatch $Pattern) {
            throw "Could not patch ClassIsland LoongArch platform name. Upstream ClassIsland source may have changed."
        }
        $AppText = [regex]::Replace($AppText, $Pattern, {
            param($m)
            $m.Value + "`n#elif PLATFORM_LOONGARCH64`n    `"loongarch64`""
        }, 1)
        Set-TextIfChanged -Path $AppCode -Content $AppText
    }

    Patch-ClassIslandRestartLogic -RepoDir $RepoDir
    Patch-ClassIslandAudioService -RepoDir $RepoDir
    Patch-ClassIslandLinuxX11Stability -RepoDir $RepoDir
}

function Write-ClassIslandGeneratedFiles {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$Commit,

        [string]$ApiSigningKey,

        [string]$ApiSigningKeyPassPhrase,

        [Parameter(Mandatory)]
        [string]$AppVersion,

        [Parameter(Mandatory)]
        [string]$AssemblyVersion
    )

    $InfoVersion = "$AppVersion-loongarch-$($BranchName -replace '[^A-Za-z0-9]+','-')-$($Commit.Substring(0, 7))"
    Patch-ClassIslandAssemblyInfo -RepoDir $RepoDir -InfoVersion $InfoVersion -AssemblyVersion $AssemblyVersion

    $HasGptSovitsSigningKey = -not [string]::IsNullOrWhiteSpace($ApiSigningKey) -and -not [string]::IsNullOrWhiteSpace($ApiSigningKeyPassPhrase)
    $EscapedApiSigningKey = ($(if ($HasGptSovitsSigningKey) { $ApiSigningKey } else { "" })).Replace('"', '""')
    $EscapedApiSigningKeyPassPhrase = ($(if ($HasGptSovitsSigningKey) { $ApiSigningKeyPassPhrase } else { "" })).Replace('"', '""')
    $IsSecretsFilled = $HasGptSovitsSigningKey.ToString().ToLowerInvariant()
    $Secrets = @"
namespace ClassIsland.Services.SpeechService;

public static partial class GptSovitsSecrets
{
    public const string PrivateKey = @"
$EscapedApiSigningKey
";
    public const string PrivateKeyPassPhrase = @"
$EscapedApiSigningKeyPassPhrase
";
    public const bool IsSecretsFilled = $IsSecretsFilled;
}
"@

    Set-TextIfChanged -Path (Join-Path $RepoDir "ClassIsland\secrets.g.cs") -Content $Secrets
}

function Get-BranchSlug {
    param([string]$Branch)
    return ($Branch -replace '^develop/v2/', '' -replace '[^A-Za-z0-9._-]+', '-')
}

function Get-PackageSlug {
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [string]$Label,

        [int]$BranchCount
    )

    $BranchSlug = Get-BranchSlug -Branch $Branch
    if ([string]::IsNullOrWhiteSpace($Label)) {
        return $BranchSlug
    }

    $LabelSlug = $Label -replace '[^A-Za-z0-9._-]+', '-'
    $LabelSlug = $LabelSlug.Trim([char[]]"-")
    if ([string]::IsNullOrWhiteSpace($LabelSlug)) {
        return $BranchSlug
    }

    if ($BranchCount -gt 1) {
        return "$LabelSlug-$BranchSlug"
    }

    return $LabelSlug
}

Ensure-Download -Uri "$LoongnixDotNetRelease/$DotnetRuntimeArchive" -Path (Join-Path $RuntimeDir $DotnetRuntimeArchive)
Ensure-Download -Uri "$LoongnixDotNetRelease/$AspnetRuntimeArchive" -Path (Join-Path $RuntimeDir $AspnetRuntimeArchive)

$Results = @()

foreach ($Branch in $Branches) {
    $Slug = Get-PackageSlug -Branch $Branch -Label $PackageLabel -BranchCount $Branches.Count
    $BranchSlug = Get-BranchSlug -Branch $Branch
    $RepoDir = Join-Path $BuildRoot "$Slug-src"
    $PublishDir = Join-Path $BuildRoot "$Slug-publish"
    $PackageName = "ClassIsland-$Slug-linux-loongarch64-net10"
    $PackageWork = Join-Path $BuildRoot "packages\$PackageName"
    $PackagePath = Join-Path $OutDir "$PackageName.tar.gz"

    $Commit = $null
    if ($SourceMode -in @("auto", "git")) {
        $Commit = Try-PrepareGitSource -RepoUrl $RepoUrl -Branch $Branch -RepoDir $RepoDir
        if (-not $Commit -and $SourceMode -eq "git") {
            throw "Git source preparation failed for $Branch and SourceMode is git."
        }
    }
    if (-not $Commit) {
        $Commit = Install-GitHubArchiveSource -RepoUrl $RepoUrl -Branch $Branch -RepoDir $RepoDir -CacheDir $BuildRoot
    }

    Apply-LoongArchPatch -RepoDir $RepoDir
    Patch-ClassIslandAvaloniaVersion -RepoDir $RepoDir -Version $AvaloniaVersion
    Patch-ClassIslandNativeAssetOverrides -RepoDir $RepoDir
    Patch-EdgeTtsSharp -RepoDir $RepoDir
    Write-ClassIslandGeneratedFiles -RepoDir $RepoDir -BranchName $BranchSlug -Commit $Commit -ApiSigningKey $ApiSigningKey -ApiSigningKeyPassPhrase $ApiSigningKeyPassPhrase -AppVersion $AppVersion -AssemblyVersion $AssemblyVersion

    Remove-Item -LiteralPath $PublishDir, $PackageWork -Recurse -Force -ErrorAction SilentlyContinue

    Push-Location $RepoDir
    try {
        Invoke-Native dotnet publish "ClassIsland.Desktop\ClassIsland.Desktop.csproj" `
            -c Release `
            --no-self-contained `
            "-p:PublishDir=$PublishDir" `
            "-p:PublishBuilding=true" `
            "-p:PublishPlatform=linux" `
            "-p:Platforms_Linux=true" `
            "-p:NIX=true" `
            "-p:GitVersion_UpdateAssemblyInfo=false" `
            "-p:TrimAssets=false" `
            "-p:UseAppHost=false" `
            "-p:PublishSingleFile=false" `
            "-p:PublishTrimmed=false" `
            "-p:DebugType=none" `
            "-p:DebugSymbols=false" `
            "-p:ClassIsland_PlatformTarget=loongarch64" `
            "-p:Version=$AppVersion" `
            "-p:AssemblyVersion=$AssemblyVersion" `
            "-p:FileVersion=$AssemblyVersion" `
            "-p:InformationalVersion=$AppVersion-loongarch-$BranchSlug-$($Commit.Substring(0, 7))"
    } finally {
        Remove-Item -LiteralPath (Join-Path $RepoDir "ClassIsland\secrets.g.cs") -Force -ErrorAction SilentlyContinue
        Pop-Location
    }

    $AppDir = Join-Path $PackageWork "ClassIsland"
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Get-ChildItem -LiteralPath $PublishDir -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $AppDir -Recurse -Force
    }

    tar -xf (Join-Path $RuntimeDir $DotnetRuntimeArchive) -C $AppDir
    tar -xf (Join-Path $RuntimeDir $AspnetRuntimeArchive) -C $AppDir

    $NativeOut = Join-Path $AppDir "runtimes\linux-loongarch64\native"
    $NativeAssetRecords = Install-ClassIslandNativeAssets -PackageWork $PackageWork -AppDir $AppDir -Branch $Branch -Commit $Commit

    "folderClassic" | Set-Content -LiteralPath (Join-Path $PackageWork "PackageType") -Encoding ASCII

    $RunSh = @'
#!/usr/bin/env bash
set -e
script_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$script_dir/ClassIsland"

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_ROOT="$app_dir"
export PATH="$DOTNET_ROOT:$PATH:/usr/bin:/usr/local/bin"
export LD_LIBRARY_PATH="$app_dir/runtimes/linux-loongarch64/native:${LD_LIBRARY_PATH:-}"
export ClassIsland_PackageRoot="$script_dir"
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/share:/usr/local/share}"
export CLASSISLAND_X11_RENDERING="${CLASSISLAND_X11_RENDERING:-software}"
export CLASSISLAND_X11_RETAINED_FRAMEBUFFER="${CLASSISLAND_X11_RETAINED_FRAMEBUFFER:-1}"
export CLASSISLAND_X11_ENABLE_IME="${CLASSISLAND_X11_ENABLE_IME:-0}"

if [ "$CLASSISLAND_X11_ENABLE_IME" = "0" ] || [ "$CLASSISLAND_X11_ENABLE_IME" = "false" ]; then
  export XMODIFIERS="@im=none"
  export GTK_IM_MODULE="xim"
  export QT_IM_MODULE="xim"
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  for env_file in "$XDG_RUNTIME_DIR/dbus-session-env" "/run/user/$(id -u)/dbus-session-env"; do
    if [ -r "$env_file" ]; then
      # shellcheck disable=SC1090
      . "$env_file"
      break
    fi
  done
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

mkdir -p "$script_dir/logs"
cd "$app_dir"
chmod +x "$app_dir/dotnet" 2>/dev/null || true

run_classisland() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
    dbus-run-session -- ./dotnet ClassIsland.Desktop.dll "$@"
  else
    ./dotnet ClassIsland.Desktop.dll "$@"
  fi
}

if [ "${1:-}" = "--foreground" ]; then
  shift
  set +e
  run_classisland "$@" 2>&1 | tee "$script_dir/logs/classisland.log"
  exit "${PIPESTATUS[0]}"
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
  nohup dbus-run-session -- ./dotnet ClassIsland.Desktop.dll "$@" >> "$script_dir/logs/classisland.log" 2>&1 &
else
  nohup ./dotnet ClassIsland.Desktop.dll "$@" >> "$script_dir/logs/classisland.log" 2>&1 &
fi
'@
    $RunShPath = Join-Path $PackageWork "run.sh"
    $Ascii = [System.Text.Encoding]::ASCII
    [System.IO.File]::WriteAllText($RunShPath, (($RunSh -replace "`r`n", "`n") -replace "`r", "`n"), $Ascii)

    foreach ($Required in @(
        (Join-Path $AppDir "ClassIsland.Desktop.dll"),
        (Join-Path $AppDir "dotnet"),
        (Join-Path $NativeOut "libSkiaSharp.so"),
        (Join-Path $NativeOut "libHarfBuzzSharp.so"),
        (Join-Path $PackageWork "run.sh"),
        (Join-Path $PackageWork "PackageType")
    )) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw "Package verification failed; missing $Required"
        }
    }

    Assert-ClassIslandRuntime -PackageWork $PackageWork -AppDir $AppDir -Branch $Branch -Commit $Commit

    Remove-Item -LiteralPath $PackagePath -Force -ErrorAction SilentlyContinue
    tar -czf $PackagePath -C (Split-Path -Parent $PackageWork) $PackageName

    $Results += [pscustomobject]@{
        Branch = $Branch
        Commit = $Commit
        Package = $PackagePath
        PackageBytes = (Get-Item -LiteralPath $PackagePath).Length
    }
}

$Results
