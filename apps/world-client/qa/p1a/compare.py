"""Compare the PC and landscape outputs of capture.py. Requires Pillow 10.1+."""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont


def save_pair(images, labels, path):
    gap, header = 6, 34
    panel = Image.new("RGB", (sum(im.width for im in images) + gap, images[0].height + header), "#192825")
    draw = ImageDraw.Draw(panel)
    font = ImageFont.load_default(size=16)
    x = 0
    for image, label in zip(images, labels):
        draw.text((x + 12, 8), label, fill="#f2f3ea", font=font)
        panel.paste(image, (x, header))
        x += image.width + gap
    panel.save(path, optimize=True)


def compare(dirs, screen_dir, suffix, labels):
    before, after = [json.loads((d / "cameras.json").read_text()) for d in dirs]
    for key in ("chromium", "viewport", "touch", "visibilityChanges"):
        assert before[key] == after[key], key
    assert before["views"].keys() == after["views"].keys()
    for run in (before, after):
        assert run["visibilityChanges"] == 24
        for key in ("glBuffers", "geometries", "textures", "calls", "triangles"):
            assert run["repeatGate"][key] == run["reloadedGate"][key], key
    views = {}
    for name, original in before["views"].items():
        pose_keys = ("position", "yaw", "pitch", "fov", "buffer", "pixelRatio")
        row = views[name] = {key: original[key] for key in pose_keys}
        images = []
        for phase, directory, run in zip(("before", "after"), dirs, (before, after)):
            stats = run["views"][name]
            assert not stats["contextLost"]
            for key in pose_keys:
                assert row[key] == stats[key], (name, key)
            path = directory / f"{name}.png"
            with Image.open(path) as im:
                images.append(im.convert("RGB"))
            row[phase] = {key: stats[key] for key in ("calls", "triangles", "glBuffers", "geometries", "textures")}
            row[phase]["pngSha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        assert images[0].size == images[1].size
        diff = ImageChops.difference(*images)
        r, g, b = diff.split()
        max_channel = ImageChops.lighter(ImageChops.lighter(r, g), b)
        histogram = max_channel.histogram()
        row["changedPixels"] = sum(histogram[1:])
        row["changedPixelsOver8"] = sum(histogram[9:])
        row["changedBoundsXYXY"] = diff.getbbox()
        row["maxChannelDelta"] = max_channel.getextrema()[1]
        save_pair(images, [f"{label}    {name}" for label in labels], screen_dir / f"{name}{suffix}.png")
    return {"viewport": after["viewport"], "chromium": after["chromium"], "views": views,
            "stableAcross24VisibilityChangesAndReload": True}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("before_pc", type=Path)
    p.add_argument("after_pc", type=Path)
    p.add_argument("before_landscape", type=Path)
    p.add_argument("after_landscape", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--before-label", default="PR #7")
    p.add_argument("--after-label", default="P1A")
    args = p.parse_args()
    screens = args.out / "screens"
    screens.mkdir(parents=True, exist_ok=True)
    labels = [args.before_label, args.after_label]
    result = {
        "pc": compare([args.before_pc, args.after_pc], screens, "", labels),
        "mobile": compare([args.before_landscape, args.after_landscape], screens, "-landscape", labels),
    }
    (args.out / "camera-results.json").write_text(json.dumps(result, indent=2) + "\n")
