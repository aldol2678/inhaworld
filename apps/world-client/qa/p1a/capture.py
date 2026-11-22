"""Capture the same ground cameras in either local build, using the live game's renderer."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from threading import Thread

from playwright.sync_api import sync_playwright

# x, z and horizontal look-at x, z in the projected game frame.
VIEWS = {
    "gate": (0, -98, 0, -73),
    "hall": (46.8, -19.9, 54.0, 4.5),
    "library": (-8, -10.25, -20.5, -3.4),
    "canal": (41, -12, 11, -71),
    "agora": (121.8, -10.4, 131, -2),
    "pond": (125.6, 5.05, 121.5, 18.5),
}
PROBE = """
globalThis.captureMapView = ([x, z, targetX, targetZ]) => {
    if (!campus.canStand(x, z)) throw Error('Occupied camera at ' + [x, z]);
    player.x = x;
    player.z = z;
    player.yaw = Math.atan2(x - targetX, z - targetZ);
    updateCamera();
    campus.updateVisibility(x, z);
    renderer.render(scene, camera);
    return {
        position: camera.position.toArray(),
        yaw: camera.rotation.y,
        pitch: camera.rotation.x,
        fov: camera.fov,
        buffer: [canvas.width, canvas.height],
        visible: scene.children.filter(o => o.isMesh && o.visible).map(o => o.name || o.type),
        calls: renderer.info.render.calls,
        triangles: renderer.info.render.triangles,
        geometries: renderer.info.memory.geometries,
        textures: renderer.info.memory.textures,
        pixelRatio: renderer.getPixelRatio(),
        glBuffers: {...globalThis.qaBufferCounts},
        contextLost: renderer.getContext().isContextLost()
    };
};
"""


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dist", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    args = p.parse_args()
    args.out.mkdir(exist_ok=True, parents=True)
    with ThreadingHTTPServer(
        ("127.0.0.1", 0), partial(QuietHandler, directory=str(args.dist))
    ) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        with sync_playwright() as pw:
            browser = pw.chromium.launch(
                executable_path=os.getenv("CHROMIUM", "/usr/bin/chromium"),
                args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
            )
            touch = args.width < 1000
            ctx = browser.new_context(
                viewport={"width": args.width, "height": args.height},
                has_touch=touch,
                is_mobile=touch,
                device_scale_factor=1,
            )
            page = ctx.new_page()
            # Count actual WebGL buffer objects on this disposable QA document.
            page.add_init_script("""(() => {
              const counts = globalThis.qaBufferCounts = {created: 0, deleted: 0};
              const gl = WebGL2RenderingContext.prototype;
              for (const [key, operation] of [['created','createBuffer'],['deleted','deleteBuffer']]) {
                const original = gl[operation];
                gl[operation] = function (...args) {
                  const value = original.apply(this, args);
                  if (key === 'created' ? value : args[0]) counts[key]++;
                  return value;
                };
              }
            })();""")
            errors = []
            page.on("pageerror", lambda err: errors.append(str(err)))

            def route(r):
                if r.request.url == origin + "/src/main.js":
                    code = (args.dist / "src/main.js").read_text()
                    r.fulfill(content_type="text/javascript", body=code + "\n" + PROBE)
                elif r.request.url == origin + "/api/health":
                    r.fulfill(status=503, json={})
                elif r.request.url.startswith(origin + "/") and r.request.method == "GET":
                    r.continue_()
                else:
                    errors.append(r.request.url)
                    r.abort()

            page.route("**/*", route)
            page.goto(origin)
            page.wait_for_function(
                "typeof captureMapView === 'function' && document.querySelector('#room-list').children.length === 3"
            )
            captures = {}
            for name, pose in VIEWS.items():
                captures[name] = page.evaluate("pose => captureMapView(pose)", pose)
                page.locator("#scene").screenshot(path=args.out / f"{name}.png")
            warm = page.evaluate("pose => captureMapView(pose)", VIEWS["gate"])
            for _ in range(12):
                for near in ("agora", "gate"):
                    page.evaluate("pose => captureMapView(pose)", VIEWS[near])
            repeat = page.evaluate("pose => captureMapView(pose)", VIEWS["gate"])
            assert repeat["glBuffers"] == warm["glBuffers"] and not repeat["contextLost"]
            assert all(
                repeat[k] == captures["gate"][k]
                for k in ["geometries", "textures", "calls", "triangles"]
            )
            assert not errors, errors
            page.reload()
            page.wait_for_function("typeof captureMapView === 'function'")
            for pose in VIEWS.values():
                page.evaluate("pose => captureMapView(pose)", pose)
            restored = page.evaluate("pose => captureMapView(pose)", VIEWS["gate"])
            assert all(
                restored[k] == repeat[k]
                for k in ["geometries", "textures", "glBuffers", "calls", "triangles"]
            )
            report = dict(
                chromium=browser.version,
                viewport=[args.width, args.height],
                touch=touch,
                visibilityChanges=24,
                repeatGate=repeat,
                reloadedGate=restored,
                views=captures,
            )
            (args.out / "cameras.json").write_text(json.dumps(report, indent=2) + "\n")
            print({k: (v["calls"], v["triangles"]) for k, v in captures.items()})
            ctx.close()
            assert not browser.contexts
            browser.close()
        server.shutdown()


if __name__ == "__main__":
    main()
