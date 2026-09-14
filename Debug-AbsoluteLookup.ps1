<#
.SYNOPSIS
    Shows what Absolute actually returns for a serial, and for no serial.

.DESCRIPTION
    Run this when Get-RefreshAppList.ps1 says "No device matched that
    identifier" for a device you know exists. It separates the three things
    that produce that message and look identical from the outside:

      1. the credential is for a different tenant, or a stale environment
         variable is being used instead of the one in the script
      2. the token cannot read devices at all
      3. the token is fine and the serial genuinely is not there

    It prints the raw response shape, so it also shows whether this module's
    assumptions about `data` and `metadata` match your tenant.

    Nothing is written anywhere. The secret is never printed.

.EXAMPLE
    .\Debug-AbsoluteLookup.ps1 4QXTTHR3
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Serial = '4QXTTHR3'
)

# Paste the same values you put in Get-RefreshAppList.ps1, or leave them and
# the environment variables are used - which is one of the things being tested.
$TokenId   = "TOKEN HERE"
$SecretKey = "KEY HERE"
$BaseUrl   = "https://api.absolute.com"

Import-Module (Join-Path $PSScriptRoot 'AppFilter.psm1') -Force -ErrorAction Stop

function Show-Shape {
    param($Response, [string]$Label)

    Write-Host ""
    Write-Host "  $Label" -ForegroundColor Cyan

    if ($null -eq $Response) {
        Write-Host "    response is null" -ForegroundColor Red
        return
    }

    $names = @($Response.PSObject.Properties | ForEach-Object { $_.Name })
    Write-Host "    top-level properties : $($names -join ', ')"

    $rows = @(Get-PageData $Response)
    Write-Host "    rows via Get-PageData: $($rows.Count)"

    $hasData = $null -ne $Response.PSObject.Properties['data']
    Write-Host "    has a 'data' property: $hasData"

    $next = Get-NextPageToken $Response
    if ($next) { Write-Host "    next page token      : present" }
    else       { Write-Host "    next page token      : none (single page)" }

    if ($rows.Count -gt 0) {
        $first = $rows[0]
        $fields = @($first.PSObject.Properties | ForEach-Object { $_.Name })
        Write-Host "    first row fields     : $(($fields | Select-Object -First 12) -join ', ')"
    }
    return $rows
}

Write-Host ""
Write-Host ("=" * 70)
Write-Host "  Absolute lookup diagnostic"
Write-Host ("=" * 70)

Write-Host ""
Write-Host "  PowerShell    $($PSVersionTable.PSVersion)  ($($PSVersionTable.PSEdition))"

$credential = Get-AbsoluteCredential -TokenId $TokenId -SecretKey $SecretKey

# Which credential answered matters more than it looks: a valid token for the
# wrong tenant authenticates cleanly and then matches no devices at all.
$id = [string]$credential.TokenId
$shown = $id
if ($id.Length -gt 8) { $shown = $id.Substring(0, 4) + '...' + $id.Substring($id.Length - 4) }
Write-Host "  Credential    from $($credential.Source), token id $shown"
# The parentheses matter: $(...).Length ends the subexpression first and
# prints the secret itself. Only ever report its length.
$secretLength = ([string]$credential.SecretKey).Length
Write-Host "  Secret        $secretLength characters" -ForegroundColor DarkGray

if ($credential.Source -eq 'environment') {
    Write-Warning "Using ABSOLUTE_TOKEN_ID / ABSOLUTE_SECRET_KEY from the environment, not the values in this file."
    Write-Warning "If those are left over from earlier testing they may point at a different account."
}

$api = @{ TokenId = $credential.TokenId; SecretKey = $credential.SecretKey; BaseUrl = $BaseUrl }

# --- 1. can this token see any devices at all? ---------------------
Write-Host ""
Write-Host "  [1] Asking for the first 5 devices, no filter" -ForegroundColor Yellow
try {
    $any = Invoke-AbsoluteApi -Uri '/v3/reporting/devices' -QueryString 'pageSize=5' @api
    $anyRows = Show-Shape -Response $any -Label 'unfiltered device query'

    if (@($anyRows).Count -eq 0) {
        Write-Host ""
        Write-Host "  The token authenticated but sees no devices." -ForegroundColor Red
        Write-Host "  That is a permissions or tenant problem, not this script." -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "    serials visible to this token:" -ForegroundColor DarkGray
        foreach ($d in @($anyRows)) {
            Write-Host ("      {0,-20} {1}" -f [string]$d.serialNumber, [string]$d.deviceName) -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Host "    unfiltered query failed: $($_.Exception.Message)" -ForegroundColor Red
}

# --- 2. the serial that is failing ---------------------------------
Write-Host ""
Write-Host "  [2] Asking for serialNumber=$Serial" -ForegroundColor Yellow
try {
    $qs  = "serialNumber=$([uri]::EscapeDataString($Serial))&pageSize=500"
    $one = Invoke-AbsoluteApi -Uri '/v3/reporting/devices' -QueryString $qs @api
    $oneRows = Show-Shape -Response $one -Label "serialNumber=$Serial"

    Write-Host ""
    if (@($oneRows).Count -gt 0) {
        Write-Host "  The API returns this device. If Get-RefreshAppList still says" -ForegroundColor Green
        Write-Host "  'no device matched', the fault is in this module - send me the above." -ForegroundColor Green
    } else {
        Write-Host "  The API itself returns nothing for that serial." -ForegroundColor Yellow
        Write-Host "  Try one of the serials listed in [1] to confirm the tool works," -ForegroundColor Yellow
        Write-Host "  then check whether this device was removed from Absolute." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "    serial query failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
