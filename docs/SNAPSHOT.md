# Snapshot mode — booting BC from a CRIU checkpoint

Replaces a ~140s cold boot with a ~25-30s restore by resuming a checkpointed
service tier instead of starting one.

**Opt-in.** Nothing changes unless you set `BC_SNAPSHOT_DIR`. With it set, a hit
restores, a miss boots normally and leaves a snapshot behind for next time. A
snapshot that cannot be used is never a build failure — the fallback is always a
cold boot.

**Only worth it on a runner that keeps its disk** — self-hosted runners and dev
boxes. See [Where this pays](#where-this-pays) before turning it on.

---

## What a snapshot is

Two files, valid only **together**:

| | | |
|---|---|---|
| `checkpoint/` | ~2.1 GB | the frozen NST process image |
| `cronus.bak` | ~540 MB | the database it was booted against |

Neither restores on its own. The checkpoint holds a process whose memory refers
to that database's schema, its published-app metadata, its license and its
session state. Restore it against a different database and you get a BC that
answers requests and is quietly wrong. They are written and read as a pair under
one key, and **the key is the whole safety story.**

## Turning it on

```bash
# 1. Host prerequisites (once)
sudo apt-get install -y build-essential libprotobuf-dev libprotobuf-c-dev \
  protobuf-c-compiler protobuf-compiler python3-protobuf libnl-3-dev libnet-dev \
  libcap-dev libbsd-dev libgnutls28-dev libnftables-dev
git clone --depth 1 --branch v4.2.1 https://github.com/checkpoint-restore/criu /tmp/criu
make -C /tmp/criu -j"$(nproc)" && sudo make -C /tmp/criu install-criu

echo '{"experimental": true}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# 2. Every run
export COMPOSE_FILE=docker-compose.yml:docker-compose.snapshot.yml
export BC_SNAPSHOT_DIR=/var/cache/bc-snapshots
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

`docker-compose.snapshot.yml` is required, not optional. It puts `bc` on host
networking (Docker cannot rebuild a bridge network namespace on restore) and
mounts the backup directory into `sql` (`RESTORE FROM DISK` reads SQL Server's
own filesystem). `preflight` refuses to run without it.

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

### `artifact` — which BC build

The **resolved** urls, read from `download-artifacts.sh`'s own
`.bc-artifact-cache` stamp — not the version you asked for. This is the single
biggest lever you have over hit rate, and it is covered in
[Keeping a snapshot valid](#keeping-a-snapshot-valid-for-as-long-as-possible)
below.

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
this cacheable.

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

GitHub-hosted `ubuntu-22.04`, 4 vCPU, BC 28.1, criu 4.2.1. Two runs of the
probe, restoring against a **fresh** SQL container with the database reloaded:

| | run 18 | run 19 |
|---|---|---|
| cold boot to healthy | 137s | 140s |
| checkpoint | 46s | 42s |
| **restore to OData 200** | **25s** | **29s** |
| novel app publish afterwards | 200 | 200 |

The last row is the check that matters: an app compiled *after* the restore
publishes through the dev endpoint, so the tenant is genuinely functional and
not merely answering. A boot check alone is not evidence — `StartupHook`'s
reverted Patch #30 passed one and was catastrophic.

`PERFORMANCE-IDEAS.md` has the full history, including every barrier and its
fix, and the several theories that turned out to be wrong.

## Testing the key

```bash
scripts/test-snapshot-key.sh
```

Runs in about a second, needs no docker daemon and no BC. It asserts what must
invalidate the key and — just as importantly — what must not. Run it after
touching any of the `_*_fp` functions in `scripts/snapshot.sh`.
