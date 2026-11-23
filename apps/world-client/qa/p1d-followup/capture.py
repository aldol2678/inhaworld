"""Compare both entrances and the survey stations in the normally built Three.js client."""
from argparse import ArgumentParser
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path

from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("measure_p1d", HERE.parent / "p1d/measure.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)
qa = measure.qa


def main():
    ap = ArgumentParser(description=__doc__)
    for key in ["before", "after", "output", "originals"]:
        ap.add_argument(key, type=Path)
    args = ap.parse_args()
    stations = json.loads((HERE / "stations.json").read_text())
    poses = {s["id"]: s["pose"] for s in stations}
    poses["student-north"] = qa.CAMERAS["student-entry"]
    report = {}
    with ExitStack() as stack, sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=os.getenv("CHROMIUM", "/usr/bin/chromium"),
                                     args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
        builds = {"before": args.before, "after": args.after}
        origins = {k: qa.serve(stack, v) for k,v in builds.items()}
        for size in qa.SIZES:
            tag = "%dx%d" % size
            views = report[tag] = {}
            for phase,dist in builds.items():
                ctx, page, errors, _ = qa.visit(browser, origins[phase], dist, size, "high")
                dest = args.originals / tag / phase
                dest.mkdir(parents=True, exist_ok=True)
                for key, pose in poses.items():
                    state = page.evaluate("p=>captureMapView(p)", pose)
                    assert not state["contextLost"]
                    views.setdefault(key, {})[phase] = {k:state[k] for k in
                        ["position", "pitch", "yaw", "fov", "buffer", "pixelRatio", "calls", "triangles", "glBuffers"]}
                    page.locator("#scene").screenshot(path=dest/(key+".png"))
                assert not errors, errors
                ctx.close()
            for key, row in views.items():
                for prop in ["position","pitch","yaw","fov","buffer","pixelRatio"]:
                    assert row["before"][prop] == row["after"][prop], (key, prop)
                images = [Image.open(args.originals/tag/phase/(key+".png")).convert("RGB") for phase in builds]
                difference = ImageChops.difference(*images)
                changed = sum(difference.convert("L").histogram()[1:])
                row["changedLumaPixels"] = changed
                if key == "student-north":
                    assert difference.getbbox() is None, "The original north-side entrance changed"
                if key in ["student-entry2","agora-east"]:
                    assert changed > 0, key
                    qa.save_pair(images, ["Before | PR #14", "After | Agora-side entrance"],
                                 args.output/"screens"/(tag+"-"+key+".png"))
    qa.dump(args.output/"raw/cameras.json", report)


if __name__ == "__main__":
    main()
