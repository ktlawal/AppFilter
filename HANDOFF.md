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
- Absolute API token ID + secret are pasted into the top of each script

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

## Files

- `Get-RefreshAppList.ps1` — main tool. `-Serial <serial>` `[-ShowFiltered]`
  `[-OutputCsv <path>]`
- `BaseImageApps.csv` — exclusion list, columns `AppName,Publisher`
- `Build-BaseImageList.ps1` — builds a baseline empirically from several
  freshly-imaged devices (not currently in use; the baseline is hand-curated).
  Not carried into this repo yet; it still lives only in `D:\AbsoluteApplicationList`.

## How classification works

Both sides of the baseline comparison are put through
`ConvertTo-NormalizedAppName` first, so a product matches itself across
machines despite version drift:

- strips `™ ® ©`
- strips architecture / edition parentheticals — `(x64)`, `(x86 edition)`,
  `(64-bit)`
- strips a trailing version in the three shapes that actually occur:
  dash-separated (`... - 11.0.61030`), `v`-prefixed (`... v14`), or dotted with
  two or more parts (`Tanium Client 7.8.1.3126`)
- collapses whitespace, lowercases

A bare trailing integer is deliberately **not** treated as a version, so
`Microsoft 365`, `Paint 3D` and `OneNote for Windows 10` keep their numbers.

Each application record then runs through three tests **in order**, first match
wins. An unmatched record goes in the install list.

1. normalized `appName` in `BaseImageApps.csv`   → `Base image`
2. `appPublisher` in `$DriverPublishers`         → `Driver / OEM`
3. `appName` matches any regex in `$NoisePatterns` → `Runtime / component`

Tests 2 and 3 still match on the raw strings, not the normalized key.
Version is never compared — name only.

## Current state

The three agreed changes below are applied and the script parses clean; a run
against a mocked API confirms the intended classification. It has **not** been
re-run against a live serial since the changes — the last real run predates
them (serial `4QXTTHR3`: 75 apps, 58 excluded, 17 install candidates), so
expect that count to move.

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

## Known caveats

- The baseline was hand-curated from a single user's device rather than a clean
  image, so it may both over- and under-exclude. `Build-BaseImageList.ps1`
  exists to rebuild it empirically; the three freshly-imaged devices tried so
  far returned only 1 app each because the software scan hadn't completed.
- Check `agentStatus` and `lastScanDateTimeUtc` before trusting an inventory.
  A disabled or long-disconnected agent yields stale or empty results.
- Store app display names can arrive localized, so a single baseline entry may
  not match across machines. Normalization does not help here — a localized
  name needs its own baseline row.
- Now that the `WindowsApps` rule is gone, every genuine inbox Store app has to
  be in `BaseImageApps.csv` by name. Expect a few to show up in an install list
  before the baseline catches up.
