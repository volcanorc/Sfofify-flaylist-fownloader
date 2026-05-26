param(
    [Parameter(Mandatory = $true)][string]$JobId,
    [Parameter(Mandatory = $true)][string]$RootPath
)

$ErrorActionPreference = "Stop"

$script:Root = $RootPath
$script:HistoryRoot = Join-Path $script:Root "app-data\\history"
$script:DownloadsRoot = Join-Path $script:Root "downloads"
$script:SpotdlExe = Join-Path $script:Root ".tools\\spotdl.exe"
$script:SpotdlConfigPath = Join-Path $script:Root ".spotdl\\config.json"
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
    Ensure-JobProperty -Job $Job -Name "retryOf" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "resumeFromJobId" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "resumeOnlyMissing" -DefaultValue $false
    Ensure-JobProperty -Job $Job -Name "resumeOutputFolder" -DefaultValue $null
    Ensure-JobProperty -Job $Job -Name "missingSongsKnown" -DefaultValue $false
    Ensure-JobProperty -Job $Job -Name "replacedByJobId" -DefaultValue $null
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

    $match = [regex]::Match($Url, 'open\.spotify\.com/(playlist|track|artist|album)/', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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

    if ($logText -match 'YT-DLP download error') {
        return "A provider download failed while spotDL was trying fallback audio sources."
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

function Test-SpotdlLoggingNoiseLine {
    param([AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    return (
        $Line -match '--- Logging error ---' -or
        $Line -match '^Traceback \(most recent call last\):$' -or
        $Line -match '^Call stack:$' -or
        $Line -match '^Logged from file ' -or
        $Line -match '^Message:$' -or
        $Line -match '^Arguments:$'
    )
}

function Get-SpotdlConfig {
    if ($script:SpotdlConfig) {
        return $script:SpotdlConfig
    }

    $configPath = Join-Path $script:Root ".spotdl\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "spotDL config was not found at $configPath"
    }

    $script:SpotdlConfig = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    return $script:SpotdlConfig
}

function Get-SpotifyApiAccessToken {
    if ($script:SpotifyApiAccessToken -and $script:SpotifyApiAccessTokenExpiresAt -gt (Get-Date).AddMinutes(2)) {
        return $script:SpotifyApiAccessToken
    }

    $config = Get-SpotdlConfig
    if ($config.auth_token) {
        $script:SpotifyApiAccessToken = [string]$config.auth_token
        $script:SpotifyApiAccessTokenExpiresAt = (Get-Date).AddMinutes(30)
        return $script:SpotifyApiAccessToken
    }

    if (-not $config.client_id -or -not $config.client_secret) {
        throw "Spotify API credentials are missing from the local spotDL config."
    }

    $pair = "{0}:{1}" -f $config.client_id, $config.client_secret
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://accounts.spotify.com/api/token" -Headers @{
        Authorization = "Basic $basic"
    } -ContentType "application/x-www-form-urlencoded" -Body "grant_type=client_credentials"

    if (-not $tokenResponse.access_token) {
        throw "Spotify API did not return an access token."
    }

    $script:SpotifyApiAccessToken = [string]$tokenResponse.access_token
    $expiresIn = if ($tokenResponse.expires_in) { [int]$tokenResponse.expires_in } else { 3600 }
    $script:SpotifyApiAccessTokenExpiresAt = (Get-Date).AddSeconds($expiresIn)
    return $script:SpotifyApiAccessToken
}

function Invoke-SpotifyApiJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri
    )

    $token = Get-SpotifyApiAccessToken
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers @{
        Authorization = "Bearer $token"
    }
}

function Get-SpotifyPagedItems {
    param(
        [Parameter(Mandatory = $true)][string]$Uri
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-SpotifyApiJson -Uri $nextUri
        foreach ($item in @($response.items)) {
            $items.Add($item)
        }
        $nextUri = $response.next
    }

    return $items
}

function Write-MetadataSongs {
    param(
        [Parameter(Mandatory = $true)]$Songs,
        [Parameter(Mandatory = $true)][string]$MetadataPath
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $Songs | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($MetadataPath, $json, $utf8NoBom)
}

function Expand-ArtistToMetadataSongs {
    param(
        [Parameter(Mandatory = $true)][string]$ArtistId,
        [Parameter(Mandatory = $true)][string]$ArtistUrl,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    $artist = Invoke-SpotifyApiJson -Uri ("https://api.spotify.com/v1/artists/{0}" -f $ArtistId)
    if (-not $artist -or -not $artist.id) {
        throw "Could not load this artist's discography from Spotify."
    }

    Update-Job -Id $JobId -Changes @{
        phase = "Reading artist releases from Spotify"
        playlistName = $artist.name
        playlistId = $ArtistId
        currentProviderPhase = "Fetching albums, singles, and compilations from Spotify."
    } | Out-Null

    $albumItems = Get-SpotifyPagedItems -Uri ("https://api.spotify.com/v1/artists/{0}/albums?include_groups=album,single,compilation&limit=50&offset=0&market=US" -f $ArtistId)
    $albumIds = New-Object System.Collections.Generic.List[string]
    $seenAlbums = @{}

    foreach ($album in $albumItems) {
        if ($album.id -and -not $seenAlbums.ContainsKey($album.id)) {
            $seenAlbums[$album.id] = $true
            $albumIds.Add([string]$album.id)
        }
    }

    Update-Job -Id $JobId -Changes @{
        phase = "Collecting tracks from the artist catalog"
        currentProviderPhase = ("Loading tracks from {0} releases." -f $albumIds.Count)
    } | Out-Null

    $songs = New-Object System.Collections.Generic.List[object]
    $seenSongs = @{}

    for ($index = 0; $index -lt $albumIds.Count; $index++) {
        $albumId = $albumIds[$index]
        try {
            Update-Job -Id $JobId -Changes @{
                currentProviderPhase = ("Collecting tracks from release {0} of {1}." -f ($index + 1), $albumIds.Count)
            } | Out-Null

            $album = Invoke-SpotifyApiJson -Uri ("https://api.spotify.com/v1/albums/{0}?market=US" -f $albumId)
            if (-not $album -or -not $album.id) {
                continue
            }

            $tracks = New-Object System.Collections.Generic.List[object]
            foreach ($track in @($album.tracks.items)) {
                $tracks.Add($track)
            }

            $nextTracksUri = $album.tracks.next
            while ($nextTracksUri) {
                $trackPage = Invoke-SpotifyApiJson -Uri $nextTracksUri
                foreach ($track in @($trackPage.items)) {
                    $tracks.Add($track)
                }
                $nextTracksUri = $trackPage.next
            }

            $discCount = 1
            if ($tracks.Count -gt 0) {
                $discCount = (($tracks | Measure-Object -Property disc_number -Maximum).Maximum)
                if (-not $discCount) {
                    $discCount = 1
                }
            }

            foreach ($track in $tracks) {
                if (-not $track.id) {
                    continue
                }

                $songKey = [string]$track.id
                if ($seenSongs.ContainsKey($songKey)) {
                    continue
                }
                $seenSongs[$songKey] = $true

                $trackArtists = @($track.artists | ForEach-Object { $_.name })
                $trackArtistId = $null
                if ($track.artists -and $track.artists[0].id) {
                    $trackArtistId = $track.artists[0].id
                }

                $releaseDate = if ($album.release_date) { [string]$album.release_date } else { "" }
                $releaseYear = $null
                if ($releaseDate -match '^\d{4}') {
                    $releaseYear = [int]$Matches[0]
                }

                $songs.Add([pscustomobject]@{
                    name = $track.name
                    artists = $trackArtists
                    artist = if ($trackArtists.Count -gt 0) { $trackArtists[0] } else { $artist.name }
                    genres = @($artist.genres)
                    disc_number = if ($track.disc_number) { [int]$track.disc_number } else { 1 }
                    disc_count = [int]$discCount
                    album_name = $album.name
                    album_artist = [string]::Join(", ", @($album.artists | ForEach-Object { $_.name }))
                    duration = [Math]::Round(([double]$track.duration_ms) / 1000)
                    year = $releaseYear
                    date = $releaseDate
                    track_number = if ($track.track_number) { [int]$track.track_number } else { $null }
                    tracks_count = if ($album.total_tracks) { [int]$album.total_tracks } else { $tracks.Count }
                    song_id = $track.id
                    explicit = [bool]$track.explicit
                    publisher = if ($album.label) { $album.label } else { "" }
                    url = $track.external_urls.spotify
                    isrc = ""
                    cover_url = if ($album.images -and $album.images[0].url) { $album.images[0].url } else { "" }
                    copyright_text = if ($album.copyrights -and $album.copyrights[0].text) { $album.copyrights[0].text } else { "" }
                    download_url = $null
                    lyrics = $null
                    popularity = 0
                    album_id = $album.id
                    list_name = $artist.name
                    list_url = $ArtistUrl
                    list_position = 0
                    list_length = 0
                    artist_id = $trackArtistId
                    album_type = $album.album_type
                })
            }
        }
        catch {
            Add-WarningLog -Id $JobId -Message ("Could not expand one release from the artist catalog. Continuing with the rest.")
        }
    }

    $totalSongs = $songs.Count
    for ($index = 0; $index -lt $songs.Count; $index++) {
        $songs[$index].list_position = $index + 1
        $songs[$index].list_length = $totalSongs
    }

    return [pscustomobject]@{
        ArtistName = $artist.name
        Songs = @($songs)
    }
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

function Get-DownloadedFileCount {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    if (-not (Test-Path -LiteralPath $FolderPath)) {
        return 0
    }

    return (Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue | Measure-Object).Count
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

    $spotdlArgs = if (Test-Path -LiteralPath $script:SpotdlConfigPath) { @("--config") + $Arguments } else { $Arguments }
    Add-Log -Id $JobId -Message ("Running: spotdl.exe " + ($spotdlArgs -join " "))
    $completedCount = 0
    $downloadStarted = $false
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $script:SpotdlExe @spotdlArgs 2>&1 | ForEach-Object {
            $line = "$_".TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line)) {
                return
            }
            if (Test-SpotdlLoggingNoiseLine -Line $line) {
                return
            }

            Add-Log -Id $JobId -Message $line

            if ($line -match 'This live event will begin in') {
                Add-WarningLog -Id $JobId -Message "A YouTube result pointed to a scheduled live event. Trying safer fallback matches."
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

    $spotdlArgs = if (Test-Path -LiteralPath $script:SpotdlConfigPath) { @("--config") + $Arguments } else { $Arguments }
    Add-Log -Id $JobId -Message ("Running: spotdl.exe " + ($spotdlArgs -join " "))
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $script:SpotdlExe @spotdlArgs 2>&1 | ForEach-Object {
            $line = "$_".TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line)) {
                return
            }
            if (Test-SpotdlLoggingNoiseLine -Line $line) {
                return
            }
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
    $playlistId = if ($job.url -match "/playlist/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/track/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/artist/([A-Za-z0-9]+)") { $Matches[1] } elseif ($job.url -match "/album/([A-Za-z0-9]+)") { $Matches[1] } else { $JobId.Substring(0, 8) }
    $playlistName = if ($urlType -eq "artist") { "Artist collection $playlistId" } elseif ($urlType -eq "album") { "Album $playlistId" } else { "playlist" }
    $uniqueSongs = @()
    $songQueue = @()
    $songs = @()

    if ($urlType -eq "artist") {
        if ($job.resumeOnlyMissing -and (Test-Path -LiteralPath $job.metadataPath)) {
            $songs = Read-MetadataSongs -MetadataPath $job.metadataPath
        }

        if ($songs.Count -eq 0) {
            try {
                $artistCatalog = Expand-ArtistToMetadataSongs -ArtistId $playlistId -ArtistUrl $job.url -JobId $JobId
                $songs = @($artistCatalog.Songs)
                if ($artistCatalog.ArtistName) {
                    $playlistName = [string]$artistCatalog.ArtistName
                }
                if ($songs.Count -gt 0) {
                    Write-MetadataSongs -Songs $songs -MetadataPath $job.metadataPath
                }
            }
            catch {
                throw "Could not load this artist's discography from Spotify."
            }
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
    }

    if ($songs.Count -eq 0) {
        throw "Could not load this artist's discography from Spotify."
    }

    $uniqueSongs = Get-UniqueSongs -Songs $songs
    $songQueue = @($uniqueSongs | ForEach-Object { Get-SongDisplayName -Song $_ })
    $playlistName = if ($songs[0].list_name) { $songs[0].list_name } else { $playlistName }

    $outputFolder = if (-not [string]::IsNullOrWhiteSpace($job.resumeOutputFolder)) {
        $job.resumeOutputFolder
    }
    else {
        Get-PlaylistFolderPath -DownloadsRoot $script:DownloadsRoot -PlaylistName $playlistName
    }

    if (-not (Test-Path -LiteralPath $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $existingDownloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder
    $resumePendingSongs = @()
    if ($job.resumeOnlyMissing) {
        $resumePendingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
        $songQueue = @($resumePendingSongs | ForEach-Object { "{0} - {1}" -f $_.artist, $_.title })
    }

    $job = Update-Job -Id $JobId -Changes @{
        phase = if ($job.resumeOnlyMissing) { "Retrying missing songs" } else { "Preparing download queue" }
        playlistName = $playlistName
        playlistId = $playlistId
        outputFolder = $outputFolder
        trackCount = $songs.Count
        uniqueTrackCount = $uniqueSongs.Count
        downloadedCount = $existingDownloadedCount
        matchCount = if ($job.resumeOnlyMissing -and $uniqueSongs.Count -gt 0) { [Math]::Max($uniqueSongs.Count - $resumePendingSongs.Count, 0) } else { 0 }
        currentSong = if ($songQueue.Count -gt 0) { $songQueue[0] } else { $null }
        currentProviderPhase = if ($job.resumeOnlyMissing) { "Retrying only the songs still missing from the last attempt." } elseif ($urlType -eq "artist") { "Preparing the artist catalog for matching." } else { "Preparing the saved playlist for matching." }
        missingSongs = if ($job.resumeOnlyMissing) { $resumePendingSongs } else { @() }
        missingCount = if ($job.resumeOnlyMissing) { $resumePendingSongs.Count } elseif ($uniqueSongs.Count -gt 0) { [Math]::Max($uniqueSongs.Count - $existingDownloadedCount, 0) } else { $null }
        missingSongsKnown = [bool]$job.resumeOnlyMissing
    }

    if ($job.resumeOnlyMissing) {
        if ($resumePendingSongs.Count -eq 0) {
            Update-Job -Id $JobId -Changes @{
                status = "completed"
                phase = "Finished"
                downloadedCount = $existingDownloadedCount
                workerPid = $null
                currentSong = $null
                currentProviderPhase = $null
                missingSongs = @()
                missingCount = 0
                missingSongsKnown = $true
                error = $null
            } | Out-Null

            Add-Log -Id $JobId -Message "Nothing left to retry. All files are already present."
        }
        else {
            foreach ($song in $resumePendingSongs) {
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
            $finalDownloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder

            Update-Job -Id $JobId -Changes @{
                status = "completed"
                phase = "Finished"
                missingSongs = $finalMissingSongs
                missingCount = $finalMissingSongs.Count
                downloadedCount = $finalDownloadedCount
                workerPid = $null
                matchCount = [Math]::Max($uniqueSongs.Count - $finalMissingSongs.Count, 0)
                currentSong = $null
                currentProviderPhase = $null
                missingSongsKnown = $true
                error = $null
            } | Out-Null

            Add-Log -Id $JobId -Message ("Finished. Downloaded files: {0}. Missing songs: {1}." -f $finalDownloadedCount, $finalMissingSongs.Count)
        }
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
            downloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder
            matchCount = $job.uniqueTrackCount - $missingSongs.Count
            currentSong = if ($missingSongs.Count -gt 0) { "{0} - {1}" -f $missingSongs[0].artist, $missingSongs[0].title } else { $null }
            currentProviderPhase = if ($missingSongs.Count -gt 0) { "Retrying missing songs with fallback sources." } else { "Checking whether any files still need a retry." }
            missingSongsKnown = $true
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
        $finalDownloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder

        Update-Job -Id $JobId -Changes @{
            status = "completed"
            phase = "Finished"
            missingSongs = $finalMissingSongs
            missingCount = $finalMissingSongs.Count
            downloadedCount = $finalDownloadedCount
            workerPid = $null
            matchCount = [Math]::Max($uniqueSongs.Count - $finalMissingSongs.Count, 0)
            currentSong = $null
            currentProviderPhase = $null
            missingSongsKnown = $true
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
