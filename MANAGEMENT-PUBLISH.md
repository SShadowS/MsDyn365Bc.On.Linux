# Publishing precompiled apps on Linux BC (no source recompile)

> Goal: deploy a **precompiled** Business Central app (e.g. Microsoft's stock
> System Application → Business Foundation → Base Application chain) onto the
> Linux NST **without recompiling it from AL source** — the equivalent of
> `Publish-NAVApp` for the shipped R2R binaries.

This document records the full investigation (every avenue, with the exact
decompiled code and commands), the mechanism that works, the tool that
implements it (`scripts/management-publish.py`), and how it was verified.

---

## TL;DR

- **Every BC publish path recompiles a source-bearing `.app` on Linux.** The
  dev endpoint, the `Publish-NAVApp` management cmdlet, `Get-NAVAppRuntimePackage`,
  and the boot-time in-place publisher all call `NavAppPackageCompiler.Recompile`
  (AL → C#) for any package that ships AL source. The stock `.app` files ship AL
  source **plus** precompiled R2R DLLs; there is **no** shipped
  "emitted-content-without-source" package that would hit the recompile-free
  `ExtractEmittedContent` path. (Decompiled evidence below.)
- **The recompile *fails* on Linux for stock apps** — proving the recompile is
  the blocker, not an incidental cost. System Application dies with
  `AL0327: Missing file 'Resources\WelcomeWizard\js\Startup.js'`; Base
  Application dies with `AL1024 ... Symbols ... could not be found`.
- **BC's own image ships these apps as pre-populated SQL rows.** NST recompiles
  each app's runtime assembly **exactly once per database** (the Merkle re-emit
  validation drifts on Linux, so the shipped R2R DLLs are rejected and
  regenerated), then persists the compiled result in SQL
  `[Application Object Metadata]`. **A warm restart against the same DB does
  ZERO recompiles** (verified). The compiled artifacts *are* the precompiled
  form.
- **Working mechanism:** capture that compiled SQL state once
  (`management-publish.py snapshot`) and replay it into a fresh/cleared database
  (`management-publish.py restore`). NST then boots finding valid compiled
  artifacts and **does not recompile** — the precompiled app is deployed,
  published, installed-for-tenant, and its objects work.

---

## How the publish paths actually work (decompiled)

All decompilation done with `ilspycmd` against the assemblies in
`/bc/service/` of a running container (BC 28.1, platform 28.0.51409).

### The management cmdlet path

`Publish-NAVApp` (`Microsoft.Dynamics.Nav.Apps.Management.Cmdlets.PublishNavApp`,
in `Admin/Microsoft.BusinessCentral.Apps.Management.dll`) does:

```
PublishNavApp.PublishToService()
  -> base.AdminService.PublishNavApp(arguments)          // AdminService = in-process NSAdminService
NSAdminService.INCLAdminService.PublishNavApp(arguments) // Microsoft.Dynamics.Nav.Service.ManagementApi.dll
  -> new NavManagementTasks(session).PublishNavApp(arguments)
NavManagementTasks.PublishNavApp(arguments)              // Microsoft.Dynamics.Nav.Ncl.dll
  -> NavAppPublisher.PublishFromArguments(arguments)
```

`AdminServiceFactory.Create(session)` returns an **in-process** `NSAdminService`
— the cmdlet does not require the dead WCF 7045 endpoint; the server-side work
runs in-process given a `NavSession`. So an in-process StartupHook injection
*could* call `NavManagementTasks(session).PublishNavApp(...)`. But it doesn't
help, because:

`NavAppPublisher.PublishFromArguments` → `Publish` → `PerformDatabasePublishAsync`
chooses the compile step by package nature:

```csharp
DoSystemCompileStep systemCompileAction = publishContext.IsRuntimePackage
    ? DoSystemCompileStepForRuntimePackageAsync
    : DoSystemCompileStepForRegularPackageAsync;
```

- **Regular package** (the stock `.app`'s embedded app, which has `/src/`):
  `DoSystemCompileStepForRegularPackageAsync` runs
  `NavAppPackageCompiler.Recompile(...)` **unconditionally** (AL → C#), then a
  `ValidatePublishedArtifacts()` Merkle-hash gate decides between
  `CopyPublishedArtifacts()` (reuse shipped R2R DLLs) and
  `DirectFillBlobCacheAsync()` (regenerate R2R). Either way the AL recompile
  has already happened.
- **Runtime package without source** (`!reader.ReadSourceCodeFilePaths().Any()`):
  `DoSystemCompileStepForRuntimePackageAsync` skips `Recompile` and calls
  `NavAppPackageCompiler.ExtractEmittedContent(packageStream)` →
  `CommitToDatabase`. **This is the only recompile-free path.**

### Why the recompile-free path can't be reached from shipped artifacts

`IsRuntimePackageWithoutSourceCode` requires `reader.IsRuntimePackage == true`
AND no `/src/` files. Inspecting the shipped stock `.app`:

- The outer `.app` is a ready-to-run wrapper: `readytorunappmanifest.json` +
  an **embedded regular `.app`** + `publishedartifacts/` (the R2R DLL(s) +
  `Merkle.json`).
- The embedded regular app has **1319 `/src/` AL files** and **no `/bin/`
  emitted content** (no `EmittedContent.json`). So `ReadSourceCodeFilePaths()`
  is non-empty → the recompile-free path is never taken.

`Get-NAVAppRuntimePackage` (`NavAppRuntimePackageGenerator.MakeRuntimePackage`)
*does* produce a source-stripped runtime package — but it builds it via
`compilation.Emit(...)`, i.e. it recompiles, and it reads from an
already-published app in the DB. So it can't bootstrap a stock app without a
prior compile.

**Conclusion:** the shipped artifacts contain AL source + R2R native DLLs, but
no path consumes the R2R DLLs without first recompiling the AL.

### The dev endpoint recompile fails on Linux (the original problem)

```
POST /BC/dev/apps  (Microsoft_System Application_28.1.49838.51482.app)
 -> HTTP 422
 -> "Extension compilation failed
     ControlAddIns/src/WelcomeWizard.ControlAddin.al(21,21): error AL0327:
     Missing file 'Resources\WelcomeWizard\js\Startup.js'. ..."
```

```
POST /BC/dev/apps  (Base Application)   [from prior investigation]
 -> AL1024: 'System Application' ... Symbols ... could not be found in the database
```

The dev endpoint recompiles from AL source; on Linux that recompile breaks for
the stock apps. This is the wall the no-recompile mechanism routes around.

---

## The mechanism that works: snapshot the compiled SQL state, replay it

### Why it works (empirical)

BC's sandbox demo DB ships **134 apps already published** in
`[Published Application]` + `[Application Object Metadata]` (14,140 compiled
object rows at emit version 28014). NST still recompiles the 5 Base Application
assemblies on a *cold* boot (the shipped R2R DLLs are pre-seeded to the assembly
cache with the correct SHA256 filenames, but NST's boot validation re-emits and
the hash drifts on Linux, so it rebuilds them — overwriting the 18 MB shipped
DLL with its own 41 MB build).

But a **warm restart against the same DB does ZERO recompiles** — NST trusts the
artifacts it previously built and persisted. Verified:

| Boot | DB state | "Compiling the application object assembly" lines |
|---|---|---|
| cold (`none`, full demo DB) | freshly restored | **5** (the 5 Base App chunks, ~8 min total) |
| warm (`docker compose restart bc`) | same DB | **0** |

So the compiled state is a one-time artifact per DB. Capturing it and replaying
it into another database is a no-recompile deployment.

### The tool: `scripts/management-publish.py`

```
management-publish.py list-apps
management-publish.py snapshot --apps <id[,id...]> --name <name>
management-publish.py restore  --name <name>        # or --bak <path>
```

`snapshot` copies, for the requested apps' `[Package ID]`s, every row of the
five tables that hold a published+installed+compiled app —

- `Published Application`
- `Installed Application`
- `NAV App Installed App`
- `Application Object Metadata`   ← the compiled metadata/IL blobs
- `Application Resource`

— into a side database (`BCAPPSNAP`) and `BACKUP`s it to a `.bak` on the shared
`bc-snapshots` volume (mounted on **both** the bc and sql containers because
`BACKUP`/`RESTORE FROM DISK` run on SQL Server's own filesystem — same reason
the license bind-mount is on both, see CLAUDE.md). Blob columns ride along
natively in the `.bak`.

`restore` restores the `.bak` and `INSERT … SELECT`s the rows back into CRONUS
(excluding the non-insertable rowversion column, wiping any existing rows for
those package ids first). NST then activates the apps on next start with no
recompile.

### Entrypoint integration (additive, default-off)

`BC_RESTORE_SNAPSHOT=<name>` in the entrypoint restores the snapshot during DB
setup, before NST starts. Typical flow:

```bash
BC_CLEAR_ALL_APPS=system-only BC_RESTORE_SNAPSHOT=stockchain \
  docker compose up -d --wait
```

(`system-only` clears to the System app; the snapshot re-adds the precompiled
chain.) Default unset = no behavior change.

---

## Verification (exact commands + outputs)

All runs against `bc-runner:local` (BC 28.1 sandbox w1, platform 28.0.51409),
2026-06-15.

### 1. The dev endpoint recompile fails for the stock app (the problem)

```
$ docker exec ...bc-1 curl -s -o /tmp/out -w "%{http_code}" -u BCRUNNER:Admin123! \
    -X POST -F "file=@.../Microsoft_System Application_28.1.49838.51482.app" \
    "http://localhost:7049/BC/dev/apps?SchemaUpdateMode=forcesync"
HTTP=422  elapsed=25s
{"Message":"Publishing failed due to 'Extension compilation failed\n
 ControlAddIns/src/WelcomeWizard.ControlAddin.al(21,21): error AL0327:
 Missing file 'Resources\WelcomeWizard\js\Startup.js'. ..."}
```

### 2. Cold vs warm boot proves the recompile is one-time per DB

```
# cold boot, full demo DB (BC_CLEAR_ALL_APPS=none):
$ docker compose logs bc | grep -c "Compiling the application object assembly"
5                                   # 5 Base App chunks, ~1:40–1:54 each

# warm restart, same DB (docker compose restart bc):
$ docker compose logs --since 90s bc | grep -c "Compiling the application object assembly"
0
```

### 3. Snapshot the precompiled chain, restore into a cleared DB

```
# Cleared baseline (BC_CLEAR_ALL_APPS=system-only): no stock apps, no Base App objects
$ sqlcmd ... "SELECT COUNT(*) FROM [Published Application]"   ->  0
$ curl .../BC/ODataV4/Company('...')/Chart_of_Accounts        ->  (entity absent)

# Snapshot from a DB where the chain is compiled (3 app ids):
$ management-publish.py snapshot \
    --apps 63ca2fa4-...,f3552374-...,437dbf0e-... --name stockchain
Published Application: 3
Installed Application: 3
NAV App Installed App: 3
Application Object Metadata: 9129
Application Resource: 86
[snapshot] backing up BCAPPSNAP -> .../stockchain.bak
[snapshot] assembly cache -> .../stockchain.cache.tar (540 MB, 2 dir(s))

# Restore into the cleared CRONUS:
$ management-publish.py restore --name stockchain
Published Application: 3 rows
Installed Application: 3 rows
NAV App Installed App: 3 rows
Application Object Metadata: 9129 rows
Application Resource: 86 rows
[restore] assembly cache extracted ...
```

### 4. After restore + restart: zero recompile, apps published+installed+functional

```
$ docker compose restart bc           # warm restart, restored DB + cache
$ docker compose logs --since 90s bc | grep -c "Compiling the application object assembly"
0                                     # NO recompile

$ sqlcmd ... "SELECT [Name] FROM [Published Application]"
Base Application
Business Foundation
System Application
$ sqlcmd ... "SELECT COUNT(*) FROM [NAV App Installed App]"   ->  3   (installed for tenant)

$ curl -u BCRUNNER:Admin123! \
    "http://localhost:7048/BC/ODataV4/Company('CRONUS%20International%20Ltd.')/Chart_of_Accounts?\$top=2"
200
{"@odata.context":".../Chart_of_Accounts","value":[
  {"No":"1000","Name":"BALANCE SHEET","Income_Balance":"Balance Sheet",
   "Account_Type":"Heading", ...}, ... ]}
```

`Chart_of_Accounts` is **Base Application** page 16 over table 15 (G/L Account).
It returns live data, proving the Base Application's objects are deployed and
working — with **zero recompile** on the activating boot. OData `$metadata`
likewise lists Base App entities (`SalesOrder`, `Chart_of_Accounts`,
`ItemSalesByCustomer`, ...) that are absent in the cleared baseline.

### Recreate vs restart nuance

`docker compose restart bc` (reuse the container) reliably activates the
restored chain with **0 recompiles**. A full container **recreate**
(`docker compose up -d --no-deps bc`) was observed to still recompile the 5
Base App chunks even with the SQL rows and the NST-built assembly cache present
— NST's boot-time runtime-assembly validation on a freshly-created container is
stricter than file presence (it re-emits and the hash drifts on Linux; see
MICROSOFT-FEEDBACK.md Finding 1). The apps end up functional either way; the
recompile only costs boot time. For the no-recompile guarantee, activate via
`restart` (or keep the bc-service assembly-cache volume warm across recreates,
which is the normal CI pattern — the cache is a persistent named volume).

---

## Limitations & notes

- **Capture requires one compile.** The snapshot must be taken from a DB where
  NST has already compiled the apps once (e.g. a full `none` boot, or BC's stock
  warm cache). After that, the `.bak` is reusable across as many fresh
  databases / CI runs as you like, with no recompile. This is the same model
  Microsoft uses internally (the build server populates the cache once).
- **Same platform/emit version.** A snapshot is valid only for the BC platform
  version whose emit version (28014 here) it was compiled against. Restoring it
  onto a different platform build would make NST detect an emit-version mismatch
  and recompile. Name snapshots per BC version.
- **The R2R assembly-cache DLLs** are handled by the entrypoint's existing R2R
  pre-seed step (it extracts `publishedartifacts/` into the assembly cache).
  The snapshot does not need to carry them; the compiled `[Application Object
  Metadata]` blobs are what NST consults to skip recompile, and the on-disk
  assembly cache is reconstructed from the artifact. (If a future change makes
  the on-disk assembly the gating factor, snapshot the assembly-cache directory
  alongside the `.bak`.)
- **This is a workaround, not the upstream fix.** The root cause is the
  environment-sensitive AL→C# emitter / Merkle re-emit validation drifting on
  Linux (see MICROSOFT-FEEDBACK.md "Finding 1"). If Microsoft shipped the
  emitted C# in the `.app` or hashed AL bytecode instead of emitted C#, the
  shipped R2R DLLs would be accepted directly and none of this would be needed.
- **In-process injection was investigated and rejected** as a route: the
  in-process `NavManagementTasks.PublishNavApp` is reachable (no WCF/auth
  needed) but recompiles for source-bearing packages, so it offers no advantage
  over the dev endpoint for stock apps.
