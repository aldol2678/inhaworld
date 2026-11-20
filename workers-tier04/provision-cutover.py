#!/usr/bin/env python3
"""Tier 4 cutover provisioner (live branches only).

Reveals the neondb_owner password for a live branch, builds the owner
connection string in memory, and runs a node step with DATABASE_URL /
TEST_PG_URL set in the child environment only. Never prints the password or
the connection string.
Usage:
  python3 provision-cutover.py live-apply    # node apply-tier4-schema.mjs (tier4-live)
  python3 provision-cutover.py live-oracle   # node run-oracle-tier4w.mjs (tier4-live)
  python3 provision-cutover.py live-parity   # node test-parity.mjs (tier4-live vs tier4-scratch)
  python3 provision-cutover.py live-sql <file>  # node run-sql.mjs <file> (tier4-live)
  python3 provision-cutover.py live-count    # tables/functions counts (tier4-live)
  python3 provision-cutover.py backup-count  # tables/functions counts (backup branch)
  python3 provision-cutover.py main-count    # tables/functions counts (live main)
"""
import json
import os
import subprocess
import sys
import urllib.parse

PROJECT = "odd-smoke-58843454"
BRANCHES = {
    "live": ("br-wild-star-aohu8otf", "ep-soft-fog-aoszii0y.c-2.ap-southeast-1.aws.neon.tech"),
    "backup": ("br-wild-recipe-aokf11ng", "ep-lucky-queen-aoubrjri.c-2.ap-southeast-1.aws.neon.tech"),
    "main": ("br-rapid-dust-aofiyhry", "ep-still-mud-ao7zevig.c-2.ap-southeast-1.aws.neon.tech"),
    "scratch": ("br-lingering-field-aor2ph0y", "ep-little-lake-aoqkud5b.c-2.ap-southeast-1.aws.neon.tech"),
}
HERE = os.path.dirname(os.path.abspath(__file__))


def neon(method, path):
    out = subprocess.run(
        ["python3", os.path.expanduser("~/workspace/custom-connectors/custom.neon/bin/neon_api.py"),
         method, path],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def role_url(which, role):
    branch, host = BRANCHES[which]
    pw = neon("GET", f"/projects/{PROJECT}/branches/{branch}/roles/{role}/reveal_password")
    password = pw["password"]
    return f"postgres://{role}:{urllib.parse.quote(password, safe='')}@{host}/neondb?sslmode=require"


def owner_url(which):
    return role_url(which, "neondb_owner")


COUNT_JS = ("import('@neondatabase/serverless').then(async m => { const sql = m.neon(process.env.DATABASE_URL);"
            " const t = await sql`select count(*) c from pg_tables where schemaname in ('public','private')`;"
            " const f = await sql`select count(*) c from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private')`;"
            " console.log(JSON.stringify({tables: t[0].c, functions: f[0].c})); })")


def main():
    step = sys.argv[1]
    env = dict(os.environ)
    if step == "live-apply":
        env["DATABASE_URL"] = owner_url("live")
        cmd = ["node", "apply-tier4-schema.mjs"]
    elif step == "live-oracle":
        env["DATABASE_URL"] = owner_url("live")
        cmd = ["node", "run-oracle-tier4w.mjs"]
    elif step == "live-parity":
        env["TEST_OWNER_URL"] = owner_url("live")
        env["TEST_LOGIN_URL"] = role_url("live", "inha_world_tier4_live_app")
        env["SCRATCH_URL"] = owner_url("scratch")
        cmd = ["node", "test-parity.mjs"]
    elif step == "live-login-sql":
        env["DATABASE_URL"] = role_url("live", "inha_world_tier4_live_app")
        cmd = ["node", "run-sql.mjs", sys.argv[2]]
    elif step == "live-sql":
        env["DATABASE_URL"] = owner_url("live")
        cmd = ["node", "run-sql.mjs", sys.argv[2]]
    elif step == "main-sql":
        env["DATABASE_URL"] = owner_url("main")
        cmd = ["node", "run-sql.mjs", sys.argv[2]]
    elif step == "backup-sql":
        env["DATABASE_URL"] = owner_url("backup")
        cmd = ["node", "run-sql.mjs", sys.argv[2]]
    elif step == "live-count":
        env["DATABASE_URL"] = owner_url("live")
        cmd = ["node", "-e", COUNT_JS]
    elif step == "backup-count":
        env["DATABASE_URL"] = owner_url("backup")
        cmd = ["node", "-e", COUNT_JS]
    elif step == "main-count":
        env["DATABASE_URL"] = owner_url("main")
        cmd = ["node", "-e", COUNT_JS]
    else:
        print("unknown step:", step)
        return 2
    result = subprocess.run(cmd, env=env, cwd=HERE)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
