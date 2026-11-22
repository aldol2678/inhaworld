import functools
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import threading

import pytest
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def build_site(tmp_path_factory):
    def build(origin, sync_origin=""):
        checkout = tmp_path_factory.mktemp("pages") / "client"
        shutil.copytree(ROOT, checkout, ignore=shutil.ignore_patterns(
            "dist", ".pages-build-*", "node_modules", "__pycache__", ".pytest_cache"
        ))
        env = dict(os.environ, WORLD_PUBLIC_ORIGIN=origin, WORLD_SYNC_ORIGIN=sync_origin,
                   WORLD_FIREBASE_WEB_CONFIG=json.dumps({
                       "apiKey": "fixture", "appId": "fixture", "projectId": "demo-world",
                       "authDomain": "auth.example.invalid",
                   }))
        subprocess.run(["node", "tools/build-pages.mjs"], cwd=checkout, env=env, check=True)
        return checkout / "dist"
    return build


@pytest.fixture(scope="session")
def origin(build_site):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
    site = build_site(f"http://127.0.0.1:{server.server_port}")
    server.RequestHandlerClass = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(site))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()
    thread.join()


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as tool:
        instance = tool.chromium.launch(
            executable_path=os.getenv("CHROMIUM", "/usr/bin/chromium"),
            args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
        )
        yield instance
        instance.close()
