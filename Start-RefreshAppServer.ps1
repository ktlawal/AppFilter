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

        netsh http add urlacl url=http://+:5000/appfilter/ user=DOMAIN\ServiceAccount

    The path is part of the reservation. Because http.sys routes by longest
    prefix match, a second application can reserve http://+:5000/something/
    and run alongside this one on the same port, in its own process.

    And a firewall rule so other machines can reach it:

        New-NetFirewallRule -DisplayName "Refresh App List" -Direction Inbound `
            -Protocol TCP -LocalPort 5000 -Profile Domain -Action Allow
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 5000,

    # The path this application answers on. http.sys routes by longest
    # prefix match, so a different application can own a different path on
    # this same port, in its own process, started and stopped independently.
    # One firewall rule covers the lot.
    #
    # Whatever is set here must match the URL reservation exactly:
    #     netsh http add urlacl url=http://+:5000/appfilter/ user=...
    [string]$BasePath = '/appfilter/',

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

    # Serve https instead of http. The certificate is not configured here:
    # it is bound to the port in http.sys, once, outside this script. Run
    # Find-ServerCertificate.ps1 to locate one and get the exact command.
    # Without that binding the listener starts and every connection is reset.
    [switch]$UseHttps,

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
  html, body { height: 100%; }
  body { margin: 0; display: grid; grid-template-columns: minmax(0,42%) minmax(0,1fr);
         font-family: "Segoe UI", -apple-system, system-ui, Calibri, Arial, sans-serif;
         color: #101828; background: #fff; }

  /* Left: what this is. Vertically centred - with the step list gone there is
     not enough here to justify pinning content to the top and bottom edges -
     and pushed to the inner edge, so on a wide monitor the two halves read as
     one composition across the divider instead of drifting to opposite walls.
     The text inside stays left-aligned; only the block moves. */
  .left { background: #0f172a; color: #fff; padding: 46px 56px 46px 40px;
          display: flex; flex-direction: column; justify-content: center;
          align-items: flex-end; }
  .left .inner { max-width: 34ch; }
  .mark { font-size: 12px; font-weight: 600; letter-spacing: .14em;
          text-transform: uppercase; color: #7dd3fc; }
  .left h2 { font-size: 26px; font-weight: 600; letter-spacing: -.02em;
             line-height: 1.25; margin: 16px 0 0; }
  .left p { color: #94a3b8; font-size: 14px; line-height: 1.6; margin: 14px 0 0; }

  /* Right: the one thing to do. */
  /* place-items: center start - vertically centred, held against the divider. */
  .right { display: grid; place-items: center start;
           padding: 40px 40px 40px 56px; min-width: 0; }
  .form { width: min(380px, 100%); min-width: 0; }
  h1 { font-size: 23px; font-weight: 600; letter-spacing: -.015em; margin: 0 0 26px; }
  label { display: block; font-size: 11px; font-weight: 600; letter-spacing: .09em;
          text-transform: uppercase; color: #98a2b3; margin-bottom: 8px; }
  /* min-width: 0 matters. A text input carries an intrinsic minimum width from
     its default size attribute, which width:100% does not override inside a
     grid or flex parent - without this the field runs off a narrow window. */
  input[type=text] { width: 100%; min-width: 0;
                     font-family: Consolas, "Cascadia Mono", ui-monospace, monospace;
                     font-size: 22px; letter-spacing: .09em; text-transform: uppercase;
                     padding: 13px 15px; border: 1.5px solid #e4e7ec; border-radius: 10px;
                     outline: none; background: #fcfcfd; color: #101828;
                     transition: border-color .15s, background .15s; }
  input[type=text]::placeholder { color: #cdd2db; }
  input[type=text]:focus { border-color: #0f172a; background: #fff; }
  button { width: 100%; margin-top: 16px; font: inherit; font-size: 15px; font-weight: 600;
           color: #fff; background: #0f172a; border: 0; border-radius: 10px;
           padding: 13px; cursor: pointer; transition: background .15s; }
  button:hover { background: #1e293b; }
  button:focus-visible { outline: 2px solid #0f172a; outline-offset: 2px; }

  .err { margin: 0 0 22px; padding: 12px 14px; border: 1px solid #f3b7b2;
         border-left-width: 3px; border-radius: 8px; background: #fef4f3;
         color: #b3261e; font-size: 13.5px; line-height: 1.5; }

  .foot { margin-top: 26px; font-size: 12.5px; color: #98a2b3; }

  /* One column on a narrow window. The left panel keeps its heading so the
     page still says what it is, but stops eating half the screen. */
  @media (max-width: 720px) {
    body { grid-template-columns: minmax(0,1fr); grid-template-rows: auto 1fr; }
    /* Stacked, there is no divider to hug: both go back to the left margin. */
    .left { padding: 28px 24px; align-items: stretch; }
    .left h2 { font-size: 21px; }
    .left p { display: none; }
    .right { padding: 32px 24px; justify-items: stretch; }
  }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
'@

function New-SplitPage {
    <#
        Both pages share one shell: the panel on the left never changes, only
        what sits in the working column on the right.
    #>
    param([string]$Title, [string]$Body)

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>$(ConvertTo-HtmlText $Title)</title>
<style>$PageCss</style>
</head>
<body>
  <div class="left">
    <div class="inner">
      <div class="mark">PC Refresh</div>
      <h2>What to install<br />on the new device</h2>
      <p>Pulls the old device's inventory and subtracts everything the image already provides.</p>
    </div>
  </div>
  <div class="right">
    <div class="form">
$Body
    </div>
  </div>
</body>
</html>
"@
}

function New-FormPage {
    param([string]$Error, [string]$Serial, [string]$User)

    $errHtml = ''
    if ($Error) { $errHtml = "      <p class=`"err`">$(ConvertTo-HtmlText $Error)</p>`n" }

    # Say plainly when authentication is off rather than crediting a lookup to
    # a user called "anonymous".
    $who = ''
    if ($User -eq 'anonymous') { $who = 'Anonymous access &ndash; authentication is off.' }
    elseif ($User)             { $who = "Signed in as $(ConvertTo-HtmlText $User)" }

    $body = @"
      <h1>Look up a device</h1>
$errHtml      <form method="get" action="${BasePath}lookup">
        <label for="serial">Serial number</label>
        <input type="text" id="serial" name="serial" autofocus autocomplete="off"
               spellcheck="false" value="$(ConvertTo-HtmlText $Serial)" />
        <button type="submit">Look up</button>
      </form>
      <p class="foot">$who</p>
"@

    New-SplitPage -Title 'Refresh App List' -Body $body
}

function New-ErrorPage {
    param([string]$Title, [string]$Detail)

    $body = @"
      <h1>$(ConvertTo-HtmlText $Title)</h1>
      <p class="err">$(ConvertTo-HtmlText $Detail)</p>
      <form method="get" action="$BasePath"><button type="submit">Back</button></form>
"@

    New-SplitPage -Title $Title -Body $body
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

# A prefix has to start and end with a slash or http.sys rejects it.
$BasePath = '/' + $BasePath.Trim('/') + '/'
if ($BasePath -eq '//') { $BasePath = '/' }

# What routes are matched against, with no trailing slash: '/appfilter'.
$basePrefix = $BasePath.TrimEnd('/')

$scheme = 'http'
if ($UseHttps) { $scheme = 'https' }

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("${scheme}://${BindAddress}:${Port}${BasePath}")

if ($Anonymous) {
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
} else {
    # Whichever scheme is chosen, a domain machine signs in without a prompt
    # and $context.User.Identity.Name names the caller in the log.
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::$AuthScheme
}

try { $listener.Start() }
catch {
    $reason = $_.Exception.Message

    Write-Host ""
    Write-Host "Could not listen on ${scheme}://${BindAddress}:${Port}${BasePath}" -ForegroundColor Red
    Write-Host $reason -ForegroundColor Red
    Write-Host ""

    # These two failures read alike and need opposite fixes, so say which.
    # http.sys says "conflicts with an existing registration"; the same
    # situation on other platforms says "Address already in use".
    if ($reason -match 'conflicts with an existing registration|Address already in use') {

        Write-Host "Three different things produce this message." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "1. The SAME PORT IS ALREADY CLAIMED FOR THE OTHER SCHEME." -ForegroundColor Yellow
        Write-Host "   A port is http or https in http.sys, never both - TLS is bound"
        Write-Host "   per ip:port, so the whole port is one or the other. An"
        Write-Host "   http://+:${Port}${BasePath} reservation therefore blocks https on"
        Write-Host "   this port, and blocks adding the https reservation too."
        Write-Host "   Look for the other scheme on this port:"
        Write-Host "       netsh http show urlacl | Select-String ':$Port'"
        Write-Host "   then drop it and reserve this scheme instead:"
        Write-Host "       netsh http delete urlacl url=http://+:${Port}${BasePath}"
        Write-Host "       netsh http add urlacl url=${scheme}://+:${Port}${BasePath} user=`"$env:USERDOMAIN\$env:USERNAME`""
        Write-Host ""
        Write-Host "2. The prefix is RESERVED FOR ANOTHER ACCOUNT." -ForegroundColor Yellow
        Write-Host "   Windows reports that as a conflict, not as access denied."
        Write-Host "   A reservation made for NT AUTHORITY\SYSTEM does not let you"
        Write-Host "   listen as $env:USERNAME. Check who holds it:"
        Write-Host "       netsh http show urlacl url=${scheme}://+:${Port}${BasePath}"
        Write-Host ""
        Write-Host "   A URL has one reservation, so testing as yourself means"
        Write-Host "   repointing it - then putting it back for the startup task:"
        Write-Host "       netsh http delete urlacl url=${scheme}://+:${Port}${BasePath}"
        Write-Host "       netsh http add urlacl url=${scheme}://+:${Port}${BasePath} user=`"$env:USERDOMAIN\$env:USERNAME`""
        Write-Host ""
        Write-Host "3. Something is already listening - usually an earlier instance." -ForegroundColor Yellow
        Write-Host "   A reboot rules this one out. Otherwise:"
        Write-Host "       Get-NetTCPConnection -LocalPort $Port -State Listen |"
        Write-Host "           ForEach-Object { Get-Process -Id `$_.OwningProcess }"
        Write-Host "       netsh http show servicestate view=requestq" 

    } elseif ($reason -match 'Access is denied') {

        Write-Host "The account running this is not allowed to listen on that prefix." -ForegroundColor Yellow
        Write-Host "Reserve it for this account, once, elevated:" -ForegroundColor Yellow
        Write-Host "    netsh http add urlacl url=${scheme}://+:${Port}${BasePath} user=`"$env:USERDOMAIN\$env:USERNAME`""
        Write-Host ""
        Write-Host "A reservation made for a different account - NT AUTHORITY\SYSTEM," -ForegroundColor Yellow
        Write-Host "say - does not let you listen. Check who holds it:" -ForegroundColor Yellow
        Write-Host "    netsh http show urlacl url=${scheme}://+:${Port}${BasePath}"

    } else {

        Write-Host "Binding to all interfaces needs a URL reservation, once:" -ForegroundColor Yellow
        Write-Host "    netsh http add urlacl url=${scheme}://+:${Port}${BasePath} user=`"$env:USERDOMAIN\$env:USERNAME`""
        Write-Host ""
        Write-Host "The reservation has to match the scheme and path exactly." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Or run with -BindAddress localhost to keep it to this machine." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Refresh App List server" -ForegroundColor Green
Write-Host "  Listening on  ${scheme}://${BindAddress}:${Port}${BasePath}"
if ($BindAddress -eq '+') {
    Write-Host "  Technicians   ${scheme}://$($env:COMPUTERNAME):${Port}${BasePath}" -ForegroundColor Cyan
}

if ($UseHttps) {
    # http.sys owns the TLS handshake, so a missing or wrong certificate
    # binding does not fail here - it fails per connection, later, looking
    # like the site is simply refusing to load.
    Write-Host "  Certificate   bound in http.sys, not by this script" -ForegroundColor DarkGray
    Write-Host "                check: netsh http show sslcert ipport=0.0.0.0:$Port" -ForegroundColor DarkGray
} else {
    Write-Host "  Certificate   none - browsers will say Not secure" -ForegroundColor DarkGray
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

        # GetContext() blocks inside native code, where PowerShell cannot
        # deliver Ctrl+C - the console just ignores it and the window has to
        # be killed. Waiting on the async version in short slices gives the
        # host a chance to process the interrupt between waits.
        $pending = $listener.GetContextAsync()
        while (-not $pending.Wait(250)) {
            if (-not $listener.IsListening) { break }
        }
        if (-not $pending.IsCompleted) { break }
        $context = $pending.Result

        $user    = if ($context.User -and $context.User.Identity) { $context.User.Identity.Name } else { 'anonymous' }

        # Requests still carry the base path. Routes are matched against
        # whatever follows it, so '/appfilter/lookup' tests as '/lookup'.
        $path = $context.Request.Url.AbsolutePath
        if ($basePrefix -and
            $path.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $path = $path.Substring($basePrefix.Length)
        }
        if (-not $path.StartsWith('/')) { $path = '/' + $path }
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
                                -TotalCount $result.Apps.Count -HomeLink $BasePath
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
