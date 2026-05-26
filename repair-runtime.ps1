param(
    [switch]$ForceRefresh,
    [switch]$Quiet,
    [switch]$Offline,
    [switch]$EmitJson
)

$ErrorActionPreference = "Stop"

if ($EmitJson) {
    $Quiet = $true
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Join-Path $root ".tools"
$spotdlHome = Join-Path $root ".spotdl"
$appDataRoot = Join-Path $root "app-data"
$spotdlExe = Join-Path $toolsDir "spotdl.exe"
$localFfmpegExe = Join-Path $spotdlHome "ffmpeg.exe"
$localDenoExe = Join-Path $spotdlHome "deno.exe"
$localConfigPath = Join-Path $spotdlHome "config.json"
$releaseApi = "https://api.github.com/repos/spotDL/spotify-downloader/releases/latest"

$env:USERPROFILE = $root
$env:HOME = $root

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Resolve-ApplicationPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ($command -and $command.Source) {
            return $command.Source
        }
    }
    catch {
    }

    return $null
}

function Get-SpotdlVersion {
    param([string]$ExePath)

    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
        return $null
    }

    try {
        $version = & $ExePath --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        return "$version".Trim()
    }
    catch {
        return $null
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $outDir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir | Out-Null
    }

    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Get-LatestSpotdlAsset {
    if ($Offline) {
        throw "Offline mode is enabled, so spotDL cannot be downloaded automatically."
    }

    Write-Step "Checking latest spotDL release..."
    try {
        $release = Invoke-RestMethod -Uri $releaseApi
    }
    catch {
        throw "Could not reach GitHub to fetch spotDL. Check internet access, proxy settings, or GitHub availability."
    }

    $latestVersion = ($release.tag_name -replace '^v', '')
    $winAsset = $release.assets | Where-Object { $_.name -like '*win32.exe' } | Select-Object -First 1
    if (-not $winAsset) {
        throw "Could not find a Windows spotDL executable in the latest GitHub release."
    }

    return [pscustomobject]@{
        Version = $latestVersion
        Url = $winAsset.browser_download_url
    }
}

function Ensure-Spotdl {
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir | Out-Null
    }

    $localVersion = Get-SpotdlVersion -ExePath $spotdlExe
    if ($localVersion -and -not $ForceRefresh) {
        Write-Step "Using repo-local spotDL ($localVersion)."
        return [pscustomobject]@{
            Path = $spotdlExe
            Source = "local"
        }
    }

    $systemSpotdl = Resolve-ApplicationPath -Name "spotdl.exe"
    if ($systemSpotdl -and -not $ForceRefresh -and -not $localVersion) {
        Write-Step "Using system spotDL at $systemSpotdl."
        return [pscustomobject]@{
            Path = $systemSpotdl
            Source = "system"
        }
    }

    $asset = Get-LatestSpotdlAsset
    Write-Step "Downloading spotDL $($asset.Version)..."
    try {
        Download-File -Url $asset.Url -OutFile $spotdlExe
    }
    catch {
        throw "Could not download spotDL automatically. Check internet access or GitHub availability."
    }

    $downloadedVersion = Get-SpotdlVersion -ExePath $spotdlExe
    if (-not $downloadedVersion) {
        throw "spotDL downloaded, but its executable could not be validated."
    }

    return [pscustomobject]@{
        Path = $spotdlExe
        Source = "downloaded"
    }
}

function Ensure-ToolViaSpotdl {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$SystemCommand,
        [Parameter(Mandatory = $true)][string]$DownloadArgument,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$SpotdlPath
    )

    if ((Test-Path -LiteralPath $LocalPath) -and -not $ForceRefresh) {
        Write-Step "Using repo-local $DisplayName."
        return [pscustomobject]@{
            Path = $LocalPath
            Source = "local"
        }
    }

    $systemPath = Resolve-ApplicationPath -Name $SystemCommand
    if ($systemPath -and -not $ForceRefresh -and -not (Test-Path -LiteralPath $LocalPath)) {
        Write-Step "Using system $DisplayName at $systemPath."
        return [pscustomobject]@{
            Path = $systemPath
            Source = "system"
        }
    }

    if ($Offline) {
        throw "$DisplayName is missing and offline mode is enabled, so it cannot be downloaded automatically."
    }

    Write-Step "Downloading missing $DisplayName..."
    try {
        & $SpotdlPath $DownloadArgument
        if ($LASTEXITCODE -ne 0) {
            throw "$DisplayName download failed."
        }
    }
    catch {
        throw "spotDL could not download $DisplayName automatically."
    }

    if (Test-Path -LiteralPath $LocalPath) {
        return [pscustomobject]@{
            Path = $LocalPath
            Source = "downloaded"
        }
    }

    $systemPathAfter = Resolve-ApplicationPath -Name $SystemCommand
    if ($systemPathAfter) {
        return [pscustomobject]@{
            Path = $systemPathAfter
            Source = "system"
        }
    }

    throw "$DisplayName is still unavailable after the automatic repair step."
}

function Ensure-SpotdlConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SpotdlPath
    )

    if (-not (Test-Path -LiteralPath $localConfigPath)) {
        Write-Step "Generating repo-local spotDL config..."
        try {
            & $SpotdlPath --generate-config
            if ($LASTEXITCODE -ne 0) {
                throw "Config generation failed."
            }
        }
        catch {
            throw "spotDL could not generate its local config automatically."
        }
    }

    $config = Get-Content $localConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $providers = @()
    if ($config.audio_providers) {
        $providers = @($config.audio_providers)
    }

    $orderedProviders = New-Object System.Collections.Generic.List[string]
    foreach ($provider in @("youtube-music", "youtube")) {
        if ($providers -contains $provider) {
            $orderedProviders.Add($provider)
        }
    }
    foreach ($provider in $providers) {
        if (-not $orderedProviders.Contains([string]$provider)) {
            $orderedProviders.Add([string]$provider)
        }
    }
    foreach ($provider in @("youtube-music", "youtube")) {
        if (-not $orderedProviders.Contains($provider)) {
            $orderedProviders.Add($provider)
        }
    }

    $shouldWrite = $false
    if (-not $config.audio_providers -or (@($config.audio_providers) -join "|") -ne (@($orderedProviders) -join "|")) {
        $config.audio_providers = @($orderedProviders)
        $shouldWrite = $true
    }

    if ($shouldWrite) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($localConfigPath, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)
    }

    return $localConfigPath
}

if (-not (Test-Path -LiteralPath $spotdlHome)) {
    New-Item -ItemType Directory -Path $spotdlHome | Out-Null
}

if (-not (Test-Path -LiteralPath $appDataRoot)) {
    New-Item -ItemType Directory -Path $appDataRoot | Out-Null
}

Write-Step "Checking local runtime..."
$spotdl = Ensure-Spotdl
$ffmpeg = Ensure-ToolViaSpotdl -LocalPath $localFfmpegExe -SystemCommand "ffmpeg.exe" -DownloadArgument "--download-ffmpeg" -DisplayName "FFmpeg" -SpotdlPath $spotdl.Path
$deno = Ensure-ToolViaSpotdl -LocalPath $localDenoExe -SystemCommand "deno.exe" -DownloadArgument "--download-deno" -DisplayName "Deno" -SpotdlPath $spotdl.Path
$configPath = Ensure-SpotdlConfig -SpotdlPath $spotdl.Path

$result = [pscustomobject]@{
    spotdlPath = $spotdl.Path
    spotdlSource = $spotdl.Source
    ffmpegPath = $ffmpeg.Path
    ffmpegSource = $ffmpeg.Source
    denoPath = $deno.Path
    denoSource = $deno.Source
    configPath = $configPath
}

if ($EmitJson) {
    $result | ConvertTo-Json -Compress
}
else {
    Write-Step "Runtime is ready."
    Write-Step ("spotDL: " + $result.spotdlPath)
    Write-Step ("FFmpeg: " + $result.ffmpegPath)
    Write-Step ("Deno: " + $result.denoPath)
    Write-Step ("Config: " + $result.configPath)
}
