param(
    [int]$Port = 8976,
    [switch]$SkipRepair,
    [switch]$ForceRefresh,
    [switch]$Offline
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $root "server.ts"
$repair = Join-Path $root "repair-runtime.ps1"
$appDataRoot = Join-Path $root "app-data"
$startupLog = Join-Path $appDataRoot "startup.log"
$localSpotdl = Join-Path $root ".tools\spotdl.exe"
$localFfmpeg = Join-Path $root ".spotdl\ffmpeg.exe"
$localDeno = Join-Path $root ".spotdl\deno.exe"
$localSpotdlConfig = Join-Path $root ".spotdl\config.json"

$env:USERPROFILE = $root
$env:HOME = $root

if (-not (Test-Path -LiteralPath $appDataRoot)) {
    New-Item -ItemType Directory -Path $appDataRoot | Out-Null
}

function Clear-StartupLog {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($startupLog, "", $utf8NoBom)
}

function Write-StartupLine {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = "[{0}] {1}" -f ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")), $Message
    Write-Host $Message
    Add-Content -Path $startupLog -Value $line -Encoding utf8
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

function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$SystemCommand,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    if (Test-Path -LiteralPath $LocalPath) {
        return [pscustomobject]@{
            Path = $LocalPath
            Source = "local"
            Name = $DisplayName
        }
    }

    $systemPath = Resolve-ApplicationPath -Name $SystemCommand
    if ($systemPath) {
        return [pscustomobject]@{
            Path = $systemPath
            Source = "system"
            Name = $DisplayName
        }
    }

    return [pscustomobject]@{
        Path = $null
        Source = "missing"
        Name = $DisplayName
    }
}

function Log-ResolvedTool {
    param([Parameter(Mandatory = $true)]$Tool)

    switch ($Tool.Source) {
        "local" {
            Write-StartupLine "Using repo-local $($Tool.Name)."
        }
        "system" {
            Write-StartupLine "Using system $($Tool.Name)."
        }
    }

    if ($Tool.Path) {
        Write-StartupLine "$($Tool.Name): $($Tool.Path)"
    }
}

function Get-FreePort {
    param(
        [Parameter(Mandatory = $true)][int]$StartPort,
        [int]$Attempts = 15
    )

    for ($offset = 0; $offset -lt $Attempts; $offset++) {
        $candidate = $StartPort + $offset
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
            $listener.Start()
            return $candidate
        }
        catch {
        }
        finally {
            if ($listener) {
                $listener.Stop()
            }
        }
    }

    throw "Could not find an open port between $StartPort and $($StartPort + $Attempts - 1)."
}

function Invoke-RepairIfNeeded {
    param(
        [Parameter(Mandatory = $true)]$MissingTools
    )

    if ($SkipRepair) {
        return
    }

    if (-not (Test-Path -LiteralPath $repair)) {
        throw "Runtime repair script was not found at $repair"
    }

    foreach ($tool in $MissingTools) {
        Write-StartupLine "Downloading missing $tool..."
    }

    $repairArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $repair,
        "-Quiet"
    )
    if ($ForceRefresh) { $repairArgs += "-ForceRefresh" }
    if ($Offline) { $repairArgs += "-Offline" }

    & powershell.exe @repairArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Automatic runtime repair failed."
    }
}

try {
    Clear-StartupLog

    if (-not (Test-Path -LiteralPath $server)) {
        throw "Server file was not found at $server"
    }

    Write-StartupLine "Checking local runtime"

    $spotdl = Resolve-Tool -LocalPath $localSpotdl -SystemCommand "spotdl.exe" -DisplayName "spotDL"
    $ffmpeg = Resolve-Tool -LocalPath $localFfmpeg -SystemCommand "ffmpeg.exe" -DisplayName "FFmpeg"
    $deno = Resolve-Tool -LocalPath $localDeno -SystemCommand "deno.exe" -DisplayName "Deno"

    $missingNames = @()
    foreach ($tool in @($spotdl, $ffmpeg, $deno)) {
        if (-not $tool.Path) {
            $missingNames += $tool.Name
        }
    }

    if ($ForceRefresh) {
        if ($SkipRepair) {
            Write-StartupLine "Force refresh was requested, but repair is skipped."
        }
        else {
            Write-StartupLine "Refreshing local runtime"
            Invoke-RepairIfNeeded -MissingTools @("spotDL", "FFmpeg", "Deno")
            $spotdl = Resolve-Tool -LocalPath $localSpotdl -SystemCommand "spotdl.exe" -DisplayName "spotDL"
            $ffmpeg = Resolve-Tool -LocalPath $localFfmpeg -SystemCommand "ffmpeg.exe" -DisplayName "FFmpeg"
            $deno = Resolve-Tool -LocalPath $localDeno -SystemCommand "deno.exe" -DisplayName "Deno"
        }
    }
    elseif ($missingNames.Count -gt 0 -or -not (Test-Path -LiteralPath $localSpotdlConfig)) {
        if (-not (Test-Path -LiteralPath $localSpotdlConfig)) {
            Write-StartupLine "Preparing local spotDL config"
        }
        Invoke-RepairIfNeeded -MissingTools $missingNames
        $spotdl = Resolve-Tool -LocalPath $localSpotdl -SystemCommand "spotdl.exe" -DisplayName "spotDL"
        $ffmpeg = Resolve-Tool -LocalPath $localFfmpeg -SystemCommand "ffmpeg.exe" -DisplayName "FFmpeg"
        $deno = Resolve-Tool -LocalPath $localDeno -SystemCommand "deno.exe" -DisplayName "Deno"
    }

    foreach ($tool in @($spotdl, $ffmpeg, $deno)) {
        if (-not $tool.Path) {
            $offlineHint = if ($Offline) { " Offline mode is enabled." } else { "" }
            throw "$($tool.Name) is unavailable.$offlineHint"
        }
        Log-ResolvedTool -Tool $tool
    }

    $selectedPort = Get-FreePort -StartPort $Port
    Write-StartupLine "Starting local web UI at http://localhost:$selectedPort"

    Push-Location $root
    try {
        $env:SPOTDL_STRICT_PORT = "1"
        & $deno.Path run --allow-net=127.0.0.1:$selectedPort,localhost:$selectedPort --allow-read --allow-write --allow-run --allow-env $server $selectedPort
    }
    finally {
        Remove-Item Env:SPOTDL_STRICT_PORT -ErrorAction SilentlyContinue
        Pop-Location
    }
}
catch {
    $message = if ($_.Exception.Message) { $_.Exception.Message } else { "$_" }
    Write-StartupLine "Startup failed: $message"
    Write-Host "Startup failed; see $startupLog"
    exit 1
}
