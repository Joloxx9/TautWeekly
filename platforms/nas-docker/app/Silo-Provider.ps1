# TautWeekly Silo media-server provider.
#
# Silo (https://siloserver.org) exposes everything a weekly newsletter needs
# through its native /api/v2 contract: accounts with recovery email, the
# finalized per-attempt playback log, the catalog with first-seen timestamps,
# rich item metadata, and signed artwork URLs. This module translates those
# reads into the Tautulli response shapes the renderer already consumes, so the
# newsletter layout, statistics, and recipient-isolation logic stay shared.
#
# Only /api/v2 is used. The Jellyfin compatibility layer and the frozen v1
# bridge are intentionally never called. Every request is a read.
#
# This file is dot-sourced by TautWeekly.ps1 after the configuration is loaded.
# Keep it compatible with Windows PowerShell 5.1 and PowerShell 7.

$script:TautWeeklyMediaServer = 'tautulli'
$script:SiloBase = ''
$script:SiloMonitorKey = ''
$script:SiloCatalogKey = ''
$script:SiloCatalogProfileId = ''
$script:SiloIncludeChildProfiles = $false
$script:SiloAccountCache = $null
$script:SiloProfileCache = @{}
$script:SiloHistoryCache = @{}
$script:SiloCatalogItemCache = @{}
$script:SiloDetailCache = @{}
$script:SiloRecentCache = $null
$script:SiloRecentHorizonDays = 0   # index into SiloRecentHorizons
$script:SiloRecentExhausted = $false
$script:SiloLibraryCache = $null
$script:SiloImageConverterWarned = $false
$script:SiloRecentHorizons = @(14, 45, 120, 400, 0)   # days; 0 = whole catalog
$script:SiloMaxPages = 200
$script:SiloMaxRetries = 6

function Test-TautWeeklySiloServer {
    return ([string]$script:TautWeeklyMediaServer -eq 'silo')
}

function Get-TautWeeklyMediaServerName {
    if (Test-TautWeeklySiloServer) { return 'Silo' }
    return 'Plex'
}

function Get-SiloConfigString {
    param([object]$Configuration, [string]$Name)
    if ($null -eq $Configuration) { return '' }
    $property = $Configuration.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return ([string]$property.Value).Trim()
}

function Test-SiloAbsoluteServerUrl {
    param([string]$Value)
    [Uri]$parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed)) { return $false }
    if ($parsed.Scheme -notin @('http', 'https')) { return $false }
    if ([string]::IsNullOrWhiteSpace($parsed.Host)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($parsed.UserInfo)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($parsed.Query)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($parsed.Fragment)) { return $false }
    return $true
}

function Initialize-TautWeeklySiloProvider {
    param([object]$Configuration)

    $server = (Get-SiloConfigString -Configuration $Configuration -Name 'MediaServer').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($server)) { $server = 'tautulli' }
    if ($server -notin @('tautulli', 'silo')) {
        throw "MediaServer must be 'tautulli' or 'silo'."
    }
    $script:TautWeeklyMediaServer = $server
    if ($server -ne 'silo') { return }

    $url = Get-SiloConfigString -Configuration $Configuration -Name 'SiloUrl'
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Missing required config value 'SiloUrl' for MediaServer 'silo'."
    }
    if (-not (Test-SiloAbsoluteServerUrl -Value $url)) {
        throw 'SiloUrl must be an absolute HTTP or HTTPS URL without credentials, a query string, or a fragment.'
    }
    $script:SiloBase = $url.TrimEnd('/')

    $monitorKey = Get-SiloConfigString -Configuration $Configuration -Name 'SiloApiKey'
    if ([string]::IsNullOrWhiteSpace($monitorKey)) {
        throw "Missing required config value 'SiloApiKey' for MediaServer 'silo'."
    }
    if ($monitorKey -match '\s' -or $monitorKey.Length -gt 512) {
        throw 'SiloApiKey must be a single API key token.'
    }
    $script:SiloMonitorKey = $monitorKey

    $catalogKey = Get-SiloConfigString -Configuration $Configuration -Name 'SiloCatalogApiKey'
    if ([string]::IsNullOrWhiteSpace($catalogKey)) { $catalogKey = $monitorKey }
    if ($catalogKey -match '\s' -or $catalogKey.Length -gt 512) {
        throw 'SiloCatalogApiKey must be a single API key token.'
    }
    $script:SiloCatalogKey = $catalogKey

    $profileId = Get-SiloConfigString -Configuration $Configuration -Name 'SiloProfileId'
    if (-not [string]::IsNullOrWhiteSpace($profileId) -and $profileId -notmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'SiloProfileId must be the opaque profile identifier Silo reports.'
    }
    $script:SiloCatalogProfileId = $profileId

    $includeChildren = $Configuration.PSObject.Properties['SiloIncludeChildProfiles']
    $script:SiloIncludeChildProfiles = ($null -ne $includeChildren -and [bool]$includeChildren.Value)
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
function ConvertTo-SiloQueryString {
    param([object[]]$Query = @())
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i + 1 -lt $Query.Count; $i += 2) {
        $name = [string]$Query[$i]
        $value = $Query[$i + 1]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $parts.Add([Uri]::EscapeDataString($name) + '=' + [Uri]::EscapeDataString([string]$value))
    }
    if ($parts.Count -eq 0) { return '' }
    return '?' + ($parts -join '&')
}

function Get-SiloHttpStatus {
    param([object]$ErrorRecord)
    try {
        if ($null -ne $ErrorRecord.Exception.Response -and $null -ne $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch { }
    return 0
}

function Get-SiloRetryDelaySeconds {
    # Honour Retry-After on 429/503 (PowerShell 7 HttpResponseMessage or
    # Windows PowerShell WebResponse), else back off exponentially.
    param([object]$ErrorRecord, [int]$Attempt)
    $seconds = [Math]::Min(30, [Math]::Pow(2, $Attempt))
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            $retryAfter = $null
            if ($response.PSObject.Properties['Headers'] -and $response.Headers -is [System.Net.WebHeaderCollection]) {
                $retryAfter = [string]$response.Headers['Retry-After']
            }
            elseif ($null -ne $response.Headers -and $null -ne $response.Headers.RetryAfter) {
                if ($null -ne $response.Headers.RetryAfter.Delta) { $retryAfter = [string][int]$response.Headers.RetryAfter.Delta.TotalSeconds }
                elseif ($null -ne $response.Headers.RetryAfter.Date) { $retryAfter = [string][int]($response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds }
            }
            [int]$parsed = 0
            if (-not [string]::IsNullOrWhiteSpace($retryAfter) -and [int]::TryParse($retryAfter.Trim(), [ref]$parsed)) {
                $seconds = [Math]::Max(1, [Math]::Min(60, $parsed))
            }
        }
    }
    catch { }
    return [int][Math]::Ceiling($seconds)
}

function Invoke-SiloRequest {
    # Runs one HTTP request, retrying only rate-limit (429) and temporary
    # unavailability (503) answers. Returns the script block's result.
    param([scriptblock]$Request, [string]$Label)
    $attempt = 0
    while ($true) {
        try {
            return (& $Request)
        }
        catch {
            $status = Get-SiloHttpStatus -ErrorRecord $_
            if ($status -in @(429, 503) -and $attempt -lt $script:SiloMaxRetries) {
                $delay = Get-SiloRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
                if ($attempt -eq 0) {
                    Write-Log ("Silo answered HTTP {0} for {1}; retrying after {2}s. Consider the 'elevated' API-key rate tier for TautWeekly." -f $status, $Label, $delay) 'WARN'
                }
                Start-Sleep -Seconds $delay
                $attempt++
                continue
            }
            $text = if ($status -gt 0) { 'HTTP ' + $status } else { $_.Exception.GetType().Name }
            # Never echo the URI: it may carry a private host name. The label
            # is a fixed API route plus an opaque catalog identifier.
            $failure = New-Object System.Exception ("Silo API request failed for ${Label}: $text")
            $failure.Data['SiloStatus'] = $status
            throw $failure
        }
    }
}

function Invoke-SiloApi {
    param(
        [string]$Path,
        [object[]]$Query = @(),
        [switch]$Catalog,
        [string]$ProfileId = ''
    )

    $key = if ($Catalog) { $script:SiloCatalogKey } else { $script:SiloMonitorKey }
    $uri = $script:SiloBase + $Path + (ConvertTo-SiloQueryString -Query $Query)
    $headers = @{
        'Authorization' = 'Bearer ' + $key
        'Accept'        = 'application/json'
    }
    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) {
        $headers['X-Profile-Id'] = $ProfileId
    }
    return Invoke-SiloRequest -Label $Path -Request {
        Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60 -UseBasicParsing
    }.GetNewClosure()
}

function Get-SiloPagedItems {
    param(
        [string]$Path,
        [object[]]$Query = @(),
        [int]$MaxPages = 0,
        [switch]$Catalog,
        [string]$ProfileId = ''
    )

    if ($MaxPages -le 0) { $MaxPages = $script:SiloMaxPages }
    $items = New-Object System.Collections.Generic.List[object]
    $cursor = ''
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $pageQuery = @($Query)
        if (-not [string]::IsNullOrWhiteSpace($cursor)) { $pageQuery += @('cursor', $cursor) }
        $doc = Invoke-SiloApi -Path $Path -Query $pageQuery -Catalog:$Catalog -ProfileId $ProfileId
        if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['items']) {
            foreach ($item in @($doc.items)) {
                if ($null -ne $item) { $items.Add($item) }
            }
        }
        $pageInfo = if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['page']) { $doc.page } else { $null }
        if ($null -eq $pageInfo -or -not [bool](Get-SiloProperty $pageInfo 'has_more')) { break }
        $cursor = [string](Get-SiloProperty $pageInfo 'next_cursor')
        if ([string]::IsNullOrWhiteSpace($cursor)) { break }
        if ($page -eq $MaxPages - 1) {
            Write-Log "Silo listing $Path reached the $MaxPages-page safety limit; later rows were not read." 'WARN'
        }
    }
    return $items.ToArray()
}

function Get-SiloProperty {
    param([AllowNull()][object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SiloString {
    param([AllowNull()][object]$InputObject, [string]$Name)
    $value = Get-SiloProperty $InputObject $Name
    if ($null -eq $value) { return '' }
    if ($value -is [IFormattable]) {
        return ([IFormattable]$value).ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$value
}

function ConvertTo-SiloEpoch {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return [int64]0 }
    if ($Value -is [DateTime]) {
        return [int64]([DateTimeOffset]([DateTime]$Value).ToUniversalTime()).ToUnixTimeSeconds()
    }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return [int64]0 }
    [DateTimeOffset]$parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse(
        $text,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) {
        return [int64]$parsed.ToUnixTimeSeconds()
    }
    return [int64]0
}

function ConvertTo-SiloInstant {
    param([DateTime]$LocalTime)
    return $LocalTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-SiloTautulliDate {
    # Tautulli's get_history after/before dates are inclusive local calendar
    # days. Silo bounds are UTC instants: ended_after inclusive and
    # ended_before exclusive, so the day after 'before' closes the window.
    param([string]$Value, [switch]$EndOfDay)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    [DateTime]$day = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
        $text, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal, [ref]$day
    )) {
        throw "Silo history bounds must use yyyy-MM-dd dates."
    }
    $local = [DateTime]::SpecifyKind($day.Date, [DateTimeKind]::Local)
    if ($EndOfDay) { $local = $local.AddDays(1) }
    return ConvertTo-SiloInstant -LocalTime $local
}

# ---------------------------------------------------------------------------
# ACCOUNTS
# ---------------------------------------------------------------------------
function Get-SiloAccounts {
    if ($null -ne $script:SiloAccountCache) { return $script:SiloAccountCache }
    $script:SiloAccountCache = @(Get-SiloPagedItems -Path '/api/v2/admin/users' -Query @('limit', 200))
    return $script:SiloAccountCache
}

function Get-SiloAccountProfiles {
    param([string]$AccountId)
    if ([string]::IsNullOrWhiteSpace($AccountId)) { return @() }
    if ($script:SiloProfileCache.ContainsKey($AccountId)) { return $script:SiloProfileCache[$AccountId] }
    $profiles = @()
    try {
        $profiles = @(Get-SiloPagedItems -Path ('/api/v2/admin/users/' + [Uri]::EscapeDataString($AccountId) + '/profiles') -MaxPages 5)
    }
    catch {
        Write-Log 'Silo profile list was unavailable for one account; its child-profile filter is disabled for this run.' 'WARN'
    }
    $script:SiloProfileCache[$AccountId] = $profiles
    return $profiles
}

function Get-SiloChildProfileIds {
    param([string]$AccountId)
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($script:SiloIncludeChildProfiles) { return ,$ids }
    foreach ($profile in @(Get-SiloAccountProfiles -AccountId $AccountId)) {
        if ([bool](Get-SiloProperty $profile 'is_child')) {
            [void]$ids.Add((Get-SiloString $profile 'id'))
        }
    }
    return ,$ids
}

function ConvertTo-SiloTautulliUser {
    param([object]$Account)
    $id = Get-SiloString $Account 'id'
    $username = Get-SiloString $Account 'username'
    $enabled = Get-SiloProperty $Account 'enabled'
    $isActive = if ($null -eq $enabled -or [bool]$enabled) { 1 } else { 0 }
    $role = (Get-SiloString $Account 'role').ToLowerInvariant()
    return [PSCustomObject]@{
        user_id       = $id
        username      = $username
        friendly_name = $username
        email         = Get-SiloString $Account 'email'
        is_active     = $isActive
        is_admin      = $(if ($role -eq 'admin') { 1 } else { 0 })
        deleted_user  = 0
        do_notify     = 1
        user_thumb    = ''
        last_seen     = ConvertTo-SiloEpoch (Get-SiloProperty $Account 'last_active_at')
    }
}

function Get-SiloTautulliUsers {
    return @(Get-SiloAccounts | ForEach-Object { ConvertTo-SiloTautulliUser -Account $_ })
}

function Get-SiloTautulliUser {
    param([string]$Id)
    $needle = ([string]$Id).Trim()
    foreach ($user in @(Get-SiloTautulliUsers)) {
        if ([string]$user.user_id -eq $needle) { return $user }
    }
    try {
        $account = Invoke-SiloApi -Path ('/api/v2/admin/users/' + [Uri]::EscapeDataString($needle))
        if ($null -ne $account -and (Get-SiloString $account 'id') -eq $needle) {
            return ConvertTo-SiloTautulliUser -Account $account
        }
    }
    catch { }
    throw "Silo account ID '$needle' was not found."
}

# ---------------------------------------------------------------------------
# CATALOG
# ---------------------------------------------------------------------------
function Get-SiloCatalogProfileId {
    if (-not [string]::IsNullOrWhiteSpace($script:SiloCatalogProfileId)) { return $script:SiloCatalogProfileId }
    $profiles = @()
    try {
        $doc = Invoke-SiloApi -Path '/api/v2/profiles' -Catalog
        if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['items']) { $profiles = @($doc.items) }
    }
    catch {
        throw 'Silo catalog reads need a profile: the catalog API key could not list its own profiles. Set SiloProfileId or use a SiloCatalogApiKey from an ordinary account.'
    }
    $chosen = @($profiles | Where-Object { [bool](Get-SiloProperty $_ 'is_primary') } | Select-Object -First 1)
    if ($chosen.Count -eq 0) {
        $chosen = @($profiles | Where-Object { -not [bool](Get-SiloProperty $_ 'is_child') } | Select-Object -First 1)
    }
    if ($chosen.Count -eq 0) { throw 'The Silo catalog API key has no usable profile.' }
    $script:SiloCatalogProfileId = Get-SiloString $chosen[0] 'id'
    return $script:SiloCatalogProfileId
}

function Get-SiloSeriesIdFromEpisodeId {
    param([string]$EpisodeId)
    # Silo episode identities embed their series identity:
    # episode-<provider>-<series id>-<season>-<episode>.
    if ($EpisodeId -match '^episode-([a-z0-9]+)-([A-Za-z0-9]+)-\d+-\d+$') {
        return 'series-' + $Matches[1] + '-' + $Matches[2]
    }
    return ''
}

function Get-SiloCatalogItems {
    # Resolve catalog listing rows (library membership, series, year) for a set
    # of content identities, 200 per request. Missing ids have left the
    # catalog; they are cached as $null so they are asked for only once.
    param([string[]]$ContentIds)
    $missing = @($ContentIds | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not $script:SiloCatalogItemCache.ContainsKey($_)
    } | Select-Object -Unique)
    for ($offset = 0; $offset -lt $missing.Count; $offset += 200) {
        $batch = @($missing[$offset..([Math]::Min($offset + 199, $missing.Count - 1))])
        $query = @('limit', 200)
        foreach ($id in $batch) { $query += @('content_ids', $id) }
        $rows = @()
        try { $rows = @(Get-SiloPagedItems -Path '/api/v2/admin/catalog/items' -Query $query -MaxPages 2) }
        catch { Write-Log 'Silo catalog identity lookup failed; library scope and series grouping may be incomplete for this run.' 'WARN' }
        foreach ($id in $batch) { $script:SiloCatalogItemCache[$id] = $null }
        foreach ($row in $rows) { $script:SiloCatalogItemCache[(Get-SiloString $row 'content_id')] = $row }
    }
    $result = @{}
    foreach ($id in @($ContentIds)) {
        if (-not [string]::IsNullOrWhiteSpace($id) -and $script:SiloCatalogItemCache.ContainsKey($id)) {
            $result[$id] = $script:SiloCatalogItemCache[$id]
        }
    }
    return $result
}

function Get-SiloItemDetail {
    param([string]$ContentId)
    if ([string]::IsNullOrWhiteSpace($ContentId)) { return $null }
    if ($script:SiloDetailCache.ContainsKey($ContentId)) { return $script:SiloDetailCache[$ContentId] }
    $detail = $null
    try {
        $detail = Invoke-SiloApi `
            -Path ('/api/v2/catalog/items/' + [Uri]::EscapeDataString($ContentId)) `
            -Query @('image_size', 'large') `
            -Catalog `
            -ProfileId (Get-SiloCatalogProfileId)
    }
    catch {
        Write-Log ("Silo item detail lookup failed: " + $_.Exception.Message) 'WARN'
    }
    # Cache misses too, so one unavailable item is asked for only once a run.
    $script:SiloDetailCache[$ContentId] = $detail
    return $detail
}

function Get-SiloLibraries {
    if ($null -ne $script:SiloLibraryCache) { return $script:SiloLibraryCache }
    $doc = Invoke-SiloApi -Path '/api/v2/user/libraries' -Catalog -ProfileId (Get-SiloCatalogProfileId)
    $script:SiloLibraryCache = @(if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['items']) { $doc.items })
    return $script:SiloLibraryCache
}

function ConvertTo-SiloSectionType {
    param([string]$Type)
    switch -Regex (([string]$Type).ToLowerInvariant()) {
        '^(movie|movies)$' { return 'movie' }
        '^(series|show|shows|tv)$' { return 'show' }
        '^(mixed)$' { return 'show' }
        default { return ([string]$Type).ToLowerInvariant() }
    }
}

function Get-SiloTautulliLibraries {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($library in @(Get-SiloLibraries)) {
        $rows.Add([PSCustomObject]@{
            section_id   = Get-SiloString $library 'id'
            section_name = Get-SiloString $library 'name'
            section_type = ConvertTo-SiloSectionType (Get-SiloString $library 'type')
            is_active    = 1
            count        = ''
        })
    }
    return $rows.ToArray()
}

function Get-SiloItemSectionId {
    param([AllowNull()][object]$CatalogRow, [string]$PreferredSectionId = '')
    $ids = @(Get-SiloProperty $CatalogRow 'library_ids' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if (-not [string]::IsNullOrWhiteSpace($PreferredSectionId) -and $PreferredSectionId -in $ids) { return $PreferredSectionId }
    if ($script:LibraryFilterEnabled) {
        foreach ($id in $ids) {
            if ($script:IncludedLibraryIdSet.Contains($id)) { return $id }
        }
    }
    if ($ids.Count -gt 0) { return $ids[0] }
    return ''
}

function Test-SiloItemInSection {
    param([AllowNull()][object]$CatalogRow, [string]$SectionId)
    if ([string]::IsNullOrWhiteSpace($SectionId)) { return $true }
    $ids = @(Get-SiloProperty $CatalogRow 'library_ids' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    return ($SectionId -in $ids)
}

# ---------------------------------------------------------------------------
# RATINGS
# ---------------------------------------------------------------------------
function Get-SiloRatings {
    # Normalise the item detail's ratings[] (with the flat rating_* fields as a
    # fallback) into IMDb/TMDB 0-10 values and RT 0-100 percentages.
    param([AllowNull()][object]$Detail)
    $result = [ordered]@{ Imdb = ''; Tmdb = ''; RtCritic = ''; RtAudience = '' }
    if ($null -eq $Detail) { return [PSCustomObject]$result }
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    foreach ($entry in @(Get-SiloProperty $Detail 'ratings')) {
        if ($null -eq $entry) { continue }
        $source = (Get-SiloString $entry 'source').ToLowerInvariant()
        $score = Get-SiloProperty $entry 'score'
        if ($null -eq $score) { continue }
        [double]$n = 0
        if (-not [double]::TryParse([string]$score, [Globalization.NumberStyles]::Float, $invariant, [ref]$n)) { continue }
        switch ($source) {
            'imdb' { if ($result.Imdb -eq '') { $result.Imdb = ([Math]::Round($n / 10, 1)).ToString('0.0', $invariant) } }
            'tmdb' { if ($result.Tmdb -eq '') { $result.Tmdb = ([Math]::Round($n / 10, 1)).ToString('0.0', $invariant) } }
            'rt_critic' { if ($result.RtCritic -eq '') { $result.RtCritic = [string][int][Math]::Round($n) } }
            'rt_audience' { if ($result.RtAudience -eq '') { $result.RtAudience = [string][int][Math]::Round($n) } }
        }
    }
    $flat = @(
        @('Imdb', 'rating_imdb', 1), @('Tmdb', 'rating_tmdb', 1),
        @('RtCritic', 'rating_rt_critic', 0), @('RtAudience', 'rating_rt_audience', 0)
    )
    foreach ($pair in $flat) {
        if ($result[$pair[0]] -ne '') { continue }
        $value = Get-SiloProperty $Detail $pair[1]
        if ($null -eq $value) { continue }
        [double]$n = 0
        if (-not [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, $invariant, [ref]$n)) { continue }
        $result[$pair[0]] = if ($pair[2] -eq 1) { $n.ToString('0.0', $invariant) } else { [string][int][Math]::Round($n) }
    }
    foreach ($name in @('Imdb', 'Tmdb')) {
        if ($result[$name] -ne '') {
            [double]$n = 0
            [void][double]::TryParse($result[$name], [Globalization.NumberStyles]::Float, $invariant, [ref]$n)
            if ($n -le 0 -or $n -gt 10) { $result[$name] = '' }
        }
    }
    foreach ($name in @('RtCritic', 'RtAudience')) {
        if ($result[$name] -ne '') {
            $n = [int]$result[$name]
            if ($n -lt 0 -or $n -gt 100) { $result[$name] = '' }
        }
    }
    return [PSCustomObject]$result
}

function Get-SiloRtCriticImage {
    param([string]$Percent)
    if ([string]::IsNullOrWhiteSpace($Percent)) { return '' }
    if ([int]$Percent -ge 60) { return 'rottentomatoes://image.rating.ripe' }
    return 'rottentomatoes://image.rating.rotten'
}

function Get-SiloRtAudienceImage {
    param([string]$Percent)
    if ([string]::IsNullOrWhiteSpace($Percent)) { return '' }
    if ([int]$Percent -ge 60) { return 'rottentomatoes://image.rating.upright' }
    return 'rottentomatoes://image.rating.spilled'
}

function ConvertTo-SiloPercentTenths {
    param([string]$Percent)
    if ([string]::IsNullOrWhiteSpace($Percent)) { return '' }
    return ([double]$Percent / 10).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-SiloTautulliRatingFields {
    # Encode Silo ratings with the Plex provider image identifiers the renderer
    # already understands. Movies prefer the RT critic/audience pair; shows and
    # episodes prefer IMDb with RT audience as the secondary rating.
    param([hashtable]$Row, [object]$Ratings, [string]$MediaType)
    $Row.rating = ''
    $Row.rating_image = ''
    $Row.audience_rating = ''
    $Row.audience_rating_image = ''
    if ($MediaType -eq 'movie' -and $Ratings.RtCritic -ne '') {
        $Row.rating = ConvertTo-SiloPercentTenths $Ratings.RtCritic
        $Row.rating_image = Get-SiloRtCriticImage $Ratings.RtCritic
    }
    elseif ($Ratings.Imdb -ne '') {
        $Row.rating = $Ratings.Imdb
        $Row.rating_image = 'imdb://image.rating'
    }
    elseif ($Ratings.Tmdb -ne '') {
        $Row.rating = $Ratings.Tmdb
        $Row.rating_image = 'themoviedb://image.rating'
    }
    if ($Ratings.RtAudience -ne '') {
        $Row.audience_rating = ConvertTo-SiloPercentTenths $Ratings.RtAudience
        $Row.audience_rating_image = Get-SiloRtAudienceImage $Ratings.RtAudience
    }
    elseif ($MediaType -eq 'movie' -and $Ratings.RtCritic -ne '' -and $Ratings.Imdb -ne '') {
        $Row.audience_rating = $Ratings.Imdb
        $Row.audience_rating_image = 'imdb://image.rating'
    }
}

function ConvertTo-SiloTautulliMediaType {
    param([string]$Type)
    switch (([string]$Type).ToLowerInvariant()) {
        'movie' { return 'movie' }
        'series' { return 'show' }
        'show' { return 'show' }
        'season' { return 'season' }
        'episode' { return 'episode' }
        default { return '' }
    }
}

function Get-SiloTautulliMetadata {
    param([string]$RatingKey)
    $detail = Get-SiloItemDetail -ContentId $RatingKey
    if ($null -eq $detail) { return $null }
    $contentId = Get-SiloString $detail 'content_id'
    if ([string]::IsNullOrWhiteSpace($contentId)) { $contentId = $RatingKey }
    $mediaType = ConvertTo-SiloTautulliMediaType (Get-SiloString $detail 'type')
    $seriesId = Get-SiloString $detail 'series_id'
    $guidSource = if ($mediaType -eq 'episode' -and -not [string]::IsNullOrWhiteSpace($seriesId)) { $seriesId } else { $contentId }
    $runtime = 0
    [void][int]::TryParse((Get-SiloString $detail 'runtime'), [ref]$runtime)
    $studios = @(Get-SiloProperty $detail 'studios' | Where-Object { $null -ne $_ })
    $row = @{
        rating_key              = $contentId
        guid                    = 'silo://' + $guidSource
        media_type              = $mediaType
        title                   = Get-SiloString $detail 'title'
        original_title          = Get-SiloString $detail 'original_title'
        year                    = Get-SiloString $detail 'year'
        summary                 = Get-SiloString $detail 'overview'
        tagline                 = Get-SiloString $detail 'tagline'
        genres                  = @(Get-SiloProperty $detail 'genres' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        content_rating          = Get-SiloString $detail 'content_rating'
        studio                  = $(if ($studios.Count -gt 0) { [string]$studios[0] } else { '' })
        originally_available_at = $(if ($mediaType -eq 'episode') { Get-SiloString $detail 'air_date' } elseif ($mediaType -eq 'show') { Get-SiloString $detail 'first_air_date' } else { Get-SiloString $detail 'release_date' })
        duration                = [string]([int64]$runtime * 60000)
        thumb                   = Get-SiloString $detail 'poster_url'
        art                     = Get-SiloString $detail 'backdrop_url'
        banner                  = ''
        grandparent_rating_key  = $seriesId
        grandparent_title       = Get-SiloString $detail 'series_title'
        parent_media_index      = Get-SiloString $detail 'season_number'
        media_index             = Get-SiloString $detail 'episode_number'
        section_id              = ''
    }
    if ($mediaType -eq 'episode' -and [string]::IsNullOrWhiteSpace($row.year)) {
        $air = Get-SiloString $detail 'air_date'
        if ($air -match '^(\d{4})') { $row.year = $Matches[1] }
    }
    Add-SiloTautulliRatingFields -Row $row -Ratings (Get-SiloRatings -Detail $detail) -MediaType $mediaType
    return [PSCustomObject]$row
}

# ---------------------------------------------------------------------------
# RECENTLY ADDED
# ---------------------------------------------------------------------------
function Expand-SiloRecentCatalog {
    # The admin catalog lists items by identity, filtered by first-seen time.
    # Widen the first-seen horizon one step at a time, only when a caller
    # pages past what is loaded, so a normal week reads a small catalog slice.
    # Returns $false once the whole catalog has been read.
    if ($script:SiloRecentExhausted) { return $false }
    $index = [int]$script:SiloRecentHorizonDays
    if ($index -ge $script:SiloRecentHorizons.Count) { $script:SiloRecentExhausted = $true; return $false }
    $days = [int]$script:SiloRecentHorizons[$index]
    $script:SiloRecentHorizonDays = $index + 1
    $query = @('limit', 200)
    if ($days -gt 0) {
        $query += @('added_after', (ConvertTo-SiloInstant -LocalTime ((Get-Date).AddDays(-$days))))
    }
    $rows = @(Get-SiloPagedItems -Path '/api/v2/admin/catalog/items' -Query $query)
    foreach ($row in $rows) {
        $script:SiloCatalogItemCache[(Get-SiloString $row 'content_id')] = $row
    }
    $script:SiloRecentCache = @($rows | Sort-Object `
        @{ Expression = { ConvertTo-SiloEpoch (Get-SiloProperty $_ 'added_at') }; Descending = $true },
        @{ Expression = { Get-SiloString $_ 'content_id' }; Descending = $false })
    if ($days -eq 0) { $script:SiloRecentExhausted = $true }
    return $true
}

function ConvertTo-SiloTautulliRecentRow {
    param([object]$Row, [string]$SectionId)
    $type = ConvertTo-SiloTautulliMediaType (Get-SiloString $Row 'type')
    $contentId = Get-SiloString $Row 'content_id'
    $seriesId = Get-SiloString $Row 'series_id'
    if ($type -eq 'episode' -and [string]::IsNullOrWhiteSpace($seriesId)) {
        $seriesId = Get-SiloSeriesIdFromEpisodeId $contentId
    }
    $guidSource = if ($type -eq 'episode' -and -not [string]::IsNullOrWhiteSpace($seriesId)) { $seriesId } else { $contentId }
    return [PSCustomObject]@{
        media_type             = $type
        rating_key             = $contentId
        guid                   = 'silo://' + $guidSource
        title                  = Get-SiloString $Row 'title'
        year                   = Get-SiloString $Row 'year'
        added_at               = [string](ConvertTo-SiloEpoch (Get-SiloProperty $Row 'added_at'))
        section_id             = Get-SiloItemSectionId -CatalogRow $Row -PreferredSectionId $SectionId
        grandparent_rating_key = $(if ($type -eq 'episode') { $seriesId } else { '' })
        grandparent_title      = $(if ($type -eq 'episode') { Get-SiloString $Row 'series_title' } else { '' })
        parent_media_index     = $(if ($type -eq 'episode') { Get-SiloString $Row 'season_number' } else { '' })
        media_index            = $(if ($type -eq 'episode') { Get-SiloString $Row 'episode_number' } else { '' })
    }
}

function Get-SiloTautulliRecentlyAdded {
    param([hashtable]$Parameters)
    $count = 25
    $start = 0
    if ($Parameters.ContainsKey('count')) { $count = [Math]::Max(1, [int]$Parameters['count']) }
    if ($Parameters.ContainsKey('start')) { $start = [Math]::Max(0, [int]$Parameters['start']) }
    $sectionId = if ($Parameters.ContainsKey('section_id')) { ([string]$Parameters['section_id']).Trim() } else { '' }

    if ($null -eq $script:SiloRecentCache) { [void](Expand-SiloRecentCatalog) }
    $selected = New-Object System.Collections.Generic.List[object]
    while ($true) {
        $selected.Clear()
        foreach ($row in @($script:SiloRecentCache)) {
            if ($null -eq $row) { continue }
            if ((ConvertTo-SiloTautulliMediaType (Get-SiloString $row 'type')) -eq '') { continue }
            if (-not (Test-SiloItemInSection -CatalogRow $row -SectionId $sectionId)) { continue }
            $selected.Add($row)
        }
        if ($selected.Count -ge ($start + $count)) { break }
        if (-not (Expand-SiloRecentCatalog)) { break }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = $start; $i -lt [Math]::Min($selected.Count, $start + $count); $i++) {
        $rows.Add((ConvertTo-SiloTautulliRecentRow -Row $selected[$i] -SectionId $sectionId))
    }
    return [PSCustomObject]@{ recently_added = $rows.ToArray() }
}

function Get-SiloTautulliChildren {
    # Tautulli returns a show's seasons or episodes. Silo's monitor scope lists
    # catalog rows, so report the series' recently-added episodes directly.
    param([hashtable]$Parameters)
    $ratingKey = if ($Parameters.ContainsKey('rating_key')) { [string]$Parameters['rating_key'] } else { '' }
    if ($null -eq $script:SiloRecentCache) { [void](Expand-SiloRecentCatalog) }
    $children = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($script:SiloRecentCache)) {
        if ((Get-SiloString $row 'type') -ne 'episode') { continue }
        $seriesId = Get-SiloString $row 'series_id'
        if ([string]::IsNullOrWhiteSpace($seriesId)) { $seriesId = Get-SiloSeriesIdFromEpisodeId (Get-SiloString $row 'content_id') }
        if ($seriesId -ne $ratingKey) { continue }
        $children.Add((ConvertTo-SiloTautulliRecentRow -Row $row -SectionId ''))
    }
    return [PSCustomObject]@{ children_type = 'episode'; children_count = $children.Count; children_list = $children.ToArray() }
}

# ---------------------------------------------------------------------------
# PLAYBACK HISTORY
# ---------------------------------------------------------------------------
function Get-SiloPlatformName {
    param([object]$Row)
    $platform = (Get-SiloString $Row 'device_platform').Trim()
    if (-not [string]::IsNullOrWhiteSpace($platform)) { return $platform }
    $client = (Get-SiloString $Row 'client_name').Trim()
    # First-party clients report "Silo <device>", for example "Silo iPhone".
    if ($client -match '^(?i)silo\s+(.+)$') { return $Matches[1].Trim() }
    return $client
}

function ConvertTo-SiloTautulliHistoryRow {
    param([object]$Row, [hashtable]$CatalogRows, [string]$SectionId = '')
    $mediaType = (Get-SiloString $Row 'media_type').ToLowerInvariant()
    if ($mediaType -notin @('movie', 'episode')) { return $null }
    $contentId = Get-SiloString $Row 'media_item_id'
    $catalogRow = if (-not [string]::IsNullOrWhiteSpace($contentId) -and $CatalogRows.ContainsKey($contentId)) { $CatalogRows[$contentId] } else { $null }

    $invariant = [Globalization.CultureInfo]::InvariantCulture
    [double]$duration = 0
    [void][double]::TryParse((Get-SiloString $Row 'duration_seconds'), [Globalization.NumberStyles]::Float, $invariant, [ref]$duration)
    [double]$endPosition = 0
    [void][double]::TryParse((Get-SiloString $Row 'watched_seconds'), [Globalization.NumberStyles]::Float, $invariant, [ref]$endPosition)
    [double]$played = 0
    $playedRaw = Get-SiloProperty $Row 'played_seconds'
    if ($null -ne $playedRaw -and [double]::TryParse([string]$playedRaw, [Globalization.NumberStyles]::Float, $invariant, [ref]$played)) {
        # Measured watch time excludes pauses, seeks and buffering.
    }
    else {
        # Attempts recorded before measurement existed only know where they
        # ended. Count from the resume point when one was recorded.
        [double]$startPosition = 0
        [void][double]::TryParse((Get-SiloString $Row 'start_position_seconds'), [Globalization.NumberStyles]::Float, $invariant, [ref]$startPosition)
        $played = [Math]::Max(0, $endPosition - $startPosition)
    }
    if ($duration -gt 0 -and $played -gt $duration) { $played = $duration }
    [double]$paused = 0
    [void][double]::TryParse((Get-SiloString $Row 'paused_seconds'), [Globalization.NumberStyles]::Float, $invariant, [ref]$paused)
    $percent = 0
    if ($duration -gt 0) { $percent = [int][Math]::Min(100, [Math]::Round(($endPosition / $duration) * 100)) }
    $completed = [bool](Get-SiloProperty $Row 'completed')
    if ($completed) { $percent = [Math]::Max($percent, 100) }

    $seriesId = ''
    if ($mediaType -eq 'episode') {
        $seriesId = Get-SiloString $catalogRow 'series_id'
        if ([string]::IsNullOrWhiteSpace($seriesId)) { $seriesId = Get-SiloSeriesIdFromEpisodeId $contentId }
    }
    $guidSource = if ($mediaType -eq 'episode' -and -not [string]::IsNullOrWhiteSpace($seriesId)) { $seriesId } else { $contentId }
    $title = Get-SiloString $Row 'media_title'
    if ([string]::IsNullOrWhiteSpace($title)) { $title = Get-SiloString $catalogRow 'title' }
    $seriesTitle = Get-SiloString $Row 'series_title'
    if ([string]::IsNullOrWhiteSpace($seriesTitle)) { $seriesTitle = Get-SiloString $catalogRow 'series_title' }
    $season = Get-SiloString $Row 'season_number'
    if ([string]::IsNullOrWhiteSpace($season)) { $season = Get-SiloString $catalogRow 'season_number' }
    $episode = Get-SiloString $Row 'episode_number'
    if ([string]::IsNullOrWhiteSpace($episode)) { $episode = Get-SiloString $catalogRow 'episode_number' }
    $started = ConvertTo-SiloEpoch (Get-SiloProperty $Row 'started_at')
    $stopped = ConvertTo-SiloEpoch (Get-SiloProperty $Row 'ended_at')
    if ($started -le 0) { $started = $stopped }
    $platform = Get-SiloPlatformName -Row $Row
    $username = Get-SiloString $Row 'username'

    return [PSCustomObject]@{
        reference_id           = Get-SiloString $Row 'session_id'
        row_id                 = Get-SiloString $Row 'session_id'
        date                   = [string]$started
        started                = [string]$started
        stopped                = [string]$stopped
        user_id                = Get-SiloString $Row 'user_id'
        user                   = $username
        friendly_name          = $username
        platform               = $platform
        platform_name          = $platform
        player                 = Get-SiloString $Row 'client_name'
        product                = Get-SiloString $Row 'client_name'
        media_type             = $mediaType
        rating_key             = $contentId
        parent_rating_key      = ''
        grandparent_rating_key = $seriesId
        guid                   = $(if ([string]::IsNullOrWhiteSpace($guidSource)) { '' } else { 'silo://' + $guidSource })
        title                  = $title
        full_title             = $(if ($mediaType -eq 'episode' -and -not [string]::IsNullOrWhiteSpace($seriesTitle)) { $seriesTitle + ' - ' + $title } else { $title })
        parent_title           = $(if ($mediaType -eq 'episode' -and -not [string]::IsNullOrWhiteSpace($season)) { 'Season ' + $season } else { '' })
        grandparent_title      = $(if ($mediaType -eq 'episode') { $seriesTitle } else { '' })
        parent_media_index     = $season
        media_index            = $episode
        year                   = Get-SiloString $catalogRow 'year'
        duration               = [string][int64][Math]::Round($duration)
        play_duration          = [string][int64][Math]::Round($played)
        paused_counter         = [string][int64][Math]::Round($paused)
        percent_complete       = [string]$percent
        watched_status         = $(if ($completed) { 1 } else { 0 })
        group_count            = 1
        group_ids              = Get-SiloString $Row 'session_id'
        section_id             = Get-SiloItemSectionId -CatalogRow $catalogRow -PreferredSectionId $SectionId
        transcode_decision     = Get-SiloString $Row 'video_decision'
    }
}

function Get-SiloHistoryWindow {
    param([string]$After, [string]$Before, [string]$UserId)
    $cacheKey = $After + '|' + $Before + '|' + $UserId
    if ($script:SiloHistoryCache.ContainsKey($cacheKey)) { return $script:SiloHistoryCache[$cacheKey] }

    $query = @('limit', 200, 'completed', 'all')
    if (-not [string]::IsNullOrWhiteSpace($After)) { $query += @('ended_after', (ConvertFrom-SiloTautulliDate -Value $After)) }
    if (-not [string]::IsNullOrWhiteSpace($Before)) { $query += @('ended_before', (ConvertFrom-SiloTautulliDate -Value $Before -EndOfDay)) }
    if (-not [string]::IsNullOrWhiteSpace($UserId)) { $query += @('user_id', $UserId) }
    $raw = @(Get-SiloPagedItems -Path '/api/v2/admin/playback-history' -Query $query)

    # Child profiles of a household account are excluded unless configured.
    $childProfiles = @{}
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($row in $raw) {
        $rowUser = Get-SiloString $row 'user_id'
        if (-not [string]::IsNullOrWhiteSpace($UserId) -and $rowUser -ne $UserId) { continue }
        if (-not $script:SiloIncludeChildProfiles) {
            if (-not $childProfiles.ContainsKey($rowUser)) { $childProfiles[$rowUser] = Get-SiloChildProfileIds -AccountId $rowUser }
            if ($childProfiles[$rowUser].Contains((Get-SiloString $row 'profile_id'))) { continue }
        }
        $kept.Add($row)
    }

    $ids = @($kept | ForEach-Object { Get-SiloString $_ 'media_item_id' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $catalogRows = Get-SiloCatalogItems -ContentIds $ids
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $kept) {
        $converted = ConvertTo-SiloTautulliHistoryRow -Row $row -CatalogRows $catalogRows
        if ($null -ne $converted) { $rows.Add($converted) }
    }
    $script:SiloHistoryCache[$cacheKey] = $rows.ToArray()
    return $script:SiloHistoryCache[$cacheKey]
}

function Get-SiloTautulliHistory {
    param([hashtable]$Parameters)
    $after = if ($Parameters.ContainsKey('after')) { [string]$Parameters['after'] } else { '' }
    $before = if ($Parameters.ContainsKey('before')) { [string]$Parameters['before'] } else { '' }
    $userId = if ($Parameters.ContainsKey('user_id')) { ([string]$Parameters['user_id']).Trim() } else { '' }
    $sectionId = if ($Parameters.ContainsKey('section_id')) { ([string]$Parameters['section_id']).Trim() } else { '' }
    $ratingKey = if ($Parameters.ContainsKey('rating_key')) { ([string]$Parameters['rating_key']).Trim() } else { '' }
    $start = if ($Parameters.ContainsKey('start')) { [Math]::Max(0, [int]$Parameters['start']) } else { 0 }
    $length = if ($Parameters.ContainsKey('length')) { [Math]::Max(1, [int]$Parameters['length']) } else { 25 }

    $all = @(Get-SiloHistoryWindow -After $after -Before $before -UserId $userId)
    $filtered = @($all | Where-Object {
        ([string]::IsNullOrWhiteSpace($sectionId) -or [string]$_.section_id -eq $sectionId) -and
        ([string]::IsNullOrWhiteSpace($ratingKey) -or [string]$_.rating_key -eq $ratingKey -or [string]$_.grandparent_rating_key -eq $ratingKey)
    } | Sort-Object @{ Expression = { [int64]$_.stopped }; Descending = $true })
    $page = @()
    if ($start -lt $filtered.Count) {
        $page = @($filtered[$start..([Math]::Min($filtered.Count, $start + $length) - 1)])
    }
    return [PSCustomObject]@{
        recordsTotal    = $all.Count
        recordsFiltered = $filtered.Count
        data            = $page
    }
}

function Get-SiloTautulliUsersTable {
    param([hashtable]$Parameters)
    $userId = if ($Parameters.ContainsKey('user_id')) { ([string]$Parameters['user_id']).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($userId)) { return [PSCustomObject]@{ data = @() } }
    $doc = Invoke-SiloApi -Path '/api/v2/admin/playback-history' -Query @('limit', 1, 'user_id', $userId)
    $latest = @()
    if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['items']) { $latest = @($doc.items | Select-Object -First 1) }
    if ($latest.Count -eq 0) { return [PSCustomObject]@{ data = @() } }
    $platform = Get-SiloPlatformName -Row $latest[0]
    return [PSCustomObject]@{
        data = @([PSCustomObject]@{
            user_id   = Get-SiloString $latest[0] 'user_id'
            platform  = $platform
            player    = Get-SiloString $latest[0] 'client_name'
            last_seen = [string](ConvertTo-SiloEpoch (Get-SiloProperty $latest[0] 'ended_at'))
        })
    }
}

# ---------------------------------------------------------------------------
# TAUTULLI COMMAND ADAPTER
# ---------------------------------------------------------------------------
function Invoke-SiloTautulliCommand {
    param([string]$Command, [hashtable]$Parameters = @{})
    if ($null -eq $Parameters) { $Parameters = @{} }
    switch ($Command) {
        'get_users' { return @(Get-SiloTautulliUsers) }
        'get_user_names' {
            return @(Get-SiloTautulliUsers | ForEach-Object {
                [PSCustomObject]@{ user_id = $_.user_id; friendly_name = $_.friendly_name }
            })
        }
        'get_user' { return Get-SiloTautulliUser -Id ([string]$Parameters['user_id']) }
        'refresh_users_list' { $script:SiloAccountCache = $null; return $null }
        'get_users_table' { return Get-SiloTautulliUsersTable -Parameters $Parameters }
        'get_libraries' { return @(Get-SiloTautulliLibraries) }
        'get_history' { return Get-SiloTautulliHistory -Parameters $Parameters }
        'get_recently_added' { return Get-SiloTautulliRecentlyAdded -Parameters $Parameters }
        'get_metadata' {
            $metadata = Get-SiloTautulliMetadata -RatingKey ([string]$Parameters['rating_key'])
            if ($null -eq $metadata) { throw 'Silo item metadata is unavailable.' }
            return $metadata
        }
        'get_children_metadata' { return Get-SiloTautulliChildren -Parameters $Parameters }
        'get_server_info' { return [PSCustomObject]@{ pms_name = 'Silo'; pms_url = '' } }
        default { throw "The '$Command' Tautulli command has no Silo equivalent." }
    }
}

# ---------------------------------------------------------------------------
# DESIGN METADATA
# ---------------------------------------------------------------------------
function Add-SiloDesignRatingMetadata {
    # Silo's item detail already carries IMDb, TMDB and Rotten Tomatoes values,
    # so no Plex, Tautulli export or hosted-metadata fallback is consulted.
    param([object]$ReleaseData)
    $all = @()
    $all += @($ReleaseData.Movies)
    $all += @($ReleaseData.TV)
    foreach ($item in $all) {
        if ($null -eq $item) { continue }
        $ratingKey = [string]$item.RatingKey
        $mediaType = if ([string]$item.Type -eq 'show') { 'show' } else { 'movie' }
        $detail = Get-SiloItemDetail -ContentId $ratingKey
        $ratings = Get-SiloRatings -Detail $detail
        $genres = @()
        if ($null -ne $item.PSObject.Properties['DesignGenres']) { $genres = @(ConvertTo-DesignGenreList -Value $item.DesignGenres) }
        if ($null -ne $detail) {
            $detailGenres = @(Get-SiloProperty $detail 'genres' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if ($detailGenres.Count -gt 0) { $genres = @(ConvertTo-DesignGenreList -Value $detailGenres) }
            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name 'Summary'))) {
                $summary = Get-SiloString $detail 'overview'
                if (-not [string]::IsNullOrWhiteSpace($summary)) {
                    $item | Add-Member -NotePropertyName 'Summary' -NotePropertyValue $summary -Force
                }
            }
            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name 'Year'))) {
                $year = Get-SiloString $detail 'year'
                if (-not [string]::IsNullOrWhiteSpace($year)) {
                    $item | Add-Member -NotePropertyName 'Year' -NotePropertyValue $year -Force
                }
            }
        }
        $provider = ''
        $providerValue = ''
        if ($ratings.Imdb -ne '') { $provider = 'IMDb'; $providerValue = $ratings.Imdb }
        elseif ($ratings.Tmdb -ne '') { $provider = 'TMDB'; $providerValue = $ratings.Tmdb }
        $imdb = if ($mediaType -eq 'show') { $ratings.Imdb } else { '' }

        Write-Log ("Design ratings (Silo): {0} -> IMDb {1}, RT critic {2}, audience {3}" -f `
            $item.Title,
            $(if ($ratings.Imdb) { $ratings.Imdb } else { 'n/a' }),
            $(if ($ratings.RtCritic) { $ratings.RtCritic + '%' } else { 'n/a' }),
            $(if ($ratings.RtAudience) { $ratings.RtAudience + '%' } else { 'n/a' }))

        $item | Add-Member -NotePropertyName 'DesignRtCritic' -NotePropertyValue $ratings.RtCritic -Force
        $item | Add-Member -NotePropertyName 'DesignRtAudience' -NotePropertyValue $ratings.RtAudience -Force
        $item | Add-Member -NotePropertyName 'DesignImdbRating' -NotePropertyValue $imdb -Force
        $item | Add-Member -NotePropertyName 'DesignRatingProvider' -NotePropertyValue $provider -Force
        $item | Add-Member -NotePropertyName 'DesignRatingValue' -NotePropertyValue $providerValue -Force
        $item | Add-Member -NotePropertyName 'DesignRtCriticImage' -NotePropertyValue (Get-SiloRtCriticImage $ratings.RtCritic) -Force
        $item | Add-Member -NotePropertyName 'DesignRtAudienceImage' -NotePropertyValue (Get-SiloRtAudienceImage $ratings.RtAudience) -Force
        $item | Add-Member -NotePropertyName 'DesignGenres' -NotePropertyValue @($genres) -Force
        $item | Add-Member -NotePropertyName 'CacheCaptureEligible' -NotePropertyValue ($null -ne $detail) -Force
    }
}

function Get-SiloEpisodeImdbRating {
    param([AllowNull()][object]$TautulliMetadata)
    if ($null -eq $TautulliMetadata) { return '' }
    $image = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name 'rating_image'
    $value = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name 'rating'
    if ($image -like 'imdb://image.rating*' -and -not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return ''
}

# ---------------------------------------------------------------------------
# ARTWORK
# ---------------------------------------------------------------------------
function Get-SiloImageConverters {
    # Windows decodes through WIC (WebP needs the WebP Image Extensions);
    # ImageMagick is the portable converter and a Windows fallback.
    $converters = New-Object System.Collections.Generic.List[string]
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)) {
        $converters.Add('wic')
    }
    foreach ($name in @('magick', 'convert')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { continue }
        $source = [string]$command.Source
        # Windows ships an unrelated convert.exe (FAT-to-NTFS volume tool).
        if ($name -eq 'convert' -and -not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot) -and
            $source.StartsWith([string]$env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $converters.Add($source)
        break
    }
    return ,$converters.ToArray()
}

function Get-SiloImageConverter {
    $converters = @(Get-SiloImageConverters)
    if ($converters.Count -eq 0) { return '' }
    return [string]$converters[0]
}

function Convert-SiloImageWithMagick {
    param([string]$Converter, [string]$Source, [string]$Destination, [ValidateSet('jpg', 'png')][string]$Format, [int]$MaxWidth, [int]$MaxHeight)
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add($Source + '[0]')
    $arguments.Add('-auto-orient')
    $arguments.Add('-resize')
    $arguments.Add(('{0}x{1}>' -f $MaxWidth, $MaxHeight))
    $arguments.Add('-strip')
    if ($Format -eq 'jpg') {
        $arguments.Add('-background'); $arguments.Add('#181818')
        $arguments.Add('-alpha'); $arguments.Add('remove')
        $arguments.Add('-quality'); $arguments.Add('88')
        $arguments.Add('jpg:' + $Destination)
    }
    else {
        $arguments.Add('png:' + $Destination)
    }
    & $Converter @arguments 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ImageMagick exit code $LASTEXITCODE" }
}

function Convert-SiloImageWithWic {
    param([string]$Source, [string]$Destination, [ValidateSet('jpg', 'png')][string]$Format, [int]$MaxWidth, [int]$MaxHeight)
    Add-Type -AssemblyName PresentationCore, WindowsBase
    $sourceStream = [IO.File]::OpenRead($Source)
    try {
        $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create(
            $sourceStream,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]
        $scale = [Math]::Min(1.0, [Math]::Min($MaxWidth / [double]$frame.PixelWidth, $MaxHeight / [double]$frame.PixelHeight))
        [Windows.Media.Imaging.BitmapSource]$bitmap = $frame
        if ($scale -lt 1.0) {
            $bitmap = New-Object Windows.Media.Imaging.TransformedBitmap($frame, (New-Object Windows.Media.ScaleTransform($scale, $scale)))
        }
        if ($Format -eq 'jpg') {
            $bitmap = New-Object Windows.Media.Imaging.FormatConvertedBitmap($bitmap, [Windows.Media.PixelFormats]::Bgr24, $null, 0)
            $encoder = New-Object Windows.Media.Imaging.JpegBitmapEncoder
            $encoder.QualityLevel = 88
        }
        else {
            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        }
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $output = [IO.File]::Create($Destination)
        try { $encoder.Save($output) } finally { $output.Dispose() }
    }
    finally { $sourceStream.Dispose() }
}

function Convert-SiloImage {
    # Silo publishes artwork as WebP. Email clients such as Outlook desktop
    # cannot show WebP, so every image is re-encoded as JPEG (posters and
    # backdrops) or PNG (logos, preserving transparency) before embedding.
    param([string]$Source, [string]$Destination, [ValidateSet('jpg', 'png')][string]$Format, [int]$MaxWidth, [int]$MaxHeight)
    $converters = @(Get-SiloImageConverters)
    if ($converters.Count -eq 0) {
        if (-not $script:SiloImageConverterWarned) {
            $script:SiloImageConverterWarned = $true
            Write-Log 'Silo artwork is WebP and no converter is available. Install ImageMagick so posters, backdrops and logos can be embedded.' 'WARN'
        }
        return $false
    }
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($converter in $converters) {
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($converter -eq 'wic') {
                Convert-SiloImageWithWic -Source $Source -Destination $Destination -Format $Format -MaxWidth $MaxWidth -MaxHeight $MaxHeight
            }
            else {
                Convert-SiloImageWithMagick -Converter $converter -Source $Source -Destination $Destination -Format $Format -MaxWidth $MaxWidth -MaxHeight $MaxHeight
            }
            # A flat-colour logo PNG can be legitimately tiny; a JPEG poster or
            # backdrop under 512 bytes is a failed render.
            $minimumBytes = if ($Format -eq 'png') { 67 } else { 512 }
            if ((Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt $minimumBytes) { return $true }
            $failures.Add($(if ($converter -eq 'wic') { 'WIC' } else { 'ImageMagick' }) + ': empty output')
        }
        catch {
            $failures.Add($(if ($converter -eq 'wic') { 'WIC' } else { 'ImageMagick' }) + ': ' + $_.Exception.Message)
        }
    }
    if (-not $script:SiloImageConverterWarned) {
        $script:SiloImageConverterWarned = $true
        Write-Log ('Silo artwork could not be converted from WebP (' + ($failures -join '; ') + '). On Windows install the WebP Image Extensions or ImageMagick; elsewhere install ImageMagick with WebP support.') 'WARN'
    }
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    return $false
}

function Resolve-SiloImageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $value = $Url.Trim()
    # Check the server-relative form first: on Unix .NET parses '/path' as an
    # absolute file:// URI.
    if ($value.StartsWith('/') -and -not $value.StartsWith('//')) { return $script:SiloBase + $value }
    [Uri]$absolute = $null
    if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$absolute) -and $absolute.Scheme -in @('http', 'https')) {
        return $value
    }
    return ''
}

function Save-SiloImage {
    param(
        [string]$Url,
        [string]$DestinationPath,
        [ValidateSet('jpg', 'png')][string]$Format = 'jpg',
        [int]$MaxWidth = 300,
        [int]$MaxHeight = 450
    )
    $resolved = Resolve-SiloImageUrl -Url $Url
    if ([string]::IsNullOrWhiteSpace($resolved)) { return $false }
    $download = $DestinationPath + '.download-' + [Guid]::NewGuid().ToString('N')
    try {
        # Artwork URLs are signed or object-storage URLs; they carry their own
        # authorization, so the API key is never sent with them.
        [void](Invoke-SiloRequest -Label 'artwork' -Request {
            Invoke-WebRequest -Uri $resolved -OutFile $download -TimeoutSec 60 -UseBasicParsing | Out-Null
        }.GetNewClosure())
        if (-not (Test-Path -LiteralPath $download) -or (Get-Item -LiteralPath $download).Length -le 64) { return $false }
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        return (Convert-SiloImage -Source $download -Destination $DestinationPath -Format $Format -MaxWidth $MaxWidth -MaxHeight $MaxHeight)
    }
    catch {
        Write-Log ('Silo artwork download failed: ' + $_.Exception.Message) 'WARN'
        return $false
    }
    finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    }
}

function Save-SiloPoster {
    param([string]$ContentId, [string]$DestinationPath)
    $detail = Get-SiloItemDetail -ContentId $ContentId
    if ($null -eq $detail) { return $false }
    $type = Get-SiloString $detail 'type'
    $candidates = if ($type -eq 'episode') {
        @('series_poster_url', 'season_poster_url', 'poster_url')
    } else {
        @('poster_url')
    }
    foreach ($field in $candidates) {
        $url = Get-SiloString $detail $field
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if (Save-SiloImage -Url $url -DestinationPath $DestinationPath -Format jpg -MaxWidth 300 -MaxHeight 450) { return $true }
    }
    return $false
}

function Get-SiloDesignHeroAssets {
    param([object]$HotRelease)
    $result = [PSCustomObject]@{
        BannerSrc    = ''
        ArtSrc       = ''
        LogoSrc      = ''
        SuppressLogoFallback = $false
        MetadataFile = ''
        DiagnosticFile = ''
    }
    if ($null -eq $HotRelease -or $null -eq $HotRelease.Item) { return $result }
    $ratingKey = [string]$HotRelease.Item.RatingKey
    if ([string]::IsNullOrWhiteSpace($ratingKey)) { $ratingKey = [string]$HotRelease.Item.PosterRatingKey }
    if ([string]::IsNullOrWhiteSpace($ratingKey)) { return $result }

    $detail = Get-SiloItemDetail -ContentId $ratingKey
    if ($null -eq $detail) { return $result }
    $safeKey = Get-SafeFilePart $ratingKey

    $backdrop = Get-SiloString $detail 'backdrop_url'
    if ([string]::IsNullOrWhiteSpace($backdrop)) { $backdrop = Get-SiloString $detail 'series_backdrop_url' }
    if (-not [string]::IsNullOrWhiteSpace($backdrop)) {
        $artName = 'art_' + $safeKey + '.jpg'
        if (Save-SiloImage -Url $backdrop -DestinationPath (Join-Path $DesignMediaDir $artName) -Format jpg -MaxWidth 1200 -MaxHeight 675) {
            $result.ArtSrc = 'media/' + $artName
            $result.BannerSrc = $result.ArtSrc
        }
    }

    $logo = Get-SiloString $detail 'logo_url'
    if (-not [string]::IsNullOrWhiteSpace($logo)) {
        $logoName = 'logo_' + $safeKey + '.png'
        if (Save-SiloImage -Url $logo -DestinationPath (Join-Path $DesignMediaDir $logoName) -Format png -MaxWidth 800 -MaxHeight 310) {
            $result.LogoSrc = 'media/' + $logoName
            Write-Log 'TautWeekly: title logo acquired from Silo artwork.'
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# VERIFICATION
# ---------------------------------------------------------------------------
function Test-TautWeeklySiloConnection {
    # Returns 0 when every read the newsletter needs works, 2 otherwise.
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($check in @(
        @('/api/v2/admin/users/capabilities', 'accounts'),
        @('/api/v2/admin/playback-history/capabilities', 'playback history'),
        @('/api/v2/admin/catalog/capabilities', 'catalog listing')
    )) {
        try {
            $doc = Invoke-SiloApi -Path $check[0]
            $allowed = Get-SiloProperty $doc 'allowed'
            if ($null -ne $allowed -and -not [bool]$allowed) { $failures.Add($check[1] + ' (not allowed for this key)') }
            else { Write-Log ('Silo ' + $check[1] + ' read: OK') }
        }
        catch { $failures.Add($check[1] + ' (' + $_.Exception.Message + ')') }
    }
    try {
        $sample = Invoke-SiloApi -Path '/api/v2/admin/catalog/items' -Query @('limit', 1)
        $first = @()
        if ($null -ne $sample -and $null -ne $sample.PSObject.Properties['items']) { $first = @($sample.items | Select-Object -First 1) }
        if ($first.Count -gt 0) {
            $detail = Get-SiloItemDetail -ContentId (Get-SiloString $first[0] 'content_id')
            if ($null -eq $detail) { $failures.Add('catalog item detail (check SiloCatalogApiKey / SiloProfileId)') }
            else { Write-Log 'Silo catalog item detail read: OK' }
        }
    }
    catch { $failures.Add('catalog item detail (' + $_.Exception.Message + ')') }
    $converter = Get-SiloImageConverter
    if ([string]::IsNullOrWhiteSpace($converter)) {
        Write-Log 'No WebP converter is available; Silo artwork will be omitted. Install ImageMagick with WebP support.' 'WARN'
    }
    if ($failures.Count -gt 0) {
        Write-Log ('Silo verification failed: ' + ($failures -join '; ')) 'ERROR'
        return 2
    }
    Write-Log 'Silo verification passed.'
    return 0
}
