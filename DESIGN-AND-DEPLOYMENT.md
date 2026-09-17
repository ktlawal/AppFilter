# PC Refresh Application List — design, deployment and how it works

What was built, the order it was built in, why each piece is the way it is, and
what was rejected along the way. Written to answer three kinds of question:

- *"What did you actually do?"* — Part I, the build in order.
- *"How does the sign-in work, and why doesn't it ask me for a password?"* —
  Part II.
- *"How does it decide what to filter?"* — Part III.

Host names, domain names and addresses are placeholders throughout:
`<lab-machine>.<domain>` is the machine the service runs on,
`DOMAIN\Account` a domain account, `5000` the port actually in use.

---

## The problem, in one paragraph

When a user's PC is refreshed, somebody has to work out what was on the old
machine that the new image does not already provide, and install it by hand.
Doing that from memory or by asking the user is unreliable and slow. The old
device's full software inventory already exists — Absolute holds it — but it is
a list of two to three hundred entries, almost all of it base image, drivers
and runtimes. The useful answer is the twenty or so entries that are left when
you subtract the noise. This tool does the subtraction.

It does not install anything. The deliverable is a list for a human.

---

## The path of one lookup, end to end

Everything below is in service of this sequence.

1. A technician opens `https://<lab-machine>.<domain>:5000/appfilter/` in Edge
   or Chrome. Windows signs them in silently (Part II).
2. They type the serial of the **old** device and submit. The serial is
   validated against `^[A-Za-z0-9\-]{1,32}$` before anything else happens — a
   rejected serial never reaches the API.
3. The server signs a request with the Absolute API token it holds and asks
   `/v3/reporting/devices` for that serial.
4. With the device's `deviceUid`, it asks `/v3/reporting/applications` for that
   device's inventory, following pagination until there is no continuation
   token.
5. Every application is classified against the rules (Part III): suppressed, or
   an install candidate.
6. The install candidates are rendered as a printable tick-box sheet. The
   suppressed ones go into a collapsed list underneath, so "why isn't X here?"
   has an answer on the page.
7. The request is logged: timestamp, the caller's domain account, the serial,
   and the outcome (`16 to install of 72`).

Nothing is stored between requests. There is no database.

---

# Part I — The build, action by action

Each action below is *what was done*, *what it was for*, *what else was
possible*, and *why this one*.

## 1. Read the inventory out of Absolute

**Done:** Wrote a v3 API client in PowerShell — `Get-AbsoluteV3` in
`AppFilter.psm1`.

**For:** The inventory is the whole input. Without it there is no tool.

**What the API actually needed**, none of which matched first assumptions:

- v3 authenticates with a **JWS token**, not signed HTTP headers. You build a
  JSON header naming the method, URI, query string and `issuedAt`, base64url it
  with a `{}` payload, sign `header.payload` with HMAC-SHA256 using the API
  secret, and POST the resulting `header.payload.signature` to
  `https://api.absolute.com/jws/validate` as `text/plain`. The endpoint you
  actually want is named *inside* the signed header; every request goes to
  `/jws/validate`.
- `issuedAt` must be the **current** UTC epoch in milliseconds. Offsetting it
  into the future — a habit from clock-skew defensiveness — causes
  intermittent 401s.
- Pagination hides at `metadata.pagination.nextPage`, two levels down. Miss it
  and you silently get only the first page, which looks like a working tool
  with a short answer.
- `pageSize` caps at 500.

**Alternatives considered:** the v2 endpoints (404 through `/jws/validate` on
this tenant), and two device-application endpoints that appear in various docs
— `/v3/reporting/device-applications` and `/v3/sw/deviceapplications`. Both
return **403 with an HTML body**, which is the edge gateway rejecting a path
that does not exist, not a permissions problem. A real API error comes back as
JSON. That distinction saved a support ticket.

**Why this one:** it is the only route that works. The pair
`/v3/reporting/devices` + `/v3/reporting/applications` is the whole data layer.

## 2. Build a baseline from real devices, not from memory

**Done:** `Build-BaseImageList.ps1` took two known base-image devices and
intersected their inventories — 61 applications present on both — then a short
hand review of the "on one of two" bucket added three more.

**For:** Deciding what counts as base image is the entire value of the tool. If
that list is wrong, every sheet is wrong.

**Alternatives considered:**

- **The existing hand-curated list.** It was the starting point and it carried
  real errors: `Zoom Workplace`, `Webex`, `Cisco AnyConnect` and `7-Zip` were
  on it, but they are not in the image — they came off one user's machine. Each
  of those was a real application a technician would have failed to reinstall.
- **An install-path rule** — treat anything under `WindowsApps` as inbox. This
  was implemented and then **deleted**, because it suppressed genuinely
  deployed software: Power BI Desktop and Power Automate were both being
  filtered out. Store-installed does not mean inbox.
- **Imaging documentation** as the source of truth. Not pursued: what the image
  is documented to contain and what it actually installs drift apart, and the
  devices are the ground truth.

**Why this one:** an intersection of known-good devices is evidence rather than
opinion, and every row can say where it came from (the `Source` column).

**Its honest limitation:** an intersection of **two** devices cannot, in
principle, distinguish "base image" from "both these users happened to have
it". Two hand-checks held up — `Adobe Creative Cloud` (on both, confirmed base
image) and `7-Zip` (on neither, confirmed a user install) — but the sample
should widen when more known-good devices are available.

## 3. Normalize names before comparing them

**Done:** `ConvertTo-NormalizedAppName` and `ConvertTo-NormalizedPublisher`,
applied to **both sides** of every comparison.

**For:** The same product does not spell itself the same way twice.
`Tanium Client 7.8.1.3126` on one machine is `Tanium Client 7.9.2.1` on the
next. `7-Zip 19.00 (x64 edition)` and `7-Zip 24.09 (x64)` are the same product.
Exact string matching turns every version bump into a false install candidate.

**Alternatives considered:** matching on `appId` or a publisher+name pair.
Absolute's `appId` is not stable enough across the fleet to hang the whole
filter on, and versions are reported inconsistently. Name normalization is
crude but it is checkable — you can read the key and see whether it is right.

**Why this one:** it is transparent. When a match is wrong, the reason is
visible in one line of output rather than buried in an identifier.

Full behaviour and worked examples are in Part III.

## 4. Move the rules out of code and into a CSV

**Done:** `AppRules.csv`, 108 rows, three match types, each row carrying its
own `Reason`, `Active` flag and provenance.

**For:** Adding a rule should be a data edit, not a code change and a redeploy.

**Alternatives considered:** keeping the publisher and pattern lists as
PowerShell arrays in the script, which is where they started. That meant every
new `Dell Products` or `Logitech` decision was a code edit on a file that also
contains the API credential.

**Why this one:** it is also the shape a SharePoint list wants. If the rules
ever need to live somewhere non-technical people can edit them, only
`Import-AppRule` changes.

## 5. Split the tool into a module and front ends

**Done:** `AppFilter.psm1` holds every function and **no credential** — it
takes one as a parameter. `Get-RefreshAppList.ps1` (console) and
`Start-RefreshAppServer.ps1` (web) each hold the credential and call the
module.

**For:** It is what made a web front end possible later without a rewrite.

**Why this one:** the credential is the thing that constrains distribution. A
module that holds none can be copied anywhere, including into a test harness,
without becoming a secret.

## 6. Decide where the API key lives

**Done:** The token ID and secret are pasted into the top of each front end,
with `ABSOLUTE_TOKEN_ID` / `ABSOLUTE_SECRET_KEY` environment variables as a
fallback when the in-file values are left as placeholders. Values in the file
win when filled in.

**For:** The tool had to be usable before a shared-credential story existed.

**Alternatives considered — all three were built, worked, and were removed:**

| Approach | What it gave | Why it is not in use |
|---|---|---|
| **SharePoint via Microsoft Graph** (`-KeyUrl`) | Central rotation, one copy of the key | Blocked by tenant policy, not by code: a real attempt returned **AADSTS50105** — the Microsoft Graph Command Line Tools app has "assignment required" set. Needs an admin assignment or a dedicated app registration with delegated `Files.Read.All`. |
| **A shared key file by path** (`-KeyPath`) — network drive, UNC or WebDAV | Central rotation, no Entra app needed | Dropped when the scope narrowed to one operator; the web front end then removed the need entirely. |
| **A DPAPI-encrypted local file** | A credential that is inert if copied to another machine or account | Same reason. Worth remembering it exists in the commit history. |

**Why this one:** it is the simplest thing that works, and the honest trade was
written down rather than hidden — with the key in the file, *the script file is
the credential*: rotation means redistribution, and there is no per-copy
attribution in Absolute's logs.

**What actually protects the token is not where it is stored.** It is the
**Approved IP Addresses** setting on the token in the Absolute console, now
restricted to the two devices that need it. A leaked key is inert anywhere
else. That control is independent of every storage decision above and does more
than any of them. (Token expiry — Jan 7, 2027 — bounds the rest.)

## 7. Put it on a server so nobody holds a copy

**Done:** `Start-RefreshAppServer.ps1`, a `System.Net.HttpListener` server on
one always-on lab machine. Three routes under `/appfilter/`: the form, the
lookup, and a health check.

**For:** This is the answer to the credential problem in §6. The key sits on
one machine; technicians get a URL. Nothing to distribute means nothing to
rotate and nothing to leak.

**Alternatives considered:**

- **IIS.** Heavier: a role to install, an application pool, a web.config, and a
  different deployment story for a 700-line script. `HttpListener` *is*
  http.sys — the same kernel driver IIS sits on — without the rest of IIS.
- **Distributing the console script to every technician.** That is what this
  replaces. It fails on rotation, attribution and leakage all at once.

**Why this one:** one file, no server role, and it gets attribution for free —
`$context.User.Identity.Name` names the caller in every log line, which a
shared script copy can never do.

**A known consequence:** requests are served one at a time, so a second
technician waits a few seconds for the first lookup. Fine for a handful of
people; it is the first thing to change if it stops being fine.

## 8. Reserve the URL (`netsh http add urlacl`)

**Done:**

```
netsh http add urlacl url=https://+:5000/appfilter/ user="NT AUTHORITY\SYSTEM"
```

**For:** http.sys will not let a non-administrator process listen on a URL
unless that exact URL is reserved for the account. Without the reservation the
server has to run elevated, every time.

**Why the path is in the reservation, not just the port:** http.sys routes by
**longest prefix match**. Reserving `/appfilter/` rather than `/` means a
second application can later reserve `http://+:5000/something-else/` and run
beside this one — separate process, started and stopped independently — on the
same port. One firewall rule covers the machine, and the URL handed to
technicians today stays correct when the second application arrives.

**Three things that cost time here, worth knowing:**

- The reservation must match `-BasePath` **exactly**.
- **"Conflicts with an existing registration" also means "reserved by another
  account."** Windows does not say "access denied" for that. A reservation made
  for `NT AUTHORITY\SYSTEM` blocks an interactive test run by a person and
  reports it as though something were already listening. Check with
  `netsh http show urlacl url=https://+:5000/appfilter/`.
- A URL carries **one** reservation. Testing as yourself means deleting and
  re-adding it — or skip the churn and test through the scheduled task, which
  runs as the account the reservation already names.

## 9. Open the firewall, to the domain profile only

**Done:**

```
New-NetFirewallRule -DisplayName "Refresh App List" -Direction Inbound `
  -Protocol TCP -LocalPort 5000 -Profile Domain -Action Allow
```

**For:** Nothing reaches the listener otherwise.

**Why `-Profile Domain`:** the rule applies only while the machine is on the
corporate network. It is one of the two reasons the service is not reachable
from outside or from the guest network.

## 10. Make it survive a reboot — a scheduled task as SYSTEM

**Done:** A scheduled task, trigger **At startup**, running as
`NT AUTHORITY\SYSTEM`, execution time limit **disabled**, restart on failure a
minute apart.

**For:** A lab machine reboots for patching. Without this, the service is down
until somebody notices.

**Alternatives considered:**

| Option | Why not |
|---|---|
| Startup folder | Needs a logged-in user session. The machine sits at a locked screen for weeks. |
| `Run` registry key | Same problem. |
| A real Windows service | PowerShell scripts cannot be services directly; it needs a wrapper such as NSSM or WinSW — another dependency to install, document and justify. |

**Why this one:** it is the only no-dependency way Windows starts a console
program at boot with nobody logged in. And it turned out to fix the
authentication problem for free — see §12.

**The four settings that are not optional**, each for a specific failure:

- **Run as SYSTEM** — also what makes Kerberos work (§12).
- **At startup**, not at logon — nobody logs in.
- **Execution time limit disabled** — the default kills a task after three
  days, which would silently stop the server mid-week.
- **Restart on failure** — the script exits 1 on a startup failure; without
  this the task simply stays dead.

**There is no console under the task**, so `Write-Host` goes nowhere.
`Write-ServerLog` therefore writes `STARTED` (with URL, auth scheme, credential
source, rule count and PID), `FAILED TO START` with the reason, and `STOPPED`.
Without those lines, a server that died at startup looks exactly like one that
is running and idle.

**It took two attempts**, and the lesson is worth repeating: **register the
task with `*>` output capture in its action from the outset.** The first
attempt failed with exit code 1 and nothing in the log, which sent the
diagnosis down a wrong path entirely (a Constrained Language Mode theory that
turned out to be false — `HttpListener` and `HMACSHA256` construct fine as
SYSTEM). What fixed it was a clean starting state plus the task's own output.
Capture costs nothing and is the difference between one round and four.

## 11. Serve HTTPS — find the certificate, bind it to the port

**Done:** `Find-ServerCertificate.ps1` to locate a usable certificate, then:

```
netsh http add sslcert ipport=0.0.0.0:5000 certhash=<thumbprint> "appid={<any guid>}" certstorename=MY
```

and the listener prefix becomes `https://+:5000/appfilter/` via `-UseHttps`.

**For:** Plain HTTP puts serials and the returned inventory on the wire in
clear text, and shows "Not secure" in the address bar — which invites the
question "is this thing safe?" at exactly the wrong moment.

**Alternatives considered:**

- **A self-signed certificate.** Browsers warn about it just as loudly. No
  gain.
- **Leaving it on HTTP.** Windows authentication is challenge–response, so no
  reusable password crosses the wire even on HTTP — but the serials and the
  inventory do.

**Why this one:** the machine already had an auto-enrolled certificate from
internal PKI, trusted by every domain client because the CA is in their trust
store. Nothing had to be requested from anyone.

**Four things that bit, all of them worth keeping:**

- **Quote the `appid`.** Unquoted, PowerShell parses `{...}` as a script block
  and reads parts of the GUID as an expression. It fails *intermittently* —
  measured at 13 of 200 random GUIDs, 0 of 200 once quoted — because the
  failures are the ones containing `<digits>e<digits>`, which PowerShell reads
  as scientific notation. So it works about nine times in ten and then fails
  for no visible reason. Same applies to `user="NT AUTHORITY\SYSTEM"`.
- **A port is HTTP or HTTPS in http.sys, never both.** TLS binds per
  `ip:port`, so the whole port is one or the other whatever the paths under it.
  The existing `http://+:5000/appfilter/` reservation therefore *blocked* the
  https one, and `netsh http add urlacl` for the https URL quietly failed to
  take while `show urlacl` for it returned nothing. **Moving to HTTPS means
  deleting the HTTP reservation, not adding a second one** — and technicians'
  http bookmarks stop working at that moment, which is intended.
- **A missing or wrong binding does not fail at startup.** The listener starts
  happily and every connection is reset, which reads as "the site won't load"
  rather than "the certificate is wrong". Check with
  `netsh http show sslcert ipport=0.0.0.0:5000`.
- **Hand out the FQDN, not the short name.** Kerberos accepts either — a
  machine account registers `HOST/shortname` *and* `HOST/fqdn` — but the
  certificate names only the FQDN, so the short name gives
  `NET::ERR_CERT_COMMON_NAME_INVALID` with TLS otherwise working perfectly. An
  IP address fails the same way.

**One diagnostic mistake to remember.** The certificate finder originally used
`Test-Certificate -SSLServerAuthentication` and collapsed every failure into
"does not chain cleanly" — which was actively misleading, because an
unreachable CRL fails identically to an untrusted root, and browsers soft-fail
revocation anyway. It now builds the chain twice, with revocation checking off
and on, and reports the real `ChainStatus`. The verdict flipped to *trusted*.
That bug nearly sent us to ask PKI for a certificate we already had.

**The scheduled outage nobody schedules:** the http.sys binding pins a
**thumbprint**. A renewed certificate is a different certificate with a
different thumbprint, so the binding still points at the old one and
connections start failing with nothing on the machine having changed.
Auto-enrolled machine certificates renew on their own, which makes this a
matter of *when*, not *if*. Re-run the binding after any renewal. The current
certificate expires **Dec 2026**; the finder warns under 120 days.

## 12. Silent single sign-on — solved by running as SYSTEM

**Done:** Nothing, in the end. Running the task as `NT AUTHORITY\SYSTEM` fixed
it for free.

**The problem:** browsing to the server by hostname produced a credential
prompt that then *rejected correct credentials* and prompted again. Meanwhile
`Invoke-WebRequest -UseDefaultCredentials` returned 200 against the same
server, and browsing by bare **IP address** authenticated first try.

**The diagnosis** those two facts force: it is a missing SPN, not a browser
fault. PowerShell got in over NTLM. The browser was offered Negotiate, tried
Kerberos, looked for an `HTTP/<host>` SPN registered to the account running the
listener, found none, and re-prompted rather than falling back. The IP worked
precisely because browsers do **not** attempt Kerberos against an IP literal —
there is no name to derive an SPN from — so it forced the NTLM fallback the
hostname never reached.

**Four ways out were on the table:**

| Option | Cost | Verdict |
|---|---|---|
| Hand out the IP | Free | **Rejected.** The address moves unless reserved, and a bare IP usually lands in the browser's Internet zone — so a credential prompt every session, which is friction pushing directly against the ease-of-use the tool exists for. It is also what starts people asking to turn authentication off. |
| `-AuthScheme Ntlm` | Free, a parameter | Kept as an escape hatch; not in use. |
| Add the host to the Local intranet zone by GPO | A GPO change and a conversation | Not needed. |
| `setspn -S HTTP/<host> DOMAIN\Account` | A domain admin | Not needed. |

**Why the answer was free:** running as SYSTEM makes the listener the
**machine account**, and a machine account already owns `HOST/<host>` — and
`HOST/` covers the HTTP service class. So Kerberos works on the FQDN with no
`setspn`, no domain admin, and no registry or GPO change. Verified on the live
machine: Edge signs in silently, and the log names the domain account.

That single decision closed a question that had shaped three earlier ones.

## 13. Security audit

**Done:** A full read of the application plus live probing, 16 Sep 2026. Nine
findings.

| | Finding | State |
|---|---|---|
| H-1 | No authorization — any domain account is served | **Open, deferred** by decision |
| H-2 | API key readable by anyone who can log into the machine | **Accepted** after reassessment |
| H-3 | Absolute token had no IP restriction | **Closed** — Approved IP Addresses set, verified by a rejected request from a non-approved address |
| M-1 | Exception text rendered to the browser | **Fixed** — generic sentence on the page, detail to the log |
| M-2 | No rate limiting; single-threaded | **Accepted** |
| L-1 | No security response headers | **Fixed** — CSP, nosniff, frame-deny, referrer policy |
| L-2 | CSV formula injection | **Fixed**, round-trip safe |
| L-3 | Logs grew without bound | **Fixed** — rotates at 5 MB, one generation kept |
| L-4 | `-Anonymous` served the network with only a warning | **Fixed** — refused unless `-AllowAnonymousOnNetwork` is also given |

Two of these are worth understanding rather than just listing:

**H-2 was first written as urgent, and that was wrong.** The file ACL does
grant `Authenticated Users: Modify`, inherited from the root of `C:\`, which
reads as "every domain account can rewrite a script SYSTEM runs at boot". But
reaching those files needs an interactive logon or the administrative share,
and **both require local administrator rights**. The effective population is
the machine's administrators — who are the technicians, who can reset any
permission at will. Tightening the ACL would constrain nobody. The real
question is not permissions but logins: *who needs interactive access to that
machine?* Narrowing that, not the ACL, is what would restore the property the
server was built for.

**L-2, the CSV escaping, is a pair and must stay one.**
`ConvertTo-CsvSafeText` prefixes an apostrophe on write;
`ConvertFrom-CsvSafeText` removes it on read. Escaping *without* the matching
un-escape would silently stop every affected rule from matching the application
it came from — a fix that breaks the tool quietly. Verified by round-trip.

**The deliberate gap:** there is authentication but no **authorization**. Any
domain account that can reach the port is served; the caller is logged but
never checked. The fix is about fifteen lines — an `-AllowedGroup` parameter
and a `WindowsPrincipal.IsInRole` test in the request loop, refusals logged,
defaulting to today's behaviour. Raised, understood, deferred pending a
decision on which AD group. Not overlooked.

## 14. Show the suppressed applications on the sheet

**Done:** A collapsed block under the sheet footer listing every suppressed
application with its version, grouped by the reason that caught it.

**For:** The sheet used to state only a count — "213 of 260 suppressed". A
technician whose user says "where is Visio?" could not tell whether it had been
filtered as base-image noise or was never in the inventory at all. The list
existed, but only behind `-ShowFiltered` on the console, which is no use to the
person standing at the machine.

**Why it is collapsed and screen-only:** it answers a lookup, not a browse. It
must not turn the printed sheet into a second list to work through, so it
carries `class="screen-only"` and never reaches the printer. No JavaScript, so
the server's Content-Security-Policy did not have to change.

**Alternative considered:** a search box that reports whether a name was
filtered. More precise, but it needs script, which means another CSP hash and
more moving parts for a question that a collapsed list answers.

## 15. Fixed "1 of 0"

**Done:** Wrapped `$classified` in `@()` inside `Get-RefreshApps`.

**For:** A device whose entire inventory was one application — BitLocker,
suppressed — printed `1 of 0 inventoried applications` on its sheet.

**Why it happened:** a `foreach` that produces exactly one row hands back the
object itself, not a one-element array, and `.Count` on a scalar comes back
`$null` in Windows PowerShell 5.1. `$result.Apps.Count` therefore arrived at
the renderer as `$null`, cast to `0`. Every other collection in that function
was already `@()`-wrapped; this one was not. The same `$null` also made the
server's no-inventory guard compare `$null -eq 0` and fall through — harmless
in this instance, but the guard was not deciding, it was being skipped.

The sheet footer now also raises its total to at least the parts it can see, so
arithmetic that cannot be true cannot reach a technician again.

---

# Part II — Authentication, and why sign-in is silent

There are **two separate authentication systems** in this tool and they have
nothing to do with each other. Conflating them is the most common way to get
confused about it.

```
  Technician's browser  ──── Windows Integrated auth (Kerberos) ───▶  The server
                                                                          │
                                                                          │ JWS + HMAC-SHA256
                                                                          ▼
                                                                   Absolute API
```

## Browser to server: Windows Integrated Authentication

The listener is configured with
`AuthenticationSchemes = IntegratedWindowsAuthentication`. In practice:

1. The browser requests the page with no credentials.
2. The server replies **401** with `WWW-Authenticate: Negotiate`.
3. The browser asks Windows for a Kerberos ticket for the service
   `HTTP/<lab-machine>.<domain>`, using the logon session the user already has.
4. Windows hands back a ticket without asking anybody anything — the user
   authenticated to the domain when they logged into their PC that morning.
5. The browser resends the request with the ticket. The server accepts it, and
   `$context.User.Identity.Name` is the technician's domain account.

**Why it is silent.** Nothing about it is unusual — it is the same mechanism
that opens a file share without a prompt. Three conditions have to hold, and
all three do:

- **The user has a valid Kerberos TGT**, which they got by logging into a
  domain-joined machine.
- **An SPN exists for the service name being browsed**, registered to the
  account running the listener. This is the condition that failed at first, and
  the one that running as SYSTEM satisfied: the machine account already owns
  `HOST/<host>`, and `HOST/` covers HTTP. Nothing was registered by hand.
- **The site is in the browser's Local intranet zone**, which is what permits
  sending default credentials without asking. A dotted FQDN on the corporate
  network qualifies automatically under the default zone rules; a bare IP
  address usually does not — which is the second reason the IP workaround was
  rejected.

**If it ever starts prompting again**, the order to check is: is the URL the
FQDN (not the short name, not an IP)? Is the task still running as SYSTEM? Has
the certificate been renewed without re-binding — because a TLS failure can
present as an authentication failure to a user who only sees "it's asking me to
sign in"?

**What the identity is used for:** logging, and nothing else. Every request
writes the caller's account name to `RefreshAppServer.log`, so every lookup is
attributable to a person. That is a property the console tool — one shared
token across every copy — can never have. There is no group check (see H-1
above).

**Escape hatch:** `-AuthScheme Ntlm` forces NTLM if Kerberos ever becomes a
problem. Not in use.

## Server to Absolute: JWS with HMAC-SHA256

Entirely separate, and not related to who the technician is. The server holds
one API token — an ID and a secret — and signs each request:

1. Build a JSON header: `alg`, `kid` (the token ID), `method`, `content-type`,
   `uri`, `query-string`, `issuedAt` (current UTC epoch milliseconds).
2. base64url-encode that header and a `{}` payload.
3. HMAC-SHA256 over `header.payload`, with the API secret as a UTF-8 key.
4. POST `header.payload.signature` to `https://api.absolute.com/jws/validate`
   as `text/plain`.

The secret never crosses the wire — only a signature computed with it. The
request being signed includes the URI and the query string, so a captured token
cannot be replayed against a different endpoint.

**The token is IP-restricted** in the Absolute console to the two devices that
need it, so a copy of the secret is inert anywhere else. That restriction, not
the storage location, is the real control.

**The secret is never printed.** `Debug-AbsoluteLookup.ps1` reports which
source supplied the credential and the secret's **length** — never its value.
(That diagnostic once printed the key by accident: `"$($credential.SecretKey).Length"`
closes the subexpression at the parenthesis, so it interpolated the secret and
then the literal text `.Length`. Compute into a variable first.)

---

# Part III — The rules, and how filtering actually works

## Is it a rule engine?

You can call it one and nobody will blink — it is a rule table plus a matcher,
which is the load-bearing half of what "rule engine" usually means. But the
accurate description is shorter and sounds better in a meeting because it
invites no follow-up you cannot answer:

> **It is a three-stage classifier over a rules table. Each application is
> tested against name rules, then publisher rules, then patterns. First match
> wins and says why. Anything unmatched is something the technician has to
> install.**

What it deliberately is **not**: there is no inference, no chaining (one rule
firing does not enable another), no priorities or weights, no scoring, and no
machine learning. Every decision traces to exactly one row in a CSV, which is
why any disputed result can be settled in about thirty seconds.

## The three kinds of rule

All 108 live in `AppRules.csv`, one per row, distinguished by `MatchType`:

| MatchType | Count | Matched against | Example row | Reason it carries |
|---|---|---|---|---|
| `Name` | 82 | the **normalized** application name | `Microsoft Teams` | Base image |
| `Publisher` | 12 | the **normalized** publisher | `Dell` | Driver / OEM |
| `Pattern` | 14 | the **raw** application name, as a regex | `Visual C\+\+` | Runtime / component |

Other columns: `Reason` (what to call a match — data, not code), `Active`
(anything but `Yes` retires a rule without losing its history), `Source`
(provenance), `AddedOn`, `AddedBy`, `Serial`.

A `Pattern` row that is not a valid regex is reported and skipped at load time
rather than blowing up mid-run against a real device.

## The order, and why it is in code

Name, then publisher, then pattern. First match wins.

That order is **not** configurable, deliberately, because it is the
classifier's meaning rather than a preference: **a named product beats its
vendor, and a vendor beats a generic pattern.** If it were data, someone could
reorder it and silently change what every rule means — a publisher rule for
`Intel` would start swallowing a named Intel product you had deliberately
listed as an install candidate.

## Normalization, with worked examples

Both sides of a `Name` comparison go through `ConvertTo-NormalizedAppName`:

| Absolute reports | Normalized key |
|---|---|
| `Tanium Client 7.8.1.3126` | `tanium client` |
| `Tanium Client 7.9.2.1` | `tanium client` |
| `7-Zip 19.00 (x64 edition)` | `7-zip` |
| `7-Zip 24.09 (x64)` | `7-zip` |
| `Microsoft Visual C++ 2012 Redistributable (x64) - 11.0.61030` | `microsoft visual c++ 2012 redistributable` |
| `Thunderbolt™ Software` | `thunderbolt software` |
| `Intel® Optane™ Memory and Storage Management` | `intel optane memory and storage management` |
| `Node.js (64-bit)` | `node.js` |
| `  Google   Chrome  ` | `google chrome` |

What it strips, in order: trademark marks (`™ ® ©`); architecture and edition
parentheticals (`(x64)`, `(x86 edition)`, `(64-bit)`); and a trailing version
in the three shapes that actually occur — dash-separated (`... - 11.0.61030`),
`v`-prefixed (`... v14`), and dotted with two or more parts
(`... 7.8.1.3126`). Then it collapses whitespace and lowercases.

**A bare trailing integer is deliberately not treated as a version**, so
`Microsoft 365`, `Paint 3D` and `OneNote for Windows 10` keep their numbers. A
version stripper that ate them would merge genuinely different products.

Publisher rules go through `ConvertTo-NormalizedPublisher`, which strips
trademark marks, punctuation, and **trailing** corporate suffixes — `Inc`,
`Corp`, `Corporation`, `Company`, `Ltd`, `LLC`, `GmbH`, `Technologies`,
`Software`, `Semiconductor`, `Systems`, `Electronics`, `Group`, `Holdings`,
`Products` — repeatedly, until none is left:

| Absolute reports | Normalized key |
|---|---|
| `Dell`, `Dell Inc.`, `Dell Technologies`, `Dell Products` | `dell` |
| `Realtek Semiconductor` | `realtek` |
| `INTEL`, `Intel Corporation` | `intel` |

One row per company is therefore enough. Suffixes come off the **end only**, so
`Advanced Micro Devices` and `Alps Electric` keep the words that distinguish
them.

**This fixed two live gaps found on real runs:** `Dell Technologies` (on
`Dell Optimizer`, `Dell Trusted Device`) and `Dell Products` (on
`Dell Digital Delivery`) were both escaping the driver rule under the old
exact-match list — they were being reported to technicians as software to
install by hand.

## Worked example: classifying six applications

Rules in play: name rule `BitLocker Drive Encryption`; publisher rule `Dell`;
pattern rules `Visual C\+\+` and `Driver`.

| Application (as Absolute reports it) | Publisher | What happens | Result |
|---|---|---|---|
| `BitLocker Drive Encryption` | Microsoft | normalizes to `bitlocker drive encryption`, hits a **name** rule | Suppressed — Base image |
| `Dell Optimizer` | Dell Technologies | no name rule; publisher normalizes to `dell`, hits a **publisher** rule | Suppressed — Driver / OEM |
| `Microsoft Visual C++ 2012 Redistributable (x64) - 11.0.61030` | Microsoft | no name or publisher rule; raw name matches the **pattern** `Visual C\+\+` | Suppressed — Runtime / component |
| `Realtek Audio Driver` | Realtek Semiconductor | publisher normalizes to `realtek`, hits a **publisher** rule before the `Driver` pattern is ever reached | Suppressed — Driver / OEM |
| `Bluebeam Revu 21` | Bluebeam, Inc. | no name rule (`bluebeam revu 21` — the bare `21` is kept, and there is no such row); publisher `bluebeam` is not in the driver list; no pattern matches | **Install candidate** |
| `7-Zip 24.09 (x64)` | Igor Pavlov | normalizes to `7-zip`; deliberately **not** a rule — it is not in the image | **Install candidate** |

The last two are the output. Everything else is noise the technician never has
to read.

## Where the rules came from

Not guesswork. Every row carries its `Source`:

- **62** `image-intersection` — present on both known base-image devices
- **26** `builtin` — the publisher and pattern rules carried over from the
  arrays that used to live in the script
- **10** `carried-over` — inbox Store apps and product-name variants the two
  sampled devices did not report (`Camera`, `Microsoft Store`, `Maps`,
  `3D Viewer`, `Paint 3D`, `OneNote for Windows 10`, Microsoft 365 variants,
  the Teams add-in entries). The devices being refreshed are old, so old-image
  names still need to match.
- **6** `hand-review` — inbox apps confirmed by hand off a real run
- **3** `hand-review-1of2` — landed in the "on one of two devices" bucket and
  were judged base image by hand
- **1** `name-variant` — a short name Absolute reports where the baseline held
  a longer one

Anything added later through the console curation prompt is stamped
`refresh-prompt`, with the operator and the serial it came from.

One normalization collision exists — the x86 and x64 rows of the same Visual
C++ redistributable — and it is harmless, because the rules are a set.

## Adding or removing a rule

**Adding is a data edit**, not a code change. Two ways:

1. **From a run.** `Get-RefreshAppList.ps1 <serial>` numbers the install list
   and asks whether any of them belong on the base image list. Picking numbers
   writes the rows, stamped with who added them and from which device. It tells
   you when a name rule will match more broadly than the name on screen,
   because the key is normalized.
2. **By hand**, editing `AppRules.csv`.

**Removing** is setting `Active` to anything but `Yes` — the row stays as
history.

**The web front end cannot write rules, on purpose.** Curation is
console-only; letting a browser write to `AppRules.csv` deserves its own
thought before it happens.

## What the filter does not do

- **It never compares versions.** Name only. An older version of a base-image
  application is still base image.
- **It has no per-user or per-department logic.** Every device is filtered
  against the same rules.
- **It does not know what the new image contains today.** It knows what two
  sampled base-image devices contained when the baseline was built. If the
  image changes materially, the baseline should be rebuilt.
- **An empty install list is a real answer**, not a failure — it means nothing
  beyond what the image provides.

---

# Appendix A — Current deployment, in commands

Placeholders: `<lab-machine>.<domain>`, `<thumbprint>`, `<guid>`.

```powershell
# 1. Files on the machine: AppFilter.psm1, AppRules.csv, Start-RefreshAppServer.ps1
#    with the token filled in at the top of the server script.

# 2. Reserve the URL for the account that will run it
netsh http add urlacl url=https://+:5000/appfilter/ user="NT AUTHORITY\SYSTEM"

# 3. Bind the certificate to the port (quote the appid)
netsh http add sslcert ipport=0.0.0.0:5000 certhash=<thumbprint> "appid={<guid>}" certstorename=MY

# 4. Open the port, domain profile only
New-NetFirewallRule -DisplayName "Refresh App List" -Direction Inbound `
  -Protocol TCP -LocalPort 5000 -Profile Domain -Action Allow

# 5. Scheduled task: At startup, run as NT AUTHORITY\SYSTEM,
#    execution time limit disabled, restart on failure.
#    Action captures its own output:
#      powershell.exe -NoProfile -File "<install-path>\Start-RefreshAppServer.ps1" -UseHttps *> "<install-path>\task-output.log"
```

Checks worth knowing:

```powershell
netsh http show urlacl url=https://+:5000/appfilter/   # who holds the reservation
netsh http show sslcert ipport=0.0.0.0:5000            # which cert is bound
Get-NetTCPConnection -LocalPort 5000 -State Listen     # something already listening?
```

# Appendix B — What is verified, and what is not

Verified on the live machine: the API client against the real tenant; the
scheduled task surviving a real reboot; silent Kerberos sign-in in Edge with no
GPO and no `setspn`; the certificate chaining cleanly to the enterprise CA with
online revocation passing; a real lookup returning `16 to install of 72`
attributed to a domain account; the token's IP restriction rejecting a request
from a non-approved address; and the reflected-XSS fix, confirmed against the
running server before and after.

Tested against a mocked API or in isolation: all routes, the injection cases,
the log, four concurrent requests, and the full rule set (94 assertions in
`Test-AppFilter.ps1`).

**Not yet exercised: a lookup from a second machine by a second person.** Every
real lookup so far has been from the lab machine under one account. The case
that matters to the attribution story — a technician at their own desk, their
name in the log — rests on reasoning rather than evidence.

# Appendix C — Open items

| Item | State |
|---|---|
| Authorization (`-AllowedGroup`) — restrict to a technicians' AD group | Deferred, pending the decision on which group. ~15 lines. |
| Who may log into the lab machine interactively | Raised with the audit; a supervisor conversation, not a code change |
| Widen the baseline beyond two sampled devices | When more known-good devices are available |
| Certificate renewal will break HTTPS silently | Re-run the `sslcert` binding after any renewal. Current cert expires Dec 2026 |
| API token expires Jan 7, 2027 | Rotation means editing the front ends on the machine |
| Single-threaded request handling | Fine for current use; first thing to change if it is not |
