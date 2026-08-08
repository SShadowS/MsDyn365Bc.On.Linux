# CI step ordering — what's on the critical path, and what's already been tried

Read this before proposing a reordering or parallelization change to the
reusable workflows. It is not required reading otherwise; `CLAUDE.md`'s
"CI wall-clock" section covers the things that affect everyday work.

Profiled 2026-08-07 against bc-linux's own version matrix (public repo,
4-vCPU runners) and a Pageworks run (private, 2-vCPU, a real consumer
workload).

## The noise floor comes first

Ten legs of a single matrix run, doing identical work, spread **83-118s**.
Four consecutive runs had medians of 97 / 97 / 93 / 94s.

Nothing below roughly 10s is measurable from one pair of runs. If you
change something here, compare medians across all legs of several runs,
and be suspicious of any win that shows up in a sub-metric but not in
total job duration.

## Where the time goes

Both workload shapes are **BC-boot-bound**, and the boot window is
already as full as it can be.

bc-linux smoke leg (4-vCPU, ~88s):

| | |
|---|---|
| download artifacts + pull images (parallel) | 29s |
| `docker compose up -d` | 6s |
| toolchain + compile — hidden behind BC boot | 20s |
| **idle, waiting for BC** | **22s** |
| tests | 7s |

Pageworks (2-vCPU, 192s leg inside a 4m03s run):

| | |
|---|---|
| download artifacts + pull images (parallel) | 58s |
| `docker compose up -d` | 6s |
| toolchain + compile — hidden behind BC boot | 70s (36s of it compile) |
| **idle, waiting for BC** | **42s** |
| publish + tests | ~0s |

The consumer's compile finishes *entirely* inside the boot window and
still leaves 42s of exposed wait. There is no remaining work to move
into that window.

Inside the container, after the artifacts are present (cold local boot,
BC 28.0):

| | |
|---|---|
| Step 2 service tier | 1s |
| Step 2b merged assemblies + binary patches | 5s |
| Step 3 SQL wait + restore + selective filter | 3s |
| R2R pre-seed | 3s |
| **NST startup** | **31s** |
| **post-NST publish** | **24s** |

## Taken

### Booting sql and bc in parallel (2026-08-08)

`bc` gated on `sql`'s healthcheck (`condition: service_healthy`), so its
container sat in `Created` until SQL answered `SELECT 1`. Measured **5.8s** of
dead time on every boot, and most of that is polling rather than SQL: the
healthcheck's `interval` is 5s, so the earliest observable "healthy" is ~5s even
when SQL is ready at 2s.

The gate was redundant. `entrypoint.sh` Step 3 has always blocked on
`until sqlcmd … SELECT 1`, so BC already waits for SQL itself. Changed to
`condition: service_started`, which keeps the dependency graph — `docker compose
up bc` still brings sql up — without waiting on the health probe.

**What this does NOT do is overlap NST with SQL's startup.** NST is not started
until Step 3 has restored the demo database, created the login, imported the
license and run the app filter. It is gated on a restored *database*, not on a
reachable server. What overlaps is the entrypoint's pre-SQL work: the artifact
copy and the service-tier patching. So the ceiling is the gate itself, ~5-6s,
whatever else changes.

**Do not expect to see this in the total boot time.** I claimed the snapshot
test's cold boot was stable to ~1s, on the strength of four consecutive 137s
readings. The next run came in at 143s. The real series is
137/137/137/137/135/135/143 — an **8s spread**, mean 137.3, stdev 2.7 — so a 6s
effect is not resolvable there, and the 132s reading immediately after the
change is one sample inside the old band. It is not evidence.

What is measurable is the gate itself, because it is deterministic: the boot
step now records how long after `sql` started `bc` was allowed to start
(`GATE:` in the log, and a row in the run summary). That was ~5.8s and should
now be ~0. The saving is structural — bc's pre-SQL work now overlaps SQL's
startup instead of following it — and that is the claim, not a wall-clock
delta measured off one pair of runs.

The entrypoint's SQL wait was unbounded and is now capped
(`BC_SQL_WAIT_TIMEOUT`, default 600s). That is not optional with the gate gone:
compose used to fail fast and clearly when SQL was unhealthy, and without a cap
"sql never came up" would surface half an hour later as "bc never became
healthy", pointing nowhere near the cause.

## Dead ends

### Starting SQL during the artifact download

Reverted (3aec328, 6ff7e81). `bc` has `depends_on: sql: service_healthy`,
so the bc container genuinely does sit in `Created` state until SQL's
healthcheck passes, and that time is dead space at the head of the boot
window. The idea was to start sql while the BC artifact was still
downloading.

It cannot work: **sql cannot start before its own image is pulled, and
that pull takes about as long as the artifact download.** There is no
window to hide the boot in. Measured: sql up at t+28s against a t+29s
download — a 1s head start.

The follow-up attempt was to pull sql on its own first, on the assumption
it was the smaller and faster image. It is not. That made sql start at
t+35s, i.e. *later* than pulling both together.

Same root cause as the artifact-caching ban in `CLAUDE.md`: the transfer
is the constraint, and it's on Microsoft's and GHCR's side.

### Moving the toolchain install earlier

Net zero by construction. `Setup .NET` + `Install AL compiler` + symbol
staging currently hide behind BC boot. Pulling them into the parallel
download phase doesn't shorten the job — it converts hidden work into
exposed idle, because BC boot is the pole either way.

### Overlapping entrypoint Step 2/2b with Step 3

Costed and skipped. It looks like a 6s win (6s of local file work
alongside 6s of DB work) but it is 3s: the R2R pre-seed depends on
**both** halves — `CustomSettings.config` from Step 2 for the instance
name, and the restored DB from Step 3 for the runtime-package-id map — so
it can't move. The chain collapses from 12s to 9s, not to 6s. Not worth
restructuring a load-bearing block with export-scope hazards for 3s that
sits below the noise floor.

### Parallel publishing to the dev endpoint

Tried 2026-04-08, documented at the call site in `scripts/entrypoint.sh`.
The NST serializes publishes server-side; layered concurrency=4 took the
same ~27s as serial POSTs.

## Self-hosted runners

The numbers above are all GitHub-hosted, i.e. a fresh VM per job where
nothing survives. On a self-hosted runner the disk persists, and as of
2026-08-08 the pipeline exploits that without any configuration: the fetch
phase (29s at 4-vCPU, 58s at 2-vCPU — the largest single block in the smoke
leg) drops to roughly zero whenever the resolved build is already extracted,
and Step 2/2b's ~6s of service-tier patching is skipped when the volume's
stamp matches. See CLAUDE.md, "Reusing a warm filesystem is NOT the
artifact-cache ban", for the stamps and what invalidates each.

What that leaves is BC's own boot, which is unchanged — so a warm
self-hosted leg is bounded below by roughly `compose up` + NST startup +
publish + tests. Do not expect the fetch-phase saving to compound with
anything; it comes off the front of the job and the pole is still BC.

Two things a self-hosted operator has to handle that a hosted runner gets
for free:

- **Leftover containers.** The workflows now run `docker compose down
  --remove-orphans` before `up -d`. Without it, `up -d` adopts the previous
  job's still-running containers and the healthcheck goes green in seconds
  against the *previous* run's database — a pass that proves nothing.
- **Concurrency.** Two jobs on one host collide on the published 7045-7089
  ports. Give each runner its own compose project name and port offset (see
  README, "Running Multiple Instances"). A shared `artifact_cache_dir` is
  safe under concurrency — `download-artifacts.sh` locks it — but the ports
  are not.

## What would actually move the needle

The two big blocks are BC's own work: NST startup (31s) and the post-NST
publish (24s). Of the publish, ~22s is BC compiling the three test
framework apps that ship **no** precompiled DLL — see `CLAUDE.md`, "Why
the post-NST publish costs what it does". If Microsoft ever ships those
as ReadyToRun packages, that time becomes addressable and the
install-vs-republish question is worth reopening.
