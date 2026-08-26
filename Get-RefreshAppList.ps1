<#
.SYNOPSIS
    Lists applications that need manual installation on a refreshed device.

.DESCRIPTION
    Pulls the installed application inventory for a device from Absolute,
    removes anything in the base image, suppresses drivers and runtimes,
    and reports what is left.

    The install list is numbered, and unless -NoPrompt is given you are asked
    whether any of it belongs in the baseline. Anything you pick is appended to
    the baseline CSV with provenance, so the next refresh filters it.

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -ShowFiltered

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -NoPrompt -OutputCsv .\JLY4F42.csv

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -OutputPdf .\JLY4F42.pdf

    Writes a printable tick-list. The PDF is produced by driving Edge (or
    Chrome) headless - no modules, nothing to install. Set APPFILTER_BROWSER
    if neither is in its usual place.
#>

[CmdletBinding(DefaultParameterSetName = 'Serial')]
param(
    # Left optional on purpose: with nothing supplied the script asks.
    [Parameter(ParameterSetName = 'Serial', Position = 0)]
    [string]$Serial,

    [Parameter(Mandatory, ParameterSetName = 'DeviceName')]
    [string]$DeviceName,

    # Also show what was filtered out and why
    [switch]$ShowFiltered,

    # Skip the "add these to the baseline?" prompt and never touch the CSV
    [switch]$NoPrompt,

    [string]$BaselineCsv = ".\BaseImageApps.csv",
    [string]$OutputCsv,

    # Printable tick-list for the bench
    [string]$OutputPdf
)

# --- CONFIGURATION -------------------------------------------------
$TokenId   = "TOKEN HERE"
$SecretKey = "KEY HERE"
$BaseUrl   = "https://api.absolute.com"
$PageSize  = 500
# -------------------------------------------------------------------


# --- NOISE SUPPRESSION RULES ---------------------------------------
# Publishers whose software arrives with the hardware or the image.
# Compared through ConvertTo-NormalizedPublisher, so one entry per company is
# enough - 'Dell', 'Dell Inc.' and 'Dell Technologies' all reduce to 'dell'.
$DriverPublishers = @(
    'Intel', 'Realtek', 'Dell', 'NVIDIA', 'Advanced Micro Devices', 'AMD',
    'Synaptics', 'Conexant', 'Broadcom', 'Qualcomm', 'ELAN', 'Alps Electric'
)

# Name patterns that are never a manual install.
$NoisePatterns = @(
    'Visual C\+\+',
    'Redistributable',
    '\.NET (Framework|Runtime|Core)',
    'Runtime',
    'Driver',
    'WebView2',
    'Update Health Tools',
    'Windows (SDK|Assessment)',
    'Microsoft Edge (Update|WebView)',
    'Management Engine',
    'Chipset',
    'Firmware'
)
# -------------------------------------------------------------------


function ConvertTo-NormalizedAppName {
    <#
        Reduces an application name to a comparable key so that the same
        product matches across machines despite version drift, architecture
        suffixes and trademark symbols. Applied to BOTH sides of the
        baseline comparison.

            'Tanium Client 7.8.1.3126'        -> 'tanium client'
            '7-Zip 19.00 (x64 edition)'       -> '7-zip'
            'Thunderbolt(tm) Software'        -> 'thunderbolt software'

        Numbers that are part of a product's name are deliberately kept:
        'Microsoft 365', 'Paint 3D' and 'OneNote for Windows 10' survive,
        because a bare trailing integer is not treated as a version.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $n = $Name

    # Trademark / registered / copyright marks
    $n = $n -replace '[™®©]', ' '

    # Architecture / edition parentheticals
    $n = $n -replace '\((?:x64|x86|amd64|arm64|ia64|32[-\s]?bit|64[-\s]?bit)(?:\s+edition)?\)', ' '

    # Trailing version numbers, in the three shapes that actually occur:
    #   ' - 11.0.61030' / ' - 19'  (dash separated, any digits)
    #   ' v14' / ' v2.1'           (explicit v prefix)
    #   ' 7.8.1.3126'              (dotted, two or more parts)
    $n = $n -replace '\s*[-–]\s*v?\d+(?:\.\d+)*\s*$', ' '
    $n = $n -replace '\s+v\d+(?:\.\d+)*\s*$', ' '
    $n = $n -replace '\s+\d+(?:\.\d+)+\s*$', ' '

    # Collapse whitespace, lowercase
    ($n -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function ConvertTo-NormalizedPublisher {
    <#
        Reduces a publisher to a comparable key, so the driver list needs one
        entry per company instead of one per spelling.

            'Dell' / 'Dell Inc.' / 'Dell Technologies'  -> 'dell'
            'Realtek Semiconductor'                     -> 'realtek'
            'INTEL' / 'Intel Corporation'               -> 'intel'

        Suffixes are only stripped from the END of the name, so a company whose
        name genuinely contains one of these words mid-string is left alone.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $n = $Name -replace '[\u2122\u00AE\u00A9]', ' '
    $n = $n -replace '[,\.]', ' '
    $n = ($n -replace '\s+', ' ').Trim()

    $suffix = '(incorporated|inc|corporation|corp|company|co|limited|ltd|llc|gmbh|technologies|technology|software|semiconductor|systems|electronics|group|holdings)'
    while ($n -match "\s$suffix\s*$") {
        $n = ($n -replace "\s$suffix\s*$", '').Trim()
    }

    $n.ToLowerInvariant()
}

function Read-IndexSelection {
    <#
        Turns "1,4" / "1-3" / "2 5 7-9" into a sorted, de-duplicated list of
        valid 1-based indexes. Anything unparseable or out of range is reported
        and dropped rather than guessed at.
    #>
    param(
        [string]$Response,
        [Parameter(Mandatory)][int]$Max
    )

    $picked = [System.Collections.Generic.SortedSet[int]]::new()

    foreach ($token in @($Response -split '[,\s]+' | Where-Object { $_ })) {
        if ($token -match '^(\d+)\s*[-\u2013]\s*(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -gt $hi) { $t = $lo; $lo = $hi; $hi = $t }
            for ($i = $lo; $i -le $hi; $i++) {
                if ($i -ge 1 -and $i -le $Max) { [void]$picked.Add($i) }
                else { Write-Warning "No item [$i] on the list - ignored." }
            }
        }
        elseif ($token -match '^\d+$') {
            $i = [int]$token
            if ($i -ge 1 -and $i -le $Max) { [void]$picked.Add($i) }
            else { Write-Warning "No item [$i] on the list - ignored." }
        }
        else {
            Write-Warning "Could not read '$token' as a number or range - ignored."
        }
    }

    # Unrolls to ints; callers wrap in @() per the usual PowerShell hazard.
    return $picked
}

function Add-BaselineEntry {
    <#
        Appends chosen applications to the baseline CSV, carrying provenance so
        a later reader can tell why a row is there. Rewrites the whole file to
        keep it sorted and single-shaped.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Apps,
        [string]$Serial
    )

    $existing = @(Import-Csv $Path)

    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $existing) {
        $k = ConvertTo-NormalizedAppName $row.AppName
        if ($k) { [void]$keys.Add($k) }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    $added = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $Apps) {
        $k = ConvertTo-NormalizedAppName $app.AppName
        if (-not $k) { continue }
        if ($keys.Contains($k)) {
            Write-Warning "'$($app.AppName)' already matches a baseline entry - skipped."
            continue
        }
        [void]$keys.Add($k)
        $added.Add([pscustomobject]@{
            AppName   = $app.AppName
            Publisher = $app.Publisher
            Source    = 'refresh-prompt'
            AddedOn   = $stamp
            AddedBy   = $env:USERNAME
            Serial    = $Serial
        })
    }

    if ($added.Count -eq 0) { return 0 }

    $all = @(@($existing) + @($added)) |
        Select-Object AppName, Publisher, Source, AddedOn, AddedBy, Serial |
        Sort-Object { $_.AppName.ToLowerInvariant() }

    $all | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $added.Count
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Invoke-AbsoluteApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$QueryString = "",
        [string]$Method      = "GET"
    )

    $header = @{
        alg            = "HS256"
        kid            = $TokenId
        method         = $Method
        'content-type' = "application/json"
        uri            = $Uri
        'query-string' = $QueryString
        issuedAt       = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    $b64Header  = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
    $b64Payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{}'))
    $toBeSigned = "$b64Header.$b64Payload"

    $hmac     = [System.Security.Cryptography.HMACSHA256]::new()
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($SecretKey)
    $b64Sig   = ConvertTo-Base64Url $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($toBeSigned))
    $hmac.Dispose()

    try {
        $response = Invoke-WebRequest -Uri "$BaseUrl/jws/validate" `
                                      -Method POST -Body "$toBeSigned.$b64Sig" `
                                      -ContentType "text/plain" -UseBasicParsing -ErrorAction Stop
        return ($response.Content | ConvertFrom-Json)
    }
    catch {
        Write-Host -ForegroundColor Red "Request failed: $Method $Uri`?$QueryString"
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host -ForegroundColor Red $_.ErrorDetails.Message
        } else {
            Write-Host -ForegroundColor Red $_.Exception.Message
        }
        throw
    }
}

function Get-AbsoluteV3 {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Query = @{},
        [ValidateRange(1, 500)][int]$PageSize = 500
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next    = $null
    $guard   = 0

    do {
        $parts = @()
        foreach ($key in $Query.Keys) {
            if ($null -ne $Query[$key] -and "$($Query[$key])" -ne "") {
                $parts += "$key=$([uri]::EscapeDataString([string]$Query[$key]))"
            }
        }
        $parts += "pageSize=$PageSize"
        if ($next) { $parts += "nextPage=$([uri]::EscapeDataString($next))" }

        $response = Invoke-AbsoluteApi -Uri $Uri -QueryString ($parts -join '&')

        $batch = @( if ($null -ne $response.data) { $response.data } else { $response } )
        foreach ($item in $batch) { if ($null -ne $item) { $results.Add($item) } }

        $next = $null
        if ($response.metadata -and $response.metadata.pagination) {
            $next = $response.metadata.pagination.nextPage
        }

        $guard++
        if ($guard -gt 500) { Write-Warning "Pagination guard tripped."; break }

    } while ($next)

    return $results
}


# ------------------------------------------------------------------
#  Load the baseline
# ------------------------------------------------------------------
if (-not (Test-Path $BaselineCsv)) {
    throw "Baseline file not found: $BaselineCsv"
}

$baseline = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in (Import-Csv $BaselineCsv)) {
    if ($row.AppName) {
        $key = ConvertTo-NormalizedAppName $row.AppName
        if ($key) { [void]$baseline.Add($key) }
    }
}
Write-Verbose "Baseline holds $($baseline.Count) normalized application name(s)."

# NOTE: PowerShell variable names are case-insensitive, so this set must NOT
# be called $driverPublishers - it would overwrite the $DriverPublishers array
# above before the loop below had read it, leaving the driver rule matching
# nothing at all.
$driverPublisherKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($publisher in $DriverPublishers) {
    $k = ConvertTo-NormalizedPublisher $publisher
    if ($k) { [void]$driverPublisherKeys.Add($k) }
}
Write-Verbose "Driver publisher rule holds $($driverPublisherKeys.Count) normalized publisher(s)."


# ------------------------------------------------------------------
#  Printable sheet
# ------------------------------------------------------------------
function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function New-InstallSheetHtml {
    <#
        A worksheet, not a report: a tick box per row so the sheet can be
        worked through on the bench, and enough device identity at the top that
        a printed page is still traceable once it leaves the screen.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [object[]]$Apps = @(),
        $ScanAge,
        [int]$SuppressedCount,
        [int]$TotalCount
    )

    $rows = foreach ($a in $Apps) {
        @"
      <tr>
        <td class="box"></td>
        <td class="app">$(ConvertTo-HtmlText $a.AppName)</td>
        <td class="ver">$(ConvertTo-HtmlText $a.Version)</td>
        <td class="pub">$(ConvertTo-HtmlText $a.Publisher)</td>
        <td class="notes"></td>
      </tr>
"@
    }

    if (-not $Apps -or $Apps.Count -eq 0) {
        $rows = '      <tr><td class="box"></td><td colspan="4" class="none">Nothing beyond the base image.</td></tr>'
    }

    $warnings = @()
    if ($Device.agentStatus -ne 'A') {
        $warnings += "Absolute agent is not active (status '$(ConvertTo-HtmlText ([string]$Device.agentStatus))') - this inventory may be out of date."
    }
    if ($null -ne $ScanAge -and $ScanAge -gt 30) {
        $warnings += "Last software scan was $ScanAge days ago - confirm with the user that nothing is missing."
    }
    $warningHtml = ''
    if ($warnings.Count -gt 0) {
        $warningHtml = "  <p class=`"warn`">" + (($warnings | ForEach-Object { ConvertTo-HtmlText $_ }) -join "<br />") + "</p>`n"
    }

    $scanText = if ($null -ne $ScanAge) { "$ScanAge day(s) ago" } else { 'unknown' }

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Applications to install - $(ConvertTo-HtmlText ([string]$Device.serialNumber))</title>
<style>
  @page { size: A4 portrait; margin: 14mm 12mm; }
  * { box-sizing: border-box; }
  body { font-family: Segoe UI, Calibri, Arial, sans-serif; font-size: 10.5pt;
         color: #000; background: #fff; margin: 0; }
  h1 { font-size: 15pt; margin: 0 0 2mm; }
  .meta { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1mm 6mm;
          border-top: 1.5pt solid #000; border-bottom: 0.5pt solid #000;
          padding: 2mm 0; margin-bottom: 3mm; }
  .meta div { font-size: 9.5pt; }
  .meta span { display: block; font-size: 7.5pt; letter-spacing: .06em;
               text-transform: uppercase; color: #555; }
  .warn { border: 0.75pt solid #000; padding: 2mm; margin: 0 0 3mm;
          font-size: 9pt; }
  table { width: 100%; border-collapse: collapse; }
  thead { display: table-header-group; }
  th { text-align: left; font-size: 8pt; letter-spacing: .06em;
       text-transform: uppercase; border-bottom: 1pt solid #000;
       padding: 0 2mm 1.5mm; }
  td { padding: 2mm; border-bottom: 0.5pt solid #bbb; vertical-align: top; }
  tr { page-break-inside: avoid; }
  .box { width: 9mm; }
  .box::before { content: ""; display: block; width: 4.5mm; height: 4.5mm;
                 border: 0.75pt solid #000; margin-top: 0.5mm; }
  .app { font-weight: 600; }
  .ver, .pub { font-size: 9pt; color: #333; white-space: nowrap; }
  .notes { width: 32%; }
  .none { color: #555; font-style: italic; }
  .foot { margin-top: 4mm; padding-top: 2mm; border-top: 0.5pt solid #000;
          font-size: 8.5pt; color: #333; }
</style>
</head>
<body>
  <h1>Applications to install</h1>
  <div class="meta">
    <div><span>Device</span>$(ConvertTo-HtmlText ([string]$Device.deviceName))</div>
    <div><span>Serial</span>$(ConvertTo-HtmlText ([string]$Device.serialNumber))</div>
    <div><span>User</span>$(ConvertTo-HtmlText ([string]$Device.username))</div>
    <div><span>Model</span>$(ConvertTo-HtmlText ([string]$Device.systemModel))</div>
    <div><span>Last software scan</span>$scanText</div>
    <div><span>Sheet generated</span>$(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
  </div>
$warningHtml  <table>
    <thead>
      <tr><th></th><th>Application</th><th>Version</th><th>Publisher</th><th>Notes</th></tr>
    </thead>
    <tbody>
$($rows -join "`n")
    </tbody>
  </table>
  <p class="foot">$($Apps.Count) to install &middot; $SuppressedCount of $TotalCount inventoried applications suppressed as base image, driver or runtime.</p>
</body>
</html>
"@
}

function Find-PdfBrowser {
    <#
        Edge ships with the image and Chrome is in the baseline, so one of these
        is always present. APPFILTER_BROWSER overrides for an unusual install.
    #>
    if ($env:APPFILTER_BROWSER -and (Test-Path $env:APPFILTER_BROWSER)) {
        return $env:APPFILTER_BROWSER
    }

    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    foreach ($name in 'msedge.exe', 'chrome.exe') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    return $null
}

function Export-InstallSheetPdf {
    <#
        Renders the sheet through a headless browser. Returns the PDF path on
        success, or $null - in which case the HTML is left behind so the sheet
        can still be printed from a browser by hand.
    #>
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not [IO.Path]::GetExtension($Path)) { $Path = "$Path.pdf" }

    # Resolve against the caller's location WITHOUT mangling an already-absolute
    # path - Join-Path would happily glue two roots together.
    $full = [IO.Path]::GetFullPath($Path, (Get-Location).Path)
    $dir  = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $htmlPath = [IO.Path]::ChangeExtension($full, '.html')
    Set-Content -Path $htmlPath -Value $Html -Encoding UTF8

    $browser = Find-PdfBrowser
    if (-not $browser) {
        Write-Warning "Could not find Edge or Chrome to render the PDF."
        Write-Host "  Sheet saved as HTML instead: $htmlPath" -ForegroundColor Yellow
        Write-Host "  Open it and print with Ctrl+P, or set APPFILTER_BROWSER to a browser path." -ForegroundColor DarkGray
        return $null
    }

    # A throwaway profile keeps this from colliding with a browser the tech
    # already has open, which otherwise makes headless exit without rendering.
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ("appfilter-" + [Guid]::NewGuid().ToString('N'))

    $arguments = @(
        '--headless=new'
        '--disable-gpu'
        '--no-first-run'
        '--no-pdf-header-footer'
        "--user-data-dir=`"$profileDir`""
        "--print-to-pdf=`"$full`""
        "`"$(([uri]$htmlPath).AbsoluteUri)`""
    )

    try {
        if (Test-Path $full) { Remove-Item $full -Force -ErrorAction SilentlyContinue }
        $proc = Start-Process -FilePath $browser -ArgumentList $arguments -NoNewWindow -Wait -PassThru -ErrorAction Stop

        if ((Test-Path $full) -and ((Get-Item $full).Length -gt 0)) {
            Remove-Item $htmlPath -Force -ErrorAction SilentlyContinue
            return $full
        }

        Write-Warning "$(Split-Path -Leaf $browser) exited with code $($proc.ExitCode) without producing a PDF."
    }
    catch {
        Write-Warning "Could not run $browser`: $($_.Exception.Message)"
    }
    finally {
        Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Sheet saved as HTML instead: $htmlPath" -ForegroundColor Yellow
    Write-Host "  Open it and print with Ctrl+P." -ForegroundColor DarkGray
    return $null
}


# ------------------------------------------------------------------
#  Ask for a device if none was supplied
# ------------------------------------------------------------------
if (-not $Serial -and -not $DeviceName) {
    $Serial = (Read-Host "Serial number").Trim()
    if (-not $Serial) {
        Write-Host "No serial entered - nothing to do." -ForegroundColor Yellow
        return
    }
}
if ($Serial) { $Serial = $Serial.Trim() }


# ------------------------------------------------------------------
#  Find the device
# ------------------------------------------------------------------
$deviceQuery = @{}
if ($Serial)     { $deviceQuery['serialNumber'] = $Serial }
if ($DeviceName) { $deviceQuery['deviceName']   = $DeviceName }

Write-Host "Looking up device..." -ForegroundColor Cyan
$devices = @(Get-AbsoluteV3 -Uri "/v3/reporting/devices" -Query $deviceQuery -PageSize $PageSize)

if ($devices.Count -eq 0) { throw "No device matched that identifier." }
if ($devices.Count -gt 1) {
    Write-Warning "$($devices.Count) devices matched - using the most recently connected."
    $devices = @($devices | Sort-Object lastConnectedDateTimeUtc -Descending)
}

$device = $devices[0]


# ------------------------------------------------------------------
#  Pull its applications
# ------------------------------------------------------------------
Write-Host "Pulling application inventory..." -ForegroundColor Cyan
$apps = @(Get-AbsoluteV3 -Uri "/v3/reporting/applications" `
                         -Query @{ deviceUid = $device.deviceUid } `
                         -PageSize $PageSize)

# Defend against the filter being ignored server-side
$apps = @($apps | Where-Object { [string]$_.deviceUid -eq [string]$device.deviceUid })

if ($apps.Count -eq 0) {
    Write-Warning "No application inventory returned for this device."
    Write-Warning "Agent status is '$($device.agentStatus)'. If the agent is disabled or hasn't checked in, the inventory may be missing."
    return
}


# ------------------------------------------------------------------
#  Classify
# ------------------------------------------------------------------
$classified = foreach ($a in $apps) {

    $reason = $null
    $key    = ConvertTo-NormalizedAppName ([string]$a.appName)

    if ($key -and $baseline.Contains($key)) {
        $reason = 'Base image'
    }
    elseif ($a.appPublisher -and $driverPublisherKeys.Contains((ConvertTo-NormalizedPublisher ([string]$a.appPublisher)))) {
        $reason = 'Driver / OEM'
    }
    else {
        foreach ($pattern in $NoisePatterns) {
            if ($a.appName -match $pattern) { $reason = 'Runtime / component'; break }
        }
    }

    [pscustomobject]@{
        AppName    = $a.appName
        Version    = $a.appVersion
        Publisher  = $a.appPublisher
        Installed  = $a.installDateTimeUtc
        Path       = $a.installPath
        Excluded   = [bool]$reason
        Reason     = $reason
    }
}

$toInstall = @($classified | Where-Object { -not $_.Excluded } | Sort-Object AppName)
for ($i = 0; $i -lt $toInstall.Count; $i++) {
    $toInstall[$i] | Add-Member -NotePropertyName Index -NotePropertyValue ($i + 1) -Force
}
$excluded  = @($classified | Where-Object { $_.Excluded })


# ------------------------------------------------------------------
#  Report
# ------------------------------------------------------------------
$scanAge = if ($apps[0].lastScanDateTimeUtc) {
    [int]((Get-Date) - [datetime]$apps[0].lastScanDateTimeUtc).TotalDays
}

Write-Host ""
Write-Host ("=" * 70)
Write-Host "  $($device.deviceName)   [$($device.serialNumber)]"
Write-Host "  User: $($device.username)"
Write-Host "  Agent status: $($device.agentStatus)   Last software scan: $scanAge day(s) ago"
Write-Host ("=" * 70)

if ($device.agentStatus -ne 'A') {
    Write-Warning "Agent is not active - this inventory may be out of date."
}
if ($scanAge -gt 30) {
    Write-Warning "Software scan is $scanAge days old - confirm with the user that nothing is missing."
}

Write-Host ""
Write-Host "  INSTALL ON NEW DEVICE ($($toInstall.Count))" -ForegroundColor Green
Write-Host ""

if ($toInstall.Count -eq 0) {
    Write-Host "    Nothing beyond the base image." -ForegroundColor DarkGray
} else {
    $toInstall | Format-Table @{ n = '#';           e = { "[$($_.Index)]" }; width = 5 },
                              @{ n = 'Application'; e = { $_.AppName };      width = 45 },
                              @{ n = 'Version';     e = { $_.Version };      width = 20 },
                              @{ n = 'Publisher';   e = { $_.Publisher } }
}

# ------------------------------------------------------------------
#  Offer to fold any of it into the baseline
# ------------------------------------------------------------------
if (-not $NoPrompt -and $toInstall.Count -gt 0) {

    Write-Host ""
    $answer = Read-Host "Add any of these to the base image list? [numbers / n]"

    if ($answer -and $answer.Trim() -notmatch '^(n|no)$') {

        $picked = @(Read-IndexSelection -Response $answer -Max $toInstall.Count)

        if ($picked.Count -eq 0) {
            Write-Host "  Nothing selected." -ForegroundColor DarkGray
        }
        else {
            $chosen = @($picked | ForEach-Object { $toInstall[$_ - 1] })

            Write-Host ""
            Write-Host "  Adding to $BaselineCsv :"
            foreach ($c in $chosen) {
                Write-Host ("    [{0}] {1}  ({2})" -f $c.Index, $c.AppName, $c.Publisher)

                # A name row is matched on its normalized key, which can be
                # broader than the name on screen. Say so before writing it.
                $key = ConvertTo-NormalizedAppName $c.AppName
                if ($key -ne ([string]$c.AppName).Trim().ToLowerInvariant()) {
                    Write-Host ("         -> matches `"$key`" (all versions)") -ForegroundColor DarkGray
                }
            }

            Write-Host ""
            $confirm = Read-Host "Confirm? [y/N]"

            if ($confirm -match '^(y|yes)$') {
                $count = Add-BaselineEntry -Path $BaselineCsv -Apps $chosen -Serial $device.serialNumber
                if ($count -gt 0) {
                    Write-Host "  Added $count row(s). They will be filtered from the next run." -ForegroundColor Green
                } else {
                    Write-Host "  Nothing added." -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host "  Nothing added." -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
}

Write-Host "  Filtered out: $($excluded.Count) of $($classified.Count) inventoried applications." -ForegroundColor DarkGray

if ($ShowFiltered) {
    Write-Host ""
    Write-Host "  FILTERED" -ForegroundColor DarkGray
    $excluded | Sort-Object Reason, AppName |
        Format-Table @{ n = 'Application'; e = { $_.AppName }; width = 45 },
                     @{ n = 'Reason';      e = { $_.Reason } }
} else {
    Write-Host "  Re-run with -ShowFiltered to see them." -ForegroundColor DarkGray
}

Write-Host ""


# ------------------------------------------------------------------
#  Optional CSV
# ------------------------------------------------------------------
if ($OutputCsv) {
    $toInstall | Select-Object AppName, Version, Publisher, Installed, Path |
        Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Saved to $OutputCsv" -ForegroundColor Green
}


# ------------------------------------------------------------------
#  Optional printable sheet
# ------------------------------------------------------------------
if ($OutputPdf) {
    $html = New-InstallSheetHtml -Device $device -Apps $toInstall -ScanAge $scanAge `
                                 -SuppressedCount $excluded.Count -TotalCount $classified.Count
    $written = Export-InstallSheetPdf -Html $html -Path $OutputPdf
    if ($written) { Write-Host "Printable sheet saved to $written" -ForegroundColor Green }
}
