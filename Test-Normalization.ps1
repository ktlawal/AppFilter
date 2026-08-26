<#
.SYNOPSIS
    Checks the two normalizers in Get-RefreshAppList.ps1 against known cases.

.DESCRIPTION
    Lifts ConvertTo-NormalizedAppName and ConvertTo-NormalizedPublisher out of
    the main script with the parser, so the script's own parameters and API
    calls are never invoked, and asserts the shapes that actually turn up in
    Absolute's data. Also reports baseline rows that collapse to the same key.

.EXAMPLE
    .\Test-Normalization.ps1
#>

[CmdletBinding()]
param([string]$BaselineCsv = "$PSScriptRoot\BaseImageApps.csv")

$script = Join-Path $PSScriptRoot 'Get-RefreshAppList.ps1'
if (-not (Test-Path $script)) { throw "Cannot find Get-RefreshAppList.ps1 next to this test." }

$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors) {
    $errors | ForEach-Object { Write-Host -ForegroundColor Red "PARSE $($_.Extent.StartLineNumber): $($_.Message)" }
    throw "Get-RefreshAppList.ps1 does not parse."
}
foreach ($name in 'ConvertTo-NormalizedAppName', 'ConvertTo-NormalizedPublisher') {
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
# Suffixes only come off the end, so these keep their distinguishing words.
Assert-Key 'Advanced Micro Devices'        'advanced micro devices' $pubFn
Assert-Key 'Alps Electric Co., Ltd.'       'alps electric'      $pubFn
Assert-Key 'Zoom Communications'           'zoom communications' $pubFn
Assert-Key 'Igor Pavlov'                   'igor pavlov'        $pubFn
Assert-Key 'Microsoft'                     'microsoft'          $pubFn
Assert-Key ''                              ''                   $pubFn
Assert-Key $null                           ''                   $pubFn

Write-Host "`nBaseline collisions" -ForegroundColor Cyan
if (Test-Path $BaselineCsv) {
    $seen = @{}
    $rows = @(Import-Csv $BaselineCsv)
    foreach ($row in $rows) {
        $k = ConvertTo-NormalizedAppName $row.AppName
        if ($seen.ContainsKey($k)) {
            Write-Host ("  '{0}' and '{1}' both key to '{2}'" -f $row.AppName, $seen[$k], $k) -ForegroundColor DarkGray
        } else { $seen[$k] = $row.AppName }
    }
    Write-Host ("  {0} rows, {1} distinct keys." -f $rows.Count, $seen.Count)
    Write-Host "  (x86/x64 pairs of one product are expected here.)" -ForegroundColor DarkGray
} else {
    Write-Warning "Baseline not found at $BaselineCsv - skipped."
}

Write-Host ""
if ($failures -eq 0) { Write-Host "All normalization cases passed." -ForegroundColor Green }
else { Write-Host "$failures case(s) failed." -ForegroundColor Red; exit 1 }
