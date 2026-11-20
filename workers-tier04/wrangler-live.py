#!/usr/bin/env python3
"""Run wrangler for the inha-world-tier04 live worker with the stored
Cloudflare credential (surrogate). Same mechanism as the Tier 4 helpers, but
with this directory as cwd. The surrogate is passed only via the
child process environment; it is never printed or written to disk.
Usage: python3 wrangler-live.py <wrangler args...>"""
import os
import subprocess
import sys

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import dynamic_credential_entry

ACCOUNT_ID = "e4d1d9c6b43b49fc3d60f40fa037f0fa"
HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    entry = dynamic_credential_entry("custom.cloudflare")
    surrogate = str(entry["surrogate"]).strip()
    env = dict(os.environ)
    env["CLOUDFLARE_API_TOKEN"] = surrogate
    env["CLOUDFLARE_ACCOUNT_ID"] = ACCOUNT_ID
    result = subprocess.run(
        ["npx", "-y", "wrangler@4"] + sys.argv[1:],
        env=env,
        cwd=HERE,
    )
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
