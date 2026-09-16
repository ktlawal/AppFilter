<#
    AppFilter.psm1 - the engine behind the refresh application list.

    Everything that decides what a technician has to install lives here, so the
    front ends stay thin and there is exactly one copy of the logic. Today that
    is two front ends:

        Get-RefreshAppList.ps1     one serial at a console
        Start-RefreshAppServer.ps1 a small web page on an always-on machine

    The rule of the split: nothing in here writes to the console or reads from
    it. Prompts, colours and tables belong to whoever is driving.
#>

# NO Set-StrictMode HERE, AND DO NOT ADD ONE. It was tried and it broke the
# tool on the first real run: under StrictMode, reading a property that does
# not exist is a terminating error, and this module reads a JSON API whose
# fields come and go. Absolute's envelope carries `metadata` with no
# `pagination` until there actually is a next page, so a one-page result -
# every normal result - died on `$response.metadata.pagination`. The same
# applies to `lastScanDateTimeUtc` on an app row and every optional device
# field. Missing-property-is-null is load-bearing here. Read optional fields
# through Get-DataProperty below rather than reaching for StrictMode.

function Get-DataProperty {
    <#
        Reads a property off an object parsed from JSON, returning $null when
        it is absent rather than assuming the shape. Use this for anything
        that came off the wire.
    #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
# Note: this is for scalar fields. PowerShell collapses an empty array on the
# way out of a function, so a field holding @() comes back as $null and you
# cannot tell it from an absent one. Where that distinction matters - it does
# for `data` - test PSObject.Properties directly, as Get-PageData does.

function Get-PageData {
    <# The rows out of one response, whether or not it is wrapped in `data`. #>
    param($Response)
    if ($null -eq $Response) { return @() }
    # Presence of the property decides, not its contents: a `data` of @() is a
    # real empty page and must stay empty. Going by the value instead made a
    # device lookup that matched nothing hand back the envelope as if it were
    # a device.
    $prop = $Response.PSObject.Properties['data']
    if ($null -ne $prop) { return @($prop.Value) }
    return @($Response)
}

function Get-NextPageToken {
    <#
        The continuation token, or $null on the last page. It is nested two
        levels down and every level is optional - see the note above.
    #>
    param($Response)
    $metadata   = Get-DataProperty $Response   'metadata'
    $pagination = Get-DataProperty $metadata   'pagination'
    $next       = Get-DataProperty $pagination 'nextPage'
    if ($next -is [string] -and $next.Trim() -eq '') { return $null }
    return $next
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AbsoluteCredential {
    <#
        Returns the token ID and secret for this run.

        The values at the top of this file win when they have been filled in.
        A recipient's leftover environment variables should not quietly take
        over from the copy the distributor intended them to use.

        Environment variables are the fallback, so a server or scheduled task
        can supply the key without this file carrying it.
    #>
    param([string]$TokenId, [string]$SecretKey)

    $placeholder = @('TOKEN HERE', 'KEY HERE')

    if ($TokenId -and $SecretKey -and
        $TokenId   -notin $placeholder -and
        $SecretKey -notin $placeholder) {
        return [pscustomobject]@{
            TokenId   = $TokenId.Trim()
            SecretKey = $SecretKey.Trim()
            Source    = 'script'
        }
    }

    if ($env:ABSOLUTE_TOKEN_ID -and $env:ABSOLUTE_SECRET_KEY) {
        return [pscustomobject]@{
            TokenId   = $env:ABSOLUTE_TOKEN_ID
            SecretKey = $env:ABSOLUTE_SECRET_KEY
            Source    = 'environment'
        }
    }

    throw @"
No Absolute credential found.

Either fill in the two values at the top of this script:

    `$TokenId   = "..."
    `$SecretKey = "..."

or set them in the environment instead:

    `$env:ABSOLUTE_TOKEN_ID   = '<token id>'
    `$env:ABSOLUTE_SECRET_KEY = '<secret>'
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

function ConvertTo-CsvSafeText {
    <#
        Neutralises a value that a spreadsheet would treat as a formula.

        Application names come from the API - which is to say, from software
        installed on managed devices - and a name beginning = + - or @ runs as
        a formula the moment someone opens AppRules.csv in Excel. Prefixing an
        apostrophe is the standard defence.

        Paired with ConvertFrom-CsvSafeText, which takes it back off on read,
        so the stored rule still matches the application it came from. Escaping
        without that pairing would silently break every rule it touched.
    #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    if ($Text -match '^[=+@\-\t\r]') { return "'" + $Text }
    return $Text
}

function ConvertFrom-CsvSafeText {
    <# Reverses ConvertTo-CsvSafeText. Only strips an apostrophe that is
       actually guarding a formula character, so a rule legitimately beginning
       with one is left alone. #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    if ($Text -match "^'[=+@\-\t\r]") { return $Text.Substring(1) }
    return $Text
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

        # Undo the spreadsheet guard before the value is used for matching.
        $row.Rule = ConvertFrom-CsvSafeText $row.Rule
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
            Rule      = ConvertTo-CsvSafeText $app.AppName
            MatchType = 'Name'
            Reason    = $Reason
            Publisher = ConvertTo-CsvSafeText $app.Publisher
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
        [Parameter(Mandatory)][string]$TokenId,
        [Parameter(Mandatory)][string]$SecretKey,
        [string]$BaseUrl     = 'https://api.absolute.com',
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
        [Parameter(Mandatory)][string]$TokenId,
        [Parameter(Mandatory)][string]$SecretKey,
        [string]$BaseUrl  = 'https://api.absolute.com',
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

        $response = Invoke-AbsoluteApi -Uri $Uri -QueryString ($parts -join '&') `
                        -TokenId $TokenId -SecretKey $SecretKey -BaseUrl $BaseUrl

        foreach ($item in (Get-PageData $response)) {
            if ($null -ne $item) { $results.Add($item) }
        }

        $next = Get-NextPageToken $response

        $guard++
        if ($guard -gt 500) { Write-Warning "Pagination guard tripped."; break }

    } while ($next)

    return $results
}

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # Quotes matter as much as angle brackets: the server puts a serial the
    # operator typed into value="..." and a link into href="...", so a bare
    # double quote would end the attribute and start a new one.
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').
          Replace('"', '&quot;').Replace("'", '&#39;')
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
        [int]$TotalCount,

        # When the sheet is served from a web front end rather than saved to
        # disk, this puts a "new lookup" link in the toolbar. Screen only.
        [string]$HomeLink
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

    $homeHtml = ''
    if ($HomeLink) {
        $homeHtml = "    <a class=`"hint`" href=`"$(ConvertTo-HtmlText $HomeLink)`">&larr; look up another device</a>`n"
    }

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
$homeHtml  </div>
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

function Get-RefreshApps {
    <#
        The whole pipeline for one device: look it up, pull its application
        inventory, classify every row, and hand back a result object.

        Returns $null-free output whatever happens - callers check .Found and
        .Apps.Count rather than trapping. A device that exists but has no
        inventory is a real outcome, not an error: it usually means the agent
        is disabled or has not checked in.
    #>
    param(
        [string]$Serial,
        [string]$DeviceName,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$Credential,
        [string]$BaseUrl  = 'https://api.absolute.com',
        [int]$PageSize    = 500
    )

    if (-not $Serial -and -not $DeviceName) {
        throw "Get-RefreshApps needs a serial number or a device name."
    }

    $api = @{
        TokenId   = $Credential.TokenId
        SecretKey = $Credential.SecretKey
        BaseUrl   = $BaseUrl
        PageSize  = $PageSize
    }

    $query = @{}
    if ($Serial)     { $query['serialNumber'] = $Serial }
    if ($DeviceName) { $query['deviceName']   = $DeviceName }

    $devices = @(Get-AbsoluteV3 -Uri '/v3/reporting/devices' -Query $query @api)

    if ($devices.Count -eq 0) {
        return [pscustomobject]@{
            Found = $false; Device = $null; Apps = @(); ToInstall = @()
            Excluded = @(); ScanAge = $null; Matched = 0
            Message = "No device matched that identifier."
        }
    }

    if ($devices.Count -gt 1) {
        $devices = @($devices | Sort-Object lastConnectedDateTimeUtc -Descending)
    }
    $device = $devices[0]

    $apps = @(Get-AbsoluteV3 -Uri '/v3/reporting/applications' `
                             -Query @{ deviceUid = $device.deviceUid } @api)

    # Defend against the filter being ignored server-side
    $apps = @($apps | Where-Object { [string]$_.deviceUid -eq [string]$device.deviceUid })

    if ($apps.Count -eq 0) {
        return [pscustomobject]@{
            Found = $true; Device = $device; Apps = @(); ToInstall = @()
            Excluded = @(); ScanAge = $null; Matched = $devices.Count
            Message = "No application inventory returned. Agent status is '$($device.agentStatus)' - if the agent is disabled or has not checked in, the inventory may be missing."
        }
    }

    $classified = foreach ($a in $apps) {
        $reason = Get-AppClassification -App $a -Rules $Rules
        [pscustomobject]@{
            AppName   = $a.appName
            Version   = $a.appVersion
            Publisher = $a.appPublisher
            Installed = $a.installDateTimeUtc
            Path      = $a.installPath
            Excluded  = [bool]$reason
            Reason    = $reason
        }
    }

    $toInstall = @($classified | Where-Object { -not $_.Excluded } | Sort-Object AppName)
    for ($i = 0; $i -lt $toInstall.Count; $i++) {
        $toInstall[$i] | Add-Member -NotePropertyName Index -NotePropertyValue ($i + 1) -Force
    }

    $scanAge = $null
    $scanned = @($apps | Where-Object { $_.lastScanDateTimeUtc } |
                 Sort-Object lastScanDateTimeUtc -Descending)
    if ($scanned.Count -gt 0) {
        $scanAge = [int]((Get-Date) - [datetime]$scanned[0].lastScanDateTimeUtc).TotalDays
    }

    [pscustomobject]@{
        Found     = $true
        Device    = $device
        Apps      = $classified
        ToInstall = $toInstall
        Excluded  = @($classified | Where-Object { $_.Excluded })
        ScanAge   = $scanAge
        Matched   = $devices.Count
        Message   = $null
    }
}

Export-ModuleMember -Function ConvertTo-NormalizedAppName, ConvertTo-NormalizedPublisher,
                              Import-AppRule, Get-AppClassification, Add-AppRule,
                              Get-AbsoluteCredential, Invoke-AbsoluteApi, Get-AbsoluteV3,
                              Get-RefreshApps, New-InstallSheetHtml, ConvertTo-HtmlText,
                              Save-InstallSheet, Read-IndexSelection, ConvertTo-Base64Url,
                              Get-DataProperty, Get-PageData, Get-NextPageToken,
                              ConvertTo-CsvSafeText, ConvertFrom-CsvSafeText
