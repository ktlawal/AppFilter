<#
.SYNOPSIS
    Finds a certificate this machine can use to serve https, and prints the
    command to bind it.

.DESCRIPTION
    Reads the local machine certificate store and reports which certificates
    could serve https for this machine's own name, with a verdict for each.
    On a domain machine there is often already a suitable one, enrolled
    automatically, and nothing needs to be requested.

    A certificate qualifies when all four hold:

      * it has a private key on this machine
      * it is currently within its validity dates
      * it allows Server Authentication
      * one of its names matches this machine's hostname or FQDN

    A fifth thing decides whether browsers stay quiet: the issuing CA has to
    be trusted by the machines your technicians use. A certificate from your
    internal CA is trusted by every domain-joined machine automatically. A
    self-signed one is trusted by nothing, and browsers warn about it exactly
    as loudly as they warn about plain http - so it is not a shortcut.

    THIS SCRIPT CHANGES NOTHING. It reads the store and prints commands for
    you to run yourself.

.EXAMPLE
    .\Find-ServerCertificate.ps1

.EXAMPLE
    .\Find-ServerCertificate.ps1 -Port 5000
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 5000
)

$serverAuth = '1.3.6.1.5.5.7.3.1'

$hostNames = @()
$hostNames += $env:COMPUTERNAME
try {
    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    if ($fqdn) { $hostNames += $fqdn }
} catch { }
$hostNames = @($hostNames | Where-Object { $_ } | Sort-Object -Unique)

Write-Host ""
Write-Host ("=" * 72)
Write-Host "  Certificates that could serve https for this machine"
Write-Host ("=" * 72)
Write-Host ""
Write-Host "  This machine answers to: $($hostNames -join ', ')"
Write-Host ""

# --- what is bound to the port right now ---------------------------
Write-Host "  Currently bound to port $Port" -ForegroundColor Yellow
$existing = & netsh http show sslcert ipport=0.0.0.0:$Port 2>&1
if ($LASTEXITCODE -ne 0 -or ("$existing" -match 'The system cannot find the file specified')) {
    Write-Host "    nothing - the port serves plain http today" -ForegroundColor DarkGray
} else {
    $existing | Where-Object { $_ -match ':' } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host ""

# --- candidates ----------------------------------------------------
$all = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)

if ($all.Count -eq 0) {
    Write-Host "  The local machine store is empty." -ForegroundColor Red
    Write-Host "  Nothing to bind - see 'If nothing qualifies' below." -ForegroundColor Red
}

$usable = @()

foreach ($cert in $all) {

    $names = @($cert.DnsNameList | ForEach-Object { $_.Unicode })
    if ($names.Count -eq 0) { $names = @($cert.Subject) }

    # An empty EKU list means the certificate carries no EKU extension at
    # all, which permits every use - including server authentication.
    $ekus    = @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
    $canServe = ($ekus.Count -eq 0) -or ($ekus -contains $serverAuth)

    $matchesHost = $false
    foreach ($n in $names) {
        foreach ($h in $hostNames) {
            if ($n -and $h -and ($n -eq $h -or $n -eq "*.$($h.Split('.', 2)[-1])")) { $matchesHost = $true }
        }
    }

    $live = ($cert.NotBefore -le (Get-Date)) -and ($cert.NotAfter -gt (Get-Date))

    $problems = @()
    if (-not $cert.HasPrivateKey) { $problems += 'no private key' }
    if (-not $live)               { $problems += 'expired or not yet valid' }
    if (-not $canServe)           { $problems += 'not valid for server authentication' }
    if (-not $matchesHost)        { $problems += "name does not match this machine" }

    $obj = [pscustomobject]@{
        Thumbprint = $cert.Thumbprint
        Names      = ($names -join ', ')
        Issuer     = $cert.Issuer
        NotAfter   = $cert.NotAfter
        Problems   = $problems
        SelfSigned = ($cert.Subject -eq $cert.Issuer)
    }

    if ($problems.Count -eq 0) { $usable += $obj }
}

if ($usable.Count -eq 0) {
    Write-Host "  No certificate in this machine's store qualifies." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  What is in the store, and why each was rejected:" -ForegroundColor DarkGray
    foreach ($cert in $all) {
        $names = @($cert.DnsNameList | ForEach-Object { $_.Unicode })
        if ($names.Count -eq 0) { $names = @($cert.Subject) }
        $ekus = @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
        $why = @()
        if (-not $cert.HasPrivateKey) { $why += 'no private key' }
        if ($cert.NotAfter -le (Get-Date)) { $why += 'expired' }
        if ($ekus.Count -gt 0 -and $ekus -notcontains $serverAuth) { $why += 'not for server auth' }
        Write-Host ("    {0}  {1}" -f $cert.Thumbprint, ($names -join ', ')) -ForegroundColor DarkGray
        if ($why.Count -gt 0) { Write-Host ("        {0}" -f ($why -join '; ')) -ForegroundColor DarkGray }
        else { Write-Host "        name does not match this machine" -ForegroundColor DarkGray }
    }
}
else {
    Write-Host "  $($usable.Count) usable certificate(s):" -ForegroundColor Green
    Write-Host ""

    foreach ($u in $usable) {
        Write-Host "  Thumbprint  $($u.Thumbprint)"
        Write-Host "  Names       $($u.Names)"
        Write-Host "  Issuer      $($u.Issuer)"
        Write-Host "  Expires     $($u.NotAfter)"

        # Chain trust is the difference between a quiet browser and a warning
        # page, and it cannot be read off the certificate itself. Build the
        # chain twice: once ignoring revocation, once checking it. A bare
        # pass/fail is useless here, because an unreachable CRL fails exactly
        # like an untrusted root while meaning something completely different
        # - browsers soft-fail revocation and would not care.
        $certObj = Get-Item "Cert:\LocalMachine\My\$($u.Thumbprint)"

        $noRevoke = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $noRevoke.ChainPolicy.RevocationMode = 'NoCheck'
        $pathOk = $noRevoke.Build($certObj)

        $withRevoke = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $withRevoke.ChainPolicy.RevocationMode = 'Online'
        $fullOk = $withRevoke.Build($certObj)

        if ($u.SelfSigned) {
            Write-Host "  Trust       SELF-SIGNED - browsers will still warn. Not a fix." -ForegroundColor Yellow
        } elseif ($pathOk) {
            Write-Host "  Trust       chains to a trusted CA on this machine" -ForegroundColor Green
            if (-not $fullOk) {
                Write-Host "              (revocation could not be checked - usually a CRL this" -ForegroundColor DarkGray
                Write-Host "               machine cannot reach. Browsers soft-fail this.)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  Trust       chain does NOT build on this machine" -ForegroundColor Yellow
            foreach ($s in $noRevoke.ChainStatus) {
                Write-Host ("              {0}: {1}" -f $s.Status, $s.StatusInformation.Trim()) -ForegroundColor Yellow
            }
            Write-Host "              A missing intermediate or root here does not always mean" -ForegroundColor DarkGray
            Write-Host "              your technicians' machines will reject it - test from one." -ForegroundColor DarkGray
        }

        # Chain built from this machine's stores, so the reader can see which
        # CA is actually being trusted.
        Write-Host "  Chain       " -NoNewline
        # GetNameInfo pulls the common name out regardless of RDN order;
        # splitting the subject on a comma picks whatever happens to be first.
        # A certificate issued with an empty Subject - its name carried only
        # in the SAN, which enterprise templates do - returns nothing from
        # SimpleName, so fall through to the SAN and then the raw subject
        # rather than printing a blank link in the chain.
        $links = @($noRevoke.ChainElements | ForEach-Object {
            $e = $_.Certificate
            $name = $e.GetNameInfo('SimpleName', $false)
            if (-not $name) { $name = $e.GetNameInfo('DnsName', $false) }
            if (-not $name) { $name = $e.Subject }
            if (-not $name) { $name = "(unnamed, $($e.Thumbprint))" }
            $name
        })
        Write-Host ($links -join '  <-  ')

        $noRevoke.Dispose()
        $withRevoke.Dispose()

        # The binding is by thumbprint. A renewed certificate is a DIFFERENT
        # certificate with a different thumbprint, so https stops working the
        # day this one is replaced, silently, with no change on this machine.
        $daysLeft = [int]($u.NotAfter - (Get-Date)).TotalDays
        if ($daysLeft -lt 120) {
            Write-Host "  Renewal     $daysLeft days left. The binding below pins this thumbprint," -ForegroundColor Yellow
            Write-Host "              so https breaks when this certificate is renewed. Diarise it." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "  To bind it, elevated:" -ForegroundColor Cyan
        Write-Host "    netsh http add sslcert ipport=0.0.0.0:$Port certhash=$($u.Thumbprint) appid=$([guid]::NewGuid().ToString('B')) certstorename=MY"
        Write-Host ""
        Write-Host ("  " + ("-" * 68))
        Write-Host ""
    }
}

Write-Host "  If nothing qualifies" -ForegroundColor Yellow
Write-Host "    Ask whoever runs your internal CA for a Server Authentication"
Write-Host "    certificate for this machine's FQDN. If the CA publishes a"
Write-Host "    template you are allowed to enrol from, this requests one:"
Write-Host ""
Write-Host "      Get-Certificate -Template Machine -CertStoreLocation Cert:\LocalMachine\My"
Write-Host ""
Write-Host "    'Machine' is the usual template name; yours may differ."
Write-Host "    certutil -pulse forces an autoenrolment check first."
Write-Host ""
Write-Host "  Then start the server with -UseHttps, and remember the URL"
Write-Host "  reservation is scheme-specific:" -ForegroundColor Yellow
Write-Host ""
Write-Host "      netsh http add urlacl url=https://+:$Port/appfilter/ user=`"NT AUTHORITY\SYSTEM`""
Write-Host ""
