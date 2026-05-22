param(
    [switch]$ForceRefresh,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Join-Path $root ".tools"
$spotdlHome = Join-Path $root ".spotdl"
$spotdlExe = Join-Path $toolsDir "spotdl.exe"
$releaseApi = "https://api.github.com/repos/spotDL/spotify-downloader/releases/latest"

$env:USERPROFILE = $root
$env:HOME = $root

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Get-SpotdlVersion {
    param([string]$ExePath)

    if (-not (Test-Path -LiteralPath $ExePath)) {
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

if (-not (Test-Path -LiteralPath $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir | Out-Null
}

if (-not (Test-Path -LiteralPath $spotdlHome)) {
    New-Item -ItemType Directory -Path $spotdlHome | Out-Null
}

Write-Step "Checking latest spotDL release..."
$release = Invoke-RestMethod -Uri $releaseApi
$latestVersion = ($release.tag_name -replace '^v', '')
$winAsset = $release.assets | Where-Object { $_.name -like '*win32.exe' } | Select-Object -First 1
if (-not $winAsset) {
    throw "Could not find a Windows spotDL executable in the latest release."
}

$installedVersion = Get-SpotdlVersion -ExePath $spotdlExe
$downloadSpotdl = $ForceRefresh -or -not $installedVersion -or ($installedVersion -ne $latestVersion)

if ($downloadSpotdl) {
    Write-Step "Downloading spotDL $latestVersion..."
    Download-File -Url $winAsset.browser_download_url -OutFile $spotdlExe
}
else {
    Write-Step "spotDL is already up to date ($installedVersion)."
}

$ffmpegExe = Join-Path $spotdlHome "ffmpeg.exe"
$denoExe = Join-Path $spotdlHome "deno.exe"

if ($ForceRefresh -or -not (Test-Path -LiteralPath $ffmpegExe)) {
    Write-Step "Ensuring FFmpeg is installed..."
    & $spotdlExe --download-ffmpeg
    if ($LASTEXITCODE -ne 0) {
        throw "spotDL failed to download FFmpeg."
    }
}
else {
    Write-Step "FFmpeg already present."
}

if ($ForceRefresh -or -not (Test-Path -LiteralPath $denoExe)) {
    Write-Step "Ensuring Deno is installed..."
    & $spotdlExe --download-deno
    if ($LASTEXITCODE -ne 0) {
        throw "spotDL failed to download Deno."
    }
}
else {
    Write-Step "Deno already present."
}

Write-Step "Runtime is ready."
