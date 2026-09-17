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

    The classifier itself lives in AppFilter.psm1, shared with
    Start-RefreshAppServer.ps1. This file is only the console front end.

.EXAMPLE
    .\Get-RefreshAppList.ps1 JLY4F42

.EXAMPLE
    .\Get-RefreshAppList.ps1 JLY4F42 -ShowFiltered

.EXAMPLE
    .\Get-RefreshAppList.ps1 JLY4F42 -NoPrompt -OutputCsv .\JLY4F42.csv

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

    # Skip the "add these to the base image?" prompt and never touch the CSV
    [switch]$NoPrompt,

    [Alias('BaselineCsv')]
    [string]$RulesCsv = "$PSScriptRoot\AppRules.csv",
    [string]$OutputCsv,

    # Printable tick-list for the bench. Written to the current directory as
    # <serial>-InstallList.html unless a path is given here or -NoSheet is set.
    [string]$OutputHtml,

    [switch]$NoSheet
)

# --- CONFIGURATION -------------------------------------------------
#
#  >> THIS FILE CONTAINS THE ABSOLUTE API KEY. <<
#
#  Anyone who has this file has the key, and it works from any internet
#  connection unless the token is restricted to approved IP addresses in the
#  Absolute console. Do not screen-share it, attach it to a ticket, or commit
#  it anywhere. Rotating the key means redistributing this file to everyone.
#
#  Leave these as-is and the script falls back to the ABSOLUTE_TOKEN_ID and
#  ABSOLUTE_SECRET_KEY environment variables instead.
#
$TokenId   = "TOKEN HERE"
$SecretKey = "KEY HERE"

$BaseUrl   = "https://api.absolute.com"
$PageSize  = 500
# -------------------------------------------------------------------

Import-Module (Join-Path $PSScriptRoot 'AppFilter.psm1') -Force -ErrorAction Stop


# ------------------------------------------------------------------
#  Rules and credentials, before the operator is asked to type anything
# ------------------------------------------------------------------
$rules      = Import-AppRule -Path $RulesCsv
$credential = Get-AbsoluteCredential -TokenId $TokenId -SecretKey $SecretKey
Write-Verbose "Credential loaded from $($credential.Source)."

if (-not $Serial -and -not $DeviceName) {
    $Serial = (Read-Host "Serial number").Trim()
    if (-not $Serial) {
        Write-Host "No serial entered - nothing to do." -ForegroundColor Yellow
        exit 0
    }
}
if ($Serial) { $Serial = $Serial.Trim() }


# ------------------------------------------------------------------
#  Do the work
# ------------------------------------------------------------------
Write-Host "Looking up device..." -ForegroundColor Cyan

$result = Get-RefreshApps -Serial $Serial -DeviceName $DeviceName `
                          -Rules $rules -Credential $credential `
                          -BaseUrl $BaseUrl -PageSize $PageSize

if (-not $result.Found) { throw $result.Message }
if ($result.Matched -gt 1) {
    Write-Warning "$($result.Matched) devices matched - using the most recently connected."
}

$device    = $result.Device
$toInstall = $result.ToInstall
$excluded  = $result.Excluded
$scanAge   = $result.ScanAge

if ($result.Apps.Count -eq 0) {
    Write-Warning $result.Message
    exit 1
}


# ------------------------------------------------------------------
#  Report
# ------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 70)
Write-Host "  $($device.deviceName)   [$($device.serialNumber)]"
Write-Host "  User: $($device.username)"
Write-Host "  Agent status: $($device.agentStatus)   Last software scan: $scanAge day(s) ago"
Write-Host ("=" * 70)

if ($device.agentStatus -ne 'A') {
    Write-Warning "Agent is not active - this inventory may be out of date."
}
if ($null -ne $scanAge -and $scanAge -gt 30) {
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
#  Offer to fold any of it into the rules
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

Write-Host "  Filtered out: $($excluded.Count) of $($result.Apps.Count) inventoried applications." -ForegroundColor DarkGray

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
        $label = @([string]$device.serialNumber, [string]$device.deviceName, 'device' |
                   Where-Object { $_ -and $_.Trim() })[0].Trim()
        foreach ($bad in [IO.Path]::GetInvalidFileNameChars()) { $label = $label.Replace($bad, '_') }
        $sheetPath = "$label-InstallList.html"
    }

    $html = New-InstallSheetHtml -Device $device -Apps $toInstall -ScanAge $scanAge `
                                 -SuppressedCount $excluded.Count -Suppressed $excluded `
                                 -TotalCount $result.Apps.Count
    $written = Save-InstallSheet -Html $html -Path $sheetPath
    if ($written) {
        Write-Host "Printable sheet saved to $written" -ForegroundColor Green
        Write-Host "  Open it in a browser." -ForegroundColor DarkGray
    }
}

exit 0
