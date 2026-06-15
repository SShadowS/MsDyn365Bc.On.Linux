#!/usr/bin/env python3
"""
management-publish.py — deploy a precompiled Business Central app onto the
Linux NST WITHOUT recompiling it from AL source.

WHY THIS EXISTS
---------------
The dev endpoint (POST /BC/dev/apps) is the only publish path that works on
this Linux port today, but it ALWAYS recompiles the .app from AL source
(`NavAppPackageCompiler.Recompile`). For Microsoft's stock apps that recompile
fails on Linux — e.g. System Application dies with
`AL0327: Missing file 'Resources\\WelcomeWizard\\js\\Startup.js'` and Base
Application dies with `AL1024 ... Symbols ... could not be found`. So the dev
endpoint cannot deploy the stock app chain.

Every other publish path was investigated and decompiled (see
MANAGEMENT-PUBLISH.md): the management cmdlet `Publish-NAVApp`
(`NavManagementTasks.PublishNavApp` -> `NavAppPublisher.PublishFromArguments`),
`Get-NAVAppRuntimePackage`, and the boot-time in-place publisher all run
`Recompile` for any package that ships AL source. The shipped stock `.app`
files contain AL source plus precompiled R2R DLLs under `publishedartifacts/`,
but there is no shipped "emitted-content-without-source" package that would
hit the recompile-free `ExtractEmittedContent` path. So an in-process
management call would recompile too.

WHAT ACTUALLY WORKS
-------------------
BC's own sandbox image ships these apps as pre-populated SQL rows. The NST
recompiles each app's runtime assembly exactly ONCE per database (the Merkle
re-emit validation drifts on Linux so the shipped R2R DLLs are rejected and
regenerated), then PERSISTS the result in SQL `[Application Object Metadata]`
and the on-disk assembly cache. Proven empirically: a warm restart (same DB)
does ZERO recompiles. The compiled artifacts ARE the precompiled form.

This tool captures that compiled state once and replays it:

  snapshot  Copy every app row (Published Application, Installed Application,
            NAV App Installed App, Application Object Metadata, Application
            Resource) for a target app id closure into a side database and
            BACK IT UP to the persistent bc-service volume. Blob columns
            (Metadata, User Code, Symbols, ...) ride along natively in the
            .bak. This is "compile once".

  restore   Restore that .bak and INSERT...SELECT the rows back into CRONUS
            (skipping the non-insertable rowversion column). The NST then
            boots finding valid compiled artifacts and does NOT recompile —
            the precompiled app is deployed.

This is the `Publish-NAVApp` equivalent: it deploys precompiled binaries +
metadata + tenant install state, no recompile.

USAGE (run inside the bc container, where sqlcmd reaches the sql container):
  management-publish.py snapshot --apps <id[,id...]> --name <snapshotname>
  management-publish.py restore  --name <snapshotname>
  management-publish.py list-apps

The .bak lives at /bc/service/app-snapshots/<name>.bak by default
(SNAP_DIR env override). /bc/service is a Docker volume, so the snapshot
survives the SQL tmpfs wipe that happens on every container restart.
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys

# The app tables that hold a published+installed+compiled app. Every one of
# these carries a [Package ID] column, so the closure filter is uniform.
# Order matters for restore: parents before children is irrelevant here (no
# FKs between them in BC's schema) but we keep a stable order for readability.
APP_TABLES = [
    "Published Application",
    "Installed Application",
    "NAV App Installed App",
    "Application Object Metadata",
    "Application Resource",
]

SQL_SERVER = os.environ.get("SQL_SERVER", "sql")
DB_USER = os.environ.get("BC_DB_USER", "bctest")
DB_PASS = os.environ.get("BC_DB_PASSWORD", "Test1234")
DB_NAME = os.environ.get("BC_DB_NAME", "CRONUS")
SNAP_DB = os.environ.get("SNAP_DB", "BCAPPSNAP")
SNAP_DIR = os.environ.get("SNAP_DIR", "/bc/app-snapshots")
SQLCMD = os.environ.get("SQLCMD_BIN", "/opt/mssql-tools18/bin/sqlcmd")


def _tls_flags() -> list[str]:
    """ODBC sqlcmd needs -C -No to trust the self-signed SQL cert; go-sqlcmd
    only takes -C. Mirror entrypoint.sh's flavor logic, but treat an empty
    SQLCMD_TLS env (the entrypoint exports it unconditionally, sometimes blank)
    as 'use the flavor default' rather than 'pass no TLS flags'."""
    env = os.environ.get("SQLCMD_TLS", "").strip()
    if env:
        return env.split()
    try:
        flavor = open("/etc/bc-sqlcmd-flavor").read().strip()
    except OSError:
        flavor = "odbc"
    return ["-C"] if flavor == "go" else ["-C", "-No"]


TLS = _tls_flags()


def run_sql(query: str, db: str = DB_NAME, capture: bool = False,
            header: bool = False) -> str:
    cmd = [SQLCMD, "-S", SQL_SERVER, "-U", DB_USER, "-P", DB_PASS, "-d", db] + TLS
    if not header:
        cmd += ["-h", "-1", "-W"]
    cmd += ["-b", "-Q", query]
    if capture:
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode != 0:
            sys.stderr.write(out.stdout + out.stderr)
            raise SystemExit(f"SQL failed (rc={out.returncode})")
        return out.stdout
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        raise SystemExit(f"SQL failed (rc={rc})")
    return ""


def run_sql_file(path: str, db: str = DB_NAME) -> str:
    cmd = [SQLCMD, "-S", SQL_SERVER, "-U", DB_USER, "-P", DB_PASS, "-d", db] + TLS
    cmd += ["-h", "-1", "-W", "-b", "-i", path]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stdout + out.stderr)
        raise SystemExit(f"SQL file failed (rc={out.returncode})")
    return out.stdout


def insertable_columns(table: str, db: str = DB_NAME) -> list[str]:
    """All columns of a table except the non-insertable rowversion/timestamp."""
    q = (
        "SET NOCOUNT ON; "
        "SELECT c.name FROM sys.columns c "
        "JOIN sys.tables t ON t.object_id=c.object_id "
        "JOIN sys.types ty ON ty.user_type_id=c.user_type_id "
        f"WHERE t.name = N'{table}' AND ty.name <> 'timestamp' "
        "ORDER BY c.column_id;"
    )
    out = run_sql(q, db=db, capture=True)
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def assembly_cache_dirs() -> list[str]:
    """The NST runtime assembly cache dir(s). NST persists each app's linked
    runtime assembly (a SHA256-named .dll) plus a per-runtime-package
    Merkle.json here after compiling it once. NST will SKIP recompiling an app
    at boot only if it finds an assembly here that it itself produced and
    trusts for the current emit version — the shipped/pre-seeded R2R DLLs fail
    NST's boot validation on Linux and get regenerated. So a complete
    no-recompile snapshot must carry these files, not just the SQL rows.

    NST writes to MicrosoftDynamicsNavServer$MicrosoftDynamicsNavServer
    regardless of the configured instance name; the entrypoint also pre-seeds
    the configured-instance ($BC) path. We capture every release dir we find."""
    base = "/usr/share/Microsoft/Microsoft Dynamics NAV"
    return sorted(glob.glob(
        os.path.join(base, "*", "Server", "*", "apps", "assembly", "release", "*")
    ))


def cmd_snapshot_cache(name: str) -> None:
    """tar the whole assembly-cache release dir(s) alongside the .bak. The
    cache is content-addressed (SHA256 dll names) so capturing the whole dir is
    correct and lets a restore drop NST's trusted assemblies onto a fresh CI
    volume whose cache only holds the rejected shipped DLLs."""
    dirs = assembly_cache_dirs()
    if not dirs:
        print("[snapshot] WARN: no assembly cache dir found — cache not captured")
        return
    os.makedirs(SNAP_DIR, exist_ok=True)
    tar = os.path.join(SNAP_DIR, f"{name}.cache.tar")
    # Store with paths relative to the NAV root so restore can place them back.
    nav_root = "/usr/share/Microsoft/Microsoft Dynamics NAV"
    cmd = ["tar", "-cf", tar, "-C", nav_root]
    for d in dirs:
        cmd.append(os.path.relpath(d, nav_root))
    subprocess.run(cmd, check=True)
    sz = os.path.getsize(tar)
    print(f"[snapshot] assembly cache -> {tar} ({sz // (1024*1024)} MB, "
          f"{len(dirs)} dir(s))")


def cmd_restore_cache(name: str, tar: str | None) -> None:
    tar = tar or os.path.join(SNAP_DIR, f"{name}.cache.tar")
    if not os.path.exists(tar):
        print(f"[restore] no cache tar at {tar} — relying on existing cache "
              "(warm volume) or the entrypoint R2R pre-seed")
        return
    nav_root = "/usr/share/Microsoft/Microsoft Dynamics NAV"
    subprocess.run(["tar", "-xf", tar, "-C", nav_root], check=True)
    print(f"[restore] assembly cache extracted from {tar}")


def closure_package_ids(app_ids: list[str]) -> list[str]:
    """Resolve the requested app ids (the [ID] / EmbeddedAppId GUIDs) to the
    [Package ID]s of every published app whose [ID] is in the set. Dependencies
    must be passed explicitly by the caller (use list-apps to see ids); we do
    not walk the dependency graph here because the caller's intended closure is
    deployment-policy, not a hard requirement of this tool."""
    ids = ",".join(f"'{a.strip().lower()}'" for a in app_ids if a.strip())
    q = (
        "SET NOCOUNT ON; "
        "SELECT LOWER(CONVERT(VARCHAR(36),[Package ID])) FROM [Published Application] "
        f"WHERE LOWER(CONVERT(VARCHAR(36),[ID])) IN ({ids});"
    )
    out = run_sql(q, capture=True)
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def in_clause(pkg_ids: list[str]) -> str:
    return ",".join(f"'{p}'" for p in pkg_ids)


def cmd_list_apps(_args) -> None:
    q = (
        "SET NOCOUNT ON; "
        "SELECT [Name] + CHAR(9) + LOWER(CONVERT(VARCHAR(36),[ID])) "
        "+ CHAR(9) + 'pkg=' + LOWER(CONVERT(VARCHAR(36),[Package ID])) "
        "FROM [Published Application] ORDER BY [Name];"
    )
    sys.stdout.write(run_sql(q, capture=True))


def cmd_snapshot(args) -> None:
    app_ids = [a for a in args.apps.split(",") if a.strip()]
    if not app_ids:
        raise SystemExit("--apps is required (comma-separated app [ID] GUIDs)")
    pkg_ids = closure_package_ids(app_ids)
    if not pkg_ids:
        raise SystemExit("No published apps matched the requested ids. "
                         "Run list-apps to see available ids.")
    print(f"[snapshot] {len(app_ids)} app id(s) -> {len(pkg_ids)} package id(s)")
    inc = in_clause(pkg_ids)

    os.makedirs(SNAP_DIR, exist_ok=True)
    bak = os.path.join(SNAP_DIR, f"{args.name}.bak")

    # Create the snapshot DB first, in its own batch — a cross-database
    # SELECT * INTO referencing [SNAP_DB] parses against catalog metadata that
    # must already exist, so it cannot share a batch with CREATE DATABASE.
    run_sql(
        f"IF DB_ID(N'{SNAP_DB}') IS NOT NULL BEGIN ALTER DATABASE [{SNAP_DB}] "
        f"SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{SNAP_DB}]; END",
        db="master",
    )
    run_sql(f"CREATE DATABASE [{SNAP_DB}];", db="master")

    # Copy the scoped rows table by table.
    lines = ["SET NOCOUNT ON;"]
    for t in APP_TABLES:
        # SELECT * INTO preserves blob columns and types natively.
        lines.append(
            f"SELECT * INTO [{SNAP_DB}].[dbo].[{t}] FROM [{DB_NAME}].[dbo].[{t}] "
            f"WHERE [Package ID] IN ({inc});"
        )
        lines.append(
            f"SELECT '{t}: ' + CAST(COUNT(*) AS VARCHAR) FROM [{SNAP_DB}].[dbo].[{t}];"
        )
    sql_path = "/tmp/mgmt-snapshot.sql"
    with open(sql_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(run_sql_file(sql_path, db="master"))

    # Back the snapshot DB up to the persistent volume so it survives the SQL
    # tmpfs wipe on container restart. BACKUP reads SQL Server's own fs, so
    # SNAP_DIR (/bc/app-snapshots) is volume-mounted into the sql container too
    # (see docker-compose.yml bc-snapshots).
    print(f"[snapshot] backing up {SNAP_DB} -> {bak}")
    run_sql(
        f"BACKUP DATABASE [{SNAP_DB}] TO DISK = N'{bak}' WITH FORMAT, INIT, "
        "COMPRESSION;",
        db="master",
    )

    # Also capture the NST-built assembly cache so a restore onto a fresh CI
    # volume doesn't trigger a recompile (the SQL metadata alone is not enough
    # — NST also checks the on-disk assembly it trusts). Skippable with
    # --no-cache when the target is known to already have a warm cache volume.
    if not args.no_cache:
        cmd_snapshot_cache(args.name)

    print(f"[snapshot] done: {bak}")


def cmd_restore(args) -> None:
    bak = args.bak or os.path.join(SNAP_DIR, f"{args.name}.bak")
    # The .bak is read by SQL Server's own process (RESTORE FROM DISK), so it
    # must live on a path the sql container can see — not necessarily one this
    # (bc) container can stat. Only enforce the local-existence check when the
    # path is under SNAP_DIR (shared volume); an explicit --bak may point at a
    # sql-only path.
    if not args.bak and not os.path.exists(bak):
        raise SystemExit(f"snapshot .bak not found: {bak}")
    print(f"[restore] restoring {bak} -> {SNAP_DB}")

    # Read logical file names via FILELISTONLY (tab-separated so blob/space
    # values can't confuse the split); col 1 is LogicalName, col 3 is Type
    # (D = data, L = log).
    fl = run_sql(
        f"SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'{bak}';",
        db="master", capture=True,
    )
    data_name, log_name = SNAP_DB, SNAP_DB + "_log"
    rows = [ln for ln in fl.splitlines() if ln.strip()]
    # sqlcmd -W collapses runs of spaces; logical name is the first token and
    # the type flag (D/L) is a lone single-char token later on the line.
    for ln in rows:
        toks = ln.split()
        if not toks:
            continue
        name = toks[0]
        singles = [t for t in toks[1:] if t in ("D", "L")]
        if "L" in singles:
            log_name = name
        elif "D" in singles:
            data_name = name
    run_sql(
        f"IF DB_ID(N'{SNAP_DB}') IS NOT NULL BEGIN ALTER DATABASE [{SNAP_DB}] "
        f"SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{SNAP_DB}]; END "
        f"RESTORE DATABASE [{SNAP_DB}] FROM DISK = N'{bak}' WITH "
        f"MOVE N'{data_name}' TO N'/var/opt/mssql/data/{SNAP_DB}.mdf', "
        f"MOVE N'{log_name}' TO N'/var/opt/mssql/data/{SNAP_DB}_log.ldf', REPLACE;",
        db="master",
    )

    # INSERT...SELECT each table back, skipping rows already present (idempotent
    # on Package ID) and excluding the non-insertable rowversion column.
    lines = ["SET NOCOUNT ON;"]
    for t in APP_TABLES:
        cols = insertable_columns(t, db=SNAP_DB)
        collist = ", ".join(f"[{c}]" for c in cols)
        # Wipe any existing rows for these package ids first so restore is clean.
        lines.append(
            f"DELETE D FROM [{DB_NAME}].[dbo].[{t}] D "
            f"JOIN [{SNAP_DB}].[dbo].[{t}] S ON S.[Package ID] = D.[Package ID];"
        )
        lines.append(
            f"INSERT INTO [{DB_NAME}].[dbo].[{t}] ({collist}) "
            f"SELECT {collist} FROM [{SNAP_DB}].[dbo].[{t}];"
        )
        lines.append(
            f"SELECT '{t}: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows';"
        )
    sql_path = "/tmp/mgmt-restore.sql"
    with open(sql_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(run_sql_file(sql_path, db="master"))

    # Restore the NST-built assembly cache so NST trusts the on-disk assemblies
    # and skips recompiling at boot. Path-derived from --bak when given.
    cache_tar = args.cache_tar
    if not cache_tar and args.name:
        cache_tar = os.path.join(SNAP_DIR, f"{args.name}.cache.tar")
    elif not cache_tar and bak.endswith(".bak"):
        cache_tar = bak[:-4] + ".cache.tar"
    cmd_restore_cache(args.name, cache_tar)

    print("[restore] done. Restart NST (docker compose restart bc) so it picks "
          "up the restored app rows; it will NOT recompile.")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="capture compiled app state to a .bak")
    s.add_argument("--apps", required=True,
                   help="comma-separated app [ID] GUIDs to snapshot")
    s.add_argument("--name", required=True, help="snapshot name (-> <name>.bak)")
    s.add_argument("--no-cache", action="store_true",
                   help="skip capturing the NST assembly cache (.cache.tar)")
    s.set_defaults(func=cmd_snapshot)

    r = sub.add_parser("restore", help="restore a .bak into CRONUS (no recompile)")
    r.add_argument("--name", help="snapshot name (-> <name>.bak + .cache.tar)")
    r.add_argument("--bak", help="explicit .bak path (overrides --name)")
    r.add_argument("--cache-tar", help="explicit assembly-cache tar path")
    r.set_defaults(func=cmd_restore)

    la = sub.add_parser("list-apps", help="list published apps (name id pkg)")
    la.set_defaults(func=cmd_list_apps)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
