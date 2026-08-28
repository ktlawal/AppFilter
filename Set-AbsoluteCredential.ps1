<#
.SYNOPSIS
    One-time setup: stores your Absolute API credentials for this Windows user.

.DESCRIPTION
    Saves the token ID and secret under your profile, with the secret encrypted
    by DPAPI. The file is bound to this Windows account on this machine -
    copied to another machine, another user, or a USB stick, it is unusable.

    Run once per person per machine. Re-run to replace what is stored.

.EXAMPLE
    .\Set-AbsoluteCredential.ps1

.EXAMPLE
    .\Set-AbsoluteCredential.ps1 -Remove
#>

[CmdletBinding()]
param(
    # Resolved after the platform check below - $env:APPDATA does not exist
    # everywhere, and evaluating it in a parameter default would throw before
    # the clearer error had a chance to fire.
    [string]$Path,

    # Delete the stored credential
    [switch]$Remove
)

# $IsWindows only exists in PowerShell 6+; Windows PowerShell 5.1 is Windows
# by definition, so treat "undefined" as Windows.
$onWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

if (-not $onWindows) {
    # DPAPI is a Windows facility. Elsewhere PowerShell still writes the file,
    # but the "encrypted" password is only UTF-16 hex of the plaintext - any
    # local user recovers it with one Import-Clixml. Refuse rather than hand
    # back a credential file that looks protected and is not.
    throw "Credentials are protected with Windows DPAPI, which is not available here. Refusing to write an unprotected credential file."
}

if (-not $Path) {
    if (-not $env:APPDATA) { throw "APPDATA is not set, so the default credential location cannot be resolved. Pass -Path explicitly." }
    $Path = Join-Path $env:APPDATA 'AppFilter\absolute.cred.xml'
}

if ($Remove) {
    if (Test-Path $Path) {
        Remove-Item $Path -Force
        Write-Host "Removed $Path" -ForegroundColor Green
    } else {
        Write-Host "Nothing stored at $Path" -ForegroundColor DarkGray
    }
    exit 0
}

Write-Host ""
Write-Host "Absolute API credential setup"
Write-Host ("Stored for {0} on {1} only. Nobody else can read it, on this machine or any other." -f $env:USERNAME, $env:COMPUTERNAME) -ForegroundColor DarkGray
Write-Host ""

$tokenId = (Read-Host "Token ID").Trim()
if (-not $tokenId) {
    Write-Host "No token ID entered - nothing saved." -ForegroundColor Yellow
    exit 1
}

$secret = Read-Host "Secret key" -AsSecureString
if (-not $secret -or $secret.Length -eq 0) {
    Write-Host "No secret entered - nothing saved." -ForegroundColor Yellow
    exit 1
}

$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# A PSCredential is the idiomatic carrier: Export-Clixml DPAPI-encrypts the
# password half and leaves the token ID readable, which is fine - the ID alone
# is useless without the secret.
[pscredential]::new($tokenId, $secret) | Export-Clixml -Path $Path

Write-Host ""
Write-Host "Saved to $Path" -ForegroundColor Green
Write-Host "Verify it works:  .\Get-RefreshAppList.ps1 <serial>" -ForegroundColor DarkGray
Write-Host ""
exit 0
