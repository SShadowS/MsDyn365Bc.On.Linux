# Snapshot mode — booting BC from a CRIU checkpoint

Replaces a ~135s cold boot with a ~47s restore by resuming a checkpointed
service tier instead of starting one.

**Opt-in per machine, not per pipeline.** An operator sets a machine up once and
every pipeline that lands on it benefits; a pipeline never has to know whether
the runner it got can do this. On a GitHub-hosted runner nothing is set up, so
every command reports `disabled` and the caller cold-boots exactly as before.

A snapshot that cannot be used is never a build failure — the fallback is always
a cold boot.

**Only worth it on a runner that keeps its disk** — self-hosted runners and dev
boxes. See [Where this pays](#where-this-pays) before turning it on.

---

## What a snapshot is

Two files, valid only **together**:

| | | |
|---|---|---|
| `checkpoint/` | ~2.1 GB | the frozen NST process image |
| `cronus.bak` | ~540 MB | the database it was booted against |
| `bc-snapshot:<key>` | small | a docker image holding the container's read-write layer |

None of them restores on its own. The checkpoint holds a process whose memory
refers to that database's schema, its published-app metadata, its license and
its session state. Restore it against a different database and you get a BC that
answers requests and is quietly wrong. They are written and read as a set under
one key, and **the key is the whole safety story.**

The third one is easy to overlook. criu references open files by *path* and
re-opens them on restore, and some of those live in the container's read-write
layer rather than in a volume — the entrypoint's `/tmp/bc-stdin` FIFO, which NST
holds as stdin, is one. A container recreated from the plain `bc-runner` image
does not have them, so restore fails with `Can't open fake fifo [tmp/bc-stdin]`.
Committing the stopped container captures that layer, and restore builds its
container from the commit. Note this lives in the local docker image store, not
in `BC_SNAPSHOT_DIR`: `docker image prune` removes it and the snapshot then
declines to restore rather than failing obscurely.

## Turning a machine on

Two things, both once per machine. Nothing goes in a pipeline.

**1. Declare the store.** Either put `BC_SNAPSHOT_DIR` in the runner's
environment — `actions-runner/.env` applies it to every job that runner takes —
or simply create one of the well-known directories:

```bash
sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 /var/cache/bc-linux/snapshots
# or: ~/.cache/bc-linux/snapshots
```

The directory existing **is** the opt-in. It is presence rather than a config
flag because the directory has to exist and be writable for the feature to work
at all, so anything else would be a second source of truth that can disagree
with the first. Nothing creates it for you.

**2. Install the prerequisites** with `scripts/setup-snapshot-host.sh`. `scripts/snapshot.sh preflight` tells you
which are missing, and `status` tells you whether this machine is on:

```
$ scripts/snapshot.sh status
disabled (this machine is not set up for snapshots — see docs/SNAPSHOT.md)
```

To turn a machine back off, remove the directory (or unset the variable). To
retire the disk space as well, delete the store's contents.

## Prerequisites and the run loop

```bash
# 1. Host prerequisites (once). Idempotent; --check reports without changing
#    anything, and it asks before restarting docker because that stops every
#    container on the machine.
scripts/setup-snapshot-host.sh --check
scripts/setup-snapshot-host.sh

# 2. Every run. No BC_SNAPSHOT_DIR here — the machine already declared it.
export COMPOSE_FILE=docker-compose.yml:docker-compose.snapshot.yml
export BC_ARTIFACTS_DIR=/var/cache/bc-artifacts     # must be a HOST directory

scripts/snapshot.sh preflight        # is this host capable at all
scripts/snapshot.sh status           # hit / miss for the current key

if scripts/snapshot.sh restore; then
  :                                  # BC is up and serving
else
  docker compose up -d --wait        # cold boot
  scripts/snapshot.sh create         # leave a snapshot for next time
fi                                   # BC is running either way
```

`create` checkpoints BC — which stops it — and then resumes it from the
checkpoint it just wrote, so you get your BC back in ~25s rather than another
cold boot. Both commands leave the container healthy: they write the
`/tmp/bc-ready` marker the healthcheck looks for, which the entrypoint normally
writes and which a resumed process never reaches.

`scripts/snapshot.sh key` prints the key and every component of it — that is the
first thing to run when a hit was expected and did not happen.

### Why the checkpoint is copied around

`docker checkpoint create --checkpoint-dir` is accepted, but the matching
`docker start --checkpoint-dir` is **not** — the daemon answers `custom
checkpointdir is not supported`. The flag exists on the CLI and is unimplemented
in the daemon's start path. It is not a CRIU limitation and no CRIU option
changes it.

So the checkpoint is taken where docker expects it
(`<docker-root>/containers/<id>/checkpoints/cp1`), copied out into the store,
and copied back into the *new* container's directory on restore — a different
path, because it is a different container id. That is two 2.1 GB local copies
per cycle, which is cheap next to the boot it replaces, and it is the reason
`podman` would be a tidier host for this feature if it ever needs one: its
`checkpoint --export` / `restore --import` are the supported way to do exactly
this.

`docker-compose.snapshot.yml` is required, not optional. It puts `bc` on host
networking (Docker cannot rebuild a bridge network namespace on restore) and
mounts the backup directory into `sql` (`RESTORE FROM DISK` reads SQL Server's
own filesystem). `preflight` refuses to run without it.

### containerd leaks 2.1 GB into `/tmp` per checkpoint

`docker checkpoint create` stages the whole checkpoint in
`/tmp/ctrd-checkpoint<random>` on the **docker daemon's** filesystem and never
removes it. Nothing in docker cleans these up — not `docker system prune`, not
container removal.

On any distro where `/tmp` is a tmpfs — Arch and Fedora among them — that is
RAM. Seven of them were found after one benchmark series, about 15 GB, on a
machine with a 16 GB tmpfs.

What then fails is not the checkpoint. It is whatever writes to `/tmp` next,
which is typically runc's few-KB process spec, so the message names a file
nobody was thinking about:

```
write /tmp/runc-process3593261234: no space left on device
```

Across five runs the same exhaustion appeared as a failed restore, a bare `criu
failed: type DUMP`, a missing criu log, and "bc is not serving OData". None of
them said "disk full" until the raw stderr was read.

`snapshot.sh` now reaps this staging before and after every `create` and before
every `restore`, and `_check_space` refuses to start when the daemon's `/tmp` is
a tmpfs with under 4 GB free. To clear it by hand:

```bash
scripts/snapshot.sh reap
```

**Check the `Mounted on` column, and prefer the daemon's view.** A `-v` source
path is resolved by the daemon, so `docker run --rm -v /tmp:/t:ro busybox df -Ph
/t` always reports the filesystem that actually fills, whether or not the caller
shares it. On the machine measured here the two agree — a self-hosted runner's
`/tmp` is the host's — and the reading that appeared to rule out the tmpfs was
simply `df -Ph / /tmp /var/tmp /var/cache/bc-linux` with its rows attributed to
the wrong arguments. Passing one path at a time removes the ambiguity.

The same reasoning is why this project's own staging (`/var/tmp/bc-sqlstage`,
`/var/tmp/criu-work`) is under `/var/tmp` and why `setup-snapshot-host.sh`
writes `work-dir /var/tmp/criu-work` into `/etc/criu/runc.conf`. Those moves do
nothing about containerd's, which takes its path from the daemon's `TMPDIR`.

---

## The cache key

```
v1
artifact=<resolved app url>|<resolved platform url>
image=<bc-runner image digest>
apps=<sha of the normalised app set>
config=<sha of bc's resolved compose service>
license=<sha of the license file, or "artifact-default">
runtime=<criu version>|<architecture>
```

Each component is here because changing it makes the checkpoint **wrong**, not
merely old.

### `artifact` — which BC build, country and type

The **resolved** urls, read from `download-artifacts.sh`'s own
`.bc-artifact-cache` stamp — not the version you asked for. This is the single
biggest lever you have over hit rate, and it is covered in
[Keeping a snapshot valid](#keeping-a-snapshot-valid-for-as-long-as-possible)
below.

**Localization is in here.** The country and the artifact type are part of the
app url — `…/sandbox/28.1.49838.53507/w1` versus `…/de` — so a `w1` snapshot can
never be handed to a `de` run. That matters more than it might look: the country
determines the demo database that gets restored, the localized app set published
into it, and the evaluation company name, all of which are baked into the
checkpoint and its paired backup.

It is keyed twice over, in fact — `BC_COUNTRY` and `BC_TYPE` also reach `config`
through bc's environment. Either alone would be sufficient; both are asserted by
`test-snapshot-key.sh` so a refactor cannot quietly drop one. Note that the
*platform* url is country-independent, so the app url is the half that carries
it.

### `image` — which bc-runner

The image digest. The patched service tier, `StartupHook.dll`, the stubs and the
entrypoint are all frozen inside the checkpoint, so a rebuilt image is a
different checkpoint. Pulling a new `:latest` invalidates every snapshot on the
host.

### `apps` — which extensions were installed

`BC_KEEP_APP_IDS` (sorted and deduplicated, so reordering the list does not
invalidate), `BC_CLEAR_ALL_APPS`, and the **contents** of `BC_TEST_APPS` if set.

`BC_KEEP_APP_IDS` is your app's transitive dependency closure, so it moves when
your dependencies move and **not** on every commit. That is what makes any of
this cacheable — and it is also why one snapshot serves many different apps;
see below.

### `config` — how BC was launched

A hash of `bc`'s fully resolved compose service: image reference, environment,
ports, volumes, network mode. NST holds these values in memory and keeps using
them after a restore *whatever the environment says at that point* — point a
restored checkpoint at a different SQL host and it carries on talking to the old
one. So all of it is keyed.

The app variables are removed from this hash before it is taken, because they
are keyed better under `apps` (as a raw string, `aaa,bbb` and `bbb,aaa` would be
different keys for an identical snapshot).

### `license` — which license was imported

The license is imported into the database before NST starts and NST caches it,
so a different license is a different checkpoint. Hashed, never stored.

### `runtime` — criu and architecture

criu's image format is version-coupled: **criu 4.2.1 or newer is required**, and
a different criu version is a different key. 3.17 — which is what Ubuntu 22.04
packages — dumps BC perfectly and then segfaults the restored process, so
`preflight` rejects it outright.

---

## One snapshot, many apps

**Yes — two different apps share a snapshot as long as their dependency closures
match.** This is the design, not a lucky accident: a snapshot is taken *before*
any consumer app is published, so what it contains is Microsoft's apps, the test
framework, and the TestRunnerExtension. Your code is never in it.

Concretely, `resolve-keep-app-ids.py` seeds the closure from the app's declared
`dependencies` and **never from the app's own `id`**. So an app's identity,
name, publisher and version do not reach `BC_KEEP_APP_IDS`, and therefore do not
reach the key:

| two apps differing in | shares a snapshot |
|---|---|
| id, name, publisher, version | yes |
| source code, objects, translations | yes |
| the `platform` / `application` version values | yes (their presence is what seeds, not their value) |
| a dependency added, removed or swapped | **no** — different closure |

It holds **across repositories** on the same machine too. The store is per
machine and keyed only on the components above, so two unrelated products with
the same closure use the same snapshot, and the second one to run gets a hit it
did nothing to earn. The host path of each repo's artifact cache is deliberately
normalised out of `config` for exactly this reason — otherwise each repo's
`${{ github.workspace }}/artifact-cache` would give it a private key and its own
2.6 GB copy.

Two things break the sharing, both avoidable:

- **`BC_TEST_APPS`.** It bakes the named apps into the snapshot, so their
  contents are part of the key and every rebuild of your app is a new snapshot.
  Publish after restore with `scripts/publish-app.sh` instead.
- **Anything else in the key differing between the two pipelines** — most often
  a different BC version pin, a different runner image tag, or a different
  license. Align those and the sharing follows.

## Keeping a snapshot valid for as long as possible

**Pin a full BC version.** This is the one that matters.

`BC_VERSION=28.1` is a *prefix*. `download-artifacts.sh` resolves it to the
newest build under it, and Microsoft ships hotfixes under the same short version
several times a day. Every one of those resolves to a new url, which is a new
key, which is a rebuilt snapshot — so a pipeline pinned to `28.1` may never get
a hit at all.

```bash
BC_VERSION=28.1                  # resolves to a new build several times a day
BC_VERSION=28.1.49838.53507      # stable until you change it
```

Bump the pin deliberately — weekly, or when you actually want the newer build.
Between bumps the key does not move and every run restores.

This is not a workaround for a limitation; it is the same reasoning as the
artifact cache (`CLAUDE.md`, "Reusing a warm filesystem is NOT the
artifact-cache ban"). Keying on the resolved build is what stops a checkpoint
built from one set of binaries being reused against another.

**The rest, in rough order of how often it bites:**

| do | instead of |
|---|---|
| pin `BC_VERSION` to a full version | a short prefix that Microsoft moves |
| pin `BC_RUNNER_IMAGE` to a digest or `:<sha>` tag | `:latest`, which changes under you |
| publish your apps **after** restore, with `scripts/publish-app.sh` | `BC_TEST_APPS`, which bakes them into the snapshot and rebuilds it whenever your code changes |
| keep ports, credentials and `DOTNET_*` knobs fixed across runs | varying them per job |
| `docker compose down` between runs | `down -v`, which destroys the service volume the checkpoint depends on |

A snapshot is not consumed by use — restoring does not invalidate it, so one
snapshot serves every run until something in the key moves.

## What invalidates a snapshot

**Key changes — a clean miss, next run rebuilds:**

- a different resolved BC build (including a hotfix under the same short version)
- a different country or artifact type
- a rebuilt or re-pulled `bc-runner` image
- a dependency added to or removed from your app's closure
- a changed port, credential, license, or `DOTNET_*` tuning value
- an upgraded criu

**Not in the key, and still fatal at restore time — falls back to a cold boot:**

- **`docker compose down -v`.** `/bc/service` is a volume, and criu references
  mapped files by path: the restored NST re-opens the same DLLs. Destroy the
  volume and the snapshot cannot be used. `restore` checks the volume's own
  stamp against the snapshot's and declines rather than trying.
- **Moving the snapshot to a different machine** whose CPU lacks a feature the
  original had. Architecture is in the key; CPU *models* are not, because
  encoding one would fragment the store across machines where restore would have
  worked fine. On a heterogeneous self-hosted fleet, give each machine class its
  own `BC_SNAPSHOT_DIR`.
- **A substantially different kernel.** Not keyed, for the same reason.

Every one of these is caught: the restore is verified (OData must return 200)
before it is accepted, and a snapshot that fails to restore is discarded so one
bad run does not poison every later one.

`BC_SNAPSHOT_REFRESH=1` forces a rebuild without waiting for a key change.

---

## Where this pays

| | GitHub-hosted runner | self-hosted runner / dev box |
|---|---|---|
| store between runs | nothing survives | a directory on disk |
| cost to keep 2.6 GB | Actions cache: 10 GB repo cap, uploaded every run | free |
| verdict | **worse than booting** | **~110s saved per run** |

On a hosted runner the snapshot would have to travel through the Actions cache
on every job — the artifact-caching ban in `CLAUDE.md`, verbatim — and creating
it costs more than the boot it replaces. This is a self-hosted feature, in the
same way the warm service tier and warm artifact cache are.

## Measurements

Two machines, and they say different things. **Quote the one that matches your
hardware**, because the ratio depends on it far more than expected.

### A real machine — Ryzen 5 5600X, 12 threads, 31 GB, btrfs, kernel 7.1.4

Bench run 17, n=3 per rung, every iteration succeeding:

| rung | median | min-max |
|---|---|---|
| warm (volumes kept, no snapshot) | **73s** | 71-74 |
| restore (snapshot mode) | **61s** | 61-61 |
| checkpoint create | 34s | — |

**12s saved, 1.2x.** Not the 2.8x the hosted runners suggested, and the reason
is the baseline: this box boots BC in 73s, so there is far less startup to skip.

Both rungs include a `docker compose down`, so they are comparable; the restore
itself, measured from inside `snapshot.sh`, is **37s** of that 61s.

#### `DOTNET_GCHeapCount` is the lever on the restore

Sweep of four GC configurations, all in one job (`scripts/bench-criu-gc.sh`):

| configuration | vmas | checkpoint | boot | criu | restore total |
|---|---|---|---|---|---|
| baseline (Server GC, heaps = ncpu) | 5,645 | 3.0 GB | 49s | 26s | 30s |
| **Server GC, `DOTNET_GCHeapCount=2`** | 5,138 | **1.5 GB** | **49s** | **12s** | **16s** |
| Server GC, `DOTNET_GCHeapCount=1` | 4,987 | 1.3 GB | 51s | 11s | 14s |
| Workstation GC (`DOTNET_gcServer=0`) | 5,544 | 2.0 GB | 49s | 17s | 20s |

**criu time tracks checkpoint BYTES, not mappings.** Fewer heaps commit less
memory, the checkpoint halves, and the restore follows it almost linearly. The
mapping count barely moves and is irrelevant — worth stating plainly, because
`vm.max_map_count >= 2^20` in the setup script makes the NST look like it has a
huge number of regions. It has about 5,000; the requirement is defensive.

**Boot does not regress.** This was expected to be a trade — Server GC is the
default precisely to speed up the parallel Roslyn compile during startup and
extension publish — and at 2 heaps the trade does not appear: 49s against a 49s
baseline. One heap costs ~2s. That is the reason the boot column exists.

What is still unmeasured is **test execution**. Boot is a compile-heavy proxy
and it is clean, but a long test run is a different workload, and this repo's
smoke test cannot stand in for a real suite. Measure it before adopting
`GCHeapCount` anywhere that runs many tests.

Not a finding, despite appearing to be one: an earlier sweep had **every**
Workstation GC restore fail with `NavODataServiceUnavailableException`, and it
was briefly written up here as an incompatibility. The next sweep restored it
3/3. One run in four across this series produced a spurious all-restores-failed
result for some configuration; treat a single failing sweep as noise and re-run
before concluding anything from it.

Between-run variance is large enough to mislead: the same baseline measured
18s, 19s and 25s across three jobs with no code change. Only compare
configurations **within one job**.

#### Where the 37s goes

| phase | time |
|---|---|
| sql up + BC login + `RESTORE DATABASE` | ~9s |
| staging the checkpoint into the new container | **1s** |
| `docker start --checkpoint` (criu maps the process back) | **27s** |
| BC serving OData after criu returned | ~0s |

Three things follow, and they are the useful part of this whole exercise:

- **criu is 73% of it.** Attacking SQL or the copy cannot move the total much.
- **The copy is already free.** `btrfs filesystem du` on the store reports
  `Total 3.54GiB, Exclusive 0.00B, Set shared 2.38GiB` — every extent is
  shared, so `--reflink=auto` is doing exactly what it was added for. An
  earlier reading that said otherwise used `du`, which cannot see sharing.
- **BC is ready the instant criu returns.** There is no post-restore warm-up to
  optimise away; the restored NST reconnects to the fresh SQL container on
  first use, as intended.

### A GitHub-hosted runner — 4 vCPU

| rung | median | min-max |
|---|---|---|
| cold boot | 130s | 108-143 |
| restore | 47s | 43-50 |

**~85s saved, ~2.8x.**

### What that comparison actually shows

Look at the restores: **47s hosted, 37s on a machine that is nearly twice as
fast at everything else.** The restore barely moved, while the boot it replaces
nearly halved. That is because the restore is dominated by criu mapping a
263 GB-VmSize process back in — page-table work that a faster CPU does not make
proportionally cheaper — whereas a cold boot is CPU-bound JIT and AL compilation
that does scale.

The practical consequence: **the faster your machine, the smaller the win.**
A slow 2-vCPU CI box has the most to gain; a fast workstation the least. Do not
quote 2.8x for a machine like the one above, and do not quote 1.2x for CI.

It also means the remaining time is in the one phase hardest to attack. Keeping
the sql container up between jobs would recover ~9s of the 37s; nothing
available recovers much of criu's 27s.

### Not reproducible on Windows

`docker checkpoint` is a front end for CRIU, and CRIU is Linux-only. Windows
containers have no checkpoint/restore equivalent, so skipping NST startup by
resuming a frozen service tier is not something a Windows BC container can do at
any speed. That makes this a structural difference between the platforms rather
than a tuning difference — but the Windows-side baseline to compare against
belongs in `PipelinePerformanceComparison`, which measures it directly; do not
pair these numbers with an estimated Windows figure.

`PERFORMANCE-IDEAS.md` has the full history, including every barrier and its
fix, and the several theories that turned out to be wrong.

## Privilege

**`scripts/snapshot.sh` needs no `sudo`.** Running it does need membership of the
`docker` group, which is root-equivalent by construction — but nothing beyond
what building anything with Docker already requires.

That was not true at first, and the reason is worth recording. Three separate
things had been conflated:

| what | why it looked privileged | where it actually belongs |
|---|---|---|
| `vm.overcommit_memory`, `vm.max_map_count`, `/etc/criu/runc.conf` | applied on every run | **one-time machine config** — `setup-snapshot-host.sh` persists them, the run path only checks |
| `/tmp/criu-work`, the backup staging dir | `sudo` fallbacks added when docker had already created them as root | create them **first**, as yourself; the privilege was fixing damage caused by ordering |
| the checkpoint under `<docker-root>/containers/…` | genuinely root — the daemon writes it `root:700` | copied **through the docker socket**, using authority the caller already holds |

Only the third is a real requirement, and it does not need `sudo` to satisfy it.
`setup-snapshot-host.sh` still needs root, once, to write host configuration —
but that is a human running a setup script, not a CI job holding a blanket
grant.

## Benchmarking it on your own machine

The published numbers come from GitHub-hosted runners, which can only show that
the restore is **correct** — the store does not survive the job there, so they
cannot show the win, and their cold-boot figure has a 35s spread. Your machine
is the real measurement:

```bash
export BC_ARTIFACTS_DIR=/var/cache/bc-artifacts
scripts/bench-snapshot.sh -n 5                 # warm vs restore
scripts/bench-snapshot.sh -n 3 --include-cold  # add a from-nothing baseline
```

Three rungs under an identical compose configuration, so only the cache state
varies, each timed the same way — command issued until `GET /BC/ODataV4/Company`
returns 200:

| rung | state |
|---|---|
| cold | no volumes, no snapshot — a machine that has never run BC |
| warm | volumes kept, no snapshot — what a self-hosted runner does today |
| restore | volumes kept, snapshot present — snapshot mode |

It reports medians with min/max, because a single slow iteration should not move
the headline and a noisy run should be visible rather than averaged away.

**Expect a better ratio than the hosted-runner figures.** Two 2.1 GB copies are
the largest component of a restore, and they behave completely differently on
NVMe — and on **btrfs or XFS** they become reflinks and cost almost nothing,
since `snapshot.sh` copies with `--reflink=auto`. The bench prints your store's
filesystem and says which case you are in.

## Testing the key

```bash
scripts/test-snapshot-key.sh
```

Runs in about a second, needs no docker daemon and no BC. It asserts what must
invalidate the key and — just as importantly — what must not. Run it after
touching any of the `_*_fp` functions in `scripts/snapshot.sh`.

---

## Getting jobs onto the machine that has the snapshots

A snapshot only helps the runner holding it, so the pipeline has to land there.
`bc-test-from-source.yml` and `bc-test-prebuilt.yml` take a `runs_on` input for
that — a label, or a JSON array for multi-label matching.

**GitHub Actions has no "prefer self-hosted, fall back to hosted".** `runs-on`
takes labels, not preferences: name a label whose runners are all offline and
the job **queues** — for up to 24 hours — and then fails. It does not fall back,
and there is no syntax that asks it to.

The only thing that works is to decide the label *before* the job starts, in a
cheap job that always runs somewhere available, and feed the answer through
`needs`. `.github/workflows/pick-runner.yml` is that job:

```yaml
jobs:
  pick:
    uses: StefanMaron/MsDyn365Bc.On.Linux/.github/workflows/pick-runner.yml@master
    with:
      preferred: "self-hosted"      # or '["self-hosted","linux","bc"]'
      fallback:  "ubuntu-latest"
    secrets:
      runner_token: ${{ secrets.RUNNER_READ_PAT }}   # optional — see below

  test:
    needs: pick
    uses: StefanMaron/MsDyn365Bc.On.Linux/.github/workflows/bc-test-from-source.yml@master
    with:
      runs_on: ${{ needs.pick.outputs.label }}
      app_dirs: "app"
```

**Real fallback needs a token.** The whole point is to send the job to a hosted
runner when a self-hosted one is *configured but not available*, and only the
API can tell you that:

| | how it knows | gives you fallback? |
|---|---|---|
| `runner_token` given | asks the API which runners are online, and optionally which are idle | **yes** |
| no token | reads the repository variable `BC_SELF_HOSTED` | **no** — it asserts availability rather than detecting it |

Listing runners needs `administration: read` (repo) or
`organization_self_hosted_runners: read` (org). **`GITHUB_TOKEN` cannot be
granted either at any permission level**, so it has to be a PAT or a GitHub App
token. That is the price of fallback; there is no way around it.

Without a token, `BC_SELF_HOSTED=true` sends the job to the self-hosted label
whether or not anything is listening, so an offline fleet means the job queues —
for up to 24 hours — which is exactly what you were trying to avoid. The picker
emits a `::warning::` on every such run saying so. Use it only if you cannot
issue a token, and treat it as a manual switch rather than as fallback.

With a token, the decisions are:

| fleet state | `require_idle: false` (default) | `require_idle: true` |
|---|---|---|
| online and idle | self-hosted | self-hosted |
| **registered but offline** | **hosted** | **hosted** |
| online, all busy | self-hosted (queues behind itself) | hosted |
| none registered | hosted | hosted |

The busy row is a policy choice, not an accident. On a fleet of one, queueing
behind your own runner is usually better than a hosted runner, because that
machine holds the warm artifact cache and the snapshots — a few minutes of
waiting against ~90s of cold boot plus a full artifact fetch. Set
`require_idle: true` if latency matters more than warmth.

**Neither is airtight, and the reason is structural:** a runner can go offline,
or be taken by another job, in the seconds between the picker answering and the
next job dispatching. `require_idle` narrows that window; nothing closes it,
because deciding in advance is the only thing GitHub allows.

`require_idle` is off by default on purpose. A runner that is busy still
satisfies `runs-on` — the job simply queues behind the current one — and on a
fleet of one that is usually better than a hosted runner, because that machine
is the one holding the warm artifact cache and the snapshots.
