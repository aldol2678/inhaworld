#!/usr/bin/env python3
"""Create the live Worker login role on tier4-live only (no secret stored).

The password is generated here and used once to create the role. It is NOT
printed or written anywhere: later steps recover it transiently through the
Neon reveal_password API (same pattern as the isolated provisioner).
Usage: python3 create-live-role.py
"""
import os
import secrets
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "prov", os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-cutover.py"))
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)

ROLE = "inha_world_tier4_live_app"
HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    password = secrets.token_urlsafe(24)
    env = dict(os.environ)
    env["DATABASE_URL"] = prov.owner_url("live")
    env["LOGIN_PASSWORD"] = password
    env["LOGIN_ROLE"] = ROLE
    r = subprocess.run(["node", "create-live-login-role.mjs"], env=env, cwd=HERE,
                       capture_output=True, text=True)
    print(r.stdout.strip())
    if r.returncode != 0:
        print(r.stderr[-1000:])
        return r.returncode
    print("live login role created (password not stored; recover via Neon reveal_password)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
