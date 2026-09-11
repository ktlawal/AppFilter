<#
.SYNOPSIS
    Checks the normalizers and the classifier against known cases.

.DESCRIPTION
    Lifts the pure functions out of Get-RefreshAppList.ps1 with the parser, so
    the script's own parameters and API calls are never invoked. Asserts the
    name and publisher shapes that turn up in Absolute's data, then classifies
    two real device inventories and checks each application lands in the bucket
    it landed in when a human looked at it.

.EXAMPLE
    .\Test-Normalization.ps1
#>

[CmdletBinding()]
param([string]$RulesCsv = "$PSScriptRoot\AppRules.csv")

$script = Join-Path $PSScriptRoot 'Get-RefreshAppList.ps1'
if (-not (Test-Path $script)) { throw "Cannot find Get-RefreshAppList.ps1 next to this test." }

$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors) {
    $errors | ForEach-Object { Write-Host -ForegroundColor Red "PARSE $($_.Extent.StartLineNumber): $($_.Message)" }
    throw "Get-RefreshAppList.ps1 does not parse."
}
foreach ($name in 'ConvertTo-NormalizedAppName', 'ConvertTo-NormalizedPublisher',
                  'Import-AppRule', 'Get-AppClassification',
                  'ConvertFrom-CredentialPayload') {
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)[0]
    if (-not $fn) { throw "Function $name not found in the script." }
    Invoke-Expression $fn.Extent.Text
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

Write-Host "`nKey file parsing" -ForegroundColor Cyan
function Assert-Payload {
    param($Text, $WantId, $Label)
    try { $got = ConvertFrom-CredentialPayload -Text $Text }
    catch {
        $script:failures++
        Write-Host -ForegroundColor Red "  FAIL  $Label threw: $($_.Exception.Message)"
        return
    }
    if ($got.TokenId -ceq $WantId) { Write-Host "  PASS  $Label" }
    else { $script:failures++; Write-Host -ForegroundColor Red "  FAIL  $Label gave '$($got.TokenId)'" }
}

$json = '{"tokenId":"a1c16ebf-1234","secretKey":"s3cr3t"}'
Assert-Payload $json 'a1c16ebf-1234' 'plain JSON'
Assert-Payload ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))) 'a1c16ebf-1234' 'base64 JSON'
Assert-Payload "  $json  `n" 'a1c16ebf-1234' 'JSON with surrounding whitespace'

foreach ($bad in @('', '   ', 'hello world', '{"tokenId":"only-an-id"}', '{"secretKey":"only-a-secret"}')) {
    try   { [void](ConvertFrom-CredentialPayload -Text $bad); $failures++; Write-Host -ForegroundColor Red "  FAIL  accepted '$bad'" }
    catch { Write-Host "  PASS  rejected '$(if($bad.Trim()){$bad}else{'<empty>'})'" }
}

Write-Host ""
if ($failures -eq 0) { Write-Host "All cases passed." -ForegroundColor Green }
else { Write-Host "$failures case(s) failed." -ForegroundColor Red; exit 1 }
