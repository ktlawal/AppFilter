<#
.SYNOPSIS
    Lists applications that need manual installation on a refreshed device.

.DESCRIPTION
    Pulls the installed application inventory for a device from Absolute,
    removes anything in the base image, suppresses drivers and runtimes,
    and reports what is left.

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42

.EXAMPLE
    .\Get-RefreshAppList.ps1 -Serial JLY4F42 -ShowFiltered
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Serial')]
    [string]$Serial,

    [Parameter(Mandatory, ParameterSetName = 'DeviceName')]
    [string]$DeviceName,

    # Also show what was filtered out and why
    [switch]$ShowFiltered,

    [string]$BaselineCsv = ".\BaseImageApps.csv",
    [string]$OutputCsv
)

# --- CONFIGURATION -------------------------------------------------
$TokenId   = "TOKEN HERE"
$SecretKey = "KEY HERE"
$BaseUrl   = "https://api.absolute.com"
$PageSize  = 500
# -------------------------------------------------------------------


# --- NOISE SUPPRESSION RULES ---------------------------------------
# Publishers whose software arrives with the hardware or the image.
$DriverPublishers = @(
    'Intel', 'INTEL', 'Realtek Semiconductor', 'Realtek', 'Dell', 'Dell Inc.',
    'NVIDIA', 'Advanced Micro Devices', 'AMD', 'Synaptics', 'Conexant',
    'Broadcom', 'Qualcomm', 'ELAN', 'Alps Electric'
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
    elseif ($a.appPublisher -and ($DriverPublishers -contains $a.appPublisher.Trim())) {
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
    $toInstall | Format-Table @{ n = 'Application'; e = { $_.AppName }; width = 45 },
                              @{ n = 'Version';    e = { $_.Version }; width = 20 },
                              @{ n = 'Publisher';  e = { $_.Publisher } }
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
