<#
.SYNOPSIS
    Serves the refresh application list as a web page on this machine.

.DESCRIPTION
    A small HTTP front end over AppFilter.psm1, meant to run on an always-on
    machine. A technician opens the URL, types a serial, and gets the same
    printable tick-list the console tool produces - with no script, no
    credential and nothing to install on their side.

    The Absolute key stays on this machine only. Nobody else needs a copy.

    Authentication is Windows Integrated by default, so only domain accounts
    can reach it and every lookup is logged against a real person. Do not run
    it with -Anonymous on a network anyone else can reach: the pages return
    fleet inventory.

.EXAMPLE
    .\Start-RefreshAppServer.ps1

    Serves on port 5000 for anyone on the network who can authenticate.

.EXAMPLE
    .\Start-RefreshAppServer.ps1 -Port 8080 -Anonymous -BindAddress localhost

    Local-only, no authentication. For trying it out on one machine.

.EXAMPLE
    .\Start-RefreshAppServer.ps1 -Port 5055 -AuthScheme Ntlm

    NTLM only. Use this when a browser prompts for credentials and will not
    accept correct ones - see -AuthScheme.

.NOTES
    Binding to all interfaces needs either an elevated session or a one-time
    URL reservation, which is the better answer:

        netsh http add urlacl url=http://+:5000/ user=DOMAIN\ServiceAccount

    And a firewall rule so other machines can reach it:

        New-NetFirewallRule -DisplayName "Refresh App List" -Direction Inbound `
            -Protocol TCP -LocalPort 5000 -Profile Domain -Action Allow
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 5000,

    # '+' listens on every interface. Use 'localhost' to keep it to this
    # machine, which also avoids needing a URL reservation.
    [string]$BindAddress = '+',

    [Alias('BaselineCsv')]
    [string]$RulesCsv = "$PSScriptRoot\AppRules.csv",

    # Turn off Windows authentication. Only sensible for a local trial.
    [switch]$Anonymous,

    # Which Windows authentication scheme to offer.
    #
    #   IntegratedWindowsAuthentication  Negotiate, falling back to NTLM
    #   Negotiate                        Kerberos, falling back to NTLM
    #   Ntlm                             NTLM only
    #
    # Use Ntlm when browsers prompt for credentials and then refuse to accept
    # correct ones. That is what a missing HTTP/<host> SPN looks like from the
    # outside: the browser attempts Kerberos with what you typed, gets no
    # ticket, and re-prompts rather than falling back. PowerShell with
    # -UseDefaultCredentials succeeds throughout, which makes it look like a
    # browser fault rather than an SPN one.
    [ValidateSet('IntegratedWindowsAuthentication', 'Negotiate', 'Ntlm')]
    [string]$AuthScheme = 'IntegratedWindowsAuthentication',

    [string]$LogPath = "$PSScriptRoot\RefreshAppServer.log"
)

# --- CONFIGURATION -------------------------------------------------
#
#  >> THIS FILE CONTAINS THE ABSOLUTE API KEY. <<
#
#  On a server that is the point: the key lives here and nowhere else, so
#  technicians never hold a copy. Restrict who can log into this machine,
#  and set Approved IP Addresses on the token in the Absolute console so the
#  key is useless anywhere but here.
#
#  Leave these as-is to use the ABSOLUTE_TOKEN_ID and ABSOLUTE_SECRET_KEY
#  environment variables instead.
#
$TokenId   = "TOKEN HERE"
$SecretKey = "KEY HERE"

$BaseUrl   = "https://api.absolute.com"
$PageSize  = 500
# -------------------------------------------------------------------

Import-Module (Join-Path $PSScriptRoot 'AppFilter.psm1') -Force -ErrorAction Stop


# ------------------------------------------------------------------
#  Shared look, so the form and the sheet are obviously one thing
# ------------------------------------------------------------------
$PageCss = @'
  * { box-sizing: border-box; }
  body { font-family: Segoe UI, Calibri, Arial, sans-serif; font-size: 10.5pt;
         color: #000; background: #f4f4f5; margin: 0; padding: 8mm; }
  .card { max-width: 150mm; margin: 12mm auto; background: #fff; padding: 10mm;
          box-shadow: 0 1px 4px rgba(0,0,0,.18); }
  h1 { font-size: 15pt; margin: 0 0 1mm; }
  p.sub { margin: 0 0 6mm; color: #555; font-size: 9.5pt; }
  label { display: block; font-size: 7.5pt; letter-spacing: .06em;
          text-transform: uppercase; color: #555; margin-bottom: 1.5mm; }
  input[type=text] { font: inherit; font-size: 13pt; letter-spacing: .04em;
                     width: 100%; padding: 3mm; border: 1px solid #999;
                     border-radius: 3px; }
  input[type=text]:focus { outline: 2px solid #000; outline-offset: 1px; }
  button { font: inherit; font-weight: 600; padding: 3mm 8mm; margin-top: 4mm;
           border: 1px solid #000; background: #000; color: #fff;
           border-radius: 3px; cursor: pointer; }
  button:hover { background: #333; border-color: #333; }
  .err { border: 0.75pt solid #000; padding: 3mm; margin: 0 0 5mm;
         font-size: 9.5pt; }
  .foot { margin-top: 6mm; padding-top: 2mm; border-top: 0.5pt solid #ccc;
          font-size: 8.5pt; color: #666; }
'@

function New-FormPage {
    param([string]$Error, [string]$Serial, [string]$User)

    $errHtml = ''
    if ($Error) { $errHtml = "    <p class=`"err`">$(ConvertTo-HtmlText $Error)</p>`n" }

    # Say plainly when authentication is off rather than crediting a lookup to
    # a user called "anonymous".
    $who = ''
    if ($User -eq 'anonymous') { $who = 'Anonymous access &ndash; authentication is off.' }
    elseif ($User)             { $who = "Signed in as $(ConvertTo-HtmlText $User)" }

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Refresh App List</title>
<style>$PageCss</style>
</head>
<body>
  <div class="card">
    <h1>Refresh App List</h1>
    <p class="sub">Enter the serial number of the machine being replaced.</p>
$errHtml    <form method="get" action="/lookup">
      <label for="serial">Serial number</label>
      <input type="text" id="serial" name="serial" autofocus autocomplete="off"
             spellcheck="false" value="$(ConvertTo-HtmlText $Serial)" />
      <button type="submit">Look up</button>
    </form>
    <p class="foot">$who</p>
  </div>
</body>
</html>
"@
}

function New-ErrorPage {
    param([string]$Title, [string]$Detail)
    @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8" /><title>$(ConvertTo-HtmlText $Title)</title>
<style>$PageCss</style></head>
<body>
  <div class="card">
    <h1>$(ConvertTo-HtmlText $Title)</h1>
    <p class="err">$(ConvertTo-HtmlText $Detail)</p>
    <form method="get" action="/"><button type="submit">Back</button></form>
  </div>
</body>
</html>
"@
}

function Write-RequestLog {
    param([string]$User, [string]$Serial, [string]$Outcome)
    # No ternary here on purpose: this has to run on Windows PowerShell 5.1.
    if (-not $User)   { $User   = '-' }
    if (-not $Serial) { $Serial = '-' }
    # A query string can carry %0A, and a newline in the log would forge a
    # second entry. Keep every request to exactly one line.
    $Serial = ($Serial -replace '[\x00-\x1f]', '?')
    if ($Serial.Length -gt 40) { $Serial = $Serial.Substring(0, 40) }
    $line = '{0}  {1,-28} {2,-16} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                                          $User, $Serial, $Outcome
    Write-Host $line
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Warning "Could not write to $LogPath - $($_.Exception.Message)" }
}


# ------------------------------------------------------------------
#  Fail on configuration before opening a port
# ------------------------------------------------------------------
$rules      = Import-AppRule -Path $RulesCsv
$credential = Get-AbsoluteCredential -TokenId $TokenId -SecretKey $SecretKey

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://${BindAddress}:$Port/")

if ($Anonymous) {
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
} else {
    # Whichever scheme is chosen, a domain machine signs in without a prompt
    # and $context.User.Identity.Name names the caller in the log.
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::$AuthScheme
}

try { $listener.Start() }
catch {
    Write-Host ""
    Write-Host "Could not listen on http://${BindAddress}:$Port/" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Binding to all interfaces needs a URL reservation, once:" -ForegroundColor Yellow
    Write-Host "    netsh http add urlacl url=http://+:$Port/ user=$env:USERDOMAIN\$env:USERNAME"
    Write-Host ""
    Write-Host "Or run with -BindAddress localhost to keep it to this machine." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Refresh App List server" -ForegroundColor Green
Write-Host "  Listening on  http://${BindAddress}:$Port/"
if ($BindAddress -eq '+') {
    Write-Host "  Technicians   http://$($env:COMPUTERNAME):$Port/" -ForegroundColor Cyan
}
Write-Host "  Rules         $($rules.Names.Count) name, $($rules.Publishers.Count) publisher, $($rules.Patterns.Count) pattern"
Write-Host "  Credential    $($credential.Source)"
$authLabel = $AuthScheme
if ($Anonymous) { $authLabel = 'ANONYMOUS - anyone who can reach the port' }
Write-Host "  Auth          $authLabel"
Write-Host "  Log           $LogPath"
Write-Host "  Stop with Ctrl+C"
Write-Host ""

if ($Anonymous -and $BindAddress -eq '+') {
    Write-Warning "Anonymous access on every interface: anyone who can reach this port can read fleet inventory."
}

try {
    while ($listener.IsListening) {

        $context = $listener.GetContext()
        $user    = if ($context.User -and $context.User.Identity) { $context.User.Identity.Name } else { 'anonymous' }
        $path    = $context.Request.Url.AbsolutePath
        $body    = $null
        $status  = 200

        try {
            switch -Regex ($path) {

                '^/health/?$' {
                    $body = 'OK'
                    $context.Response.ContentType = 'text/plain; charset=utf-8'
                    break
                }

                '^/lookup/?$' {
                    $serial = [string]$context.Request.QueryString['serial']
                    $serial = $serial.Trim()

                    if ($serial -notmatch '^[A-Za-z0-9\-]{1,32}$') {
                        $status = 400
                        $body = New-FormPage -User $user -Serial $serial `
                                    -Error "That does not look like a serial number. Letters, digits and hyphens only."
                        Write-RequestLog -User $user -Serial $serial -Outcome 'rejected (bad serial)'
                        break
                    }

                    $result = Get-RefreshApps -Serial $serial -Rules $rules -Credential $credential `
                                              -BaseUrl $BaseUrl -PageSize $PageSize

                    if (-not $result.Found) {
                        $status = 404
                        $body = New-FormPage -User $user -Serial $serial -Error $result.Message
                        Write-RequestLog -User $user -Serial $serial -Outcome 'not found'
                        break
                    }

                    if ($result.Apps.Count -eq 0) {
                        $body = New-FormPage -User $user -Serial $serial -Error $result.Message
                        Write-RequestLog -User $user -Serial $serial -Outcome 'no inventory'
                        break
                    }

                    $body = New-InstallSheetHtml -Device $result.Device -Apps $result.ToInstall `
                                -ScanAge $result.ScanAge -SuppressedCount $result.Excluded.Count `
                                -TotalCount $result.Apps.Count -HomeLink '/'
                    Write-RequestLog -User $user -Serial $serial `
                        -Outcome "$($result.ToInstall.Count) to install of $($result.Apps.Count)"
                    break
                }

                '^/?$' {
                    $body = New-FormPage -User $user
                    break
                }

                default {
                    $status = 404
                    $body = New-ErrorPage -Title 'Not found' -Detail "Nothing is served at $path."
                }
            }
        }
        catch {
            # One bad request must not take the server down with it.
            $status = 500
            $body = New-ErrorPage -Title 'Lookup failed' -Detail $_.Exception.Message
            Write-RequestLog -User $user -Serial '-' -Outcome "ERROR $($_.Exception.Message)"
        }

        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $context.Response.StatusCode = $status
            if (-not $context.Response.ContentType) {
                $context.Response.ContentType = 'text/html; charset=utf-8'
            }
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        catch {
            Write-Warning "Could not send the response: $($_.Exception.Message)"
        }
        finally { $context.Response.Close() }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Host ""
    Write-Host "Server stopped." -ForegroundColor Yellow
}
