#!/usr/bin/env python3
"""Run the A-3 curl verification end to end on the isolated test branch:
setup fixtures -> curl-verify.sh -> teardown fixtures (always, even on failure).
TEST_OWNER_URL is passed to the node fixtures in the child environment only;
it is never printed. Usage: python3 run-curl-a3.py"""
import os
import subprocess
import sys

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "provision_tier4bcd", os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-tier4bcd.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
owner_url = _mod.owner_url

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    if not os.environ.get("MAIL_ADMIN_KEY"):
        print("MAIL_ADMIN_KEY is required in the environment (Worker secret for the mail-claim tests); not set, aborting before setup.")
        return 2
    env = dict(os.environ)
    env["TEST_OWNER_URL"] = owner_url("test")
    log = open(os.path.join(HERE, "curl-run.log"), "w")
    rc = 0
    try:
        r = subprocess.run(["node", "curl-fixtures.mjs", "setup"],
                           env=env, cwd=HERE, stdout=log, stderr=subprocess.STDOUT)
        print("setup rc:", r.returncode)
        if r.returncode != 0:
            return r.returncode
        r = subprocess.run(["bash", "curl-verify.sh"],
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
