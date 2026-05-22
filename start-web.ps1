param(
    [int]$Port = 8976,
    [switch]$SkipRepair
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$deno = Join-Path $root ".spotdl\deno.exe"
$server = Join-Path $root "server.ts"
$repair = Join-Path $root "repair-runtime.ps1"

if (-not $SkipRepair) {
    & $repair -Quiet
}

if (-not (Test-Path $deno)) {
    throw "Deno was not found at $deno"
}

if (-not (Test-Path $server)) {
    throw "Server file was not found at $server"
}

Push-Location $root
try {
    & $deno run --allow-net=127.0.0.1:8976,localhost:8976 --allow-read --allow-write --allow-run --allow-env $server $Port
}
finally {
    Pop-Location
}
