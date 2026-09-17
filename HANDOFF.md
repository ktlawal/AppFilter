# Absolute refresh-app-list — handoff context

## Goal

During the device refresh cycle, techs need a list of applications to manually
install on a user's new machine. Pull the old device's installed-application
inventory from Absolute, subtract everything the new machine gets anyway
(base image, drivers, runtimes), and print what's left.

No install automation yet — a list for a human is the deliverable. Automating
installs (Intune group membership) is a possible later phase.

## Environment

- Windows. **Assume Windows PowerShell 5.1 unless you have checked.** The
  working copy on the operator's machine is running 5.1 — its error format
  (`+ CategoryInfo`) and its lack of `.Count` on a scalar gave it away. Write
  for 5.1 and it also runs on 7; the reverse is not true.
- Working dir: `D:\AbsoluteApplicationList`
- Absolute API token ID + secret are pasted into the top of whichever front
  end is being run — `Get-RefreshAppList.ps1` or `Start-RefreshAppServer.ps1`
  — with environment variables as a fallback; see Credentials. The module
  itself holds no credential: it takes one as a parameter.

## Credentials

The token ID and secret are pasted into the top of each front end —
`Get-RefreshAppList.ps1` and `Start-RefreshAppServer.ps1` — and handed to the
module as parameters. If those are left as the `TOKEN HERE` / `KEY HERE`
placeholders, the script falls back to `ABSOLUTE_TOKEN_ID` and
`ABSOLUTE_SECRET_KEY` from the environment — which is how a server or scheduled task would supply it without
the file carrying the key.

The values in the file win when they are filled in. A recipient's leftover
environment variables should not quietly take over from the copy the
distributor intended them to use. `-Verbose` reports which source answered.

**This is a deliberate step back, taken so the tool can be handed to the team
before a shared-credential story exists.** Everything below applies to handing
out `Get-RefreshAppList.ps1`. **The web front end is the way out of it:** with
`Start-RefreshAppServer.ps1` on one lab machine, that machine holds the only
copy of the key and technicians get a URL instead of a script. Nothing to
distribute means nothing to rotate and nothing to leak. What follows is the
cost of the console route.

What it means in practice:

- **The script file *is* the credential.** Do not screen-share it, attach it to
  a ticket, put it on a flash drive that leaves the building, or commit it.
- **Rotation means redistribution.** Changing the key means getting a new copy
  of the file to everyone who has one. Note the token expires **Jan 7, 2027**.
- **There is no attribution.** Every call from every copy looks identical in
  Absolute's logs. If it leaks, you cannot tell whose copy.
- **Anyone holding the file can read the key**, so this only ever makes sense
  for people already trusted with the tenant's inventory data.

**Approved IP Addresses on the token is therefore no longer optional.** It is
the only remaining control that limits what a leaked copy can do: restrict the
token to the corporate egress range and the key stops working anywhere else.
Set it in the Absolute console, under the token's API Management page.

### Three richer routes were built and removed

All three worked. They came out as the scope narrowed to a single operator, and
the commit history has each of them.

- **SharePoint via Microsoft Graph** (`-KeyUrl`). Blocked by tenant policy, not
  by the code: a real attempt returned **AADSTS50105** — the *Microsoft Graph
  Command Line Tools* app (`14d82eec-204b-4c2f-b7e8-296a70dab67e`) has
  "assignment required" set and the operator was not assigned. Getting past it
  needs an admin assignment to that app, or a dedicated Entra app registration
  with delegated `Files.Read.All`.
- **A shared key file by path** (`-KeyPath`), covering a network drive, a UNC
  share, or SharePoint over WebDAV. No Entra app needed — Windows authenticates
  as the caller.
- **A DPAPI-encrypted local file** written by `Set-AbsoluteCredential.ps1`,
  which decrypted only for the account and machine that wrote it, so a copied
  file was inert.

The trade, if any of them is ever wanted back: a **shared file** gives central
rotation and revocation. **DPAPI** gives a credential that is inert if copied.
**Environment variables** give neither but keep the secret out of the script.
The key in the script, where it is now, gives none of the three — it is the
simplest thing that works for distribution today, and the first thing to
revisit when there is somewhere better to put it.

### What actually protects the token

**Approved IP Addresses**, set on the token in Absolute. A leaked key stops
working outside the corporate network. That control is independent of every
storage decision above and does more than any of them. Token expiry (currently
Jan 7, 2027) bounds the damage regardless.

## Absolute API — verified facts

Everything below was determined empirically against a live tenant. Do not
assume the public docs match; several things differ.

### Authentication

v3 uses a JWS flow, not signed HTTP headers:

1. Build a JWS header containing `alg`, `kid` (token ID), `method`,
   `content-type`, `uri`, `query-string`, `issuedAt`
2. `issuedAt` = **current** UTC epoch milliseconds. Do NOT offset it into the
   future — that causes intermittent 401s.
3. base64url-encode header and payload (`{}` for GET), sign
   `header.payload` with HMAC-SHA256 using the secret as a UTF-8 key
4. POST the resulting `header.payload.signature` token to
   `https://api.absolute.com/jws/validate` with `Content-Type: text/plain`

The target endpoint lives in the JWS header's `uri` and `query-string` fields;
the actual POST always goes to `/jws/validate`.

### Endpoints

| Path | Status |
|---|---|
| `/v3/reporting/devices` | works |
| `/v3/reporting/applications` | works — this is the software inventory |
| `/v2/...` anything | 404 — v2 is not routed through `/jws/validate` on this tenant |
| `/v3/reporting/device-applications` | 403 at the nginx edge (does not exist) |
| `/v3/sw/deviceapplications` | 403 at the nginx edge (does not exist) |

A 403 returning **HTML** means the edge gateway rejected a nonexistent path.
A real API error returns JSON. Don't confuse the two for a permissions problem.

### Response shape and pagination

```json
{ "data": [ ... ], "metadata": { "pagination": { "nextPage": "<token>" } } }
```

- `pageSize` max is **500** (400 error above that)
- continuation token is at `metadata.pagination.nextPage` — nested two levels,
  easy to miss, and missing it silently truncates to the first page
- pass it back as a `nextPage=` query param, URI-encoded (it's base64 with `==`)

### Query parameters

v3 does NOT use OData (`$top`/`$skip`/`$filter`). It uses plain named params:
`serialNumber=`, `deviceName=`, `deviceUid=`, `pageSize=`, `nextPage=`,
`select=`, `sortBy=field:order`.

`deviceUid=` on `/v3/reporting/applications` appears to filter correctly, but
the scripts verify this at runtime rather than trusting it.

### Field names

Devices (`/v3/reporting/devices`) — note these differ from v2:
`deviceUid`, `esn`, `deviceName`, `fullSystemName`, `serialNumber` (not
`serial`), `username` (lowercase n), `systemModel`, `agentStatus`
(`A` = active, `D` = disabled), `lastConnectedDateTimeUtc`,
`firstCallDateTimeUtc`. OS is nested: `operatingSystem.name`.
No application data at any depth.

Applications (`/v3/reporting/applications`):
`deviceUid`, `accountUid`, `appName`, `esn`, `deviceName`,
`deviceSerialNumber`, `userName`, `installPath`, `installDateTimeUtc`,
`osName`, `major`, `minor`, `deviceAppId`, `appId`, `appOriginalName`,
`appPublisher`, `appOriginalPublisher`, `appVersion`, `appOriginalVersion`,
`firstDetectDateTimeUtc`, `lastScanDateTimeUtc`.

Date fields are ISO strings that `ConvertFrom-Json` parses into real
`[datetime]` objects — do NOT apply epoch-millisecond conversion.

`appName` is Absolute's normalized name; `appOriginalName` is the raw
publisher string. Match on `appName`.

## PowerShell gotchas already hit (don't reintroduce)

- **A single-element array unrolls on its way out of a function, and in 5.1
  the resulting scalar has no `.Count`.** `return @($one)` gives the caller a
  bare object. PowerShell 7 synthesises `.Count` = 1 for any scalar, 5.1 does
  not — it returns nothing. So `(Get-PageData $x).Count` passed on 7 and
  failed on 5.1. `foreach` over a scalar is fine, which is why only the test
  broke. Wrap the call in `@()` when you need a count.
- **`"$($x).Length"` prints `$x` followed by the literal text `.Length`.** The
  subexpression closes at the paren. This shipped in a first draft of
  `Debug-AbsoluteLookup.ps1` and printed the API secret to the console.
  Compute into a variable first, and never interpolate a secret at all.
- **Do NOT put `Set-StrictMode` in `AppFilter.psm1`.** It was added during the
  module split and broke the tool on the very first real run. Under StrictMode
  reading a property that does not exist is a *terminating error*, and this
  module reads a JSON API whose fields come and go: Absolute's envelope carries
  `metadata` with **no `pagination` property** until there actually is a next
  page, so every ordinary one-page result died on
  `$response.metadata.pagination`. The same hazard applies to
  `lastScanDateTimeUtc` on an app row and to every optional device field.
  Missing-property-is-null is load-bearing. Read anything that came off the
  wire through `Get-DataProperty`. There is a comment to this effect at the top
  of the module; leave it there. Note the mock could not catch this because its
  fixture used `metadata = $null` — **make a fixture match the real shape or it
  proves nothing.**
- **An empty array returned from a function collapses to `$null`.** So a field
  holding `@()` is indistinguishable from an absent one once it has passed
  through a `return`. This bit immediately after the fix above: `data = @()`
  on a serial that matched nothing looked absent, fell through to the "response
  is not wrapped" branch, and handed back **the envelope itself as if it were a
  device** — the user saw "no application inventory" instead of "no device
  matched". Where the difference matters, test
  `$obj.PSObject.Properties['name']` for presence rather than looking at the
  value, as `Get-PageData` does.
- **No ternary `? :` and no `??`.** They are PowerShell 7 syntax. The target
  here is 7, but a lab machine may well be on stock 5.1, and a parse error
  takes the whole file down before a single line runs. `Start-RefreshAppServer.ps1`
  had two and they were removed. Use `if`/`else`.
- **`ConvertTo-HtmlText` has to escape quotes, not just angle brackets.** It
  originally did `& < >` only, which was harmless while every interpolation
  was element text. The server puts a rejected serial into `value="..."`, and
  a serial of `" autofocus onfocus="alert(1)` escaped the attribute and
  injected a working event handler — confirmed against the running server
  before the fix. `Test-AppFilter.ps1` now asserts all five characters.
  Escape `&` first or the escapes get re-escaped.
- **`[IO.Path]::GetFullPath($path, $base)` is .NET Core only.** The
  two-argument overload does not exist in Windows PowerShell 5.1, which runs
  on .NET Framework — it fails with "Cannot find an overload for GetFullPath
  and the argument count: 2". Branch on `[IO.Path]::IsPathRooted()` and use
  `Join-Path` instead; that works on both. Hit for real when the script was
  run under 5.1 rather than 7.
- **An unquoted URL with `&` is two commands.** `-KeyUrl https://...?a=1&e=x`
  runs `-KeyUrl https://...?a=1` and then tries to execute `e=x`. Always quote.

- **Array unrolling**: `$x = if (...) { @($single) }` flattens back to a
  scalar. Wrap the whole `if` — `$x = @( if (...) { $single } )`.
- **Function returns**: returning a `List[object]` unrolls; a single-item
  result becomes a scalar. Callers must wrap in `@()`. Using `return ,$list`
  instead breaks the empty case (produces one phantom null item).
- **Hashtable vs array**: `$h.ContainsKey($k)` succeeds via member enumeration
  even when `$h` is an *array* of hashtables, then `$h[$k]` throws "Argument
  types do not match". Use
  `[System.Collections.Generic.Dictionary[string,...]]` with `TryGetValue`.
- **Error handling**: PS7 exceptions carry `HttpResponseMessage`, which has no
  `GetResponseStream()`. Read the body from `$_.ErrorDetails.Message`; keep
  the 5.1 stream path behind a method-existence check.
- **Variable names are case-insensitive**: `$driverPublishers = ...` silently
  overwrites `$DriverPublishers`. This was hit for real — a lookup set built
  from the config array clobbered the array before the loop read it, and the
  driver rule matched nothing at all while still looking correct. Give derived
  variables a distinct name (`$driverPublisherKeys`), not just a different case.

## Files

- `AppFilter.psm1` — **the engine, and the only place the logic lives.** Both
  front ends import it. Exports `Get-DataProperty`, `Get-PageData` and
  `Get-NextPageToken` for reading anything that came off the wire (see the
  StrictMode gotcha), the normalizers, `Import-AppRule`,
  `Get-AppClassification`, `Add-AppRule`, `Get-AbsoluteCredential`,
  `Invoke-AbsoluteApi`, `Get-AbsoluteV3`, `Get-RefreshApps`,
  `New-InstallSheetHtml`, `ConvertTo-HtmlText`, `Save-InstallSheet`,
  `Read-IndexSelection`, `ConvertTo-Base64Url`. The API functions take
  `-TokenId`/`-SecretKey` as parameters rather than reading a script-scope
  variable, which is what let a second front end exist at all.
  `Get-RefreshApps` is the one call that does everything: it returns an object
  with `.Found`, `.Device`, `.Apps`, `.ToInstall`, `.Excluded`, `.ScanAge`,
  `.Matched` and `.Message`. Put new behaviour here, not in a front end.
- `Get-RefreshAppList.ps1` — console front end. `[-Serial <serial>]`
  `[-ShowFiltered]` `[-NoPrompt]` `[-RulesCsv <path>]` `[-OutputCsv <path>]`
  `[-OutputHtml <path>]` `[-NoSheet]`. With no serial and no device name it
  asks for a serial; an empty answer exits without doing anything.
  `-BaselineCsv` still works as an alias for `-RulesCsv`. It is now output and
  prompting only — roughly 250 lines where it used to be 890.
- `Start-RefreshAppServer.ps1` — web front end, for the always-on lab machine.
  `[-Port <n>]` (5000) `[-BindAddress <addr>]` (`+`) `[-RulesCsv <path>]`
  `[-Anonymous]` `[-AuthScheme <scheme>]` `[-LogPath <path>]`. See **Web front
  end** below.
- `AppRules.csv` — **all** suppression rules, columns
  `Rule,MatchType,Reason,Publisher,Active,Source,AddedOn,AddedBy,Serial`.
  Replaces `BaseImageApps.csv` and the two hardcoded arrays that used to live
  in the script.
- `Find-ServerCertificate.ps1` — read-only. Lists the local machine
  certificates that could serve https for this machine, with a verdict and a
  reason for each rejection, and prints the binding command. See the https
  section under **Web front end**.
- `Debug-AbsoluteLookup.ps1` — run this when a lookup says "no device matched"
  for a device you know exists. It prints the PowerShell version, which
  credential source answered, and the raw response shape for both an
  unfiltered device query and the failing serial. That separates a
  wrong-tenant token, a token that cannot read devices, and a serial that
  genuinely is not there — three causes that look identical from the tool.
  It never prints the secret, only its length.
- `Test-AppFilter.ps1` — asserts both normalizers and the HTML escaper, loads
  the rules file, and classifies two real device inventories against the bucket
  a human confirmed for each. It imports `AppFilter.psm1` and never calls the
  API, so it needs no credential; it also parses both front ends so a syntax
  error surfaces here rather than in front of a technician. **Run it after
  touching a normalizer or the rules file** — the classification cases are the
  regression net. 64 cases, all passing.
- `Build-BaseImageList.ps1` — builds the baseline empirically by intersecting
  the inventories of known base-image devices, and prints an "on some devices"
  bucket for anything short of unanimous. This is now the source of
  `BaseImageApps.csv`. Not carried into this repo yet; it still lives only in
  `D:\AbsoluteApplicationList`.

## How classification works

Every rule lives in `AppRules.csv`, one per row, distinguished by `MatchType`:

| MatchType | Matched against | Example rule | Reason |
|---|---|---|---|
| `Name` | normalized `appName` | `Microsoft Teams` | Base image |
| `Publisher` | normalized `appPublisher` | `Dell` | Driver / OEM |
| `Pattern` | raw `appName`, as a regex | `Visual C\+\+` | Runtime / component |

`Active` set to anything but `Yes` retires a rule without losing its history.
A `Pattern` row that is not a valid regex is reported and skipped rather than
blowing up mid-run against a real device.

The `Reason` travels with the rule, so what a match is *called* is data too.
The **order** the three kinds are tried in stays in code, because that ordering
is the classifier's meaning rather than a preference: a named product beats its
vendor, and a vendor beats a generic pattern. First match wins; anything
unmatched is an install candidate.

Both sides of a `Name` comparison go through `ConvertTo-NormalizedAppName`, so
a product matches itself across machines despite version drift:

- strips `™ ® ©`
- strips architecture / edition parentheticals — `(x64)`, `(x86 edition)`,
  `(64-bit)`
- strips a trailing version in the three shapes that actually occur:
  dash-separated (`... - 11.0.61030`), `v`-prefixed (`... v14`), or dotted with
  two or more parts (`Tanium Client 7.8.1.3126`)
- collapses whitespace, lowercases

A bare trailing integer is deliberately **not** treated as a version, so
`Microsoft 365`, `Paint 3D` and `OneNote for Windows 10` keep their numbers.

`Publisher` rules go through `ConvertTo-NormalizedPublisher`, which strips
trademark marks and **trailing** corporate suffixes (`Inc.`, `Corp.`,
`Technologies`, `Software`, `Semiconductor`, `Systems`, `Products`, …) and
lowercases. So `Dell`, `Dell Inc.`, `Dell Technologies` and `Dell Products` all
reach `dell` and one row per company is enough. Suffixes come off the end only,
so `Advanced Micro Devices` and `Alps Electric` keep their distinguishing
words.

That normalization fixed two live gaps found on real runs: `Dell Technologies`
(on `Dell Optimizer`, `Dell Trusted Device`) and `Dell Products` (on
`Dell Digital Delivery`) were both escaping the driver rule under the old
exact-match list. Expect to add a suffix occasionally — a one-word change plus
a test case.

Version is never compared — name only.

**Adding a rule is a data edit.** The publisher and pattern rules used to be
PowerShell arrays; putting them in the same file as the names means the next
`Dell Products` or `Logitech` decision is a row, not a code change and a
redeploy. It is also the shape a SharePoint list wants, so swapping the loader
later touches `Import-AppRule` and nothing else.

## Current state

**In production.** The web front end runs under a scheduled task as
`NT AUTHORITY\SYSTEM` on the lab machine, starts at boot, survived a real
reboot, and serves over https at
`https://<machine-fqdn>:5000/appfilter/`. Technicians sign in silently via
Kerberos; every lookup is logged against their domain account. Real lookups
against live devices return sensible counts (`6 to install of 71`,
`16 to install of 72`).

### The files

| File | What it is | Holds the API key? |
|---|---|---|
| `AppFilter.psm1` | **The engine.** Classifier, Absolute API client, HTML generation, rule read/write. Both front ends import it. Put new behaviour here. | **No** — takes the credential as a parameter |
| `Start-RefreshAppServer.ps1` | **The web front end**, and the one that matters day to day. Runs under the startup task. | **Yes** |
| `Get-RefreshAppList.ps1` | Console front end. Same classifier, plus the curation prompt, which is console-only. | **Yes** |
| `AppRules.csv` | Every suppression rule: 82 name, 12 publisher, 14 pattern. Editing rules is a data change, not a code change. | No |
| `Test-AppFilter.ps1` | 94 cases: normalizers, classification against two real inventories, API envelope shapes, HTML escaping, the sheet's suppressed list. Needs no credential and no network. **Run it after touching a normalizer or the rules file.** | No |
| `Debug-AbsoluteLookup.ps1` | Run when a lookup says "no device matched" for a device you believe exists. Separates a wrong-tenant token, a token that cannot read devices, and a serial that is genuinely gone. | **Yes** |
| `Find-ServerCertificate.ps1` | Read-only. Finds a certificate that can serve https, says whether it chains, and prints the binding command. | No |
| `Application-List-Technician-Guide.docx` | Two-page how-to for technicians, for the SharePoint library. **The URL in it is a placeholder** — replace `https://<lab-machine>.<domain>:5000/appfilter/` and the contact line before publishing. | No |
| `Application-List-Quick-Reference.docx` | One page: the URL and the three routes, nothing else. For pinning up or keeping open. Host name is a placeholder. | No |
| `Application-List-Operator-Reference.docx` | Routes, status codes, every script's parameters, and the start/stop commands. For whoever maintains the tool. Host name is a placeholder. | No |
| `DESIGN-AND-DEPLOYMENT.md` | **The why.** Every build and deployment action in order, what each was for, what was rejected and why; how authentication works and why sign-on is silent; how the rules classify, with worked examples. Written for the questions a supervisor or a new maintainer asks. | No |
| `HANDOFF.md` | This file. | No |

**Three files carry the key** — the two front ends and the lookup diagnostic.
That is the list to have in mind before sharing anything. The module, which is
the largest file and the one most likely to be copied for reference, carries
none.

### What is live on the lab machine

- Scheduled task **Refresh App List**, at startup, as SYSTEM, execution time
  limit disabled, restart on failure
- URL reservation `https://+:5000/appfilter/` for `NT AUTHORITY\SYSTEM`
- Certificate bound to `0.0.0.0:5000` from the enterprise CA
- Inbound firewall rule, TCP 5000, Domain profile only
- Absolute token restricted to approved egress IPs

### What is deliberately not done

- **Authorization.** Any domain account that reaches the port is served. An
  `-AllowedGroup` check is scoped and agreed but awaiting a decision on which
  AD group. See the security audit section.
- **The `_Moved` serial suffix.** The tenant appends `_Moved` to some devices'
  `serialNumber`, so a technician typing a serial off a sticker can get "no
  device matched" for a device that is there. Whether that is a convention or
  coincidence is unconfirmed. If it is a convention, the tool should retry on
  a partial match and offer the near match. Not built.

### What will break, and when

- **The certificate renews around Dec 2026.** The http.sys binding pins a
  thumbprint, so https stops working the day it rolls — silently, with nothing
  on the machine having changed. Re-run `netsh http add sslcert` with the new
  thumbprint. This is the single most likely future outage.
- **The API token expires Jan 7, 2027.**

## Rule provenance

The `Name` rules are not hand-curated guesswork. They are:

- the **intersection of 2 known base-image devices** (61 apps on 2/2), from
  `Build-BaseImageList.ps1`
- plus `Dell Trusted Device`, `Feedback Hub` and `Terugvoer-spil`, which landed
  in that tool's 1/2 "review these" bucket and were judged base image by hand
- plus 12 names carried over from the old hand-curated list: inbox Store apps
  and product name variants the two sampled devices did not report — `Camera`
  and `Microsoft Store` (the sample says `Windows Camera` / `Windows Store`),
  `Maps`, `3D Viewer`, `Paint 3D`, `OneNote for Windows 10`, the `Microsoft 365
  Apps for enterprise - en-us` / `Microsoft 365 Copilot` variants, and the two
  Teams add-in entries. The devices being refreshed are old, so old-image inbox
  names still need to match.
`Adobe Creative Cloud` was queried and confirmed as base image, so it stays in.

82 `Name` rules, plus 12 `Publisher` and 14 `Pattern` rules carried over from
the arrays that used to be in the script — 108 rows in total. The one
normalization collision is the x86/x64 pair of the same Visual C++
redistributable, which is harmless: the rules are a set.

Every row carries its provenance in `Source` — `image-intersection` (62),
`carried-over` (10), `hand-review-1of2` (3), `hand-review` for inbox apps
confirmed by hand off a real run, `name-variant` for a short name Absolute
reports where the baseline held a longer one, and `refresh-prompt` for anything
added through the prompt. The backfilled rows have no `AddedBy`/`Serial`; we know where
they came from but not which operator entered them.

Entries dropped from the old list are the point of the exercise, not a
regression: `Zoom Workplace`, `Webex`, `Cisco AnyConnect` and `7-Zip` came off
one user's machine and are not in the image, so they now correctly appear as
install candidates. Hardware and runtime entries that were dropped
(`Realtek Card Reader`, the Thunderbolt and Intel utilities, the older Visual
C++ rows) are still suppressed by `$DriverPublishers` and `$NoisePatterns`.

## Applied changes

1. **Deleted test 3** (the `WindowsApps` install-path rule) along with
   `$InboxPathPattern`. It suppressed genuine deployed software — Power BI
   Desktop and Power Automate were wrongly filtered. Store-installed does not
   mean inbox.
2. **Added name normalization** before matching (see above), applied to both
   the baseline and the device's apps.
3. **`BaseImageApps.csv` edits**:
   - removed `Xerox Print and Scan Experience` (installed per-user, not base)
   - added name variants that drift between machines: `BitLocker Drive
     Encryption`, `Microsoft 365`, `Tanium Client`
   - added inbox Store apps that were only being caught by the deleted path
     rule: `Windows Camera`, `Windows Store`, `To Do`, `Family`,
     `Feedback Hub`, `Terugvoer-spil` (Afrikaans display name for Feedback Hub
     — Absolute sometimes reports localized Store app names)

   75 rows, 71 distinct keys after normalization. The duplicates are the
   x86/x64 pairs of the same Visual C++ redistributables plus the deliberate
   `Tanium Client` / `Tanium Client 7.8.1.3126` pair — harmless, the baseline
   is a set.

## Curating the baseline from a run

The install list is numbered, and unless `-NoPrompt` is given the script asks
whether any of it belongs in the baseline:

```
Add any of these to the base image list? [numbers / n]: 1,4
```

Accepts single numbers, comma lists and ranges (`1-3`); anything unparseable or
out of range is reported and dropped rather than guessed at. The selection is
echoed for confirmation before anything is written, and where a row's
normalized key is broader than the name on screen the confirmation says so:

```
    [1] 7-Zip 24.09 (x64 edition)  (Igor Pavlov)
         -> matches "7-zip" (all versions)
```

That line matters — one keystroke there suppresses every version of a product,
which is usually the intent but is worth seeing first. Answering anything but
`y` writes nothing, and an empty answer (no stdin, redirected output) skips the
prompt entirely rather than hanging.

Rows added this way carry `Source=refresh-prompt` along with the date, the
operator and the serial that prompted them. Additions affect the **next** run;
the current run's classification is left as it was.

## Printable sheet

**Every run leaves a sheet behind.** With no `-OutputHtml` the file lands in
the working directory as `<serial>-InstallList.html` (falling back to the
device name, with invalid filename characters replaced). `-OutputHtml` puts it
somewhere specific — relative and absolute paths both work, missing directories
are created, a missing `.html` extension is added — and `-NoSheet` turns it off
for a console-only run.

The sheet is a one-page worksheet: a **Download** button at the top, then
device identity, the install list as a tick-box table with a Notes column, and
a footer giving the install count and how many applications were suppressed. A non-active agent or a scan older than 30 days appears as a boxed
warning on the sheet itself, not just in the console.

The footer's total is computed, not trusted: it is raised to at least what
the two lists add up to. That is there because a device with a single
application printed "1 of 0" - `$classified` inside `Get-RefreshApps` was the
one collection not wrapped in `@()`, a one-row `foreach` yields a scalar, and
`.Count` on a scalar is `$null` in Windows PowerShell 5.1. The wrap is the
fix; the clamp means the arithmetic cannot go wrong on the page again.

Under that footer is a collapsed **Not on this list, and why** block: every
suppressed application with its version, grouped by the reason that caught it.
It exists for one question — the user says they had X, it is not on the sheet,
was it filtered out or was it never in the inventory? — which is why it is
closed by default and carries `class="screen-only"`, so it never reaches the
paper. It renders only when the caller passes `-Suppressed`; a caller that
passes only `-SuppressedCount` gets the sheet exactly as it was. Both front
ends pass it. Reasons render in a fixed order (Base image, Driver / OEM,
Runtime / component) with anything unexpected after them, so a new reason
string shows up rather than disappearing.

**There is no print button.** Printing was withdrawn on cost grounds, so the
toolbar offers **Download** instead: `/download?serial=X` re-runs the lookup and
returns a PDF attachment. Ctrl+P still works - a page cannot and should not try
to block it - but nothing invites it. The `@media print` rules stay, so anyone
who does print still gets the sheet without the screen furniture.

Bringing the button back is the toolbar block in `New-InstallSheetHtml` plus the
CSP hash the server used to carry: `'unsafe-hashes'` and the SHA-256 of
`window.print()`. With the handler gone, `script-src` is now `'none'` outright.

**The PDF is written by hand** - `New-InstallSheetPdf`, about 250 lines: a
catalogue, a page tree, two standard Type1 fonts (nothing embedded) and one
uncompressed content stream per page. That is deliberate. This project used to
render PDFs by driving Edge or Chrome headless, and that came out because it
meant a subprocess per request, a browser dependency on a machine whose listener
runs as SYSTEM, and a profile directory to clean up. The hand-written path has
no dependency and leaves nothing running. Uncompressed streams cost a few KB and
make the output greppable, which is how the tests check it.

Three things in that code are load-bearing. **Byte offsets in the xref table
must be exact**, so the file is assembled into a MemoryStream with each object's
offset recorded as it is written, and a test walks every offset back to the
object it claims. **`-f` binds tighter than `+`**, so a format string split
across a concatenation formats only its second half - which left `{0}` sitting
in the page dictionary as literal text and produced a PDF that opened but had no
MediaBox. **Text is WinAnsi**; parentheses and backslashes are escaped, or a
name like `7-Zip (x64)` ends the PDF string early.

This used to render a PDF by driving Edge or Chrome headless. That is gone —
along with `Find-PdfBrowser`, `APPFILTER_BROWSER`, the throwaway profile
directory and the subprocess wait. Plain HTML prints just as well, has no
browser dependency, and leaves nothing running after the script ends.

## Web front end

`Start-RefreshAppServer.ps1` serves the same tick-list over HTTP from an
always-on machine. It exists to answer the credential-distribution problem:
the key sits on that one machine, technicians open a URL, and nobody else ever
holds a copy of anything.

```
.\Start-RefreshAppServer.ps1                                  # port 5000, /appfilter/, Windows auth
.\Start-RefreshAppServer.ps1 -Port 8080 -BasePath /tools/apps/
.\Start-RefreshAppServer.ps1 -AuthScheme Ntlm                 # when browsers loop on the credential prompt
.\Start-RefreshAppServer.ps1 -Anonymous -BindAddress localhost  # local trial only
```

Routes, all under `-BasePath` (default `/appfilter/`):

| Route | Returns |
|---|---|
| `/appfilter/` | the serial form |
| `/appfilter/lookup?serial=X` | the sheet, with a Download button and a "look up another device" link |
| `/appfilter/download?serial=X` | the same sheet as a PDF attachment, `<serial>-InstallList.pdf` |
| `/appfilter/health` | `OK`, for a monitor or a scheduled restart check |

**Why a path and not just a port.** http.sys routes by longest prefix match,
so a second application can reserve `http://+:5000/something-else/` and run
beside this one on the same port, in its own process, started and stopped
independently. One firewall rule covers every application on the machine, and
the URL handed to technicians today stays correct when the second one arrives.
The reservation must match the path exactly — `url=http://+:5000/appfilter/`,
not `url=http://+:5000/`.

Behaviour worth knowing:

- **A browser that prompts and then refuses correct credentials is a missing
  SPN, not a browser fault.** Verified on the lab machine: `Invoke-WebRequest
  -UseDefaultCredentials` returned 200 over both `localhost` and the machine's
  own hostname, while a browser at the same hostname looped on the credential
  prompt. PowerShell got in over NTLM; the browser was offered Negotiate, tried
  Kerberos with the typed credentials, found no `HTTP/<host>` SPN registered
  for the account running the listener, and re-prompted rather than falling
  back. **Confirmed independently:** browsing the same server by its bare IP
  authenticated first try. Browsers do not attempt Kerberos against an IP
  literal — there is no name to derive an SPN from — so the IP forced the NTLM
  fallback the hostname never reached. Four ways out, cheapest first: use the
  IP; run with `-AuthScheme Ntlm`; add the host to the Local intranet zone so
  browsers send default credentials silently; or have a domain admin register
  the SPN (`setspn -S HTTP/<host> DOMAIN\Account`).

  **The IP is a poor permanent answer** on two counts: the address moves
  unless it is reserved, and a bare IP usually lands in the browser's Internet
  zone, so technicians get a credential prompt every session rather than
  silent sign-on — friction pushing directly against the ease-of-use this was
  built for, and the thing that starts people asking to turn the auth off.

  **Running as `SYSTEM` under the startup task is expected to fix it for
  free**, because the machine account's own `HOST/<host>` SPN already covers
  HTTP, so Kerberos works with no `setspn`, no domain admin and no registry
  change. Not yet verified — verify it when the scheduled task goes in. That
  task also needs its own reservation:
  `netsh http add urlacl url=http://+:<port>/ user="NT AUTHORITY\SYSTEM"`.
- **Windows Integrated authentication is the default.** Only domain accounts
  reach it, and `$context.User.Identity.Name` names the caller in the log, so
  every lookup is attributable — which the console tool, sharing one token
  across copies, can never be. `-Anonymous` turns it off and is for a local
  trial only; combined with the default `-BindAddress +` it prints a warning,
  because anyone who can reach the port could then read fleet inventory.
- **The request loop waits on `GetContextAsync`, not `GetContext`.** The
  synchronous call blocks inside native code where PowerShell cannot deliver
  Ctrl+C, so the console ignored it and the window had to be killed. Waiting
  on the task in 250 ms slices gives the host a chance to process the
  interrupt between waits. **Unverified** — this sandbox cannot deliver
  Ctrl+C to PowerShell at all (a bare `while ($true) { Start-Sleep }` control,
  with no blocking call in it, also survives SIGINT here), so the reasoning is
  sound but the fix has only been confirmed not to break request serving.
  Check it on the real machine.
- **A port is http OR https in http.sys, never both.** TLS is bound per
  `ip:port`, so the whole port is one or the other, whatever the paths under
  it. An existing `http://+:5000/appfilter/` reservation therefore blocks
  `https://+:5000/appfilter/` — the listener reports "conflicts with an
  existing registration", and `netsh http add urlacl` for the https URL
  quietly fails to take. Observed on the real machine: the https reservation
  appeared to have been created and `show urlacl` for it returned nothing,
  while `netsh http show urlacl | Select-String ':5000'` revealed the http one
  still sitting there. **Moving to https means deleting the http reservation,
  not adding a second one.** Technicians' http bookmarks stop working at that
  moment, which is the intent.
- **`min-width: 0` on a text input, and `width: min(Npx, 100%)` on its
  wrapper.** A text input carries an intrinsic minimum width from its default
  `size`, which `width: 100%` does not override inside a grid or flex parent.
- **Headless Chrome will not render below a 500px viewport.** `--window-size`
  smaller than that is silently clamped, so a screenshot taken at 420 is a
  crop of a 500-wide render and shows content running off the right edge that
  is not actually overflowing. This looked exactly like a responsive bug and
  was not one. Measure `document.body.scrollWidth` against
  `documentElement.clientWidth`, or set an explicit container width and read
  the rectangles back, rather than trusting a narrow screenshot.
- **"Conflicts with an existing registration" also covers a reservation held
  by another account.** Windows does *not* say
  "Access is denied" for that, as you might expect — it says conflict. So a
  `netsh http add urlacl ... user="NT AUTHORITY\SYSTEM"` reservation, made in
  preparation for the startup task, blocks an interactive test run by a person
  and reports it as though something were already listening. Observed on the
  real machine, and it survived a reboot, which is what ruled out the other
  cause. Check with
  `netsh http show urlacl url=https://+:5000/appfilter/`.

  A URL carries **one** reservation, so testing as yourself means deleting and
  re-adding it, then putting it back for the startup task. Or skip the churn
  and test through the task itself, running as SYSTEM, which is what the
  reservation already matches.

  The other cause is something genuinely listening, usually an earlier
  instance — easy to accumulate while Ctrl+C is unreliable. A reboot rules
  that one out. `Get-NetTCPConnection -LocalPort 5000 -State Listen` and
  `netsh http show servicestate view=requestq` find it.
- **The form and error pages share one shell**, `New-SplitPage`: a fixed dark
  panel on the left saying what the tool is, and a working column on the right
  that holds either the serial form or an error. Adding a page means writing
  its right-hand column only. The design was chosen from four mockups; the
  printable sheet was deliberately left alone, since it is print-first and
  gains nothing from screen styling.
- **Rules and credentials load before the port opens**, so a bad rules file or
  a missing key fails at startup instead of on a technician's first lookup.
- **One bad request cannot take the server down.** The body of the request loop
  is wrapped; a failure returns a 500 page and the listener keeps serving.
- **Serials are validated** against `^[A-Za-z0-9\-]{1,32}$` before any API call.
  A rejected serial is echoed back into the form — which is exactly why the
  escaping gotcha above matters.
- **Every request is logged** to `RefreshAppServer.log` (override with
  `-LogPath`): timestamp, caller, serial, outcome. Control characters in a
  serial are replaced so a crafted `%0A` cannot forge a second log line.
- **Requests are served one at a time.** `HttpListener` plus a single loop
  means a second technician waits for the first lookup to finish — a few
  seconds against the live API. Fine for a handful of people; it is the first
  thing to change if it is not.
- The curation prompt ("add any of these to the base image list?") is
  **console-only**. Rules are still edited by running `Get-RefreshAppList.ps1`
  or by hand. Adding it to the web page means letting a browser write to
  `AppRules.csv`, which deserves its own thought.

### The startup task works. Verified end to end

The server runs under a scheduled task as `NT AUTHORITY\SYSTEM`, starts at
boot, and **survived a real reboot**. Confirmed on the live machine: a fresh
`STARTED` line after boot, a real lookup returning `16 to install of 72`
attributed to a domain account, and the page loading with nobody having
touched anything.

**Edge signs in silently, with no GPO, no `AuthServerAllowlist` and no
`-AuthScheme Ntlm`.** Running as SYSTEM makes the listener the machine
account, which already owns `HOST/<host>`, and `HOST/` covers HTTP — so
Kerberos works on the FQDN. That closes the SPN question that shaped three
separate decisions earlier in this project; none of the workarounds are
needed and none are in use.

It took two attempts. The first failed with exit 1 and nothing in the log,
which sent the diagnosis toward Constrained Language Mode. **That theory was
wrong** — the second attempt reached the listen loop, so `HttpListener` and
`HMACSHA256` construct fine as SYSTEM. What actually fixed it was rebuilding
from a clean state (no leftover task, no process holding the port, the
reservation on SYSTEM) and capturing the task's own output from the first
run, rather than registering a task that could only report an exit code.
**Register a task with `*>` capture in its action from the outset**; it costs
nothing and it is the difference between one round and four.

One earlier alarm was also false: a missing `STARTED` line looked like SYSTEM
being unable to write the log. It had simply been read mid-write — the line
was there.

### Running it under the startup task

**The task is what makes it survive a reboot.** Windows has no other
no-dependency way to start a console program at boot without a logged-in user:
the Startup folder and the Run key both need a session, and a real service
would need a wrapper like WinSW or NSSM around a PowerShell script. A
scheduled task with an At-Startup trigger running as `NT AUTHORITY\SYSTEM` is
the whole mechanism.

Four settings on that task are not optional:

- **Run as `NT AUTHORITY\SYSTEM`**, which is also what fixes Kerberos — the
  machine account already owns `HOST/<host>`.
- **Trigger: At startup.** Not at logon; the lab machine may sit at a locked
  screen for weeks.
- **Execution time limit: disabled.** The default stops a task after three
  days, which would silently kill the server mid-week.
- **Restart on failure**, a minute apart, a few times. The script exits 1 on a
  startup failure, and without this the task simply stays dead.

**There is no console under the task**, so `Write-Host` goes to a discarded
stdout. `Write-ServerLog` therefore records `STARTED` (with the URL, auth
scheme, credential source, rule count and PID), `FAILED TO START` with the
reason, and `STOPPED` into `RefreshAppServer.log` beside the request lines.
Without those, a server that died at startup looks exactly like one that is
running and idle. Task Scheduler's "Last Run Result" is the other signal.

### Standing it up on the lab machine

1. Copy `AppFilter.psm1`, `AppRules.csv` and `Start-RefreshAppServer.ps1` to
   the machine and fill in the token at the top of the server script.
2. Reserve the URL once, so it does not need an elevated session to run:
   `netsh http add urlacl url=http://+:5000/appfilter/ user=DOMAIN\ServiceAccount`
   (or `user="NT AUTHORITY\SYSTEM"` if the startup task runs as SYSTEM). The
   path is part of the reservation and has to match `-BasePath` exactly.
3. Open the port to the domain profile:
   `New-NetFirewallRule -DisplayName "Refresh App List" -Direction Inbound -Protocol TCP -LocalPort 5000 -Profile Domain -Action Allow`
4. Make it survive a reboot — a scheduled task at startup running as the
   service account, `pwsh -NoProfile -File ...\Start-RefreshAppServer.ps1`.
5. Tell technicians `https://<machine-fqdn>:5000/appfilter/`. **The FQDN, not
   the short name** — see below.

**Kerberos and TLS disagree about which names are acceptable, and both have to
be satisfied.** A machine account registers `HOST/shortname` *and* `HOST/fqdn`,
so Windows authentication is happy with either. The certificate is not: the
auto-enrolled one here names **only the FQDN**, so the short name gives
`NET::ERR_CERT_COMMON_NAME_INVALID` with TLS otherwise working perfectly — the
handshake completes, the chain verifies, and the browser objects to the name
alone. An IP address fails the same way, which retires the IP workaround used
earlier for the SPN problem. Hand out the FQDN. `Find-ServerCertificate.ps1`
now prints which of the machine's names the certificate covers and which it
does not.

### It will say "Not secure", and the startup task does not change that

That warning is plain HTTP with no TLS. It has nothing to do with the service
account, the SPN or the reservation, so nothing in the startup step affects
it. Traffic is readable by anyone on the path: the serials looked up and the
application inventory returned. Windows authentication is challenge-response,
so no reusable password crosses the wire, but the data does.

Fixing it properly needs a certificate the client machines already trust —
which on a domain usually means one issued by internal PKI (AD Certificate
Services) to the machine's own name. Then bind it to the port and serve
`https://`:

    netsh http add sslcert ipport=0.0.0.0:5000 certhash=<thumbprint> "appid={<any guid>}" certstorename=MY

**Quote the `appid`.** Unquoted, PowerShell parses `{...}` as a script block
and reads parts of the GUID as expressions, dying with "You must provide a
value expression following the '-' operator" before netsh is ever invoked.

It fails **intermittently**, which is what makes it nasty: measured at 13 of
200 random GUIDs, 0 of 200 once quoted. The failures all contain
`<digits>e<digits>` — `{6e61644d-...}`, `{50463e31-...}` — which PowerShell
reads as scientific notation. So an unquoted line works about nine times in
ten and then fails for no visible reason. The same quoting applies to
`user="NT AUTHORITY\SYSTEM"` on a reservation.

and the listener prefix becomes `https://+:5000/appfilter/`. A self-signed
certificate does **not** help — browsers warn about it just as loudly.

`Start-RefreshAppServer.ps1 -UseHttps` switches the scheme. It does **not**
configure the certificate: http.sys owns the TLS handshake, and the binding is
made once, outside the script. Two consequences worth knowing:

- **A missing or wrong binding does not fail at startup.** The listener starts
  happily and every connection is reset instead, which reads as "the site
  won't load" rather than "the certificate is wrong". Check with
  `netsh http show sslcert ipport=0.0.0.0:5000`.
- **The URL reservation is scheme-specific.** An `http://+:5000/appfilter/`
  reservation does nothing for https; add `https://+:5000/appfilter/` too.

The certificate binds **per ip:port, not per path**, so every application
sharing port 5000 shares one certificate — convenient, but the certificate has
to carry a name that suits all of them.

`Find-ServerCertificate.ps1` reads the local machine store and reports which
certificates qualify (private key present, in date, valid for Server
Authentication, name matching this machine), says whether each chains to a
trusted CA, and prints the exact `netsh http add sslcert` line. It changes
nothing.

**The http.sys binding pins a thumbprint, so a renewed certificate silently
breaks https.** A renewal is a different certificate with a different
thumbprint; the binding still points at the old one and connections start
failing with nothing on this machine having changed. Auto-enrolled machine
certificates renew on their own, which makes this a *scheduled* outage rather
than a possible one. Re-run the binding after any renewal — the certificate in
use at the time of writing expires **Dec 2026**, and the finder warns when
fewer than 120 days remain.

**Trust is reported from the chain, not from `Test-Certificate`.** The first
version used `Test-Certificate -SSLServerAuthentication` and collapsed every
failure into "does NOT chain cleanly", which was actively misleading: an
unreachable CRL fails identically to an untrusted root, and browsers soft-fail
revocation so would not have cared. It now builds the chain twice, once with
revocation checking off and once on, prints the real `ChainStatus` reason, and
separates "cannot verify revocation" from "does not trust the issuer". The
chain-building path is verified against a real certificate; the
store-enumeration path is not, since the sandbox has no
`Cert:\LocalMachine\My`.

**Confirmed on the real machine:** the auto-enrolled machine certificate
chains cleanly to the enterprise CA through an intermediate, with online
revocation checking passing too. The first report calling it untrusted was the
`Test-Certificate` bug above, not a real finding — worth remembering before
anyone goes asking PKI for a certificate they already have.

The leaf certificate there carries its name **only in the SAN, with an empty
Subject**, which is normal for an enterprise template. `GetNameInfo('SimpleName')`
returns nothing for such a certificate, so the chain display falls through to
the SAN and then the raw subject.

### Still unverified

**A lookup from a second machine, by a second person.** Every real lookup so
far has been from the lab machine under one account. The case that actually
matters to the attribution story — a technician at their own desk, their name
in the log — has not been exercised. It is the last claim in this document
that rests on reasoning rather than evidence.

### Security audit, 16 Sep 2026

A full read of the application plus live probing. Nine findings; the state of
each:

| | Finding | State |
|---|---|---|
| H-1 | No authorization — any domain account is served | **Open, deferred.** An AD group for technicians probably exists; pending a decision. |
| H-2 | API key readable by anyone who can log into the machine | **Accepted**, after reassessment. See below. |
| H-3 | Absolute token had no IP restriction | **Closed.** Approved IP Addresses now set to the host's egress IP; verified by a request from a non-approved address being rejected. |
| M-1 | Exception text rendered to the browser | **Fixed.** Generic sentence on the page, detail to the log. |
| M-2 | No rate limiting; single-threaded | **Accepted.** External access is blocked, the token is IP-bound, and H-1 will narrow the population further. |
| L-1 | No security response headers | **Fixed.** CSP, nosniff, frame-deny, referrer policy. |
| L-2 | CSV formula injection | **Fixed**, round-trip safe. |
| L-3 | Logs grew without bound | **Fixed.** Rotates at 5 MB, one generation kept. |
| L-4 | `-Anonymous` served the network with only a warning | **Fixed.** Refused unless `-AllowAnonymousOnNetwork` is also given. |

**H-2 was first written as urgent and that was wrong.** The ACL does grant
`NT AUTHORITY\Authenticated Users: Modify`, inherited from the root of `C:\`,
which reads as "every domain account can rewrite a script SYSTEM runs at boot".
But reaching those files needs an interactive logon or the administrative
share, and **both require local administrator rights**. The effective
population is the machine's administrators, not the domain.

The technicians are administrators on that machine, so tightening the ACL
would constrain nobody — an administrator resets any permission at will. The
change was declined on that basis and the reasoning is sound. **Do not
re-raise this as an ACL problem.**

What is real, and worth stating without alarm: a single compromised technician
account yields the Absolute token *and* the ability to plant code that runs as
SYSTEM at every boot on an always-on machine. That is tolerable only because
H-3 is done — with Approved IP Addresses on the token, a stolen key is inert
outside the corporate egress.

The question that would actually change this is not about permissions but
about logins: **who needs interactive access to the lab machine?** The web
server exists so technicians do not hold a copy of the credential. If every
technician can log in and read it, that property is weakened through the login
path rather than the distribution path. Narrowing RDP, not ACLs, is what would
restore it — a conversation for the supervisor, alongside H-1.

**On CSP:** the policy now allows no script at all — `script-src 'none'`. It
used to allow exactly one inline handler by hash, `'unsafe-hashes'` plus the
SHA-256 of `window.print()`, which was the sheet's print button; that button is
gone and the exception went with it. If printing ever returns, so does the pair
— and note that an inline event handler cannot be allowed by hash *without*
`'unsafe-hashes'`, and that the hash must be recomputed if the handler's text
changes by so much as a space.

**On CSV escaping:** `ConvertTo-CsvSafeText` prefixes an apostrophe on write
and `ConvertFrom-CsvSafeText` removes it on read. **The pair is the point** —
escaping without the matching un-escape would silently stop every affected rule
from matching the application it came from. Verified by round-trip: a rule
stored as `'=cmd|calc!A1` still classifies an app named `=cmd|calc!A1`.

**Known and deliberate gap: there is no authorization, only authentication.**
Any domain account that can reach the port gets served; the caller's name is
logged but never checked. In practice that is most of the organisation, and
what they can read is fleet inventory — device names, assigned users, serials
and installed applications. The fix is about fifteen lines: an
`-AllowedGroup` parameter and a `WindowsPrincipal.IsInRole` test in the
request loop, refusals logged, defaulting to today's behaviour so nothing
breaks when it is omitted. Raised, understood, and deferred by the operator —
not overlooked.

Everything not listed as verified on the real machine was tested against a
mocked API — all routes, the injection case, the log, and four concurrent
requests.

## Exit behaviour

The script ends with an explicit `exit`, so nothing lingers after a run:

- `exit 0` — normal completion, and when the operator answers the serial
  prompt with nothing
- `exit 1` — no application inventory came back for the device

The server is the exception: it runs until Ctrl+C, and exits 1 if it cannot
open the port (the failure message prints the `netsh http add urlacl` remedy).

Note that `exit` inside a `.ps1` ends the *script*, not the console window it
was launched from. Running `.\Get-RefreshAppList.ps1` from an open prompt
returns you to that prompt, which is correct. Launch it as
`pwsh -File .\Get-RefreshAppList.ps1` if the window itself should close.

## Known caveats

- The baseline now has real provenance but the sample is **2 devices**. An
  intersection of two cannot in principle distinguish a base-image app from an
  app both sampled users happened to have. In practice it has held up on both
  entries that were checked by hand: `Adobe Creative Cloud` (on 2/2, confirmed
  base) and `7-Zip` (on 0/2, confirmed a user install). Still, widen the sample
  when more known-good devices are available; the earlier attempt failed only
  because freshly-imaged devices had not completed a software scan — sample
  devices imaged 3-7 days ago instead.
- Because Dell and Intel utilities are now in the baseline by name,
  `$DriverPublishers` is carrying much less weight than it was. It is still a
  blunt rule that hides any Dell- or Intel-published application, including
  real ones; narrowing it is now much safer than it used to be.
- Check `agentStatus` and `lastScanDateTimeUtc` before trusting an inventory.
  A disabled or long-disconnected agent yields stale or empty results.
- **Short-name variants are the recurring miss.** Absolute reported `OneDrive`
  on a real device while the baseline carried `Microsoft OneDrive`;
  normalization does not bridge those, so it needed its own row
  (`Source=name-variant`). Inbox Store apps are the usual offenders — they tend
  to arrive under a bare product name. When a run surfaces something obviously
  in-box, that is what the curation prompt is for.
- **The console table needs a real console.** `Format-Table` renders nothing
  when stdout is redirected to a file or a pipe with no attached terminal — a
  sandbox artifact, but it means `.\Get-RefreshAppList.ps1 X > out.txt`
  captures the headers and counts without the application rows. Use
  `-OutputCsv` or the printable sheet to capture a run. The web front end is
  unaffected.
- Store app display names can arrive localized, so a single baseline entry may
  not match across machines. Normalization does not help here — a localized
  name needs its own baseline row.
- Now that the `WindowsApps` rule is gone, every genuine inbox Store app has to
  be in `BaseImageApps.csv` by name. Expect a few to show up in an install list
  before the baseline catches up.
