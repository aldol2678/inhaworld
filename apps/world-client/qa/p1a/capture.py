"""Capture the same ground cameras in either local build, using the live game's renderer."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
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
# Optional comparison views. The last two values specify an elevated QA camera
# only. The game uses its ordinary eye height for all four-coordinate poses.
FIELD_VIEWS = {
    "west-bank": (109, 22, 151, 13),
    "lake-oblique": (103, -16, 133, 30, 26, -0.40),
    "lake-plan": (122.56, 19.25, 131.58, 14.95, 34, -math.pi / 2),
}
PROBE = """
globalThis.captureMapView = ([x, z, targetX, targetZ, height, pitch]) => {
    if (height === undefined && !campus.canStand(x, z)) throw Error('Occupied camera at ' + [x, z]);
    player.x = x;
    player.z = z;
    player.yaw = Math.atan2(x - targetX, z - targetZ);
    updateCamera();
    if (height !== undefined) { camera.position.y = height; camera.rotation.x = pitch; }
    campus.updateVisibility(x, z);
    campus.updateWater?.(0);
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
globalThis.sampleMapRender = count => {
    const gl = renderer.getContext(), pixel = new Uint8Array(4);
    const times = [];
    for (let i = 0; i < count + 12; i++) {
        const start = performance.now();
        renderer.render(scene, camera);
        gl.readPixels(canvas.width >> 1, canvas.height >> 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
        if (i >= 12) times.push(performance.now() - start);
    }
    return times;
};
"""


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


BUFFER_PROBE = """(() => {
              const counts = globalThis.qaBufferCounts = {created: 0, deleted: 0, bytes: 0};
              const sizes = new Map();
              const gl = WebGL2RenderingContext.prototype;
              const allocate = gl.bufferData;
              gl.bufferData = function (target, data, ...args) {
                const result = allocate.call(this, target, data, ...args);
                const binding = target === this.ARRAY_BUFFER ? this.ARRAY_BUFFER_BINDING : this.ELEMENT_ARRAY_BUFFER_BINDING;
                const buffer = this.getParameter(binding);
                const bytes = this.getBufferParameter(target, this.BUFFER_SIZE);
                counts.bytes += bytes - (sizes.get(buffer) || 0);
                sizes.set(buffer, bytes);
                return result;
              };
              for (const [key, operation] of [['created','createBuffer'],['deleted','deleteBuffer']]) {
                const original = gl[operation];
                gl[operation] = function (...args) {
                  const value = original.apply(this, args);
                  if (key === 'created' ? value : args[0]) counts[key]++;
                  if (key === 'deleted') { counts.bytes -= sizes.get(args[0]) || 0; sizes.delete(args[0]); }
                  return value;
                };
              }
            })();"""


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dist", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--field-study", action="store_true", help="include west bank and overhead lake cameras")
    p.add_argument("--timing", action="store_true", help="time 60 synchronized pond renders after warm-up")
    args = p.parse_args()
    views = VIEWS | FIELD_VIEWS if args.field_study else VIEWS
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
            page.add_init_script(path=Path(__file__).resolve().parents[2] / "tests/world-driver.js")
            # Count actual WebGL buffer objects on this disposable QA document.
            page.add_init_script(BUFFER_PROBE)
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
            def hold_game():
                page.evaluate("worldTest.hold()")
                page.wait_for_function("worldTest.ready()", polling=20)

            hold_game()
            captures = {}
            for name, pose in views.items():
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
            hold_game()
            for pose in views.values():
                page.evaluate("pose => captureMapView(pose)", pose)
            restored = page.evaluate("pose => captureMapView(pose)", VIEWS["gate"])
            assert all(
                restored[k] == repeat[k]
                for k in ["geometries", "textures", "glBuffers", "calls", "triangles"]
            )
            cdp = ctx.new_cdp_session(page)
            cdp.send("HeapProfiler.collectGarbage")
            heap = cdp.send("Runtime.getHeapUsage")
            samples = []
            if args.timing:
                page.evaluate("pose => captureMapView(pose)", views["pond"])
                samples = page.evaluate("sampleMapRender(60)")
            report = dict(
                heapAfterReloadBytes=heap,
                pondRenderReadbackMs=samples,
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
