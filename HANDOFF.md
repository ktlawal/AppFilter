# Absolute refresh-app-list — handoff context

## Goal

During the device refresh cycle, techs need a list of applications to manually
install on a user's new machine. Pull the old device's installed-application
inventory from Absolute, subtract everything the new machine gets anyway
(base image, drivers, runtimes), and print what's left.

No install automation yet — a list for a human is the deliverable. Automating
installs (Intune group membership) is a possible later phase.

## Environment

- Windows, PowerShell 7 (NOT 5.1 — error handling differs, see gotchas)
- Working dir: `D:\AbsoluteApplicationList`
- Absolute API token ID + secret are **not** in any script. Each operator
  stores their own once with `Set-AbsoluteCredential.ps1`; see Credentials.

## Credentials

Nothing sensitive lives in the repo. `Get-RefreshAppList.ps1` resolves the
token at run time from the first source that answers:

| Order | Source | How |
|---|---|---|
| 1 | **Environment** | `ABSOLUTE_TOKEN_ID` + `ABSOLUTE_SECRET_KEY`, if both are set. The hook a server, container or scheduled task uses. |
| 2 | **Local** | `%APPDATA%\AppFilter\absolute.cred.xml`, written once by `Set-AbsoluteCredential.ps1`. |

`-CredentialSource` pins one of `Auto` (the table above), `Environment` or
`Local`.

### The local DPAPI file

A `PSCredential` exported with `Export-Clixml`, so the secret is encrypted with
**DPAPI under the current user**. Copy it to another machine, another profile,
or a USB stick and it will not decrypt. The token ID is stored readable, which
is fine — it is useless without the secret.

**`Set-AbsoluteCredential.ps1` refuses to run on non-Windows, deliberately.**
DPAPI is a Windows facility; elsewhere PowerShell still writes the file, but the
"encrypted" password is only UTF-16 hex of the plaintext — any local user
recovers it with a single `Import-Clixml`. Writing that would look protected and
would not be, so the script errors instead.

### Two shared-key routes were built and removed

Both worked as designed and both were taken out rather than left as dead code.
The commit history has them if they are ever wanted back.

- **SharePoint via Microsoft Graph.** Blocked by tenant policy, not by the code:
  a real attempt returned **AADSTS50105** — the *Microsoft Graph Command Line
  Tools* app (`14d82eec-204b-4c2f-b7e8-296a70dab67e`) has "assignment required"
  set and the operator was not assigned. Getting past it needs an admin
  assignment to that app, or a dedicated Entra app registration with delegated
  `Files.Read.All`.
- **A shared key file by path** (`-KeyPath`), covering a network drive, a UNC
  share, or SharePoint over WebDAV. Removed as unused once the decision was to
  keep each operator's credential local.

The trade being made: a shared key file gives central rotation and revocation,
which DPAPI cannot. DPAPI gives a credential that is inert if copied, which a
shared file cannot. With one operator, local is the simpler correct answer.

### What each control actually buys

- **Approved IP Addresses** (set on the token in Absolute) — a leaked key is
  useless off the corporate network. The single biggest win, and independent of
  everything above.
- **DPAPI** — a leaked *file* is inert. Does not give revocation or audit.
- **Token expiry** — bounded lifetime regardless. Currently Jan 7, 2027.

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

- `Get-RefreshAppList.ps1` — main tool. `[-Serial <serial>]` `[-ShowFiltered]`
  `[-NoPrompt]` `[-RulesCsv <path>]` `[-OutputCsv <path>]` `[-OutputHtml <path>]`
  `[-NoSheet]`. With no serial and no device name it asks for a serial; an
  empty answer exits without doing anything. `-BaselineCsv` still works as an
  alias for `-RulesCsv`.
- `AppRules.csv` — **all** suppression rules, columns
  `Rule,MatchType,Reason,Publisher,Active,Source,AddedOn,AddedBy,Serial`.
  Replaces `BaseImageApps.csv` and the two hardcoded arrays that used to live
  in the script.
- `Set-AbsoluteCredential.ps1` — one-time per-user credential setup.
  `[-Path <path>]` `[-Remove]`. Windows only, by design.
- `Test-AppFilter.ps1` — asserts both normalizers, loads the rules file, and
  classifies two real device inventories against the bucket a human confirmed
  for each. Lifts the functions out with the parser, so it never calls the API
  and needs no credential. **Run it after touching a normalizer or the rules
  file** — the classification cases are the regression net.
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

The three agreed changes are applied and the baseline has been rebuilt from
real base-image devices. The script parses clean and a run against a mocked API
confirms the intended classification. It has **not** been re-run against a live
serial since — the last real run predates all of this (serial `4QXTTHR3`:
75 apps, 58 excluded, 17 install candidates), so expect that count to move,
probably upward.

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

The sheet is a one-page worksheet: a **Print this sheet** button at the top,
then device identity, the install list as a tick-box table with a Notes column,
and a footer giving the install count and how many applications were
suppressed. A non-active agent or a scan older than 30 days appears as a boxed
warning on the sheet itself, not just in the console.

Open it, click Print. The button calls `window.print()`; it and the rest of the
screen-only furniture (grey backdrop, card padding, drop shadow) are hidden
under `@media print`, so what reaches the paper is just the sheet. Verified by
forcing the print block to apply on screen and rendering it.

This used to render a PDF by driving Edge or Chrome headless. That is gone —
along with `Find-PdfBrowser`, `APPFILTER_BROWSER`, the throwaway profile
directory and the subprocess wait. Plain HTML prints just as well, has no
browser dependency, and leaves nothing running after the script ends.

## Exit behaviour

The script ends with an explicit `exit`, so nothing lingers after a run:

- `exit 0` — normal completion, and when the operator answers the serial
  prompt with nothing
- `exit 1` — no application inventory came back for the device

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
- Store app display names can arrive localized, so a single baseline entry may
  not match across machines. Normalization does not help here — a localized
  name needs its own baseline row.
- Now that the `WindowsApps` rule is gone, every genuine inbox Store app has to
  be in `BaseImageApps.csv` by name. Expect a few to show up in an install list
  before the baseline catches up.
