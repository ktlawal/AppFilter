<#
.SYNOPSIS
    Lists applications that need manual installation on a refreshed device.

.DESCRIPTION
    Pulls the installed application inventory for a device from Absolute,
    removes anything in the base image, suppresses drivers and runtimes,
    and reports what is left.

    The install list is numbered, and unless -NoPrompt is given you are asked
    whether any of it belongs in the base image. Anything you pick is appended
    to AppRules.csv with provenance, so the next refresh filters it.

    All suppression rules - base image names, driver publishers and runtime
    patterns - live in AppRules.csv, one row each. Adding a rule is a data
    edit, not a code edit.

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -ShowFiltered

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -NoPrompt -OutputCsv .\JLY4F42.csv

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42

    Every run leaves a printable tick-list in the current directory, named
    after the device - here .\JLY4F42-InstallList.html. Open it and click
    Print. Use -OutputHtml to put it somewhere else, or -NoSheet for console
    output only.
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

    # All three rule kinds live in one file - see Import-AppRule.
    [Alias('BaselineCsv')]
    [string]$RulesCsv = ".\AppRules.csv",
    [string]$OutputCsv,

    # Printable tick-list for the bench. Written to the current directory as
    # <serial>-InstallList.html unless a path is given here or -NoSheet is set.
    [string]$OutputHtml,

    [switch]$NoSheet,

    # Where the Absolute credential comes from. Auto tries the environment
    # first, then the local DPAPI file.
    [ValidateSet('Auto', 'Environment', 'Local')]
    [string]$CredentialSource = 'Auto'
)

# --- CONFIGURATION -------------------------------------------------
$BaseUrl   = "https://api.absolute.com"
$PageSize  = 500

# No credentials here, deliberately. They are loaded per-user at run time by
# Get-AbsoluteCredential below, from a DPAPI-protected file written once by
# Set-AbsoluteCredential.ps1. That keeps this file safe to sign, share,
# screen-share and commit.
$CredentialPath = $null   # override for testing; $null resolves to APPDATA
# -------------------------------------------------------------------


# Suppression rules are data, not code: see AppRules.csv. Adding a publisher
# or a pattern is a row in that file, not an edit here.


function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AbsoluteCredential {
    <#
        Resolves the token ID and secret for this run, trying each source in
        turn and reporting which one answered.

            Environment  ABSOLUTE_TOKEN_ID + ABSOLUTE_SECRET_KEY. The hook a
                         server, container or scheduled task uses.
            Local        The DPAPI file written by Set-AbsoluteCredential.ps1.
                         Decrypts only for the account and machine that wrote
                         it, so a copied file is inert.
    #>
    param(
        [string]$Path,
        [ValidateSet('Auto', 'Environment', 'Local')]
        [string]$Source = 'Auto'
    )

    $tried = [System.Collections.Generic.List[string]]::new()

    # --- environment ----------------------------------------------------
    if ($Source -in 'Auto', 'Environment') {
        if ($env:ABSOLUTE_TOKEN_ID -and $env:ABSOLUTE_SECRET_KEY) {
            return [pscustomobject]@{
                TokenId   = $env:ABSOLUTE_TOKEN_ID
                SecretKey = $env:ABSOLUTE_SECRET_KEY
                Source    = 'environment'
            }
        }
        $tried.Add('environment (ABSOLUTE_TOKEN_ID / ABSOLUTE_SECRET_KEY not set)')
    }

    # --- local DPAPI file ----------------------------------------------
    if ($Source -in 'Auto', 'Local') {

        if (-not $Path) {
            if (-not $env:APPDATA) {
                throw "No credential found, and APPDATA is not set so the local default location cannot be resolved. Tried: $($tried -join '; ')."
            }
            $Path = Join-Path $env:APPDATA 'AppFilter\absolute.cred.xml'
        }

        if (Test-Path $Path) {
            try {
                $cred = Import-Clixml -Path $Path -ErrorAction Stop
            }
            catch {
                # Two causes look the same from here: a file copied from another
                # machine or profile (DPAPI refuses it - which is the point), or a
                # corrupt file. Name both rather than asserting the wrong one.
                throw "Could not read the stored credential at $Path. If it was copied from another machine or user profile it cannot be decrypted here; it may also be corrupt. Re-run .\Set-AbsoluteCredential.ps1 on this machine. ($($_.Exception.Message))"
            }

            if ($cred -isnot [System.Management.Automation.PSCredential]) {
                throw "$Path is not a stored credential. Re-run .\Set-AbsoluteCredential.ps1."
            }

            return [pscustomobject]@{
                TokenId   = $cred.UserName
                SecretKey = $cred.GetNetworkCredential().Password
                Source    = $Path
            }
        }
        $tried.Add("local file ($Path not found)")
    }

    throw @"
No Absolute credential found. Tried: $($tried -join '; ').

Either store one on this machine:

    .\Set-AbsoluteCredential.ps1

or set ABSOLUTE_TOKEN_ID and ABSOLUTE_SECRET_KEY in the environment.
"@
}

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
            'Dell Products'                             -> 'dell'
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

    $suffix = '(incorporated|inc|corporation|corp|company|co|limited|ltd|llc|gmbh|technologies|technology|software|semiconductor|systems|electronics|group|holdings|products)'
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

function Import-AppRule {
    <#
        Loads AppRules.csv and buckets it by MatchType. One file, three kinds
        of rule:

            Name       exact match on the normalized application name
            Publisher  exact match on the normalized publisher
            Pattern    regex against the raw application name

        Rows with Active set to anything but Yes are ignored, which is how a
        rule gets retired without losing its history.

        The Reason column travels with the rule, so what a match is called is
        data too - but the ORDER the kinds are tried in stays in code, because
        that ordering is the classifier's meaning, not a preference.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Rules file not found: $Path"
    }

    $names      = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $publishers = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $patterns   = [System.Collections.Generic.List[object]]::new()
    $skipped    = 0

    foreach ($row in @(Import-Csv $Path)) {

        if (-not $row.Rule) { continue }
        if ($row.Active -and $row.Active.Trim() -notmatch '^(yes|true|1)$') { $skipped++; continue }

        $reason = if ($row.Reason) { $row.Reason.Trim() } else { 'Base image' }

        switch (($row.MatchType | ForEach-Object { "$_".Trim() })) {

            'Publisher' {
                $k = ConvertTo-NormalizedPublisher $row.Rule
                if ($k -and -not $publishers.ContainsKey($k)) { $publishers.Add($k, $reason) }
            }

            'Pattern' {
                # Validate here rather than letting a bad regex blow up mid-run
                # against a real device.
                try   { [void][regex]::new($row.Rule) }
                catch { Write-Warning "Skipping pattern rule '$($row.Rule)' - not a valid regex: $($_.Exception.Message)"; continue }
                $patterns.Add([pscustomobject]@{ Pattern = $row.Rule; Reason = $reason })
            }

            default {
                # Name, and anything unlabelled - a bare name is the common case
                $k = ConvertTo-NormalizedAppName $row.Rule
                if ($k -and -not $names.ContainsKey($k)) { $names.Add($k, $reason) }
            }
        }
    }

    Write-Verbose "Rules: $($names.Count) name, $($publishers.Count) publisher, $($patterns.Count) pattern; $skipped inactive."

    [pscustomobject]@{
        Names      = $names
        Publishers = $publishers
        Patterns   = $patterns
        Path       = $Path
    }
}

function Get-AppClassification {
    <#
        Returns the reason an application is suppressed, or $null if it is an
        install candidate.

        Three tests in a fixed order, first match wins. The rules are data; the
        order is not, because it is what the classifier means: a named product
        beats its vendor, and a vendor beats a generic pattern.
    #>
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)]$Rules
    )

    $matched = ''

    $nameKey = ConvertTo-NormalizedAppName ([string]$App.appName)
    if ($nameKey -and $Rules.Names.TryGetValue($nameKey, [ref]$matched)) { return $matched }

    $pubKey = ConvertTo-NormalizedPublisher ([string]$App.appPublisher)
    if ($pubKey -and $Rules.Publishers.TryGetValue($pubKey, [ref]$matched)) { return $matched }

    foreach ($rule in $Rules.Patterns) {
        if ($App.appName -match $rule.Pattern) { return $rule.Reason }
    }

    return $null
}

function Add-AppRule {
    <#
        Appends chosen applications to the rules file as Name rules, carrying
        provenance so a later reader can tell why a row is there. Rewrites the
        whole file to keep it sorted and single-shaped.

        Only Name rules are added from a run - a publisher or pattern rule is
        a broader decision than "this one app is base image", and belongs to
        someone editing the file deliberately.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Apps,
        [string]$Serial,
        [string]$Reason = 'Base image'
    )

    $existing = @(Import-Csv $Path)

    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $existing) {
        if ($row.MatchType -and $row.MatchType.Trim() -ne 'Name') { continue }
        $k = ConvertTo-NormalizedAppName $row.Rule
        if ($k) { [void]$keys.Add($k) }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    $added = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $Apps) {
        $k = ConvertTo-NormalizedAppName $app.AppName
        if (-not $k) { continue }
        if ($keys.Contains($k)) {
            Write-Warning "'$($app.AppName)' already matches a rule - skipped."
            continue
        }
        [void]$keys.Add($k)
        $added.Add([pscustomobject]@{
            Rule      = $app.AppName
            MatchType = 'Name'
            Reason    = $Reason
            Publisher = $app.Publisher
            Active    = 'Yes'
            Source    = 'refresh-prompt'
            AddedOn   = $stamp
            AddedBy   = $env:USERNAME
            Serial    = $Serial
        })
    }

    if ($added.Count -eq 0) { return 0 }

    # Name rules sorted for readability; Publisher and Pattern keep their
    # existing order, which for patterns is the order they are tried in.
    $order = @{ 'Name' = 0; 'Publisher' = 1; 'Pattern' = 2 }
    $all = @(@($existing) + @($added)) |
        Select-Object Rule, MatchType, Reason, Publisher, Active, Source, AddedOn, AddedBy, Serial |
        Sort-Object @{ e = { $order[[string]$_.MatchType] } },
                    @{ e = { if ($_.MatchType -eq 'Name') { ([string]$_.Rule).ToLowerInvariant() } else { '' } } }

    $all | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $added.Count
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
#  Load the rules
# ------------------------------------------------------------------
$rules = Import-AppRule -Path $RulesCsv


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

        Print button at the top calls window.print(); it and the rest of the
        screen-only furniture disappear under @media print, so what comes out
        of the printer is just the sheet.
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
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Applications to install - $(ConvertTo-HtmlText ([string]$Device.serialNumber))</title>
<style>
  @page { size: A4 portrait; margin: 14mm 12mm; }
  * { box-sizing: border-box; }
  body { font-family: Segoe UI, Calibri, Arial, sans-serif; font-size: 10.5pt;
         color: #000; background: #f4f4f5; margin: 0; padding: 8mm; }
  .sheet { max-width: 195mm; margin: 0 auto; background: #fff; padding: 10mm;
           box-shadow: 0 1px 4px rgba(0,0,0,.18); }
  h1 { font-size: 15pt; margin: 0 0 2mm; }
  .toolbar { max-width: 195mm; margin: 0 auto 4mm; display: flex; gap: 3mm;
             align-items: center; }
  button.print { font: inherit; font-weight: 600; padding: 2.5mm 6mm;
                 border: 1px solid #000; background: #000; color: #fff;
                 border-radius: 3px; cursor: pointer; }
  button.print:hover { background: #333; border-color: #333; }
  .hint { font-size: 9pt; color: #555; }
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

  /* What actually reaches the paper: the sheet, nothing else. */
  @media print {
    body { background: #fff; padding: 0; }
    .sheet { max-width: none; margin: 0; padding: 0; box-shadow: none; }
    .screen-only { display: none !important; }
  }
</style>
</head>
<body>
  <div class="toolbar screen-only">
    <button class="print" type="button" onclick="window.print()">Print this sheet</button>
    <span class="hint">or press Ctrl+P</span>
  </div>
  <div class="sheet">
    <h1>Applications to install</h1>
    <div class="meta">
      <div><span>Device</span>$(ConvertTo-HtmlText ([string]$Device.deviceName))</div>
      <div><span>Serial</span>$(ConvertTo-HtmlText ([string]$Device.serialNumber))</div>
      <div><span>User</span>$(ConvertTo-HtmlText ([string]$Device.username))</div>
      <div><span>Model</span>$(ConvertTo-HtmlText ([string]$Device.systemModel))</div>
      <div><span>Last software scan</span>$scanText</div>
      <div><span>Sheet generated</span>$(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
    </div>
$warningHtml    <table>
      <thead>
        <tr><th></th><th>Application</th><th>Version</th><th>Publisher</th><th>Notes</th></tr>
      </thead>
      <tbody>
$($rows -join "`n")
      </tbody>
    </table>
    <p class="foot">$($Apps.Count) to install &middot; $SuppressedCount of $TotalCount inventoried applications suppressed as base image, driver or runtime.</p>
  </div>
</body>
</html>
"@
}

function Save-InstallSheet {
    <#
        Writes the sheet next to wherever the tech is working. Returns the full
        path, or $null if it could not be written.
    #>
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not [IO.Path]::GetExtension($Path)) { $Path = "$Path.html" }

    # Resolve against the caller's location WITHOUT mangling an already-absolute
    # path - Join-Path would happily glue two roots together.
    #
    # The two-argument GetFullPath($path, $base) is .NET Core only, so it does
    # not exist in Windows PowerShell 5.1. Branch on IsPathRooted instead,
    # which works on both.
    $full = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
    }
    $dir  = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    try {
        Set-Content -Path $full -Value $Html -Encoding UTF8 -ErrorAction Stop
        return $full
    }
    catch {
        Write-Warning "Could not write the sheet to $full`: $($_.Exception.Message)"
        return $null
    }
}

# ------------------------------------------------------------------
#  Credentials
# ------------------------------------------------------------------
# Fail here, before the operator is asked to type anything.
$credential = Get-AbsoluteCredential -Path $CredentialPath -Source $CredentialSource
$TokenId    = $credential.TokenId
$SecretKey  = $credential.SecretKey
Write-Verbose "Credential loaded from $($credential.Source)."


# ------------------------------------------------------------------
#  Ask for a device if none was supplied
# ------------------------------------------------------------------
if (-not $Serial -and -not $DeviceName) {
    $Serial = (Read-Host "Serial number").Trim()
    if (-not $Serial) {
        Write-Host "No serial entered - nothing to do." -ForegroundColor Yellow
        exit 0
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
    exit 1
}


# ------------------------------------------------------------------
#  Classify
# ------------------------------------------------------------------
$classified = foreach ($a in $apps) {

    $reason = Get-AppClassification -App $a -Rules $rules

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
            Write-Host "  Adding to $RulesCsv :"
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
                $count = Add-AppRule -Path $RulesCsv -Apps $chosen -Serial $device.serialNumber
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
if (-not $NoSheet) {

    $sheetPath = $OutputHtml
    if (-not $sheetPath) {
        # Default to something predictable in the working directory, so a plain
        # run always leaves a sheet behind rather than only console output.
        $label = @([string]$device.serialNumber, [string]$device.deviceName, 'device' |
                   Where-Object { $_ -and $_.Trim() })[0].Trim()
        foreach ($bad in [IO.Path]::GetInvalidFileNameChars()) { $label = $label.Replace($bad, '_') }
        # Bare name, no ".\" prefix: it resolves against the working directory
        # either way, and stays a legal filename on non-Windows hosts.
        $sheetPath = "$label-InstallList.html"
    }

    $html = New-InstallSheetHtml -Device $device -Apps $toInstall -ScanAge $scanAge `
                                 -SuppressedCount $excluded.Count -TotalCount $classified.Count
    $written = Save-InstallSheet -Html $html -Path $sheetPath
    if ($written) {
        Write-Host "Printable sheet saved to $written" -ForegroundColor Green
        Write-Host "  Open it and click Print." -ForegroundColor DarkGray
    }
}

exit 0
