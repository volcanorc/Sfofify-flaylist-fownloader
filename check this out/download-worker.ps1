param(
    [Parameter(Mandatory = $true)][string]$JobId,
    [Parameter(Mandatory = $true)][string]$RootPath
)

$ErrorActionPreference = "Stop"

$script:Root = $RootPath
$script:JobsRoot = Join-Path $script:Root "app-data\\jobs"
$script:DownloadsRoot = Join-Path $script:Root "downloads"
$script:SpotdlExe = Join-Path $script:Root ".tools\\spotdl.exe"
$script:HomeRoot = $script:Root

$env:USERPROFILE = $script:HomeRoot
$env:HOME = $script:HomeRoot

function Get-JobFile {
    param([Parameter(Mandatory = $true)][string]$Id)
    return Join-Path $script:JobsRoot "$Id.json"
}

function Read-Job {
    param([Parameter(Mandatory = $true)][string]$Id)
    return Get-Content (Get-JobFile -Id $Id) -Raw -Encoding utf8 | ConvertFrom-Json
}

function Save-Job {
    param([Parameter(Mandatory = $true)]$Job)
    $Job.updatedAt = [DateTime]::UtcNow.ToString("o")
    $json = $Job | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-JobFile -Id $Job.id), $json, $utf8NoBom)
}

function Update-Job {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$Changes
    )

    $job = Read-Job -Id $Id
    foreach ($key in $Changes.Keys) {
        $job.$key = $Changes[$key]
    }
    Save-Job -Job $job
    return $job
}

function Add-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [AllowEmptyString()][string]$Message
    )

    $job = Read-Job -Id $Id
    if ($null -eq $Message) {
        $Message = ""
    }
    $line = "[{0}] {1}" -f ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")), $Message
    Add-Content -LiteralPath $job.logPath -Value $line -Encoding utf8
}

function Normalize-Name {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $text = $Value.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    $text = $text -replace "&", " and "
    $text = $text -replace "[^\p{L}\p{Nd}]+", ""
    return $text
}

function Get-UniqueSongs {
    param([Parameter(Mandatory = $true)]$Songs)

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($song in $Songs) {
        $key = ([string]::Join(", ", $song.artists)) + " - " + $song.name
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($song)
        }
    }

    return $unique
}

function Get-MissingSongs {
    param(
        [Parameter(Mandatory = $true)]$Songs,
        [Parameter(Mandatory = $true)][string]$FolderPath
    )

    $files = @()
    if (Test-Path -LiteralPath $FolderPath) {
        $files = Get-ChildItem -LiteralPath $FolderPath -File | Select-Object -ExpandProperty BaseName
    }

    $fileNorms = @{}
    foreach ($file in $files) {
        $fileNorms[(Normalize-Name -Value $file)] = $true
    }

    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($song in $Songs) {
        $artists = [string]::Join(", ", $song.artists)
        $expected = "$artists - $($song.name)"
        $songNorm = Normalize-Name -Value $song.name
        $expectedNorm = Normalize-Name -Value $expected
        $matched = $fileNorms.ContainsKey($expectedNorm)

        if (-not $matched) {
            foreach ($file in $files) {
                $fileNorm = Normalize-Name -Value $file
                if ($fileNorm.Contains($songNorm) -or $songNorm.Contains($fileNorm)) {
                    $matched = $true
                    break
                }
            }
        }

        if (-not $matched) {
            $missing.Add([pscustomobject]@{
                artist = $artists
                title = $song.name
                url = $song.url
            })
        }
    }

    return $missing
}

function Get-SafeFolderName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safe = $Name -replace '[<>:"/\\|?*]', "-"
    $safe = $safe -replace "\s+", " "
    $safe = $safe.Trim(" .")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "playlist"
    }

    return $safe
}

function Invoke-Spotdl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    Add-Log -Id $JobId -Message ("Running: spotdl.exe " + ($Arguments -join " "))
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $script:SpotdlExe @Arguments 2>&1 | ForEach-Object {
            $line = "$_".TrimEnd()
            Add-Log -Id $JobId -Message $line
        }
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

try {
    $job = Update-Job -Id $JobId -Changes @{
        status = "running"
        phase = "Saving playlist metadata"
    }

    if (-not (Test-Path $script:SpotdlExe)) {
        throw "Missing spotdl executable at $script:SpotdlExe"
    }

    if (-not (Test-Path $job.logPath)) {
        New-Item -ItemType File -Path $job.logPath | Out-Null
    }

    $saveArgs = @("save", $job.url, "--save-file", $job.metadataPath)
    $saveExit = Invoke-Spotdl -Arguments $saveArgs -WorkingDirectory $script:Root -JobId $JobId
    if ($saveExit -ne 0 -or -not (Test-Path $job.metadataPath)) {
        throw "spotDL could not save playlist metadata."
    }

    $songs = Get-Content $job.metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($songs.Count -eq 0) {
        throw "No songs were found in the playlist."
    }

    $uniqueSongs = Get-UniqueSongs -Songs $songs
    $playlistName = if ($songs[0].list_name) { $songs[0].list_name } else { "playlist" }
    $playlistId = if ($job.url -match "/playlist/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/track/([A-Za-z0-9]+)") { $Matches[1] } else { $JobId.Substring(0, 8) }
    $folderName = Get-SafeFolderName -Name ("{0} ({1})" -f $playlistName, $playlistId)
    $outputFolder = Join-Path $script:DownloadsRoot $folderName

    if (-not (Test-Path -LiteralPath $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $job = Update-Job -Id $JobId -Changes @{
        phase = "Downloading playlist"
        playlistName = $playlistName
        playlistId = $playlistId
        outputFolder = $outputFolder
        trackCount = $songs.Count
        uniqueTrackCount = $uniqueSongs.Count
    }

    $mainArgs = @(
        "download",
        $job.url,
        "--threads", "4",
        "--save-file", $job.metadataPath,
        "--overwrite", "skip",
        "--output", "{artists} - {title}.{output-ext}",
        "--print-errors"
    )
    [void](Invoke-Spotdl -Arguments $mainArgs -WorkingDirectory $outputFolder -JobId $JobId)

    $missingSongs = Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder
    $job = Update-Job -Id $JobId -Changes @{
        phase = "Retrying missing songs"
        missingSongs = $missingSongs
        missingCount = $missingSongs.Count
        downloadedCount = (Get-ChildItem -LiteralPath $outputFolder -File -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    foreach ($song in $missingSongs) {
        Add-Log -Id $JobId -Message ("Retrying missing song: {0} - {1}" -f $song.artist, $song.title)
        $retryArgs = @(
            "download",
            $song.url,
            "--threads", "1",
            "--audio", "soundcloud", "youtube-music", "youtube",
            "--dont-filter-results",
            "--overwrite", "skip",
            "--output", "{artists} - {title}.{output-ext}",
            "--print-errors"
        )
        [void](Invoke-Spotdl -Arguments $retryArgs -WorkingDirectory $outputFolder -JobId $JobId)
    }

    $finalMissingSongs = Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder
    $finalDownloadedCount = (Get-ChildItem -LiteralPath $outputFolder -File -ErrorAction SilentlyContinue | Measure-Object).Count

    Update-Job -Id $JobId -Changes @{
        status = "completed"
        phase = "Finished"
        missingSongs = $finalMissingSongs
        missingCount = $finalMissingSongs.Count
        downloadedCount = $finalDownloadedCount
        error = $null
    } | Out-Null

    Add-Log -Id $JobId -Message ("Finished. Downloaded files: {0}. Missing songs: {1}." -f $finalDownloadedCount, $finalMissingSongs.Count)
}
catch {
    $message = $_.Exception.Message
    Add-Log -Id $JobId -Message ("Worker failed: " + $message)
    Update-Job -Id $JobId -Changes @{
        status = "failed"
        phase = "Failed"
        error = $message
    } | Out-Null
}
