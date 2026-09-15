<#
.SYNOPSIS
    Reports what the account running it can actually do, into a file.

.DESCRIPTION
    Run this through the scheduled task, as NT AUTHORITY\SYSTEM, before
    pointing that task at the server. A task that exits 1 tells you nothing
    about why; this writes a report you can read afterwards.

    Everything is wrapped individually, so one failure does not hide the
    others, and nothing here needs a console.

    It never prints the API secret - only which source supplied it and how
    long it is.

.EXAMPLE
    .\Test-ServiceAccount.ps1

.EXAMPLE
    .\Test-ServiceAccount.ps1 -ReportPath C:\Temp\check.txt
#>

[CmdletBinding()]
param(
    [string]$ReportPath = "$PSScriptRoot\service-account-check.txt",
    [int]$Port = 5000,
    [string]$BasePath = '/appfilter/'
)

$lines = New-Object System.Collections.ArrayList

function Add-Line { param([string]$Text) [void]$lines.Add($Text) }

function Test-Step {
    param([string]$Name, [scriptblock]$Body)
    try {
        $result = & $Body
        Add-Line ("  PASS  {0,-34} {1}" -f $Name, $result)
    }
    catch {
        # Collapse the message onto one line - several of these span three
        # lines and would wreck the column the report is read in.
        $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + '...' }
        Add-Line ("  FAIL  {0,-34} {1}" -f $Name, $msg)
    }
}

Add-Line ("=" * 76)
Add-Line "  Service account check - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line ("=" * 76)
Add-Line ""

# ---- who and what -------------------------------------------------
Add-Line "  Identity and host"
Test-Step 'running as' { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
Test-Step 'PowerShell version' { $PSVersionTable.PSVersion.ToString() + '  (' + $PSVersionTable.PSEdition + ')' }
Test-Step 'execution policy' { (Get-ExecutionPolicy).ToString() }

# The one that would explain everything. Under ConstrainedLanguage the
# module's type calls - HttpListener, HMACSHA256 - are blocked outright,
# and they run before any of the server's own error handling.
Test-Step 'language mode' { $ExecutionContext.SessionState.LanguageMode.ToString() }

Test-Step 'script directory' { $PSScriptRoot }
Add-Line ""

# ---- can it write where it needs to -------------------------------
Add-Line "  File access"
Test-Step 'write to script directory' {
    $probe = Join-Path $PSScriptRoot 'write-probe.tmp'
    Set-Content -Path $probe -Value 'probe' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    'yes'
}
Test-Step 'read AppRules.csv' {
    $csv = Join-Path $PSScriptRoot 'AppRules.csv'
    "$((Import-Csv -Path $csv -ErrorAction Stop).Count) rows"
}
Add-Line ""

# ---- the module ---------------------------------------------------
Add-Line "  Module"
Test-Step 'import AppFilter.psm1' {
    Import-Module (Join-Path $PSScriptRoot 'AppFilter.psm1') -Force -ErrorAction Stop
    "$((Get-Command -Module AppFilter).Count) functions"
}
Test-Step 'load rules' {
    $r = Import-AppRule -Path (Join-Path $PSScriptRoot 'AppRules.csv')
    "$($r.Names.Count) name, $($r.Publishers.Count) publisher, $($r.Patterns.Count) pattern"
}
Test-Step 'resolve credential' {
    # Reads the same placeholders the server does. Never prints the secret.
    $server = Get-Content (Join-Path $PSScriptRoot 'Start-RefreshAppServer.ps1') -Raw
    $tok = ([regex]'\$TokenId\s*=\s*"([^"]*)"').Match($server).Groups[1].Value
    $key = ([regex]'\$SecretKey\s*=\s*"([^"]*)"').Match($server).Groups[1].Value
    $c = Get-AbsoluteCredential -TokenId $tok -SecretKey $key
    "from $($c.Source), secret is $(([string]$c.SecretKey).Length) characters"
}
Add-Line ""

# ---- the things constrained language would block -------------------
Add-Line "  Type access"
Test-Step 'construct HttpListener' {
    $l = [System.Net.HttpListener]::new()
    $l.Close()
    'yes'
}
Test-Step 'construct HMACSHA256' {
    $h = [System.Security.Cryptography.HMACSHA256]::new()
    $h.Dispose()
    'yes'
}
Add-Line ""

# ---- http.sys -----------------------------------------------------
Add-Line "  http.sys"
Test-Step 'https reservation' {
    $out = & netsh http show urlacl url=https://+:${Port}${BasePath} 2>&1 | Out-String
    if ($out -match 'Reserved URL') { ($out -split "`n" | Where-Object { $_ -match 'User:' } | Select-Object -First 1).Trim() }
    else { 'NOT RESERVED' }
}
Test-Step 'any reservation on this port' {
    $out = & netsh http show urlacl 2>&1 | Out-String
    $hits = @($out -split "`n" | Where-Object { $_ -match ":$Port/" })
    if ($hits.Count -eq 0) { 'none' } else { ($hits | ForEach-Object { $_.Trim() }) -join ' ; ' }
}
Test-Step 'certificate binding' {
    $out = & netsh http show sslcert ipport=0.0.0.0:$Port 2>&1 | Out-String
    if ($out -match 'Certificate Hash\s*:\s*(\S+)') { "bound, hash $($Matches[1])" } else { 'NOT BOUND' }
}
Test-Step 'port currently listening' {
    $c = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($c.Count -eq 0) { 'free' }
    else { ($c | ForEach-Object { "held by pid $($_.OwningProcess)" }) -join ', ' }
}
Add-Line ""
Add-Line ("=" * 76)

# Write the report last, in one go, so a partial failure still leaves a file.
try {
    Set-Content -Path $ReportPath -Value $lines -Encoding UTF8 -ErrorAction Stop
}
catch {
    # If even this fails, fall back somewhere SYSTEM can always write.
    Set-Content -Path "$env:windir\Temp\service-account-check.txt" -Value $lines -Encoding UTF8
}

# Console too, for when it is run by hand.
$lines | ForEach-Object { Write-Host $_ }
