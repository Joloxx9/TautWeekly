[CmdletBinding()]
param(
    [string]$PythonPath = '',
    [string[]]$EngineFilter = @()
)

# Silo media-server provider: unit contracts for the /api/v2 translation layer
# plus an end-to-end renderer run against a deterministic Silo double. Runs
# under Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)
if ([string]::IsNullOrWhiteSpace($PythonPath)) { $PythonPath = if ($onWindows) { 'python' } else { 'python3' } }
$processWindowArgs = @{}
if ($onWindows) { $processWindowArgs.WindowStyle = 'Hidden' }

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "[FAIL] $Message" }
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Wait-ForFile([string]$Path, [System.Diagnostics.Process]$Process, [string]$Label, [string]$ErrorLog) {
    for ($attempt = 0; $attempt -lt 200 -and -not (Test-Path -LiteralPath $Path); $attempt++) {
        if ($Process.HasExited) { throw "$Label exited early: $(Get-Content -LiteralPath $ErrorLog -Raw -ErrorAction SilentlyContinue)" }
        Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $Path) "$Label did not become ready."
}

# ---------------------------------------------------------------------------
# 1. Every maintained renderer ships the identical provider module.
# ---------------------------------------------------------------------------
$modulePaths = @('platforms/windows/Silo-Provider.ps1', 'platforms/nas-docker/app/Silo-Provider.ps1', 'platforms/mac-docker/app/Silo-Provider.ps1')
$reference = (Get-Content -LiteralPath (Join-Path $Root $modulePaths[0]) -Raw) -replace "`r`n", "`n"
foreach ($relative in $modulePaths) {
    $candidate = (Get-Content -LiteralPath (Join-Path $Root $relative) -Raw) -replace "`r`n", "`n"
    Assert-True ($candidate -ceq $reference) "Silo provider drifted across renderers: $relative"
    $jellyfinRoutes = '/api/v1|/Items|/Sessions|/' + 'Users/'
    Assert-True ($candidate -cnotmatch $jellyfinRoutes) "$relative must use only the native /api/v2 contract."
    Assert-True ($candidate -notmatch 'Invoke-(RestMethod|WebRequest)[^\r\n]*-Method\s+(Post|Put|Delete|Patch)') "$relative must only read from Silo."
}
foreach ($renderer in @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $Root $renderer) -Raw
    Assert-True ($text.Contains('. (Join-Path $ScriptRoot "Silo-Provider.ps1")')) "$renderer does not load the Silo provider."
    Assert-True ($text.Contains('return Invoke-SiloTautulliCommand -Command $Command -Parameters $Parameters')) "$renderer does not route Tautulli commands to Silo."
    Assert-True ($text.Contains('Add-SiloDesignRatingMetadata -ReleaseData $ReleaseData')) "$renderer does not use Silo ratings."
    Assert-True ($text.Contains('Save-SiloPoster -ContentId $RatingKey -DestinationPath $path')) "$renderer does not fetch Silo posters."
}
Write-Host '[PASS] The Silo provider is identical, read-only, and /api/v2-only in every renderer.'

# ---------------------------------------------------------------------------
# 2. Unit contracts for the translation layer.
# ---------------------------------------------------------------------------
& {
    $script:LibraryFilterEnabled = $false
    $script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]'
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    function Get-OptionalStringProperty {
        param([object]$InputObject, [string]$Name)
        if ($null -eq $InputObject) { return '' }
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return '' }
        return [string]$property.Value
    }
    . (Join-Path $Root 'platforms/nas-docker/app/Silo-Provider.ps1')

    foreach ($case in @(
        @{ Config = [PSCustomObject]@{ MediaServer = 'jellyfin' }; Message = "MediaServer must be 'tautulli' or 'silo'." },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo' }; Message = "Missing required config value 'SiloUrl'" },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo'; SiloUrl = 'ftp://silo.test' }; Message = 'SiloUrl must be an absolute HTTP or HTTPS URL' },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo'; SiloUrl = 'http://user:pw@example.com' }; Message = 'SiloUrl must be an absolute HTTP or HTTPS URL' },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo'; SiloUrl = 'http://silo.test/?x=1' }; Message = 'SiloUrl must be an absolute HTTP or HTTPS URL' },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo'; SiloUrl = 'http://silo.test' }; Message = "Missing required config value 'SiloApiKey'" },
        @{ Config = [PSCustomObject]@{ MediaServer = 'silo'; SiloUrl = 'http://silo.test'; SiloApiKey = 'two words' }; Message = 'SiloApiKey must be a single API key token.' }
    )) {
        $failure = ''
        try { Initialize-TautWeeklySiloProvider -Configuration $case.Config } catch { $failure = $_.Exception.Message }
        Assert-True ($failure.StartsWith($case.Message)) "Invalid Silo configuration was not refused as expected: '$failure'"
    }
    Initialize-TautWeeklySiloProvider -Configuration ([PSCustomObject]@{ TautulliUrl = 'http://t.test' })
    Assert-True (-not (Test-TautWeeklySiloServer)) 'A configuration without MediaServer must stay on Tautulli.'
    Assert-True ((Get-TautWeeklyMediaServerName) -eq 'Plex') 'Tautulli mode must keep Plex wording.'
    Initialize-TautWeeklySiloProvider -Configuration ([PSCustomObject]@{ MediaServer = 'Silo'; SiloUrl = 'http://silo.test:8080/'; SiloApiKey = 'sa_monitor' })
    Assert-True (Test-TautWeeklySiloServer) 'MediaServer=Silo must enable the provider case-insensitively.'
    Assert-True ($script:SiloBase -eq 'http://silo.test:8080') 'SiloUrl must lose its trailing slash.'
    Assert-True ($script:SiloCatalogKey -eq 'sa_monitor') 'Catalog reads must default to the monitor key.'

    Assert-True ((Resolve-SiloImageUrl -Url '/api/v2/artwork/a.webp?sig=x') -eq 'http://silo.test:8080/api/v2/artwork/a.webp?sig=x') 'Server-relative artwork must resolve against SiloUrl on every OS.'
    Assert-True ((Resolve-SiloImageUrl -Url 'https://cdn.test/a.webp') -eq 'https://cdn.test/a.webp') 'Absolute HTTPS artwork must be kept.'
    Assert-True ((Resolve-SiloImageUrl -Url 'file:///etc/passwd') -eq '') 'Non-HTTP artwork must be refused.'
    Assert-True ((Resolve-SiloImageUrl -Url '//evil.test/a.webp') -eq '') 'Protocol-relative artwork must be refused.'

    Assert-True ((Get-SiloSeriesIdFromEpisodeId 'episode-tvdb-412426-1-8') -eq 'series-tvdb-412426') 'Episode identities must map to their series.'
    Assert-True ((Get-SiloSeriesIdFromEpisodeId 'movie-tmdb-1') -eq '') 'Non-episode identities have no series.'

    $local = [DateTime]::new(2026, 3, 29, 0, 0, 0, [DateTimeKind]::Local)
    Assert-True ((ConvertFrom-SiloTautulliDate -Value '2026-03-29') -eq (ConvertTo-SiloInstant -LocalTime $local)) 'History lower bound must be local midnight.'
    Assert-True ((ConvertFrom-SiloTautulliDate -Value '2026-03-29' -EndOfDay) -eq (ConvertTo-SiloInstant -LocalTime $local.AddDays(1))) 'History upper bound must be the next local midnight (exclusive).'
    Assert-True ((ConvertTo-SiloEpoch '2026-01-01T00:00:00.000Z') -eq 1767225600) 'RFC 3339 instants must convert to Unix seconds.'

    $ratings = Get-SiloRatings -Detail ([PSCustomObject]@{ ratings = @(
        [PSCustomObject]@{ source = 'imdb'; score = 81 },
        [PSCustomObject]@{ source = 'tmdb'; score = 79.17 },
        [PSCustomObject]@{ source = 'rt_critic'; score = 97 }); rating_rt_audience = 55 })
    Assert-True ($ratings.Imdb -eq '8.1' -and $ratings.Tmdb -eq '7.9' -and $ratings.RtCritic -eq '97' -and $ratings.RtAudience -eq '55') "Silo ratings were not normalized: $($ratings | ConvertTo-Json -Compress)"
    $row = @{}
    Add-SiloTautulliRatingFields -Row $row -Ratings $ratings -MediaType 'movie'
    Assert-True ($row.rating -eq '9.7' -and $row.rating_image -eq 'rottentomatoes://image.rating.ripe') 'Movies must lead with the RT critic score.'
    Assert-True ($row.audience_rating -eq '5.5' -and $row.audience_rating_image -eq 'rottentomatoes://image.rating.spilled') 'A sub-60 RT audience score must be spilled.'
    $row = @{}
    Add-SiloTautulliRatingFields -Row $row -Ratings $ratings -MediaType 'show'
    Assert-True ($row.rating -eq '8.1' -and $row.rating_image -eq 'imdb://image.rating') 'Shows must lead with IMDb.'
    $bad = Get-SiloRatings -Detail ([PSCustomObject]@{ ratings = @([PSCustomObject]@{ source = 'imdb'; score = 1200 }, [PSCustomObject]@{ source = 'rt_critic'; score = -3 }) })
    Assert-True ($bad.Imdb -eq '' -and $bad.RtCritic -eq '') 'Out-of-range ratings must be dropped.'

    $history = [PSCustomObject]@{
        session_id = 's'; user_id = '7'; username = 'viewer'; profile_id = 'p'; media_item_id = 'episode-tvdb-9-2-3'
        media_title = 'Hour'; media_type = 'episode'; started_at = '2026-01-01T00:00:00.000Z'; ended_at = '2026-01-01T01:00:00.000Z'
        watched_seconds = 2900.0; duration_seconds = 3000; completed = $false; played_seconds = $null
        start_position_seconds = 400; paused_seconds = $null; series_title = 'Show'; season_number = 2; episode_number = 3
        device_platform = $null; client_name = 'Silo iPhone'
    }
    $converted = ConvertTo-SiloTautulliHistoryRow -Row $history -CatalogRows @{}
    Assert-True ($converted.grandparent_rating_key -eq 'series-tvdb-9' -and $converted.guid -eq 'silo://series-tvdb-9') 'Episode history must group under its series.'
    Assert-True ($converted.play_duration -eq '2500') "Unmeasured attempts must count from the resume point: $($converted.play_duration)"
    Assert-True ($converted.percent_complete -eq '97' -and $converted.watched_status -eq 0) 'Percent complete must use the end position.'
    Assert-True ($converted.platform -eq 'iPhone') 'First-party client names must yield their device platform.'
    Assert-True ($converted.started -eq '1767225600' -and $converted.stopped -eq '1767229200') 'History instants must become Unix seconds.'
    $history.media_type = ''
    Assert-True ($null -eq (ConvertTo-SiloTautulliHistoryRow -Row $history -CatalogRows @{})) 'Attempts without a media type must be skipped.'
}
Write-Host '[PASS] Silo configuration, identity, date, rating, history, and artwork-URL translation contracts hold.'

# ---------------------------------------------------------------------------
# 3. End-to-end renderer runs against the Silo double.
# ---------------------------------------------------------------------------
$powerShell7 = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $command) { $command.Source } else { '' }
}
$windowsPowerShell = if ($onWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source) } else { '' }
$engines = @(
    [PSCustomObject]@{ Name = 'windows'; Source = 'platforms/windows'; Host = $windowsPowerShell; Container = $false },
    [PSCustomObject]@{ Name = 'nas-docker-linux-freebsd'; Source = 'platforms/nas-docker/app'; Host = $powerShell7; Container = $true },
    [PSCustomObject]@{ Name = 'mac-docker'; Source = 'platforms/mac-docker/app'; Host = $powerShell7; Container = $true }
)
$fakeSilo = Join-Path $Root 'scripts/test-support/fake-silo.py'
$fakeSmtp = Join-Path $Root 'scripts/test-support/fake-smtp.py'
$headless = Join-Path $Root 'scripts/test-support/invoke-renderer-headless.ps1'
$executed = 0

foreach ($engine in $engines) {
    if ($EngineFilter.Count -gt 0 -and $engine.Name -notin $EngineFilter) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host)) {
        Write-Host "[SKIP] $($engine.Name): its PowerShell host is unavailable on this runner; the Windows CI job runs it."
        continue
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-silo-' + [Guid]::NewGuid().ToString('N'))
    $app = Join-Path $temp 'app'
    $data = Join-Path $temp 'data'
    $callLog = Join-Path $temp 'silo-calls.jsonl'
    $smtpLog = Join-Path $temp 'smtp-calls.jsonl'
    $smtpMessage = Join-Path $temp 'message.eml'
    $silo = $null
    $smtp = $null
    New-Item -ItemType Directory -Force -Path $app, $data | Out-Null
    Copy-Item -Path (Join-Path (Join-Path $Root $engine.Source) '*') -Destination $app -Recurse -Force
    $oldData = $env:TAUTWEEKLY_DATA_DIR
    $oldConfig = $env:TAUTWEEKLY_CONFIG
    try {
        $siloPort = Get-FreeTcpPort
        $silo = Start-Process -FilePath $PythonPath -ArgumentList @('-u', $fakeSilo, '--port', [string]$siloPort, '--call-log', $callLog, '--ready-file', (Join-Path $temp 'silo-ready.txt')) -PassThru @processWindowArgs -RedirectStandardOutput (Join-Path $temp 'silo.out') -RedirectStandardError (Join-Path $temp 'silo.err')
        Wait-ForFile (Join-Path $temp 'silo-ready.txt') $silo 'Silo double' (Join-Path $temp 'silo.err')
        $siloUrl = (Get-Content -LiteralPath (Join-Path $temp 'silo-ready.txt') -Raw).Trim()
        $smtpPort = Get-FreeTcpPort
        $smtp = Start-Process -FilePath $PythonPath -ArgumentList @('-u', $fakeSmtp, '--port', [string]$smtpPort, '--call-log', $smtpLog, '--ready-file', (Join-Path $temp 'smtp-ready.txt'), '--data-file', $smtpMessage) -PassThru @processWindowArgs -RedirectStandardOutput (Join-Path $temp 'smtp.out') -RedirectStandardError (Join-Path $temp 'smtp.err')
        Wait-ForFile (Join-Path $temp 'smtp-ready.txt') $smtp 'SMTP double' (Join-Path $temp 'smtp.err')

        $config = Get-Content -LiteralPath (Join-Path $app 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in ([ordered]@{
            MediaServer = 'silo'; SiloUrl = $siloUrl
            SiloApiKey = 'sa_fictional_monitor_key'; SiloCatalogApiKey = 'sa_fictional_catalog_key'
            TautulliUrl = ''; ApiKey = ''; ServerLabel = ''; FooterServerName = ''; PlexWebUrl = ''; PlexButtonLabel = ''
            SmtpHost = '127.0.0.1'; SmtpPort = $smtpPort; SmtpEnableSsl = $false; SmtpUseAuthentication = $false; SmtpTimeoutSeconds = 5
            FromEmail = 'sender@example.com'; FromName = 'TautWeekly Silo Test'; ReplyToEmail = 'sender@example.com'; TestEmail = 'recipient@example.com'
            TestSendDelaySeconds = 0; SendDelaySeconds = 0; DaysBack = 7; MaxMovies = 4; MaxTv = 4
            DeletedItemCacheEnabled = $true
        }).GetEnumerator()) {
            $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
        }
        if ($engine.Container) {
            New-Item -ItemType Directory -Force -Path (Join-Path $data 'assets') | Out-Null
            Copy-Item -Path (Join-Path $app 'assets-default/*') -Destination (Join-Path $data 'assets') -Recurse -Force
            $configPath = Join-Path $data 'config.json'
            $output = Join-Path $data 'output'
            $env:TAUTWEEKLY_DATA_DIR = $data
            $env:TAUTWEEKLY_CONFIG = $configPath
        }
        else {
            $configPath = Join-Path $app 'config.json'
            $output = Join-Path $app 'output'
        }
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8

        function Invoke-Renderer([string]$Mode, [string]$UserId = '1') {
            $stdout = Join-Path $temp ("$Mode.out")
            $stderr = Join-Path $temp ("$Mode.err")
            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headless, '-RendererPath', (Join-Path $app 'TautWeekly.ps1'), '-ConfigPath', $configPath, '-Mode', $Mode)
            if ($Mode -notin @('VerifyPlex')) { $arguments += @('-UserId', $UserId) }
            $process = Start-Process -FilePath $engine.Host -ArgumentList $arguments -Wait -PassThru @processWindowArgs -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $text = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
            if ($process.ExitCode -ne 0) { throw "$($engine.Name) $Mode failed ($($process.ExitCode)):`n$text" }
            return $text
        }

        $verify = Invoke-Renderer 'VerifyPlex'
        Assert-True ($verify.Contains('Silo verification passed.')) "$($engine.Name) VerifyPlex did not verify Silo."
        Assert-True (-not $verify.Contains('Direct Plex verification')) "$($engine.Name) VerifyPlex still probed Plex in Silo mode."

        $previewLog = Invoke-Renderer 'PreviewAll'
        Assert-True (($verify + $previewLog).Contains('retrying after')) "$($engine.Name) did not retry the rate-limited Silo request."
        $normal = Get-Content -LiteralPath (Join-Path $output 'preview-all-04-normal-newsletter.html') -Raw -Encoding UTF8
        foreach ($expected in @('Silo Fictional Feature', 'Silo Rotten Fixture', 'Silo Fictional Series', 'YOUR WEEK ON SILO', 'Open Silo', 'Silo drop', 'rt_ripe', 'rt_rotten', 'rt_upright', 'rt_spilled', 'posters/poster_movie-tmdb-1001.jpg', 'posters/poster_series-tvdb-2001.jpg')) {
            Assert-True ($normal.Contains($expected)) "$($engine.Name) Silo newsletter lacks '$expected'."
        }
        foreach ($forbidden in @('Plex drop', 'Open Plex', 'YOUR WEEK ON PLEX', 'sa_fictional', 'alice@example.com')) {
            Assert-True (-not $normal.Contains($forbidden)) "$($engine.Name) Silo newsletter contains '$forbidden'."
        }
        $statsStart = $normal.IndexOf('YOUR WEEK ON SILO')
        $statsEnd = $normal.IndexOf('BINGE CHAMPION', $statsStart)
        Assert-True ($statsStart -ge 0 -and $statsEnd -gt $statsStart) "$($engine.Name) newsletter has no personal stats section."
        $stats = $normal.Substring($statsStart, $statsEnd - $statsStart)
        Assert-True ($stats.Contains('Silo Fictional Feature')) "$($engine.Name) personal stats omit the recipient's own movie."
        Assert-True (-not $stats.Contains('Bob Private Rewatch')) "$($engine.Name) personal stats leaked another account's history."
        Assert-True (-not $stats.Contains('Silo Rotten Fixture')) "$($engine.Name) personal stats counted a child profile's play."
        foreach ($asset in @('posters/poster_movie-tmdb-1001.jpg', 'posters/poster_movie-tmdb-1002.jpg', 'media/art_movie-tmdb-1001.jpg', 'media/logo_movie-tmdb-1001.png')) {
            $path = Join-Path $output $asset
            Assert-True ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 67) "$($engine.Name) did not convert Silo artwork $asset."
        }
        $poster = [IO.File]::ReadAllBytes((Join-Path $output 'posters/poster_movie-tmdb-1001.jpg'))
        Assert-True ($poster[0] -eq 0xFF -and $poster[1] -eq 0xD8) "$($engine.Name) poster is not JPEG."
        $logo = [IO.File]::ReadAllBytes((Join-Path $output 'media/logo_movie-tmdb-1001.png'))
        Assert-True ($logo[0] -eq 0x89 -and $logo[1] -eq 0x50) "$($engine.Name) logo is not PNG."

        $sendLog = Invoke-Renderer 'SendTest'
        Assert-True (Test-Path -LiteralPath $smtpMessage) "$($engine.Name) SendTest delivered no message."
        $mime = Get-Content -LiteralPath $smtpMessage -Raw
        Assert-True ($mime -match '(?im)^Content-Type:\s*image/jpeg') "$($engine.Name) email does not embed JPEG posters."
        Assert-True ($mime -notmatch '(?i)image/webp') "$($engine.Name) email embeds WebP artwork."
        Assert-True ($mime -notmatch 'sa_fictional') "$($engine.Name) email leaks a Silo API key."

        $calls = @(Get-Content -LiteralPath $callLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($calls.Count -gt 0) "$($engine.Name) made no Silo requests."
        foreach ($call in $calls) {
            Assert-True ($call.method -eq 'GET') "$($engine.Name) sent a non-GET request to Silo: $($call.method) $($call.path)"
            Assert-True ($call.path.StartsWith('/api/v2/') -or $call.path.StartsWith('/artwork/')) "$($engine.Name) left the /api/v2 contract: $($call.path)"
            if ($call.path.StartsWith('/artwork/')) {
                Assert-True ([string]::IsNullOrEmpty([string]$call.auth)) "$($engine.Name) sent the API key to an artwork URL."
            }
            Assert-True ([int]$call.status -lt 400 -or [int]$call.status -eq 429) "$($engine.Name) received HTTP $($call.status) for $($call.path)."
        }
        $personal = @($calls | Where-Object { $_.path -eq '/api/v2/admin/playback-history' -and @($_.query) -contains 'user_id' })
        Assert-True ($personal.Count -gt 0) "$($engine.Name) did not scope personal history to the recipient account."
        Assert-True (@($calls | Where-Object { $_.path -like '/api/v2/catalog/items/*' -and [string]$_.profile -eq '' }).Count -eq 0) "$($engine.Name) read item detail without a profile."
        Assert-True (@($calls | Where-Object { $_.status -eq 429 }).Count -ge 1) "$($engine.Name) never hit the simulated rate limit."
        Write-Host "[PASS] $($engine.Name): Silo verify, all-state preview, recipient isolation, artwork conversion, and SMTP delivery."
        $executed++
    }
    finally {
        $env:TAUTWEEKLY_DATA_DIR = $oldData
        $env:TAUTWEEKLY_CONFIG = $oldConfig
        foreach ($process in @($silo, $smtp)) {
            if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Assert-True ($executed -gt 0) 'No Silo renderer engine could run on this host.'
Write-Host "[PASS] Silo provider integration covered $executed renderer engine(s)."
