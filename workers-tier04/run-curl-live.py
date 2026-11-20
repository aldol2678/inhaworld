#!/usr/bin/env python3
"""Run the BCD curl verification end to end against the LIVE Worker + tier4-live branch:
generate MAIL_ADMIN_KEY -> set as Worker secret (stdin) -> setup fixtures ->
curl-verify-live.sh -> teardown fixtures (always, even on failure).
TEST_OWNER_URL is passed to the node fixtures in the child environment only;
no secret is printed or written to a file. Usage: python3 run-curl-live.py"""
import os
import secrets
import subprocess
import sys

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "provision_cutover", os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-cutover.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
owner_url = _mod.owner_url

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    key = secrets.token_urlsafe(24)
    r = subprocess.run(["python3", "wrangler-live.py", "secret", "put", "MAIL_ADMIN_KEY"],
                       input=key, text=True, cwd=HERE, capture_output=True)
    print(r.stdout.strip()[-300:])
    if r.returncode != 0:
        print(r.stderr[-500:])
        return r.returncode
    env = dict(os.environ)
    env["MAIL_ADMIN_KEY"] = key
    env["TEST_OWNER_URL"] = owner_url("live")
    log = open(os.path.join(HERE, "curl-run-live.log"), "w")
    rc = 0
    try:
        r = subprocess.run(["node", "curl-fixtures.mjs", "setup"],
                           env=env, cwd=HERE, stdout=log, stderr=subprocess.STDOUT)
        print("setup rc:", r.returncode)
        if r.returncode != 0:
            return r.returncode
        r = subprocess.run(["bash", "curl-verify-live.sh"],
                           env=env, cwd=HERE, stdout=log, stderr=subprocess.STDOUT)
        print("verify rc:", r.returncode)
        rc = r.returncode
    finally:
        r = subprocess.run(["node", "curl-fixtures.mjs", "teardown"],
                           env=env, cwd=HERE, stdout=log, stderr=subprocess.STDOUT)
        print("teardown rc:", r.returncode)
        log.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
