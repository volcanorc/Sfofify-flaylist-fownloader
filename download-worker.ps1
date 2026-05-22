param(
    [Parameter(Mandatory = $true)][string]$JobId,
    [Parameter(Mandatory = $true)][string]$RootPath
)

$ErrorActionPreference = "Stop"

$script:Root = $RootPath
$script:HistoryRoot = Join-Path $script:Root "app-data\\history"
$script:DownloadsRoot = Join-Path $script:Root "downloads"
$script:SpotdlExe = Join-Path $script:Root ".tools\\spotdl.exe"
$script:HomeRoot = $script:Root

$env:USERPROFILE = $script:HomeRoot
$env:HOME = $script:HomeRoot

function Get-JobFile {
    param([Parameter(Mandatory = $true)][string]$Id)
    return Join-Path (Join-Path $script:HistoryRoot $Id) "job.json"
}

function Read-Job {
    param([Parameter(Mandatory = $true)][string]$Id)
    $job = Get-Content (Get-JobFile -Id $Id) -Raw -Encoding utf8 | ConvertFrom-Json
    Ensure-JobShape -Job $job
    return $job
}

function Save-Job {
    param([Parameter(Mandatory = $true)]$Job)
    Ensure-JobShape -Job $Job
    $Job.updatedAt = [DateTime]::UtcNow.ToString("o")
    $json = $Job | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-JobFile -Id $Job.id), $json, $utf8NoBom)
}

function Ensure-JobProperty {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $property = $Job.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue
    }
    elseif ($null -eq $property.Value) {
        $property.Value = $DefaultValue
    }
}

function Ensure-JobShape {
    param([Parameter(Mandatory = $true)]$Job)

    Ensure-JobProperty -Job $Job -Name "playlistName" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "playlistId" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "outputFolder" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "trackCount" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "uniqueTrackCount" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "downloadedCount" -DefaultValue 0
    Ensure-JobProperty -Job $Job -Name "missingCount" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "missingSongs" -DefaultValue @()
    Ensure-JobProperty -Job $Job -Name "workerPid" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "matchCount" -DefaultValue 0
    Ensure-JobProperty -Job $Job -Name "currentSong" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "currentProviderPhase" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "error" -DefaultValue $null
}

function Update-JobSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][scriptblock]$Mutator
    )

    $path = Get-JobFile -Id $Id
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $job = Read-Job -Id $Id
            & $Mutator $job
            Save-Job -Job $job
            return $job
        }
        catch {
            Start-Sleep -Milliseconds 120
        }
    }

    throw "Could not update job file after multiple retries."
}

function Update-Job {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$Changes
    )

    return Update-JobSafe -Id $Id -Mutator {
        param($job)
        Ensure-JobShape -Job $job
        foreach ($key in $Changes.Keys) {
            Ensure-JobProperty -Job $job -Name $key -DefaultValue $null
            $job.PSObject.Properties[$key].Value = $Changes[$key]
        }
    }
}

function Add-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Message = ""
    )

    if ($null -eq $Message) {
        $Message = ""
    }

    $job = Read-Job -Id $Id
    $line = "[{0}] {1}{2}" -f ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")), $Message, [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $stream = $null
        $writer = $null
        try {
            $stream = [System.IO.File]::Open($job.logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
            $writer.Write($line)
            $writer.Flush()
            return
        }
        catch {
            Start-Sleep -Milliseconds 120
        }
        finally {
            if ($writer) { $writer.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
    }
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

function Get-PlaylistFolderPath {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadsRoot,
        [Parameter(Mandatory = $true)][string]$PlaylistName
    )

    $folderName = Get-SafeFolderName -Name $PlaylistName
    $candidate = Join-Path $DownloadsRoot $folderName

    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }
    return $candidate
}

function Get-SongDisplayName {
    param([Parameter(Mandatory = $true)]$Song)

    return ("{0} - {1}" -f ([string]::Join(", ", $Song.artists)), $Song.name)
}

function Get-SpotifyUrlType {
    param([Parameter(Mandatory = $true)][string]$Url)

    $match = [regex]::Match($Url, 'open\.spotify\.com/(playlist|track|artist)/', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups[1].Value.ToLowerInvariant()
    }

    return "unknown"
}

function Get-FriendlyWorkerError {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$FallbackMessage,
        [Parameter(Mandatory = $true)][string]$UrlType
    )

    $job = Read-Job -Id $JobId
    $logText = ""
    try {
        $logText = Get-Content $job.logPath -Raw -Encoding utf8
    }
    catch {
        return $FallbackMessage
    }

    if ($logText -match 'Could not get client token') {
        return "Spotify lookup failed because spotDL could not get a Spotify client token."
    }

    if ($logText -match 'Could not get client') {
        return "Spotify lookup failed because spotDL could not get a Spotify client."
    }

    if ($logText -match 'Could not get song info') {
        return "Spotify lookup failed for one or more tracks because spotDL could not get song info."
    }

    if ($logText -match 'Could not get album info') {
        return "Spotify lookup failed for one or more releases because spotDL could not get album info."
    }

    if ($UrlType -eq "artist" -and $logText -match "artist_albums" -and $logText -match "NoneType' object is not subscriptable") {
        return "spotDL could not resolve albums for this Spotify artist link."
    }

    if ($logText -match 'This live event will begin in') {
        return "A YouTube result pointed to a scheduled live event instead of a normal track."
    }

    return $FallbackMessage
}

function Add-WarningLog {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Add-Log -Id $Id -Message $Message
}

function Read-MetadataSongs {
    param([Parameter(Mandatory = $true)][string]$MetadataPath)

    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        return @()
    }

    try {
        $parsed = Get-Content $MetadataPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($null -eq $parsed) {
            return @()
        }
        if ($parsed -is [System.Array]) {
            return @($parsed)
        }
        return @($parsed)
    }
    catch {
        return @()
    }
}

function Update-CurrentSongProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$SongQueue,
        [int]$CompletedCount = 0,
        [string]$ProviderPhase = $null,
        [string]$Phase = $null
    )

    $safeCompletedCount = [Math]::Max(0, [Math]::Min($CompletedCount, $SongQueue.Count))
    $currentSong = $null
    if ($safeCompletedCount -lt $SongQueue.Count) {
        $currentSong = $SongQueue[$safeCompletedCount]
    }

    Update-JobSafe -Id $Id -Mutator {
        param($job)
        Ensure-JobShape -Job $job
        $job.matchCount = $safeCompletedCount
        $job.currentSong = $currentSong
        if ($PSBoundParameters.ContainsKey("ProviderPhase")) {
            $job.currentProviderPhase = $ProviderPhase
        }
        if ($Phase) {
            $job.phase = $Phase
        }
    } | Out-Null
}

function Update-ProgressSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [int]$UniqueSongCount = 0,
        [string]$Phase = $null
    )

    $downloadedCount = 0
    if (Test-Path -LiteralPath $FolderPath) {
        $downloadedCount = (Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    Update-JobSafe -Id $Id -Mutator {
        param($job)
        Ensure-JobShape -Job $job
        $job.downloadedCount = $downloadedCount
        if ($UniqueSongCount -gt 0) {
            $job.missingCount = [Math]::Max($UniqueSongCount - $downloadedCount, 0)
        }
        if ($Phase) {
            $job.phase = $Phase
        }
    } | Out-Null
}

function Invoke-SpotdlWithProgress {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$JobId,
        [string]$ProgressFolder,
        [string[]]$SongQueue = @(),
        [int]$UniqueSongCount = 0,
        [string]$MatchingPhase = "Matching songs to sources",
        [string]$DownloadingPhase = "Downloading files"
    )

    Add-Log -Id $JobId -Message ("Running: spotdl.exe " + ($Arguments -join " "))
    $completedCount = 0
    $downloadStarted = $false
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $script:SpotdlExe @Arguments 2>&1 | ForEach-Object {
            $line = "$_".TrimEnd()
            Add-Log -Id $JobId -Message $line

            if ($line -match 'This live event will begin in') {
                Add-WarningLog -Id $JobId -Message "A YouTube result pointed to a scheduled live event. Trying safer fallback matches."
            }
            elseif ($line -match '--- Logging error ---') {
                Add-WarningLog -Id $JobId -Message "The provider emitted a logging error. The downloader will keep trying safer fallbacks where possible."
            }

            if ($ProgressFolder -and $SongQueue.Count -gt 0) {
                if ($line -match '^Found \d+ songs in ') {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase "Preparing the saved playlist for matching." -Phase "Preparing download queue"
                    return
                }

                $shouldAdvance = $line -match 'Downloaded "' -or $line -match '^Skipping ' -or $line -match '^AudioProviderError:' -or $line -match '^LookupError:'
                if (-not $downloadStarted -and ($shouldAdvance -or $line -match '^Downloading ' -or $line -match '^Converting ')) {
                    $downloadStarted = $true
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase "Downloading matched audio sources." -Phase $DownloadingPhase
                    Update-ProgressSnapshot -Id $JobId -FolderPath $ProgressFolder -UniqueSongCount $UniqueSongCount -Phase $DownloadingPhase
                }

                if ($line -match '^Retrying') {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase "Trying the next source after a provider miss." -Phase $MatchingPhase
                }
                elseif ($line -match '^AudioProviderError:' -or $line -match '^LookupError:') {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase "The current provider missed. Moving to the next source." -Phase $MatchingPhase
                }
                elseif (-not $downloadStarted) {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase "Checking YouTube Music and YouTube for the next track." -Phase $MatchingPhase
                }

                if ($shouldAdvance) {
                    $completedCount = [Math]::Min($completedCount + 1, $SongQueue.Count)
                    $nextProviderPhase = if ($downloadStarted) { "Downloading matched audio sources." } else { "Checking YouTube Music and YouTube for the next track." }
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -ProviderPhase $nextProviderPhase -Phase $(if ($downloadStarted) { $DownloadingPhase } else { $MatchingPhase })
                    Update-ProgressSnapshot -Id $JobId -FolderPath $ProgressFolder -UniqueSongCount $UniqueSongCount -Phase $(if ($downloadStarted) { $DownloadingPhase } else { $MatchingPhase })
                }
            }
        }
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
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

function Invoke-SpotdlSaveWithRetry {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$JobId,
        [int]$MaxAttempts = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $exitCode = Invoke-Spotdl -Arguments $Arguments -WorkingDirectory $WorkingDirectory -JobId $JobId
        if ($exitCode -eq 0) {
            return $exitCode
        }

        if ($attempt -lt $MaxAttempts) {
            Add-Log -Id $JobId -Message ("Save step failed. Retrying metadata fetch (attempt {0} of {1})." -f ($attempt + 1), $MaxAttempts)
            Start-Sleep -Seconds 2
        }
    }

    return $exitCode
}

try {
    if (-not (Test-Path -LiteralPath $script:HistoryRoot)) {
        New-Item -ItemType Directory -Path $script:HistoryRoot | Out-Null
    }

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

    $urlType = Get-SpotifyUrlType -Url $job.url
    $playlistId = if ($job.url -match "/playlist/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/track/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/artist/([A-Za-z0-9]+)") { $Matches[1] } else { $JobId.Substring(0, 8) }
    $playlistName = if ($urlType -eq "artist") { "Artist collection $playlistId" } else { "playlist" }
    $uniqueSongs = @()
    $songQueue = @()

    if ($urlType -eq "artist") {
        $job = Update-Job -Id $JobId -Changes @{
            phase = "Downloading files"
            playlistId = $playlistId
            playlistName = $playlistName
            currentProviderPhase = "Downloading the artist catalog directly from spotDL."
        }
    }
    else {
        $saveArgs = @("save", $job.url, "--save-file", $job.metadataPath)
        $saveExit = Invoke-SpotdlSaveWithRetry -Arguments $saveArgs -WorkingDirectory $script:Root -JobId $JobId
        $songs = Read-MetadataSongs -MetadataPath $job.metadataPath

        if ($saveExit -ne 0 -and $songs.Count -gt 0) {
            Add-WarningLog -Id $JobId -Message ("Spotify metadata finished with some lookup errors. Continuing with {0} saved songs." -f $songs.Count)
        }

        if ($songs.Count -eq 0) {
            throw (Get-FriendlyWorkerError -JobId $JobId -FallbackMessage "spotDL could not save playlist metadata." -UrlType $urlType)
        }

        $uniqueSongs = Get-UniqueSongs -Songs $songs
        $songQueue = @($uniqueSongs | ForEach-Object { Get-SongDisplayName -Song $_ })
        $playlistName = if ($songs[0].list_name) { $songs[0].list_name } else { "playlist" }
    }

    $outputFolder = Get-PlaylistFolderPath -DownloadsRoot $script:DownloadsRoot -PlaylistName $playlistName

    if (-not (Test-Path -LiteralPath $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $job = Update-Job -Id $JobId -Changes @{
        phase = if ($urlType -eq "artist") { "Downloading files" } else { "Preparing download queue" }
        playlistName = $playlistName
        playlistId = $playlistId
        outputFolder = $outputFolder
        trackCount = if ($urlType -eq "artist") { $null } else { $songs.Count }
        uniqueTrackCount = if ($urlType -eq "artist") { $null } else { $uniqueSongs.Count }
        downloadedCount = 0
        matchCount = 0
        currentSong = if ($songQueue.Count -gt 0) { $songQueue[0] } else { $null }
        currentProviderPhase = if ($urlType -eq "artist") { "Downloading the artist catalog directly from spotDL." } else { "Preparing the saved playlist for matching." }
        missingSongs = if ($urlType -eq "artist") { @() } else { $uniqueSongs | ForEach-Object {
                [pscustomobject]@{
                    artist = [string]::Join(", ", $_.artists)
                    title = $_.name
                    url = $_.url
                }
            }
        }
        missingCount = if ($urlType -eq "artist") { $null } else { $uniqueSongs.Count }
    }

    if ($urlType -eq "artist") {
        $mainArgs = @(
            "download",
            $job.url,
            "--audio", "youtube-music", "youtube",
            "--threads", "4",
            "--overwrite", "skip",
            "--output", "{artists} - {title}.{output-ext}",
            "--print-errors"
        )
        [void](Invoke-SpotdlWithProgress -Arguments $mainArgs -WorkingDirectory $outputFolder -JobId $JobId -ProgressFolder $outputFolder)
        $finalDownloadedCount = (Get-ChildItem -LiteralPath $outputFolder -File -ErrorAction SilentlyContinue | Measure-Object).Count

        Update-Job -Id $JobId -Changes @{
            status = "completed"
            phase = "Finished"
            downloadedCount = $finalDownloadedCount
            workerPid = $null
            currentSong = $null
            currentProviderPhase = $null
            error = $null
        } | Out-Null

        Add-Log -Id $JobId -Message ("Finished. Downloaded files: {0}. Missing songs: 0." -f $finalDownloadedCount)
    }
    else {
        $mainArgs = @(
            "download",
            $job.metadataPath,
            "--audio", "youtube-music", "youtube",
            "--threads", "4",
            "--overwrite", "skip",
            "--output", "{artists} - {title}.{output-ext}",
            "--print-errors"
        )
        Update-CurrentSongProgress -Id $JobId -SongQueue $songQueue -CompletedCount 0 -ProviderPhase "Checking YouTube Music and YouTube for the next track." -Phase "Matching songs to sources"
        [void](Invoke-SpotdlWithProgress -Arguments $mainArgs -WorkingDirectory $outputFolder -JobId $JobId -ProgressFolder $outputFolder -SongQueue $songQueue -UniqueSongCount $uniqueSongs.Count -MatchingPhase "Matching songs to sources" -DownloadingPhase "Downloading files")

        $missingSongs = Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder
        $job = Update-Job -Id $JobId -Changes @{
            phase = "Retrying missing songs"
            missingSongs = $missingSongs
            missingCount = $missingSongs.Count
            downloadedCount = (Get-ChildItem -LiteralPath $outputFolder -File -ErrorAction SilentlyContinue | Measure-Object).Count
            matchCount = $job.uniqueTrackCount - $missingSongs.Count
            currentSong = if ($missingSongs.Count -gt 0) { "{0} - {1}" -f $missingSongs[0].artist, $missingSongs[0].title } else { $null }
            currentProviderPhase = if ($missingSongs.Count -gt 0) { "Retrying missing songs with fallback sources." } else { "Checking whether any files still need a retry." }
        }

        foreach ($song in $missingSongs) {
            Add-Log -Id $JobId -Message ("Retrying missing song: {0} - {1}" -f $song.artist, $song.title)
            Update-Job -Id $JobId -Changes @{
                currentSong = "{0} - {1}" -f $song.artist, $song.title
                currentProviderPhase = "Trying YouTube Music, YouTube, and SoundCloud for a missing track."
            } | Out-Null
            $retryArgs = @(
                "download",
                $song.url,
                "--threads", "1",
                "--audio", "youtube-music", "youtube", "soundcloud",
                "--dont-filter-results",
                "--overwrite", "skip",
                "--output", "{artists} - {title}.{output-ext}",
                "--print-errors"
            )
            [void](Invoke-SpotdlWithProgress -Arguments $retryArgs -WorkingDirectory $outputFolder -JobId $JobId -ProgressFolder $outputFolder -SongQueue @("{0} - {1}" -f $song.artist, $song.title) -UniqueSongCount $uniqueSongs.Count -MatchingPhase "Retrying missing songs" -DownloadingPhase "Retrying missing songs")
        }

        $finalMissingSongs = Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder
        $finalDownloadedCount = (Get-ChildItem -LiteralPath $outputFolder -File -ErrorAction SilentlyContinue | Measure-Object).Count

        Update-Job -Id $JobId -Changes @{
            status = "completed"
            phase = "Finished"
            missingSongs = $finalMissingSongs
            missingCount = $finalMissingSongs.Count
            downloadedCount = $finalDownloadedCount
            workerPid = $null
            matchCount = $uniqueSongs.Count
            currentSong = $null
            currentProviderPhase = $null
            error = $null
        } | Out-Null

        Add-Log -Id $JobId -Message ("Finished. Downloaded files: {0}. Missing songs: {1}." -f $finalDownloadedCount, $finalMissingSongs.Count)
    }
}
catch {
    $message = Get-FriendlyWorkerError -JobId $JobId -FallbackMessage $_.Exception.Message -UrlType (Get-SpotifyUrlType -Url ((Read-Job -Id $JobId).url))
    Add-Log -Id $JobId -Message ("Worker failed: " + $message)
    Update-Job -Id $JobId -Changes @{
        status = "failed"
        phase = "Failed"
        workerPid = $null
        currentProviderPhase = $null
        error = $message
    } | Out-Null
}
