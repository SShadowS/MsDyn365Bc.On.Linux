# NST STARTUP profile (2026-08-08) — read this first

Everything below the next heading is about **test execution** throughput and
predates the current configuration; several of its claims are stale (it says
Server GC and `TieredCompilation=0` break the API endpoint — both are the
shipping defaults today, see CLAUDE.md). This section is about **startup**,
which is where CI wall-clock actually goes once the caches in CLAUDE.md are in
place: 80s of a 90s boot.

Collected with the entrypoint's own `BC_PROFILE_NST=1` hook (suspends NST on
`/tmp/nst-diag.sock` until `dotnet-trace` attaches, so the trace starts at the
first instruction), 120s window, Speedscope, BC 28.1, 4-vCPU box, DB snapshot
+ warm assembly cache. NST startup was 90s under the tracer vs 76s without.

**Startup is blocked, not busy.** Main thread: **100s blocked, 20s CPU**.
Across all 47 threads only ~33s is `CPU_TIME`. Chasing CPU here is chasing 20%.

Main thread, blocked time by nearest managed caller:

| | |
|---|---|
| `Console`→`Interop.Sys.Read` | 35.6s — **not a cost**, BC idling on stdin after readiness; the trace window outlives startup |
| `SHA256`→`OneShotHashProvider` | **29.2s** |
| `Monitor.Wait` | 13.1s |
| `ModuleHandle.ResolveTypeHandle` | 5.0s |
| `Inflater.Inflate` | 3.9s |

## 1. Merkle validation of the assembly cache — the big one

The hashing resolves to one call path, and it is 245.9s of *aggregate thread
time* (it runs under `Parallel.For`, so wall time is far less — but it is the
single largest consumer in the trace):

```
Parallel.ForWorker
  SimpleMerkleTree.IsValidInput
    SimpleMerkleTree.MerkleProof.IsValid
      SimpleMerkleTree.CombineHash
        SHA256.HashData
```

`Microsoft.Dynamics.Nav.Runtime.Apps.SimpleMerkleTree` is BC verifying the R2R
assembly cache — the `{RuntimePackageId}_<N>_Merkle.json` files the entrypoint's
pre-seed already writes. So **persisting the assembly cache buys compile time
and pays it partly back in hash validation.**

### Tried it. It is 10x WORSE. Do not retry.

The obvious move is a JMP hook forcing `MerkleProof.IsValid` to return true.
Implemented as an opt-in Patch #30, measured, and reverted (commit b99383d and
its revert). Interleaved runs, same container, only the env var changing:

| | total | NST | dev endpoint |
|---|---|---|---|
| validation ON (normal) | 96s | 85s | HTTP 401, healthy |
| validation SKIPPED | **913s** | **903s** | **HTTP 000, never healthy** |

**The validation result is not a checkbox — it selects BC's loading strategy.**
With the hook on, BC accepts cache entries whose proofs would have failed, then
fails to load them and falls back:

```
CLR type load failed -- Assembly: F2B3AE52321A9D8D...                        x10
Switching from OneApplicationMultipleAssemblies to OneApplicationObjectOneAssembly  x8
Loading assembly into the Neither context from path /usr/share/Microsoft/... x8
```

`OneApplicationMultipleAssemblies` is the fast bulk path; the fallback loads
per application object. So the hashing is doing useful triage — it tells BC
which cached assemblies it can bulk-load and which must be rebuilt, and paying
29s to avoid that fallback is a bargain, not waste.

The corollary matters for anything else in this file: **time spent in the
assembly cache path is not automatically removable.** Measure the end state,
not just the phase you shortened.

## 4. Process snapshot (CRIU) — measured constraints, NOT yet attempted

With the caches in CLAUDE.md in place a boot is ~90s, of which ~80s is NST
startup, and the two direct attacks on that failed (tiering: noise; Merkle
skip: 10x worse, above). The remaining lever is to not run startup at all.

Measured on a healthy BC 28.1 instance at readiness, so nobody has to
re-derive them:

| | |
|---|---|
| RSS | 2.24 GB |
| **private dirty — the checkpoint payload** | **1.80 GB** |
| threads | 40 |
| open fds | 838 |
| **established sockets to SQL** | **17** |

What those numbers imply:

- **Self-hosted only.** Restoring 1.8 GB from local disk is single-digit
  seconds against 80s of startup. On a GitHub-hosted runner you would
  *download* it every job, which is the same transfer constraint that makes
  caching artifacts a losing trade (see CLAUDE.md).
- **The 17 SQL sockets are the hard part.** CRIU's `--tcp-established` needs
  the peer alive with matching sequence numbers; restoring against a fresh
  SQL container leaves all 17 dead. Either checkpoint SQL too (multi-GB, and
  its data is on a 4 GB tmpfs) or rely on SqlClient invalidating and
  reopening pooled connections — which will appear to work and then fail
  under load, looking like a flaky test rather than a broken restore.
- **The DB snapshot is a prerequisite, not an alternative.** A restored
  process image is only coherent against the exact database state it was
  checkpointed with. The post-publish snapshot provides that deterministically.

Not attempted here: this session ran on a Firecracker microVM whose kernel has
`# CONFIG_CHECKPOINT_RESTORE is not set`, so CRIU cannot run at any privilege
level and `docker checkpoint` (which sits on CRIU) is unavailable with it.
Stock Ubuntu hosts have the option enabled and `criu` in universe.

### Probed on GitHub-hosted runners, 2026-08-08 — IT WORKS; skip to "RESULT (run 18)"

Everything between here and that section is the path, kept because each dead
end costs a five-minute run to rediscover. The headline is that a booted BC
service tier checkpoints and restores intact — 137s of boot replaced by a 25s
restore, with the tenant still able to publish a newly compiled app — **and it
does so against a brand-new SQL Server container**, which was the case the whole
design hinged on.

The economics, up front, because they decide where this is worth building:
the checkpoint is 2.1 GB and the database backup 539 MB. On a self-hosted
runner they sit on disk and cost nothing. On a GitHub-hosted runner they would
have to go through the Actions cache — the artifact-caching ban in CLAUDE.md,
verbatim — and the 46s checkpoint plus that transfer is worse than the 137s
boot it replaces. **This is a self-hosted-runner feature.**

### The path — the wall was NOT the SQL socket pool

`.github/workflows/probe-criu.yml` ran this end to end. Results, so nobody
repeats the dead ends:

| runner | kernel | criu | outcome |
|---|---|---|---|
| ubuntu-latest | 6.17.0-azure | 4.0 and newest tag, from source | **unusable** — criu cannot parse its own vDSO (`kerndat_vdso_fill_symtable`), fails before touching any process |
| ubuntu-22.04 | 6.8.0-azure | from apt (in universe) | criu initialises, BC boots in 109s, dump reaches BC and **fails on established TCP** |

The 22.04 dump log names it exactly:

```
Error (criu/sk-inet.c:189): inet: Connected TCP socket, consider using --tcp-established option.
Error (criu/cr-dump.c:1361): Dump files (pid: 5383) failed with -1
Error (criu/cr-dump.c:1781): Dumping FAILED.
```

So **BC was never the problem** — the blocker is the ~17 pooled connections to
SQL, precisely as predicted from the socket count above. Checkpoint payload
measured 2.16 GB on the runner, matching the 1.80 GB measured locally.

`docker checkpoint create` has no flag for `--tcp-established`, but runc reads
`/etc/criu/runc.conf` (the dump log says so: "Would overwrite RPC settings with
values from /etc/criu/runc.conf"), so the option is reachable by writing
`tcp-established` into that file before checkpointing. That is the next thing
to try, and the probe now does.

Two cautions if you pick this up. `--tcp-established` makes the DUMP succeed;
RESTORE still needs a peer whose sequence numbers match, so restoring against a
fresh SQL container remains the hard, untested case. And a hosted runner is
ephemeral, so none of this measures the win — that only exists where the
checkpoint survives between jobs.

### SHIPPED (2026-08-08): snapshot mode. 135s cold boot -> 47s restore.

`scripts/snapshot.sh` + `docker-compose.snapshot.yml`, opt-in per MACHINE (the
operator creates a store directory; no pipeline changes). Full description in
**docs/SNAPSHOT.md** — read that first; this section is the road to it.

Verified end to end by `.github/workflows/test-snapshot.yml`, which removes the
containers between create and restore, so the restore runs against nothing but
the store and the persisted volumes:

| | |
|---|---|
| cold boot to healthy | 135s |
| create (checkpoint 43s + commit + backup + copy + resume) | ~110s, once |
| **restore, containers gone** | **47s** |
| novel app compiled after restore and published | HTTP 200 |

Four things the probe never had to solve, each of which cost a run:

| | |
|---|---|
| `docker start --checkpoint-dir` | **unimplemented in the daemon** — "custom checkpointdir is not supported". `create` accepts the flag, so a checkpoint written into the store can never be restored from there. It is taken in docker's own directory and copied in and out. |
| checkpoint file ownership | the daemon writes it root:700, so sizing, copying and deleting it all need sudo. A `du` that silently undercounted looked exactly like a checkpoint that was never written. |
| the container read-write layer | criu re-opens files by PATH, and `/tmp/bc-stdin` — the FIFO the entrypoint gives NST as stdin — is not in any volume. A recreated container fails with "Can't open fake fifo". `docker commit` of the stopped container carries it, and does preserve the FIFO. |
| `set -e` + `$(...)` | `sed` exits 2 on a missing file and that status leaves the script. One run died at exit 2 with no message. `shellcheck` now runs before anything that costs a boot. |

The 25-30s figure below is the process resume ALONE, with SQL already up and the
database already restored. 47s is what a real run pays.

### RESULT (run 18): it survives a FRESH SQL container too. 137s boot -> 25s restore.

The case that decides the design, not the easy one. sql is a different container
(id checked), its tmpfs verified empty of CRONUS before the database is reloaded
from a backup taken after the checkpoint, and the BC login recreated because it
went down with `master`:

```
cold boot to healthy: 137s
checkpoint took 46s              container status after checkpoint: exited
/tmp/sqlsnap/cronus.bak          539M
sql container: 8546dffa4b51 -> 6750dafdccdc
confirmed: fresh sql has no CRONUS database
logical names: data='Navision_NAV_Data' log='Navision_NAV_Log'
restore to OData 200: 25s
OData /Company : 200             publish HTTP 200   <- novel app, compiled after restore
```

So a restored NST reconnects to a SQL Server it has never spoken to, holding a
connection pool whose peer no longer exists, and the tenant still works well
enough to publish a freshly compiled extension.

Run 19 repeated it independently, because one observation of the case the whole
design rests on is not enough:

| | run 18 | run 19 |
|---|---|---|
| cold boot to healthy | 137s | 140s |
| checkpoint | 46s | 42s |
| **restore to OData 200** | **25s** | **29s** |
| novel app publish | 200 | 200 |

**Feasibility is settled**, and the restore is a ~110s saving against a cold
boot on this runner class.

What is left is engineering, not risk:

- carry the checkpoint (2.1 GB) and the backup (539 MB) across a job boundary —
  on a self-hosted runner that is "leave them on disk", which is the only place
  the economics work anyway (see point 2 below)
- decide what invalidates the pair: BC version, image, and the published app set
  at minimum — same shape as the three stamps in CLAUDE.md
- the two halves are **not independently restorable**. A BC checkpoint is only
  usable with a snapshot of the database it was booted against.

### RESULT (run 16): it works. A booted BC restores in 30s and still publishes.

ubuntu-22.04, kernel 6.8.0-azure, **criu v4.2.1 built from source**, host
networking, `/etc/criu/runc.conf` = `tcp-established`, `tcp-close`,
`file-locks`, `ext-unix-sk`, `link-remap`, `ghost-limit 512M`, plus
`vm.overcommit_memory=1` and `vm.max_map_count=1048576`:

```
cold boot to healthy: 127s
NST RSS: 2.39 GB   private dirty (checkpoint payload): 2.07 GB
checkpoint took 51s
container status after checkpoint: exited      <- it really stopped
restore to OData 200: 30s
OData /Company : 200
publish HTTP 200                               <- a NOVEL app, compiled after restore
checkpoint on disk: 2.1 GB
```

**127s of boot becomes 30s of restore**, and the tenant survives — a freshly
compiled app publishes through the dev endpoint afterwards, which is the check
that distinguishes this from Patch #30 (looked fine on a boot check, was
catastrophic). Every prerequisite is now known-good, so the design is viable
in principle and the remaining questions are about plumbing, not feasibility.

Sixteen runs to get here. Each barrier and its fix, so none is re-derived:

| barrier | run | fix |
|---|---|---|
| kernel cannot run criu at all (vDSO symtable) | 5-6 | `ubuntu-22.04`, **not** `ubuntu-latest`. NOT a "new kernel" problem — see below |
| `Connected TCP socket` (the SQL pool) | 7 | `tcp-established` in `/etc/criu/runc.conf` |
| `Some file locks are hold by dumping tasks` | 8 | `file-locks` |
| restore: `bind-mount /proc/0/ns/net … no such file` | 9 | `network_mode: host` — docker cannot rebuild a bridge netns whose init pid does not exist yet |
| restore: ENOMEM remapping | 13 | `vm.overcommit_memory=1`, `vm.max_map_count=1048576`. RAM was 4/15 GB used — a policy refusal, not exhaustion. .NET's GC gives NST a **263 GB** VmSize and criu must recreate every reservation |
| restore: `killed by signal 11`, no diagnostic | 14-16 | **criu 4.2.1 from source.** jammy packages 3.17 (2022), which dumps BC fine and segfaults the restored task |

That last row is the one worth remembering: three runs went into theories about
BC (W^X double mapping, glibc rseq, our JMP hooks) for a failure that was
entirely criu's age. `DOTNET_EnableWriteXorExecute=0` was tested and made no
difference; rseq was never the cause — 4.2.1 restores BC with it left on.
**Check the criu version before theorising about the process.**

What is still open, in the order it matters:

1. **A fresh SQL container.** Run 16 restored against the same live SQL
   container throughout. `tcp-close` means criu closes the pooled connections
   rather than repairing them, so what actually has to hold is that ADO.NET
   reconnects on first use — never put under stress.

   **Run 17 tried `docker compose restart sql` and the result is void.**
   `/var/opt/mssql/data` is a **tmpfs**, and a tmpfs is re-created every time a
   container starts — so the restart wiped the whole instance, `master`
   included. BC restored and then reported *"Cannot establish a connection to
   the SQL Server/Database … The database does not exist"*, OData 400, publish
   422. That is a measurement of deleting the database, not of replacing the
   peer. **Do not restart the sql container expecting its data to survive.**

   The probe now does the honest version (`FRESH_SQL_BEFORE_RESTORE`): back the
   database up *after* the checkpoint, when BC is frozen and the two are
   consistent; `docker compose rm -sf sql` and bring up a new container; assert
   the new instance really has no CRONUS; recreate the BC login (it lived in the
   wiped `master`) and restore the backup; then restore BC. The backup goes to a
   host bind mount, because `RESTORE FROM DISK` reads SQL Server's filesystem —
   the same constraint as the OPENROWSET license import in CLAUDE.md.

   That shape is also the answer to "what would production look like": a BC
   checkpoint is only usable together with a snapshot of the database it was
   booted against. Neither half is independently restorable.

   **Run 18 ran exactly that and passed** — see the RESULT section above. This
   item is closed; what remains of it is the job boundary, in point 2.
2. **Moving the payload.** 2.1 GB per checkpoint. On a self-hosted runner it
   sits on disk and costs nothing. Through GitHub's cache it is the artifact
   caching ban all over again (CLAUDE.md) — 10 GB repo cap, upload every run —
   so **this is a self-hosted-runner feature, and on hosted runners the 51s
   checkpoint plus the transfer is worse than the 127s boot it replaces.**
3. **What invalidates a checkpoint.** BC version, image, and the published app
   set at minimum. Same shape as the three stamps in CLAUDE.md.
4. **podman** — `podman container checkpoint/restore` is first-class rather
   than experimental and takes these options as flags. Not needed now that the
   docker route works, but it is the fallback if the daemon's netns handling
   becomes a problem again.

Reproducing it, on any host with `CONFIG_CHECKPOINT_RESTORE=y`:

1. Build criu **≥ 4.2.1** from source. Distro packages are too old.
2. `dockerd` with `{"experimental": true}` in `/etc/docker/daemon.json`.
3. Write the six options above into `/etc/criu/runc.conf`; set the two sysctls.
4. Run bc with `network_mode: host`.
5. `docker checkpoint create --leave-running=false <bc> cp1`, then
   `docker start --checkpoint cp1 <bc>`.
6. Pass/fail: `GET /BC/ODataV4/Company` returns 200 **and** a *novel* app still
   publishes through the dev endpoint. Anything less is not a pass.

If you resume this, do it where `criu dump` runs interactively in seconds
rather than five-minute CI round trips — a third of the runs here were spent on
defects in the probe rather than on the question.

## 2. XLIFF translation parsing — ~10s CPU, plus an ~11s serializer-generation stall

Top CPU frame across all threads is
`Microsoft.Xml.Serialization.GeneratedAssembly.XmlSerializationReaderxliff`
(5.1s), with `Read*_xliffFileBodyGroupTransunit` paths summing ~10s. BC parses
**XLIFF translation files** at startup.

`GeneratedAssembly` means the serializer was built **at runtime**: no
`*.XmlSerializers.dll` ships in the artifact (`find /bc/service /bc/artifacts
-iname '*XmlSerializers*'` → 0 files), so .NET generates it. The timestamped
boot log shows an 11.4s silence immediately after
`AssemblyResolve attempt: Microsoft.Dynamics.Nav.AL.Common.XmlSerializers`,
and a second burst for `Microsoft.Dynamics.BusinessCentral.Bcl.XmlSerializers`.

Two independent angles, neither tried: pre-generate the serializer assemblies
once (`Microsoft.XmlSerializer.Generator`) and drop them beside their owners so
the resolve succeeds; and/or stop feeding BC translations it will never use —
a pipeline runs one language.

## 3. Event-publisher reflection warmup — ~5s

`NavEventPublisherReflectionHelper.TryGetScopeTypeByExactMatchAndWarmupCache`
→ `RuntimeType.GetNestedTypes` → `ModuleHandle.ResolveTypeHandle`, 4.8s. This
is the "event subscriber resolution" item listed speculatively further down
this file, now measured.

## How to re-run this

```bash
BC_PROFILE_NST=1 docker compose up -d          # NST suspends until a client attaches
docker compose exec bc /path/to/dotnet-trace collect \
  --diagnostic-port /tmp/nst-diag.sock --duration 00:02:00 \
  --format Speedscope -o /tmp/nst.nettrace
```

The Speedscope JSON is **evented** (open/close), not `sampled` — aggregating it
means walking O/C events and attributing leaf time to the nearest managed
ancestor, since the leaves are the `UNMANAGED_CODE_TIME` / `CPU_TIME` pseudo
frames. A naive `profiles[*].samples` reader returns zero and looks like an
empty trace.

# Sequential Throughput Optimization Ideas

Current state: ~0.33s/method average (Bucket 4, single runner, headless Linux).
Goal: identify where time is spent and reduce irreducible overhead.

## Experiment Results

### Profiling (dotnet-trace, 2 min sample during ERM execution)

Key finding: **47% of time is UNMANAGED_CODE_TIME** (SQL Server processing),
only **2% is CPU_TIME**. This is an I/O-bound workload, not CPU-bound.

Top hot methods:
- `UNMANAGED_CODE_TIME`: 564s (47%) — SQL query processing, locks, transactions
- `AsyncMethodBuilderCore.Start`: 146s — async machinery overhead
- `TestClientProxy.Invoke`: 32s — test page client reflection
- `CallServerSync`: 25s — synchronous client→server RPC
- `BindingManager.DoFill`: 12.7s — page data binding
- `NstDataAccess.GetPage`: 12.5s — server-side page retrieval
- `ActionField` chain: 9.9s — field validation roundtrips

### Experiment 1: SQL Network Co-location (Docker bridge vs host network)

Hypothesis: Docker bridge network adds latency to BC↔SQL communication.
Result: **No measurable difference.**

| Setup | Run 1 | Run 2 | Run 3 | Avg |
|-------|-------|-------|-------|-----|
| Docker bridge (warm) | 76s | 74s | 65s | **72s** |
| Host network (warm) | 71s | 69s | — | **70s** |

Test: 5 codeunits, 301 methods from Tests-SINGLESERVER.
Conclusion: Network hop adds ~0.1ms/call which is negligible. The 47% unmanaged
time is SQL Server's internal processing (query compilation, locking, buffer ops),
not network latency. **Docker bridge is fine.**

### Experiment 2: Server GC (DOTNET_gcServer=1)

Hypothesis: Server GC reduces pause frequency, improving throughput.
Result: **Breaks the API endpoint.** BC's OData/API port (7052) returns 400
errors with Server GC enabled. The HttpSysStub or request handling pipeline
is incompatible with Server GC's thread pool behavior. **Cannot use.**

Baseline (Workstation GC): 62-64s avg (3 runs, warm).
Server GC: API broken, tests cannot run.

### Experiment 3: SQL Server Tuning (MAXDOP, ad hoc, cost threshold)

Hypothesis: BC generates many small queries; MAXDOP=1 and ad hoc optimization
should reduce SQL overhead.

Applied: `max degree of parallelism`=1, `cost threshold for parallelism`=50,
`optimize for ad hoc workloads`=1.

| Setup | Run 1 | Run 2 | Run 3 | Avg |
|-------|-------|-------|-------|-----|
| Baseline (defaults) | 62s | 60s | 61s | **61s** |
| SQL tuned | 65s | 61s | 61s | **62s** |

**No difference.** BC's queries are already single-threaded (small, simple),
plan cache is already warm, and ad hoc optimization doesn't help because the
same queries repeat. The 47% SQL time is irreducible query processing overhead.

### Summary

Three experiments tested, none improved throughput:
1. Network co-location: no effect (Docker bridge overhead negligible)
2. Server GC: breaks BC's API endpoint
3. SQL tuning: no effect (queries already optimal for this workload)

The ~0.2s/method execution speed appears to be the floor for the current
architecture. Further gains require structural changes (RPC short-circuit,
session pooling) or parallelization across multiple BC instances.

## Remaining Ideas to Test

### TCP Tuning (Nagle's Algorithm)
BC↔SQL communication uses TCP. Nagle's algorithm buffers small packets before
sending, adding latency to each of the thousands of tiny SQL round-trips.
Disabling Nagle (`TCP_NODELAY`) could reduce per-call latency. This would NOT
have shown up in bridge-vs-host test since both had Nagle enabled.

### SQL Forced Parameterization
BC may send ad-hoc SQL text for each query. `ALTER DATABASE CRONUS SET
PARAMETERIZATION FORCED` makes SQL Server reuse execution plans more
aggressively, reducing plan compilation overhead per query.

### SQL Packet Size
Default network packet size is 4096 bytes. Tuning this (smaller for many tiny
queries, larger for result sets) could reduce per-round-trip overhead.

### Transaction Log on tmpfs
Data files are on tmpfs but the log file may be on Docker overlay filesystem.
Every commit writes to the log. Check and move if needed.

### SQL Memory
Currently `MSSQL_MEMORY_LIMIT_MB=2048`. More RAM = larger buffer pool and plan
cache. Test with 4096 or unlimited.

### CPU Affinity
Pin BC and SQL to separate CPU cores to avoid context switching overhead.
`--cpuset-cpus` in Docker.

## Experiment Results (continued)

### Experiment 4: SQL Forced Parameterization
`ALTER DATABASE CRONUS SET PARAMETERIZATION FORCED`
Result: **No improvement.** 64s avg vs 62s baseline. May hurt because BC's
queries rely on literal values for optimal plans. *Platform-agnostic.*

### Experiment 5: SQL Memory (4096MB vs default unlimited)
`EXEC sp_configure 'max server memory', 4096`
Result: **No improvement.** 64s avg vs 62s baseline. Working set fits in
default memory allocation. *Platform-agnostic.*

### Experiments blocked by BC compatibility
- **Server GC** (DOTNET_gcServer=1): Breaks API endpoint
- **Tiered compilation off** (DOTNET_TieredCompilation=0): Breaks API endpoint
- **Quick JIT for loops** (DOTNET_TC_QuickJitForLoops=1): Breaks API endpoint
All JIT/GC changes are incompatible with BC's HttpSysStub. *Linux-only issue
(HttpSysStub is the Linux replacement for Windows HttpSys).*

### Experiment 6: TCP Nagle / Low Latency
Could not modify sysctl inside containers (read-only filesystem).
No measurable effect. 68s avg vs 62s baseline (noise). *Platform-agnostic.*

### Experiment 7: CPU Affinity (cpuset-cpus)
Pinned SQL to cores 0,1 and BC to cores 2,3 on a 12-core machine.
Result: **50% slower** (94s warm avg vs 62s). Starving both processes of
cores is worse than letting the OS schedule freely. BC uses many async
threads; SQL Server needs cores for internal task scheduling.
*Platform-agnostic.*

### Experiment 8: Transaction Log Location
Verified: both data (.mdf) and log (.ldf) are on `/var/opt/mssql/data` which
is tmpfs (RAM). Log I/O is not a bottleneck. Combined with DELAYED_DURABILITY
= FORCED, log writes are already minimal. SQL Server does not support disabling
the transaction log entirely — it's fundamental to ACID. *Platform-agnostic.*

### What actually helped
Only SQL overhead removal (Experiment 3b) produced measurable improvement.
Small benchmark (301 methods): **13% faster** (64s → 56s).
Full ERM benchmark (9,320 methods): **23% faster** (70.5 min → 54.4 min).

| Benchmark | Before | After | Improvement |
|-----------|--------|-------|-------------|
| 5 codeunits (301 methods) | 64s | 56s | **-13%** |
| Full ERM (9,320 methods) | 70.5 min | 54.4 min | **-23%** |

The larger improvement at scale suggests SQL overhead (query store, stats
updates) compounds over thousands of operations. *All platform-agnostic.*

Settings applied:
- Query store OFF
- Auto statistics OFF (update + create + async)
- Page verify NONE
- Delayed durability FORCED
- Change tracking OFF

## 1. Profile First — Find the Bottleneck

Before optimizing, attach `dotnet-trace` or `dotnet-counters` to the BC process
during a test run. Answer: what percentage of wall time is session setup vs AL
execution vs SQL vs GC vs idle/waiting?

```bash
# Collect a trace during a small test run
dotnet-trace collect -p $(pgrep -f Microsoft.Dynamics.Nav.Server) --duration 00:02:00
# Analyze with speedscope or dotnet-trace convert
```

If 40% is session overhead → patches will help a lot.
If 90% is AL execution → not much to squeeze sequentially.

## 2. Session Overhead Reduction

Each codeunit in isolation mode (130450) creates a fresh BC session. This involves:
- Extension loading / validation
- Permission set evaluation
- Feature flag / entitlement checks
- Telemetry context setup
- Azure AD / identity initialization

**Ideas:**
- Patch session init to skip non-essential steps (feature flags, entitlements,
  telemetry context). Similar to existing StartupHook patches but targeting
  `NavSession` or `NavServerSession` initialization.
- CRIU at session level — checkpoint a "warm session" state after first init,
  restore it for subsequent codeunits instead of creating from scratch. This
  is speculative but could eliminate per-codeunit startup cost entirely.
- Pre-warm the extension metadata cache so each new session doesn't re-validate.

## 3. More Runtime Overhead Stripping

Already patched: Watson, SideService, Reporting, AzureAD, ShowForm.

**Candidates to investigate:**
- Telemetry/diagnostics collection during test execution (NavOpenTelemetry,
  TraceWriter). Even with no-op logger, the call sites may do work before
  reaching the no-op.
- Permission checks — in test mode, SUPER user runs everything. Can we short-
  circuit the permission evaluation path?
- Event subscriber resolution — BC resolves subscribers dynamically on each
  event raise. Could we cache the resolution table?
- Extension dependency validation — checked on every session but never changes
  during a test run.

## 4. .NET Runtime Tuning

**JIT / Tiered Compilation:**
```bash
# Force aggressive optimization (skip tier 0 interpretation)
export DOTNET_TieredCompilation=1
export DOTNET_TC_QuickJitForLoops=1
# Or disable tiered compilation entirely (immediate full JIT)
export DOTNET_TieredCompilation=0
```

**GC Tuning:**
```bash
# Server GC with larger generations (reduce pause frequency)
export DOTNET_gcServer=1
export DOTNET_GCHeapCount=4
# Reduce GC pressure during test bursts
export DOTNET_GCConserveMemory=0
```

**ReadyToRun:**
- The BC service DLLs ship as R2R (pre-compiled). Test extension DLLs do not.
  Pre-compiling hot test DLLs with crossgen2 could help startup.

## 5. SQL Micro-Optimizations

tmpfs for data files showed no improvement (SQL buffer pool handles caching).
But there may be other angles:
- `OPTIMIZE_FOR_SEQUENTIAL_KEY` on hot test tables
- Increase SQL memory allocation (currently 2GB default)
- Disable SQL telemetry / query store during test runs
- Pre-create temp tables used by test framework

## 6. Test Runner Efficiency

- Batch multiple codeunits per session where isolation isn't strictly needed
  (risky — some tests leave dirty state)
- Reduce WebSocket round-trip overhead between test runner and BC
- Pipeline the next codeunit setup while current one is executing

## 7. Wild Ideas

- **Patch the AL interpreter hot loop** — if profiling shows a specific method
  in Nav.Ncl's AL execution engine is hot, a targeted JMP hook could optimize it
- **Shared memory IPC** instead of WebSocket for test runner ↔ BC communication
- **Snapshot/restore at DB level** between codeunits (SQL Server snapshots are
  near-instant) instead of relying on transaction rollback

## Linux-Exclusive Experiments

### Experiment 9: TuneD mssql sysctl Profile
**Blocked: requires sudo.** Could not apply sysctl changes in this session.
Key parameters to test: `vm.swappiness=1`, `vm.dirty_ratio=80`,
`net.ipv4.tcp_low_latency=1`. THP and CPU governor already optimal on host.
```bash
sudo sysctl -w vm.swappiness=1 vm.dirty_background_ratio=3 vm.dirty_ratio=80 \
  vm.dirty_expire_centisecs=500 vm.dirty_writeback_centisecs=100 \
  vm.max_map_count=1600000 net.ipv4.tcp_low_latency=1
```

### Experiment 10: SQL Trace Flag 3979 + writethrough
**TF 3979:** "not supported" by mssql-conf on SQL Server 2022-latest image.
May need specific CU level or RHEL-based image.
**control.writethrough=1:** Crashed SQL Server — tmpfs doesn't support O_DSYNC.
Both settings are moot when data is on tmpfs (no real disk I/O to optimize).

### Testing sysctl in CI
The sysctl experiments (Exp 9) need sudo which is available on GitHub Actions
runners. Run the TuneD mssql profile benchmark in a CI pipeline for proper
testing on standardized hardware.

## Linux-Exclusive Ideas (Still To Test)

### Microsoft TuneD `mssql` sysctl Profile
Official Microsoft/Red Hat kernel tuning for SQL Server on Linux.
Key parameters: `force_latency=5` (prevents CPU deep sleep between tiny ops),
`vm.transparent_hugepages=always`, `vm.swappiness=1`, `vm.dirty_ratio=80`.
Apply via `docker run --sysctl` or on the Docker host.
Test: apply sysctls, run 5-codeunit benchmark, compare to 56s baseline.
*Linux-exclusive — no Windows equivalent for these kernel parameters.*

### TCP_QUICKACK (Linux-only socket option)
Disables delayed ACKs per-socket. Windows has no equivalent. Our Experiment 6
failed because containers had read-only sysctl. Proper test: run container with
`--sysctl net.ipv4.tcp_low_latency=1` or use LD_PRELOAD shim to set
TCP_NODELAY + TCP_QUICKACK on all sockets created by BC process.
There's a known SqlClient-on-Linux performance issue (dotnet/SqlClient#422)
related to TCP behavior with MARS.
Test: strace/tcpdump to confirm delayed ACKs occur, then apply fix.
*Linux-exclusive — TCP_QUICKACK is a Linux-only socket option.*

### SQL Server Trace Flag 3979 (FUA/Write-Through)
Linux-specific optimization for XFS filesystem. Microsoft's own testing showed
~50% I/O reduction for write-intensive workloads. Our data is on tmpfs so
impact may be minimal, but transaction log writes may still benefit.
Test: `mssql-conf set traceflag 3979 on` + `control.writethrough 1`.
*Linux-exclusive — optimizes XFS FUA path that only exists on Linux.*

## Priority Order

1. **Profile** — without data, everything else is guessing
2. **Session overhead patches** — likely highest ROI if profiling confirms
3. **.NET tuning** — low effort, potentially meaningful
4. **Runtime stripping** — incremental gains, each patch helps a little
5. **SQL tuning** — probably minimal impact but cheap to try
6. **Test runner efficiency** — small gains
7. **Wild ideas** — high risk, explore only if profiling points there
