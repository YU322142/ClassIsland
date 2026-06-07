[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDir,

    [string]$SkiaRepo = "YU322142/SkiaSharp-Loongarch-ABI1.0",
    [string]$SkiaArtifactName = "libSkiaSharp-linux-loongarch64-oldworld",
    [string]$HarfBuzzRepo = "YU322142/harfbuzz-Loongarch-ABI1.0",
    [string]$HarfBuzzArtifactName = "libHarfBuzzSharp-linux-loongarch64-oldworld",
    [string]$WorkflowFileName = "build-loongarch-oldworld.yml",
    [string]$Branch = "main",
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [switch]$Wait,
    [int]$TimeoutMinutes = 180,
    [int]$PollSeconds = 30
)

$ErrorActionPreference = "Stop"

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Args = @(
        "--fail", "--silent", "--show-error", "--location", "--ipv4",
        "--retry", "8", "--retry-all-errors", "--retry-delay", "2",
        "--connect-timeout", "30", "--max-time", "180", "--ssl-no-revoke",
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

function Save-GitHubDownload {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Part = "$Path.part"
    Remove-Item -LiteralPath $Part -Force -ErrorAction SilentlyContinue
    $Args = @(
        "--fail", "--silent", "--show-error", "--location", "--ipv4",
        "--retry", "8", "--retry-all-errors", "--retry-delay", "2",
        "--connect-timeout", "30", "--max-time", "600", "--ssl-no-revoke",
        "--output", $Part,
        "-H", "X-GitHub-Api-Version: 2022-11-28"
    )
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $Args += @("-H", "Authorization: Bearer $GitHubToken")
    }
    $Args += $Uri

    curl.exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub artifact download failed for $Uri with code $LASTEXITCODE"
    }
    Move-Item -LiteralPath $Part -Destination $Path -Force
}

function Get-LatestWorkflowRun {
    param(
        [Parameter(Mandatory)]
        [string]$Repo
    )

    $EncodedBranch = [uri]::EscapeDataString($Branch)
    $RunsUri = "https://api.github.com/repos/$Repo/actions/workflows/$WorkflowFileName/runs?branch=$EncodedBranch&per_page=10"
    $Runs = Invoke-GitHubApi -Uri $RunsUri
    $Run = @($Runs.workflow_runs | Where-Object { $_.head_branch -eq $Branch } | Select-Object -First 1)
    if (-not $Run) {
        throw "No workflow run found for $Repo/$WorkflowFileName on branch $Branch."
    }

    if (-not $Wait) {
        return $Run
    }

    $Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($Run.status -ne "completed") {
        if ((Get-Date) -gt $Deadline) {
            throw "Timed out waiting for $Repo workflow run $($Run.id) to complete."
        }
        Write-Host "Waiting for $Repo workflow run $($Run.id): status=$($Run.status)"
        Start-Sleep -Seconds $PollSeconds
        $Run = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/actions/runs/$($Run.id)"
    }

    return $Run
}

function Download-NativeArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$ArtifactName,

        [Parameter(Mandatory)]
        [string]$TargetDir
    )

    $Run = Get-LatestWorkflowRun -Repo $Repo
    if ($Run.status -ne "completed" -or $Run.conclusion -ne "success") {
        throw "$Repo workflow run $($Run.id) is not successful. status=$($Run.status), conclusion=$($Run.conclusion), url=$($Run.html_url)"
    }

    $Artifacts = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/actions/runs/$($Run.id)/artifacts?per_page=100"
    $Artifact = @($Artifacts.artifacts | Where-Object { $_.name -eq $ArtifactName -and -not $_.expired } | Select-Object -First 1)
    if (-not $Artifact) {
        throw "Artifact $ArtifactName was not found in $Repo workflow run $($Run.id)."
    }

    Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

    $ZipPath = Join-Path $TargetDir "$ArtifactName.zip"
    Save-GitHubDownload -Uri $Artifact.archive_download_url -Path $ZipPath
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $TargetDir -Force
    Remove-Item -LiteralPath $ZipPath -Force

    return [pscustomobject]@{
        Repo = $Repo
        RunId = $Run.id
        RunUrl = $Run.html_url
        HeadSha = $Run.head_sha
        ArtifactName = $Artifact.name
        ArtifactId = $Artifact.id
        ArtifactDigest = $Artifact.digest
        TargetDir = $TargetDir
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $File = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $FileName | Select-Object -First 1
    if (-not $File) {
        throw "Downloaded artifact under $Root does not contain $FileName."
    }
    Copy-Item -LiteralPath $File.FullName -Destination $Destination -Force
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$DownloadRoot = Join-Path $OutputDir "_downloaded"
Remove-Item -LiteralPath $DownloadRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

$SkiaInfo = Download-NativeArtifact -Repo $SkiaRepo -ArtifactName $SkiaArtifactName -TargetDir (Join-Path $DownloadRoot "SkiaSharp")
$HarfBuzzInfo = Download-NativeArtifact -Repo $HarfBuzzRepo -ArtifactName $HarfBuzzArtifactName -TargetDir (Join-Path $DownloadRoot "HarfBuzzSharp")

Copy-RequiredFile -Root $SkiaInfo.TargetDir -FileName "libSkiaSharp.so" -Destination (Join-Path $OutputDir "libSkiaSharp.so")
Copy-RequiredFile -Root $HarfBuzzInfo.TargetDir -FileName "libHarfBuzzSharp.so" -Destination (Join-Path $OutputDir "libHarfBuzzSharp.so")

$SkiaManifest = Get-ChildItem -LiteralPath $SkiaInfo.TargetDir -Recurse -File -Filter "native-build-manifest.txt" | Select-Object -First 1
$HarfBuzzManifest = Get-ChildItem -LiteralPath $HarfBuzzInfo.TargetDir -Recurse -File -Filter "native-build-manifest.txt" | Select-Object -First 1

$Manifest = @(
    "ClassIsland online LoongArch old-world ABI1.0 native assets",
    "Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")",
    "",
    "SkiaSharp artifact:",
    "  Repo: $($SkiaInfo.Repo)",
    "  Run: $($SkiaInfo.RunId)",
    "  URL: $($SkiaInfo.RunUrl)",
    "  HeadSha: $($SkiaInfo.HeadSha)",
    "  Artifact: $($SkiaInfo.ArtifactName) ($($SkiaInfo.ArtifactId))",
    "  Digest: $($SkiaInfo.ArtifactDigest)",
    "  SHA256: $((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $OutputDir "libSkiaSharp.so")).Hash)",
    "",
    "HarfBuzzSharp artifact:",
    "  Repo: $($HarfBuzzInfo.Repo)",
    "  Run: $($HarfBuzzInfo.RunId)",
    "  URL: $($HarfBuzzInfo.RunUrl)",
    "  HeadSha: $($HarfBuzzInfo.HeadSha)",
    "  Artifact: $($HarfBuzzInfo.ArtifactName) ($($HarfBuzzInfo.ArtifactId))",
    "  Digest: $($HarfBuzzInfo.ArtifactDigest)",
    "  SHA256: $((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $OutputDir "libHarfBuzzSharp.so")).Hash)",
    ""
)

if ($SkiaManifest) {
    $Manifest += @("---- SkiaSharp native manifest ----", (Get-Content -LiteralPath $SkiaManifest.FullName -Raw))
}
if ($HarfBuzzManifest) {
    $Manifest += @("---- HarfBuzzSharp native manifest ----", (Get-Content -LiteralPath $HarfBuzzManifest.FullName -Raw))
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $OutputDir "native-build-manifest.txt"), ($Manifest -join "`n"), $Utf8NoBom)

Get-ChildItem -LiteralPath $OutputDir -File | Select-Object FullName, Length
