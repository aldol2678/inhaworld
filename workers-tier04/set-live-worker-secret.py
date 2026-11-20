#!/usr/bin/env python3
"""Create the live Worker login role on tier4-live and store its connection
string as the inha-world-tier04 Worker secret DATABASE_URL.

The password is generated here, used once to create the role, and passed to
`wrangler secret put` via stdin only. Nothing secret is printed or written
to a file. Usage: python3 set-live-worker-secret.py
"""
import os
import secrets
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "prov", os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-cutover.py"))
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)

HOST = "ep-soft-fog-aoszii0y.c-2.ap-southeast-1.aws.neon.tech"
ROLE = "inha_world_tier4_live_app"
HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    # Recover the live login role's connection string transiently through the
    # Neon reveal_password API (same pattern as the isolated provisioner).
    # Nothing secret is printed or written to a file.
    conn = prov.role_url("live", ROLE)
    r2 = subprocess.run(["python3", "wrangler-live.py", "secret", "put", "DATABASE_URL"],
                        input=conn, text=True, cwd=HERE,
                        capture_output=True)
    print(r2.stdout.strip()[-500:])
    if r2.stderr.strip():
        print(r2.stderr.strip()[-500:])
    return r2.returncode


if __name__ == "__main__":
    sys.exit(main())
