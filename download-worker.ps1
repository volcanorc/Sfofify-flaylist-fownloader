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

function Get-JobDirectory {
    param([Parameter(Mandatory = $true)][string]$Id)
    return Join-Path $script:HistoryRoot $Id
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
    $Job.missingSongs = @(Get-ArrayValue -Value $Job.missingSongs)
    if ($null -ne $Job.missingCount) {
        $Job.missingCount = [int]$Job.missingCount
    }
    $Job.downloadedCount = [int]$Job.downloadedCount
    $Job.matchCount = [int]$Job.matchCount
}

function Get-ArrayValue {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value)
    }

    return @($Value)
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

    if ($FallbackMessage -match '\(429\)\s+Too Many Requests' -or $logText -match 'Spotify rate-limited the' -or $logText -match 'Spotify temporarily rate-limited artist metadata requests' -or $logText -match 'Spotify temporarily rate-limited artist top-track lookup') {
        return "Spotify temporarily rate-limited artist metadata lookup."
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

    if ($UrlType -eq "artist" -and $logText -match 'Could not get artist') {
        return "Spotify lookup failed because spotDL could not open this artist page."
    }

    if ($UrlType -eq "artist" -and $logText -match 'artist_albums' -and $logText -match "NoneType' object is not subscriptable") {
        return "Spotify lookup failed because spotDL could not read the artist catalog."
    }

    if ($UrlType -eq "artist" -and $logText -match 'official Spotify Web API') {
        return "Spotify lookup failed while spotDL was retrying the artist with the official Spotify API."
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
        $Line -match '^\s*File ".*", line \d+, in .+$' -or
        $Line -match '^\+\-+\+$' -or
        $Line -match '^\|.*\|$' -or
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
    param(
        [string]$JobId
    )

    if ($script:SpotifyApiAccessToken -and $script:SpotifyApiAccessTokenExpiresAt -gt (Get-Date).AddMinutes(2)) {
        return $script:SpotifyApiAccessToken
    }

    try {
        $webTokenResponse = Invoke-SpotifyApiRequestWithRetry -Method "Get" -Uri "https://open.spotify.com/get_access_token?reason=transport&productType=web_player" -Headers @{} -JobId $JobId -StageLabel "Spotify web access token"
        if ($webTokenResponse.accessToken) {
            $script:SpotifyApiAccessToken = [string]$webTokenResponse.accessToken
            $expiresAt = $null
            if ($webTokenResponse.accessTokenExpirationTimestampMs) {
                try {
                    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$webTokenResponse.accessTokenExpirationTimestampMs).UtcDateTime
                }
                catch {
                }
            }
            $script:SpotifyApiAccessTokenExpiresAt = if ($expiresAt) { $expiresAt } else { (Get-Date).AddMinutes(30) }
            return $script:SpotifyApiAccessToken
        }
    }
    catch {
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
    $tokenResponse = Invoke-SpotifyApiRequestWithRetry -Method "Post" -Uri "https://accounts.spotify.com/api/token" -Headers @{
        Authorization = "Basic $basic"
    } -ContentType "application/x-www-form-urlencoded" -Body "grant_type=client_credentials" -JobId $JobId -StageLabel "Spotify access token"

    if (-not $tokenResponse.access_token) {
        throw "Spotify API did not return an access token."
    }

    $script:SpotifyApiAccessToken = [string]$tokenResponse.access_token
    $expiresIn = if ($tokenResponse.expires_in) { [int]$tokenResponse.expires_in } else { 3600 }
    $script:SpotifyApiAccessTokenExpiresAt = (Get-Date).AddSeconds($expiresIn)
    return $script:SpotifyApiAccessToken
}

function Get-SpotifyApiStatusCode {
    param([Parameter(Mandatory = $true)]$Exception)

    try {
        if ($Exception.Response -and $Exception.Response.StatusCode) {
            return [int]$Exception.Response.StatusCode
        }
    }
    catch {
    }

    return $null
}

function Get-SpotifyApiRetryAfterSeconds {
    param([Parameter(Mandatory = $true)]$Exception)

    try {
        if (-not $Exception.Response -or -not $Exception.Response.Headers) {
            return $null
        }

        $retryAfter = [string]$Exception.Response.Headers["Retry-After"]
        if ([string]::IsNullOrWhiteSpace($retryAfter)) {
            return $null
        }

        $parsedSeconds = 0
        if ([int]::TryParse($retryAfter, [ref]$parsedSeconds)) {
            return [Math]::Max($parsedSeconds, 1)
        }

        $retryAt = $null
        if ([DateTime]::TryParse($retryAfter, [ref]$retryAt)) {
            $seconds = [Math]::Ceiling(($retryAt.ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds)
            return [Math]::Max([int]$seconds, 1)
        }
    }
    catch {
    }

    return $null
}

function Test-SpotifyApiTransientFailure {
    param([int]$StatusCode)

    if ($StatusCode -eq 429) {
        return $true
    }

    if ($StatusCode -ge 500 -and $StatusCode -lt 600) {
        return $true
    }

    return $false
}

function Get-SpotifyApiBackoffSeconds {
    param(
        [int]$AttemptNumber,
        [int]$RetryAfterSeconds
    )

    $maxRetryAfterSeconds = 20

    if ($RetryAfterSeconds -gt 0) {
        return [Math]::Min($RetryAfterSeconds, $maxRetryAfterSeconds)
    }

    $baseDelay = [Math]::Min([Math]::Pow(2, [Math]::Max($AttemptNumber - 1, 0)), 20)
    $jitter = Get-Random -Minimum 1 -Maximum 4
    return [int]([Math]::Min($baseDelay + $jitter, $maxRetryAfterSeconds))
}

function Invoke-SpotifyApiRequestWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [string]$ContentType,
        $Body,
        [string]$JobId,
        [Parameter(Mandatory = $true)][string]$StageLabel,
        [int]$MaxAttempts = 5,
        [switch]$AllowTokenRefresh
    )

    $refreshedToken = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $invokeParams = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ErrorAction = "Stop"
            }

            if ($PSBoundParameters.ContainsKey("ContentType") -and $null -ne $ContentType) {
                $invokeParams.ContentType = $ContentType
            }
            if ($PSBoundParameters.ContainsKey("Body") -and $null -ne $Body) {
                $invokeParams.Body = $Body
            }

            return Invoke-RestMethod @invokeParams
        }
        catch {
            $statusCode = Get-SpotifyApiStatusCode -Exception $_.Exception

            if ($statusCode -eq 401 -and $AllowTokenRefresh -and -not $refreshedToken) {
                $refreshedToken = $true
                $script:SpotifyApiAccessToken = $null
                $script:SpotifyApiAccessTokenExpiresAt = Get-Date
                if ($JobId) {
                    Add-WarningLog -Id $JobId -Message ("Spotify rejected the cached token during the {0} request. Refreshing it once." -f $StageLabel)
                }
                continue
            }

            $shouldRetry = Test-SpotifyApiTransientFailure -StatusCode $statusCode
            if (-not $shouldRetry -or $attempt -ge $MaxAttempts) {
                if ($statusCode -eq 429) {
                    if ($JobId) {
                        Add-WarningLog -Id $JobId -Message ("Spotify kept rate-limiting the {0} request after {1} attempt(s)." -f $StageLabel, $attempt)
                    }
                    throw ("Spotify temporarily rate-limited artist top-track lookup during the {0} request." -f $StageLabel)
                }

                if ($statusCode -ge 500 -and $statusCode -lt 600 -and $JobId) {
                    Add-WarningLog -Id $JobId -Message ("Spotify's server returned HTTP {0} for the {1} request." -f $statusCode, $StageLabel)
                }

                throw
            }

            $retryAfterSeconds = Get-SpotifyApiRetryAfterSeconds -Exception $_.Exception
            if ($statusCode -eq 429 -and $retryAfterSeconds -gt 300) {
                if ($JobId) {
                    Add-WarningLog -Id $JobId -Message ("Spotify asked us to wait {0} second(s) for the {1} request. Stopping instead of parking this job for hours." -f $retryAfterSeconds, $StageLabel)
                }
                throw ("Spotify temporarily rate-limited artist top-track lookup during the {0} request." -f $StageLabel)
            }
            $delaySeconds = Get-SpotifyApiBackoffSeconds -AttemptNumber $attempt -RetryAfterSeconds $retryAfterSeconds
            if ($JobId) {
                if ($statusCode -eq 429) {
                    $retryAfterLabel = if ($retryAfterSeconds) { " Spotify asked us to wait {0} second(s)." -f $retryAfterSeconds } else { "" }
                    Add-WarningLog -Id $JobId -Message ("Spotify rate-limited the {0} request. Waiting {1} second(s) before retrying (attempt {2} of {3}).{4}" -f $StageLabel, $delaySeconds, ($attempt + 1), $MaxAttempts, $retryAfterLabel)
                }
                else {
                    Add-WarningLog -Id $JobId -Message ("Spotify returned HTTP {0} for the {1} request. Waiting {2} second(s) before retrying (attempt {3} of {4})." -f $statusCode, $StageLabel, $delaySeconds, ($attempt + 1), $MaxAttempts)
                }
            }
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Invoke-SpotifyApiJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$JobId,
        [Parameter(Mandatory = $true)][string]$StageLabel
    )

    $token = Get-SpotifyApiAccessToken -JobId $JobId
    return Invoke-SpotifyApiRequestWithRetry -Method "Get" -Uri $Uri -Headers @{
        Authorization = "Bearer $token"
    } -JobId $JobId -StageLabel $StageLabel -AllowTokenRefresh
}

function Get-SpotifyPagedItems {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$JobId,
        [Parameter(Mandatory = $true)][string]$StageLabel
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri
    $pageNumber = 1

    while ($nextUri) {
        $response = Invoke-SpotifyApiJson -Uri $nextUri -JobId $JobId -StageLabel ("{0} page {1}" -f $StageLabel, $pageNumber)
        foreach ($item in @($response.items)) {
            $items.Add($item)
        }
        $nextUri = $response.next
        $pageNumber += 1
        if ($nextUri) {
            Start-Sleep -Milliseconds 150
        }
    }

    return $items
}

function Save-ArtistCatalogCache {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ArtistId,
        [Parameter(Mandatory = $true)][string]$ArtistName,
        [string[]]$TrackUrls = @(),
        $Songs = @(),
        [bool]$IsComplete = $false
    )

    Write-JsonFile -Data @{
        artistId = $ArtistId
        artistName = $ArtistName
        cachedAt = [DateTime]::UtcNow.ToString("o")
        isComplete = $IsComplete
        trackUrls = @($TrackUrls)
        songs = @($Songs)
    } -Path $Path
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

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $Data | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
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

    $jobDirectory = Get-JobDirectory -Id $JobId
    $artistCachePath = Join-Path $jobDirectory "artist-cache.json"
    $job = Read-Job -Id $JobId
    $cachedArtistData = Read-JsonFile -Path $artistCachePath
    $cachedTrackUrls = if ($cachedArtistData) { @($cachedArtistData.trackUrls) } else { @() }

    if ($cachedArtistData -and $cachedArtistData.artistName -and $cachedArtistData.isComplete -and @($cachedArtistData.songs).Count -gt 0 -and $cachedTrackUrls.Count -gt 0) {
        Add-Log -Id $JobId -Message ("Using cached artist metadata with {0} track(s)." -f @($cachedArtistData.songs).Count)
        Update-Job -Id $JobId -Changes @{
            phase = "Loading artist top tracks"
            playlistName = [string]$cachedArtistData.artistName
            playlistId = $ArtistId
            currentProviderPhase = "Loaded the saved artist top tracks from this job's cache."
        } | Out-Null

        return [pscustomobject]@{
            ArtistName = [string]$cachedArtistData.artistName
            Songs = @($cachedArtistData.songs)
        }
    }

    Add-Log -Id $JobId -Message "Reading artist profile from Spotify."
    Update-Job -Id $JobId -Changes @{
        phase = "Reading artist profile"
        playlistId = $ArtistId
        currentProviderPhase = "Loading the Spotify artist profile."
    } | Out-Null

    $artist = Invoke-SpotifyApiJson -Uri ("https://api.spotify.com/v1/artists/{0}" -f $ArtistId) -JobId $JobId -StageLabel "artist profile"
    if (-not $artist -or -not $artist.id) {
        throw "Could not load this artist's Spotify profile."
    }

    Update-Job -Id $JobId -Changes @{
        phase = "Loading artist top tracks"
        playlistName = $artist.name
        playlistId = $ArtistId
        currentProviderPhase = "Fetching Spotify's popular tracks for this artist."
    } | Out-Null

    Add-Log -Id $JobId -Message ("Artist found: {0}" -f $artist.name)
    $trackUrls = @()
    if ($cachedTrackUrls.Count -gt 0) {
        Add-Log -Id $JobId -Message ("Using cached artist top tracks with {0} Spotify link(s)." -f $cachedTrackUrls.Count)
        $trackUrls = @($cachedTrackUrls)
    }
    else {
        Add-Log -Id $JobId -Message "Loading artist top tracks from Spotify."
        $topTracksResponse = Invoke-SpotifyApiJson -Uri ("https://api.spotify.com/v1/artists/{0}/top-tracks?market=US" -f $ArtistId) -JobId $JobId -StageLabel "artist top tracks"
        $topTracks = @($topTracksResponse.tracks)
        if ($topTracks.Count -eq 0) {
            throw "Spotify returned no popular tracks for this artist."
        }

        $seenTrackUrls = @{}
        foreach ($track in $topTracks) {
            $trackUrl = if ($track.external_urls -and $track.external_urls.spotify) { [string]$track.external_urls.spotify } else { "" }
            if ([string]::IsNullOrWhiteSpace($trackUrl)) {
                continue
            }
            if ($seenTrackUrls.ContainsKey($trackUrl)) {
                continue
            }
            $seenTrackUrls[$trackUrl] = $true
            $trackUrls += $trackUrl
        }
    }

    if ($trackUrls.Count -eq 0) {
        throw "Spotify returned top tracks, but no usable Spotify track links were available for this artist."
    }

    Save-ArtistCatalogCache -Path $artistCachePath -ArtistId $ArtistId -ArtistName $artist.name -TrackUrls @($trackUrls) -IsComplete $false
    Add-Log -Id $JobId -Message ("Preparing metadata for the artist's top tracks ({0} song(s))." -f $trackUrls.Count)
    Update-Job -Id $JobId -Changes @{
        phase = "Saving playlist metadata"
        currentProviderPhase = "Preparing metadata for the artist's top tracks."
    } | Out-Null

    $saveArgs = @("save") + $trackUrls + @("--save-file", $job.metadataPath)
    $saveExit = Invoke-SpotdlSaveWithRetry -Arguments $saveArgs -WorkingDirectory $script:Root -JobId $JobId -OperationLabel "Preparing metadata for the artist's top tracks."
    $songs = @(Read-MetadataSongs -MetadataPath $job.metadataPath)

    if ($saveExit -ne 0 -and $songs.Count -gt 0) {
        Add-WarningLog -Id $JobId -Message ("Artist metadata finished with some lookup errors. Continuing with {0} saved song(s)." -f $songs.Count)
    }

    if ($songs.Count -eq 0) {
        throw "spotDL could not save metadata for this artist's top tracks."
    }

    Add-Log -Id $JobId -Message ("Saved {0} top track(s) to the local metadata file." -f $songs.Count)
    Save-ArtistCatalogCache -Path $artistCachePath -ArtistId $ArtistId -ArtistName $artist.name -TrackUrls @($trackUrls) -Songs @($songs) -IsComplete $true

    return [pscustomobject]@{
        ArtistName = $artist.name
        Songs = @($songs)
    }
}

function Get-OperationLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$ItemName = ""
    )

    switch ($Kind) {
        "save" {
            if ($ItemName) {
                return "Reading Spotify details for $ItemName."
            }
            return "Reading Spotify details."
        }
        "download-main" {
            return "Starting the primary download pass."
        }
        "download-retry" {
            if ($ItemName) {
                return "Retrying $ItemName with fallback audio sources."
            }
            return "Retrying one missing song with fallback audio sources."
        }
        "resume-check" {
            return "Checking saved files before retrying only what is still missing."
        }
        default {
            return "Starting downloader work."
        }
    }
}

function Get-LastMeaningfulLogLine {
    param([Parameter(Mandatory = $true)][string]$JobId)

    $job = Read-Job -Id $JobId
    if (-not (Test-Path -LiteralPath $job.logPath)) {
        return $null
    }

    $lines = Get-Content $job.logPath -Encoding utf8
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $bare = $line -replace '^\[[^\]]+\]\s*', ''
        if (Test-SpotdlLoggingNoiseLine -Line $bare) {
            continue
        }

        if ($bare -match '^(Processing query:|https?://|[A-Za-z]:\\)' -or $bare -match '^ylist\.spotdl$') {
            continue
        }

        return $bare
    }

    return $null
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
        [int]$CompletedOffset = 0,
        [string]$ProviderPhase = $null,
        [string]$Phase = $null
    )

    $safeCompletedCount = [Math]::Max(0, [Math]::Min($CompletedCount, $SongQueue.Count))
    $resolvedCompletedCount = [Math]::Max(0, $CompletedOffset + $safeCompletedCount)
    $currentSong = $null
    if ($safeCompletedCount -lt $SongQueue.Count) {
        $currentSong = $SongQueue[$safeCompletedCount]
    }

    Update-JobSafe -Id $Id -Mutator {
        param($job)
        Ensure-JobShape -Job $job
        $job.matchCount = $resolvedCompletedCount
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
        [int]$MissingCount = -1,
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
        if ($MissingCount -ge 0) {
            $job.missingCount = $MissingCount
        }
        elseif ($UniqueSongCount -gt 0) {
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
        [Parameter(Mandatory = $true)][string]$OperationLabel,
        [string]$ProgressFolder,
        [string[]]$SongQueue = @(),
        [int]$UniqueSongCount = 0,
        [int]$CompletedOffset = 0,
        [string]$MatchingPhase = "Matching songs to sources",
        [string]$DownloadingPhase = "Downloading files"
    )

    $spotdlArgs = if (Test-Path -LiteralPath $script:SpotdlConfigPath) { @("--config") + $Arguments } else { $Arguments }
    Add-Log -Id $JobId -Message $OperationLabel
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
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase "Preparing the saved playlist for matching." -Phase "Preparing download queue"
                    return
                }

                $shouldAdvance = $line -match 'Downloaded "' -or $line -match '^Skipping ' -or $line -match '^AudioProviderError:' -or $line -match '^LookupError:'
                if (-not $downloadStarted -and ($shouldAdvance -or $line -match '^Downloading ' -or $line -match '^Converting ')) {
                    $downloadStarted = $true
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase "Downloading matched audio sources." -Phase $DownloadingPhase
                    Update-ProgressSnapshot -Id $JobId -FolderPath $ProgressFolder -UniqueSongCount $UniqueSongCount -Phase $DownloadingPhase
                }

                if ($line -match '^Retrying') {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase "Trying the next source after a provider miss." -Phase $MatchingPhase
                }
                elseif ($line -match '^AudioProviderError:' -or $line -match '^LookupError:') {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase "The current provider missed. Moving to the next source." -Phase $MatchingPhase
                }
                elseif (-not $downloadStarted) {
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase "Checking YouTube Music and YouTube for the next track." -Phase $MatchingPhase
                }

                if ($shouldAdvance) {
                    $completedCount = [Math]::Min($completedCount + 1, $SongQueue.Count)
                    $nextProviderPhase = if ($downloadStarted) { "Downloading matched audio sources." } else { "Checking YouTube Music and YouTube for the next track." }
                    Update-CurrentSongProgress -Id $JobId -SongQueue $SongQueue -CompletedCount $completedCount -CompletedOffset $CompletedOffset -ProviderPhase $nextProviderPhase -Phase $(if ($downloadStarted) { $DownloadingPhase } else { $MatchingPhase })
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
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$OperationLabel
    )

    $spotdlArgs = if (Test-Path -LiteralPath $script:SpotdlConfigPath) { @("--config") + $Arguments } else { $Arguments }
    Add-Log -Id $JobId -Message $OperationLabel
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
        [Parameter(Mandatory = $true)][string]$OperationLabel,
        [string]$UrlType = "unknown",
        [int]$MaxAttempts = 2
    )

    $attempts = New-Object System.Collections.Generic.List[object]
    $attempts.Add([pscustomobject]@{
        Arguments = $Arguments
        Label = $OperationLabel
    })

    if ($UrlType -eq "artist") {
        $officialApiArgs = @($Arguments + @("--use-official-api", "--max-retries", "5"))
        $attempts.Add([pscustomobject]@{
            Arguments = $officialApiArgs
            Label = "Retrying artist metadata with spotDL's official Spotify API mode."
        })

        $config = $null
        try {
            $config = Get-SpotdlConfig
        }
        catch {
        }

        if ($config -and $config.auth_token) {
            $authTokenArgs = @($Arguments + @("--use-official-api", "--auth-token", [string]$config.auth_token, "--max-retries", "5"))
            $attempts.Add([pscustomobject]@{
                Arguments = $authTokenArgs
                Label = "Retrying artist metadata with spotDL's official Spotify API mode and the saved auth token."
            })
        }
    }

    $maxAttemptCount = [Math]::Min($attempts.Count, [Math]::Max($MaxAttempts, $attempts.Count))
    $exitCode = 1
    for ($attempt = 1; $attempt -le $maxAttemptCount; $attempt++) {
        $attemptInfo = $attempts[$attempt - 1]
        $exitCode = Invoke-Spotdl -Arguments $attemptInfo.Arguments -WorkingDirectory $WorkingDirectory -JobId $JobId -OperationLabel $attemptInfo.Label
        if ($exitCode -eq 0) {
            return $exitCode
        }

        if ($attempt -lt $maxAttemptCount) {
            Add-Log -Id $JobId -Message ("Save step failed. Retrying metadata fetch (attempt {0} of {1})." -f ($attempt + 1), $maxAttemptCount)
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

    if ($job.resumeOnlyMissing -and (Test-Path -LiteralPath $job.metadataPath)) {
        Add-Log -Id $JobId -Message (Get-OperationLabel -Kind "resume-check")
        $songs = Read-MetadataSongs -MetadataPath $job.metadataPath
    }

    if ($songs.Count -eq 0) {
        $saveArgs = @("save", $job.url, "--save-file", $job.metadataPath)
        $saveExit = Invoke-SpotdlSaveWithRetry -Arguments $saveArgs -WorkingDirectory $script:Root -JobId $JobId -OperationLabel (Get-OperationLabel -Kind "save" -ItemName $urlType) -UrlType $urlType
        $songs = Read-MetadataSongs -MetadataPath $job.metadataPath

        if ($saveExit -ne 0 -and $songs.Count -gt 0) {
            Add-WarningLog -Id $JobId -Message ("Spotify metadata finished with some lookup errors. Continuing with {0} saved songs." -f $songs.Count)
        }

        if ($songs.Count -eq 0) {
            throw (Get-FriendlyWorkerError -JobId $JobId -FallbackMessage "spotDL could not save playlist metadata." -UrlType $urlType)
        }
    }

    if ($songs.Count -eq 0) {
        throw "No Spotify tracks were collected for this link."
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
        currentProviderPhase = if ($job.resumeOnlyMissing) { "Retrying only the songs still missing from the last attempt." } else { "Preparing the saved playlist for matching." }
        missingSongs = if ($job.resumeOnlyMissing) { @($resumePendingSongs) } else { @() }
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
                matchCount = $uniqueSongs.Count
            } | Out-Null

            Add-Log -Id $JobId -Message "Nothing left to retry. All files are already present."
        }
        else {
            $retryBaseCompletedCount = [Math]::Max($uniqueSongs.Count - $resumePendingSongs.Count, 0)
            for ($retryIndex = 0; $retryIndex -lt $resumePendingSongs.Count; $retryIndex++) {
                $song = $resumePendingSongs[$retryIndex]
                $songLabel = "{0} - {1}" -f $song.artist, $song.title
                Add-Log -Id $JobId -Message ("Retrying missing song: {0}" -f $songLabel)
                Update-Job -Id $JobId -Changes @{
                    currentSong = $songLabel
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
                [void](Invoke-SpotdlWithProgress -Arguments $retryArgs -WorkingDirectory $outputFolder -JobId $JobId -OperationLabel (Get-OperationLabel -Kind "download-retry" -ItemName $songLabel) -ProgressFolder $outputFolder -SongQueue @($songLabel) -UniqueSongCount $uniqueSongs.Count -CompletedOffset ($retryBaseCompletedCount + $retryIndex) -MatchingPhase "Retrying missing songs" -DownloadingPhase "Retrying missing songs")

                $liveMissingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
                Update-Job -Id $JobId -Changes @{
                    missingSongs = $liveMissingSongs
                    missingCount = $liveMissingSongs.Count
                    downloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder
                    matchCount = [Math]::Max($uniqueSongs.Count - $liveMissingSongs.Count, 0)
                    currentSong = if ($retryIndex + 1 -lt $resumePendingSongs.Count) { "{0} - {1}" -f $resumePendingSongs[$retryIndex + 1].artist, $resumePendingSongs[$retryIndex + 1].title } else { $null }
                } | Out-Null
            }

            $finalMissingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
            $finalDownloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder

            Update-Job -Id $JobId -Changes @{
                status = "completed"
                phase = "Finished"
                missingSongs = @($finalMissingSongs)
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
        [void](Invoke-SpotdlWithProgress -Arguments $mainArgs -WorkingDirectory $outputFolder -JobId $JobId -OperationLabel (Get-OperationLabel -Kind "download-main") -ProgressFolder $outputFolder -SongQueue $songQueue -UniqueSongCount $uniqueSongs.Count -MatchingPhase "Matching songs to sources" -DownloadingPhase "Downloading files")

        $missingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
        $job = Update-Job -Id $JobId -Changes @{
            phase = "Retrying missing songs"
            missingSongs = @($missingSongs)
            missingCount = $missingSongs.Count
            downloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder
            matchCount = [Math]::Max($job.uniqueTrackCount - $missingSongs.Count, 0)
            currentSong = if ($missingSongs.Count -gt 0) { "{0} - {1}" -f $missingSongs[0].artist, $missingSongs[0].title } else { $null }
            currentProviderPhase = if ($missingSongs.Count -gt 0) { "Retrying missing songs with fallback sources." } else { "Checking whether any files still need a retry." }
            missingSongsKnown = $true
        }

        $retryBaseCompletedCount = [Math]::Max($uniqueSongs.Count - $missingSongs.Count, 0)
        for ($retryIndex = 0; $retryIndex -lt $missingSongs.Count; $retryIndex++) {
            $song = $missingSongs[$retryIndex]
            $songLabel = "{0} - {1}" -f $song.artist, $song.title
            Add-Log -Id $JobId -Message ("Retrying missing song: {0}" -f $songLabel)
            Update-Job -Id $JobId -Changes @{
                currentSong = $songLabel
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
            [void](Invoke-SpotdlWithProgress -Arguments $retryArgs -WorkingDirectory $outputFolder -JobId $JobId -OperationLabel (Get-OperationLabel -Kind "download-retry" -ItemName $songLabel) -ProgressFolder $outputFolder -SongQueue @($songLabel) -UniqueSongCount $uniqueSongs.Count -CompletedOffset ($retryBaseCompletedCount + $retryIndex) -MatchingPhase "Retrying missing songs" -DownloadingPhase "Retrying missing songs")

            $liveMissingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
            Update-Job -Id $JobId -Changes @{
                missingSongs = $liveMissingSongs
                missingCount = $liveMissingSongs.Count
                downloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder
                matchCount = [Math]::Max($uniqueSongs.Count - $liveMissingSongs.Count, 0)
                currentSong = if ($retryIndex + 1 -lt $missingSongs.Count) { "{0} - {1}" -f $missingSongs[$retryIndex + 1].artist, $missingSongs[$retryIndex + 1].title } else { $null }
            } | Out-Null
        }

        $finalMissingSongs = @(Get-MissingSongs -Songs $uniqueSongs -FolderPath $outputFolder)
        $finalDownloadedCount = Get-DownloadedFileCount -FolderPath $outputFolder

        Update-Job -Id $JobId -Changes @{
            status = "completed"
            phase = "Finished"
            missingSongs = @($finalMissingSongs)
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
    $job = Read-Job -Id $JobId
    $lastMeaningfulLogLine = Get-LastMeaningfulLogLine -JobId $JobId
    $fallbackMessage = if ($_.Exception.Message -eq "--- Logging error ---" -and $lastMeaningfulLogLine) {
        "The downloader stopped after: $lastMeaningfulLogLine"
    }
    elseif ($_.Exception.Message) {
        $_.Exception.Message
    }
    elseif ($lastMeaningfulLogLine) {
        "The downloader stopped after: $lastMeaningfulLogLine"
    }
    else {
        "The downloader stopped unexpectedly."
    }

    $message = Get-FriendlyWorkerError -JobId $JobId -FallbackMessage $fallbackMessage -UrlType (Get-SpotifyUrlType -Url $job.url)
    if ($job.outputFolder) {
        $savedFiles = Get-DownloadedFileCount -FolderPath $job.outputFolder
        $remainingFiles = if ($job.uniqueTrackCount -gt 0) { [Math]::Max($job.uniqueTrackCount - $savedFiles, 0) } else { $null }
        if ($null -ne $remainingFiles) {
            Add-Log -Id $JobId -Message ("Current summary: {0} file(s) saved, {1} still missing." -f $savedFiles, $remainingFiles)
        }
    }
    Add-Log -Id $JobId -Message ("Worker failed: " + $message)
    Update-Job -Id $JobId -Changes @{
        status = "failed"
        phase = "Failed"
        workerPid = $null
        currentSong = $null
        currentProviderPhase = $null
        error = $message
    } | Out-Null
}
