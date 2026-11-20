#!/usr/bin/env python3
"""Run the live jeongseok-only gate activation + smoke (seed-gate-live.sh).
TEST_OWNER_URL is the LIVE (promoted main) owner URL, passed to the node
fixtures in the child environment only; never printed.
Usage: python3 run-seed-gate-live.py"""
import os
import subprocess
import sys

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "provision_cutover", os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-cutover.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    env = dict(os.environ)
    env["TEST_OWNER_URL"] = _mod.owner_url("live")
    log = open(os.path.join(HERE, "seed-gate-live.log"), "w")
    r = subprocess.run(["bash", "seed-gate-live.sh"], env=env, cwd=HERE,
                       stdout=log, stderr=subprocess.STDOUT)
    print("seed-gate-live rc:", r.returncode)
    log.close()
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
