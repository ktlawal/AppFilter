<#
.SYNOPSIS
    Checks the normalizers and the classifier against known cases.

.DESCRIPTION
    Imports AppFilter.psm1 and exercises the pure functions in it. Nothing
    here touches the network: the API functions are never called. Asserts the
    name and publisher shapes that turn up in Absolute's data, then classifies
    two real device inventories and checks each application lands in the bucket
    it landed in when a human looked at it.

.EXAMPLE
    .\Test-AppFilter.ps1
#>

[CmdletBinding()]
param([string]$RulesCsv = "$PSScriptRoot\AppRules.csv")

$module = Join-Path $PSScriptRoot 'AppFilter.psm1'
if (-not (Test-Path $module)) { throw "Cannot find AppFilter.psm1 next to this test." }
Import-Module $module -Force -ErrorAction Stop

# Both front ends are only worth testing if they parse. Catch a syntax error
# here rather than when a technician runs one.
foreach ($front in 'Get-RefreshAppList.ps1', 'Start-RefreshAppServer.ps1') {
    $path = Join-Path $PSScriptRoot $front
    if (-not (Test-Path $path)) { throw "Cannot find $front next to this test." }
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        $errors | ForEach-Object { Write-Host -ForegroundColor Red "PARSE $front $($_.Extent.StartLineNumber): $($_.Message)" }
        throw "$front does not parse."
    }
}

$failures = 0
function Assert-Key {
    param($In, $Want, [scriptblock]$Fn, $Label)
    $got = & $Fn $In
    if ($got -ceq $Want) {
        Write-Host ("  PASS  {0,-52} -> '{1}'" -f "'$In'", $got)
    } else {
        $script:failures++
        Write-Host -ForegroundColor Red ("  FAIL  {0,-52} -> '{1}'  wanted '{2}'" -f "'$In'", $got, $Want)
    }
}

Write-Host "`nApplication names" -ForegroundColor Cyan
$appFn = { param($n) ConvertTo-NormalizedAppName $n }
# Version drift, architecture suffixes and trademark marks all collapse...
Assert-Key 'Tanium Client 7.8.1.3126'      'tanium client'      $appFn
Assert-Key 'Tanium Client 7.9.2.1'         'tanium client'      $appFn
Assert-Key '7-Zip 19.00 (x64 edition)'     '7-zip'              $appFn
Assert-Key '7-Zip 24.09 (x64)'             '7-zip'              $appFn
Assert-Key 'Node.js (64-bit)'              'node.js'            $appFn
Assert-Key 'Thunderbolt™ Software'         'thunderbolt software' $appFn
Assert-Key 'Intel® Optane™ Memory and Storage Management' 'intel optane memory and storage management' $appFn
Assert-Key 'Microsoft Visual C++ 2012 Redistributable (x64) - 11.0.61030' 'microsoft visual c++ 2012 redistributable' $appFn
Assert-Key '  Google   Chrome  '           'google chrome'      $appFn
# ...but a bare trailing integer is part of the name, not a version.
Assert-Key 'Microsoft 365'                 'microsoft 365'      $appFn
Assert-Key 'Paint 3D'                      'paint 3d'           $appFn
Assert-Key 'OneNote for Windows 10'        'onenote for windows 10' $appFn
Assert-Key 'Microsoft 365 Apps for enterprise - en-us' 'microsoft 365 apps for enterprise - en-us' $appFn
Assert-Key ''                              ''                   $appFn
Assert-Key $null                           ''                   $appFn

Write-Host "`nPublishers" -ForegroundColor Cyan
$pubFn = { param($n) ConvertTo-NormalizedPublisher $n }
# Every spelling of a vendor has to reach the same key or the driver rule leaks.
Assert-Key 'Dell'                          'dell'               $pubFn
Assert-Key 'Dell Inc.'                     'dell'               $pubFn
Assert-Key 'Dell Technologies'             'dell'               $pubFn
Assert-Key 'DELL TECHNOLOGIES INC.'        'dell'               $pubFn
Assert-Key 'Intel'                         'intel'              $pubFn
Assert-Key 'INTEL'                         'intel'              $pubFn
Assert-Key 'Intel Corporation'             'intel'              $pubFn
Assert-Key 'Realtek Semiconductor'         'realtek'            $pubFn
Assert-Key 'Realtek Semiconductor Corp.'   'realtek'            $pubFn
# Seen on a real refresh: 'Dell Products' was escaping the driver rule.
Assert-Key 'Dell Products'                 'dell'               $pubFn
Assert-Key 'Adobe Systems'                 'adobe'              $pubFn
Assert-Key 'Adobe Systems Incorporated'    'adobe'              $pubFn
# Suffixes only come off the end, so these keep their distinguishing words.
Assert-Key 'Advanced Micro Devices'        'advanced micro devices' $pubFn
Assert-Key 'Alps Electric Co., Ltd.'       'alps electric'      $pubFn
Assert-Key 'Zoom Communications'           'zoom communications' $pubFn
Assert-Key 'Igor Pavlov'                   'igor pavlov'        $pubFn
Assert-Key 'Microsoft'                     'microsoft'          $pubFn
Assert-Key ''                              ''                   $pubFn
Assert-Key $null                           ''                   $pubFn

Write-Host "`nRules file" -ForegroundColor Cyan
if (-not (Test-Path $RulesCsv)) {
    Write-Warning "Rules file not found at $RulesCsv - skipping the rest."
    exit 1
}
$rules = Import-AppRule -Path $RulesCsv
Write-Host ("  {0} name, {1} publisher, {2} pattern rules loaded." -f
            $rules.Names.Count, $rules.Publishers.Count, $rules.Patterns.Count)

$seen = @{}
foreach ($row in @(Import-Csv $RulesCsv | Where-Object { $_.MatchType -ne 'Publisher' -and $_.MatchType -ne 'Pattern' })) {
    $k = ConvertTo-NormalizedAppName $row.Rule
    if ($seen.ContainsKey($k)) {
        Write-Host ("  '{0}' and '{1}' both key to '{2}'" -f $row.Rule, $seen[$k], $k) -ForegroundColor DarkGray
    } else { $seen[$k] = $row.Rule }
}
Write-Host "  (x86/x64 pairs of one product are expected above.)" -ForegroundColor DarkGray

function Assert-Class {
    param($Name, $Publisher, $Want)
    $got = Get-AppClassification -Rules $rules -App ([pscustomobject]@{
        appName = $Name; appPublisher = $Publisher })
    $label = if ($null -eq $got) { 'INSTALL' } else { $got }
    if ($label -ceq $Want) {
        Write-Host ("  PASS  {0,-42} {1}" -f $Name, $label)
    } else {
        $script:failures++
        Write-Host -ForegroundColor Red ("  FAIL  {0,-42} {1}  wanted {2}" -f $Name, $label, $Want)
    }
}

# Both lists below are real device inventories, with the bucket a human
# confirmed for each. They are the regression net for any rules change.
Write-Host "`nClassification - device 4QXTTHR3" -ForegroundColor Cyan
Assert-Class 'Dell Digital Delivery'  'Dell Products'              'Driver / OEM'
Assert-Class 'OneDrive'               'Microsoft'                  'Base image'
Assert-Class 'Messaging'              'Microsoft'                  'Base image'
Assert-Class 'Mobile Plans'           'Microsoft'                  'Base image'
Assert-Class 'People'                 'Microsoft'                  'Base image'
Assert-Class 'MPEG-2 Video Extension' 'Microsoft'                  'Base image'
Assert-Class 'Notification Manager for Adobe Acrobat' 'Adobe Systems Incorporated' 'Runtime / component'
Assert-Class 'GoTo Opener'            'LogMeIn'                    'Runtime / component'
Assert-Class 'GoTo'                   'GoTo Group'                 'INSTALL'
Assert-Class 'GoToMeeting'            'LogMeIn'                    'INSTALL'
Assert-Class 'Power BI Desktop'       'Microsoft'                  'INSTALL'
Assert-Class 'Whiteboard'             'Microsoft'                  'INSTALL'

Write-Host "`nClassification - second device" -ForegroundColor Cyan
Assert-Class 'Cortana'                'Microsoft'                  'Base image'
Assert-Class 'MDOP MBAM'              'Microsoft'                  'Base image'
Assert-Class '7-Zip'                  'Igor Pavlov'                'INSTALL'
Assert-Class 'Avaya one-X Communicator' 'Avaya'                    'INSTALL'
Assert-Class 'Citrix Workspace'       'Citrix Systems'             'INSTALL'
Assert-Class 'Java'                   'Oracle'                     'INSTALL'
Assert-Class 'KeePass'                'Dominik Reichl'             'INSTALL'
Assert-Class 'Notepad++'              'Notepad++ Team'             'INSTALL'
Assert-Class 'Snagit'                 'TechSmith'                  'INSTALL'
Assert-Class 'Logi Options+'          'Logitech'                   'INSTALL'

Write-Host "`nClassification - version drift and vendor spellings" -ForegroundColor Cyan
Assert-Class 'Tanium Client 7.9.2.1'  'Tanium'                     'Base image'
Assert-Class 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.38.33130' 'Microsoft' 'Base image'
Assert-Class 'Intel(R) Wireless Bluetooth(R)' 'Intel Corporation'  'Driver / OEM'
Assert-Class 'Realtek High Definition Audio'  'Realtek Semiconductor Corp.' 'Driver / OEM'

Write-Host "`nAPI response envelope" -ForegroundColor Cyan
# A one-page result carries metadata with NO pagination property. Reading it
# as if it were always there is what broke the first real run after the module
# split, so every level is asserted here - no network needed.
#
# Note the @() around every Get-PageData call. PowerShell unrolls a
# single-element array on its way out of a function, and on Windows
# PowerShell 5.1 the resulting scalar has no .Count at all (7 gives it one).
# Without the wrapper this file passes on 7 and fails on 5.1.
function Assert-Envelope {
    param($Label, $Got, $Want)
    if ("$Got" -ceq "$Want") {
        Write-Host ("  PASS  {0,-52} -> '{1}'" -f $Label, $Got)
    } else {
        $script:failures++
        Write-Host -ForegroundColor Red ("  FAIL  {0,-52} -> '{1}'  wanted '{2}'" -f $Label, $Got, $Want)
    }
}

# The shape Absolute actually returns on a single page: metadata, no pagination.
$onePage = [pscustomobject]@{ data = @(1, 2, 3); metadata = [pscustomobject]@{ } }
Assert-Envelope 'one page: rows'        (@(Get-PageData $onePage)).Count      3
Assert-Envelope 'one page: next token'  (Get-NextPageToken $onePage)       ''

# Envelope with no metadata property at all.
$bare = [pscustomobject]@{ data = @(1) }
Assert-Envelope 'no metadata: rows'     (@(Get-PageData $bare)).Count         1
Assert-Envelope 'no metadata: next'     (Get-NextPageToken $bare)          ''

# metadata.pagination present but carrying no nextPage - the last page.
$lastPage = [pscustomobject]@{ data = @(1); metadata = [pscustomobject]@{ pagination = [pscustomobject]@{ } } }
Assert-Envelope 'last page: next'       (Get-NextPageToken $lastPage)      ''

# A real continuation token has to come back intact.
$more = [pscustomobject]@{ data = @(1); metadata = [pscustomobject]@{ pagination = [pscustomobject]@{ nextPage = 'AbC123==' } } }
Assert-Envelope 'more pages: next'      (Get-NextPageToken $more)          'AbC123=='

# An empty-string token means done, not "fetch page ''" forever.
$blank = [pscustomobject]@{ data = @(); metadata = [pscustomobject]@{ pagination = [pscustomobject]@{ nextPage = '' } } }
Assert-Envelope 'blank token: next'     (Get-NextPageToken $blank)         ''

# An empty page must stay empty. This is the one that matters: if `data = @()`
# falls through to "treat the envelope as a row", a serial that matches no
# device comes back as one nonsense device instead of a clean "not found".
$emptyPage = [pscustomobject]@{ data = @(); metadata = [pscustomobject]@{ } }
Assert-Envelope 'empty page: rows'      (@(Get-PageData $emptyPage)).Count    0

# An unwrapped response is its own single row.
Assert-Envelope 'unwrapped: rows'       (@(Get-PageData ([pscustomobject]@{ appName = 'x' }))).Count 1
Assert-Envelope 'null response: rows'   (@(Get-PageData $null)).Count         0

# Optional fields on a row are absent, not empty - an app with no scan date.
$row = [pscustomobject]@{ appName = 'Thing' }
Assert-Envelope 'missing field is null' (Get-DataProperty $row 'lastScanDateTimeUtc') ''
Assert-Envelope 'present field reads'   (Get-DataProperty $row 'appName')  'Thing'

Write-Host "`nHTML escaping" -ForegroundColor Cyan
# The server echoes a rejected serial back into value="...", so a bare quote
# there would end the attribute and let a crafted link inject script into a
# signed-in technician's page. Every one of these has to come back encoded.
$htmlFn = { param($n) ConvertTo-HtmlText $n }
Assert-Key '<script>'                      '&lt;script&gt;'     $htmlFn
Assert-Key '" autofocus onfocus="alert(1)' '&quot; autofocus onfocus=&quot;alert(1)' $htmlFn
Assert-Key "' onmouseover='x"              '&#39; onmouseover=&#39;x' $htmlFn
Assert-Key 'Tom & Jerry'                   'Tom &amp; Jerry'    $htmlFn
# Ampersand first, or the escapes get re-escaped into &amp;lt;.
Assert-Key '&lt;'                          '&amp;lt;'           $htmlFn
Assert-Key 'Realtek High Definition Audio' 'Realtek High Definition Audio' $htmlFn
Assert-Key ''                              ''                   $htmlFn

Write-Host "`nSuppressed list on the sheet" -ForegroundColor Cyan
# The collapsed list answers one question: the user says they had X and it is
# not on the sheet - was it filtered out, or was it never in the inventory? So
# it has to carry the name, the version and the reason it was filtered, and it
# must never reach the printer.
$shDevice = [pscustomobject]@{ deviceName = 'D'; serialNumber = 'S1'; username = 'u'
                               systemModel = 'm'; agentStatus = 'A' }
$shApps   = @([pscustomobject]@{ AppName = 'Bluebeam Revu'; Version = '21.0'; Publisher = 'Bluebeam' })
$shSupp   = @(
    [pscustomobject]@{ AppName = 'Google Chrome';      Version = '128.0.6613.120'; Publisher = 'Google';  Reason = 'Base image' }
    [pscustomobject]@{ AppName = 'Realtek Audio';      Version = '6.0.9564.1';     Publisher = 'Realtek'; Reason = 'Driver / OEM' }
    [pscustomobject]@{ AppName = 'No Version';         Version = '';               Publisher = 'x';       Reason = 'Base image' }
    [pscustomobject]@{ AppName = '<script>x</script>'; Version = '1"2';            Publisher = 'x';       Reason = 'Base image' }
)
$sheet = New-InstallSheetHtml -Device $shDevice -Apps $shApps -ScanAge 2 `
             -SuppressedCount $shSupp.Count -Suppressed $shSupp -TotalCount 5 `
             -HomeLink '/appfilter/' -DownloadLink '/appfilter/download?serial=ABC1234'

Assert-Envelope 'details, collapsed'    ($sheet -match '<details class="filtered screen-only">')  'True'
Assert-Envelope 'summary carries count' ($sheet -match 'Suppressed applications \(4\)')           'True'
# screen-only is the whole print story: the rule that hides it already exists.
Assert-Envelope 'print rule present'    ($sheet -match '\.screen-only \{ display: none !important; \}') 'True'
Assert-Envelope 'grouped: base image'   ($sheet -match '<h2>Base image <span>\(3\)</span></h2>')  'True'
Assert-Envelope 'grouped: driver'       ($sheet -match '<h2>Driver / OEM <span>\(1\)</span></h2>') 'True'
Assert-Envelope 'version rides along'   ($sheet -match '<li>Google Chrome <span class="v">128\.0\.6613\.120</span></li>') 'True'
# No version means a name and nothing else, not an empty span hanging off it.
Assert-Envelope 'no version, no span'   ($sheet -match '<li>No Version</li>')                     'True'
# Both fields come from the API, so both are escaped - the install table above
# is not the only place a crafted application name reaches the page.
Assert-Envelope 'name escaped'          ($sheet -match '<li>&lt;script&gt;x&lt;/script&gt;')      'True'
Assert-Envelope 'version escaped'       ($sheet -match 'class="v">1&quot;2</span>')               'True'
Assert-Envelope 'no raw script tag'     ($sheet -match '<script>')                                'False'

# Printing was withdrawn on cost grounds. The button and its inline handler are
# gone, which is also what let the server drop 'unsafe-hashes' from its CSP - so
# a window.print() creeping back in is a policy change, not a cosmetic one.
Assert-Envelope 'no print handler'      ($sheet -match 'window\.print')                            'False'
Assert-Envelope 'download link present' ($sheet -match '<a class="action" href="[^"]*download\?serial=ABC1234">Download</a>') 'True'
Assert-Envelope 'back link kept'        ($sheet -match 'look up another device')                   'True'
# A sheet saved to disk has no server to ask for a PDF, so it gets no toolbar.
$shNoTools = New-InstallSheetHtml -Device $shDevice -Apps $shApps -ScanAge 1 -SuppressedCount 0 -TotalCount 1
Assert-Envelope 'no links, no toolbar'  ($shNoTools -match 'class="toolbar')                       'False'

# The footer stated "1 of 0" on a real device: one application, suppressed, and
# a total of zero. A total below the parts it is made of cannot be true, so the
# sheet computes it rather than printing the caller's arithmetic.
$oneSupp = @([pscustomobject]@{ AppName = 'BitLocker Drive Encryption'; Version = '10.0.26100.9444'
                                Publisher = 'Microsoft'; Reason = 'Base image' })
$shOne = New-InstallSheetHtml -Device $shDevice -Apps @() -ScanAge 1 `
             -SuppressedCount 1 -Suppressed $oneSupp -TotalCount 0
Assert-Envelope 'total never below parts' ($shOne -match '0 to install &middot; 1 of 1 inventoried') 'True'
Assert-Envelope 'no "1 of 0"'             ($shOne -match '1 of 0')                                  'False'
# A caller that has the real total keeps it - the clamp is a floor, not a rewrite.
$shBig = New-InstallSheetHtml -Device $shDevice -Apps $shApps -ScanAge 1 `
             -SuppressedCount 4 -TotalCount 260
Assert-Envelope 'real total survives'     ($shBig -match '4 of 260 inventoried')                    'True'

# A caller that passes only the count still gets the sheet it always got.
$shPlain = New-InstallSheetHtml -Device $shDevice -Apps $shApps -ScanAge 2 `
               -SuppressedCount 4 -TotalCount 5
Assert-Envelope 'no list, no details'   ($shPlain -match '<details')                              'False'
Assert-Envelope 'footer count stands'   ($shPlain -match '4 of 5 inventoried applications')       'True'

Write-Host "`nDownloadable PDF" -ForegroundColor Cyan
# Written by hand, so the parts a reader will reject are worth asserting: the
# header, the terminator, a cross-reference table, and the page tree agreeing
# with the number of pages actually emitted. The content stream is left
# uncompressed, which is what makes the text greppable here.
$pdfBytes = New-InstallSheetPdf -Device $shDevice -Apps $shApps -ScanAge 2 `
                -SuppressedCount 4 -TotalCount 5
$pdfText  = [System.Text.Encoding]::GetEncoding(1252).GetString($pdfBytes)

Assert-Envelope 'returns bytes'         ($pdfBytes -is [byte[]])                       'True'
Assert-Envelope 'PDF header'            ($pdfText.StartsWith('%PDF-1.4'))              'True'
Assert-Envelope 'PDF terminator'        ($pdfText.TrimEnd().EndsWith('%%EOF'))         'True'
Assert-Envelope 'has xref'              ($pdfText -match "(?m)^xref$")                 'True'
Assert-Envelope 'has startxref'         ($pdfText -match "(?m)^startxref$")            'True'
Assert-Envelope 'A4 media box'          ($pdfText -match '/MediaBox \[0 0 595 842\]')  'True'
# The MediaBox is the one that catches a -f binding to half a concatenation.
Assert-Envelope 'no unformatted braces' ($pdfText -match '\{\d')                       'False'
Assert-Envelope 'one page'              ($pdfText -match '/Count 1')                   'True'
Assert-Envelope 'app name in stream'    ($pdfText -match 'Bluebeam Revu')              'True'
Assert-Envelope 'footer count'          ($pdfText -match '1 to install - 4 of 5')      'True'

# Every xref offset has to land on the object it claims, or a reader seeking by
# offset reads garbage. Check each one against the file itself.
$xrefOk = $true
$xrefAt = $pdfText.LastIndexOf('startxref')
$startAt = [int](($pdfText.Substring($xrefAt) -split "`n")[1].Trim())
$entries = @(($pdfText.Substring($startAt) -split "`n") | Where-Object { $_ -match '^\d{10} \d{5} n' })
for ($e = 0; $e -lt $entries.Count; $e++) {
    $off = [int]$entries[$e].Substring(0, 10)
    if (-not $pdfText.Substring($off).StartsWith("$($e + 1) 0 obj")) { $xrefOk = $false }
}
Assert-Envelope 'xref offsets land'     $xrefOk                                        'True'
Assert-Envelope 'xref entry count'      $entries.Count                                 6

# Long values are truncated rather than left to run into the next column.
$long = @([pscustomobject]@{ AppName = ('X' * 200); Version = '1.0'; Publisher = 'Y' })
$pdfLong = [System.Text.Encoding]::GetEncoding(1252).GetString(
               (New-InstallSheetPdf -Device $shDevice -Apps $long -ScanAge 1 -SuppressedCount 0 -TotalCount 1))
Assert-Envelope 'long name truncated'   ($pdfLong -match ('X{200}'))                   'False'
Assert-Envelope 'truncation marked'     ($pdfLong -match 'X+\.\.\.')                   'True'

# Parentheses and backslashes end a PDF string early if they are not escaped.
$tricky = @([pscustomobject]@{ AppName = 'Thing (x64) \ test'; Version = '1'; Publisher = 'p' })
$pdfTricky = [System.Text.Encoding]::GetEncoding(1252).GetString(
                 (New-InstallSheetPdf -Device $shDevice -Apps $tricky -ScanAge 1 -SuppressedCount 0 -TotalCount 1))
Assert-Envelope 'parens escaped'        ($pdfTricky -match 'Thing \\\(x64\\\)')        'True'
Assert-Envelope 'backslash escaped'     ($pdfTricky -match '\\\\ test')                'True'

# Sixty rows do not fit on one page, and the page tree has to say so.
$many = @(1..60 | ForEach-Object { [pscustomobject]@{ AppName = "App $_"; Version = "1.$_"; Publisher = 'v' } })
$pdfMany = [System.Text.Encoding]::GetEncoding(1252).GetString(
               (New-InstallSheetPdf -Device $shDevice -Apps $many -ScanAge 1 -SuppressedCount 0 -TotalCount 60))
Assert-Envelope 'paginates'             ($pdfMany -match '/Count 2')                   'True'
Assert-Envelope 'page numbering'        ($pdfMany -match 'Page 2 of 2')                'True'

# An empty install list is a real answer and still produces a valid sheet.
$pdfNone = [System.Text.Encoding]::GetEncoding(1252).GetString(
               (New-InstallSheetPdf -Device $shDevice -Apps @() -ScanAge $null -SuppressedCount 1 -TotalCount 0))
Assert-Envelope 'empty list renders'    ($pdfNone -match 'Nothing beyond the base image') 'True'
Assert-Envelope 'empty list total'      ($pdfNone -match '0 to install - 1 of 1')      'True'

Write-Host ""
if ($failures -eq 0) { Write-Host "All cases passed." -ForegroundColor Green }
else { Write-Host "$failures case(s) failed." -ForegroundColor Red; exit 1 }
