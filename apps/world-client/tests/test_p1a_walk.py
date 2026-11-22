"""Replay the P0 service ways into Agora and along Inkyung's east bank through normal input."""

import json
import math

import pytest

from test_world import CASES, OUT, ROOT, Driver, draw_stats, frame, guest_ready, hold, position, touches


def look_at(driver, target):
    x, z = position(driver.page)
    yaw = math.atan2(x - target["x"], z - target["z"])
    if not driver.mobile:
        driver.face(yaw)
    else:
        # Keep each right-thumb drag inside the canvas, even on the 320px viewport.
        delta = (driver.yaw - yaw + math.pi) % (2 * math.pi) - math.pi
        pixels = round(delta / 0.006)
        limit = int(driver.page.locator("#scene").bounding_box()["width"] * 0.20)
        while pixels:
            step = max(-limit, min(limit, pixels))
            touches(driver.cdp, "touchStart", [(2, driver.right, driver.cy)])
            touches(driver.cdp, "touchMove", [(2, driver.right + step, driver.cy)])
            touches(driver.cdp, "touchEnd", [])
            driver.yaw -= step * 0.006
            pixels -= step
    frame(driver.page, 1, 0.016)


def water_contact(driver, ring):
    # At the documented eastern approach the water lies immediately left of way 481241663.
    a, b = ring[1:3]
    dx, dz = b["x"] - a["x"], b["z"] - a["z"]
    length = math.hypot(dx, dz)
    tx, tz = dx / length, dz / length
    nx, nz = -tz, tx

    def distance(pos):
        return (pos[0] - a["x"]) * nx + (pos[1] - a["z"]) * nz

    start = position(driver.page)
    assert 1.4 < distance(start) < 2.1
    driver.walk({"x": start[0] - 5 * nx, "z": start[1] - 5 * nz}, collision=True)
    contact = position(driver.page)
    driver.walk({"x": contact[0] - 5 * tx - 3 * nx, "z": contact[1] - 5 * tz - 3 * nz}, collision=True)
    slide = position(driver.page)
    assert 0.52 < distance(contact) < 0.68 and 0.52 < distance(slide) < 0.68, (contact, slide)
    assert math.dist(contact, slide) > 4.4, (contact, slide)
    driver.walk({"x": start[0], "z": start[1]})
    return {"contact": contact, "slide": slide, "clearanceWU": round(distance(slide), 3)}


@pytest.mark.parametrize("width,height", CASES)
def test_p1a_round_trip(origin, browser, width, height):
    layout = json.loads((ROOT / "data/layout.json").read_text())
    routes = {r["id"]: r["line"] for r in layout["routes"]}
    pond = next(o["polygon"] for o in layout["obstacles"] if o["id"] == "lmk_inkyung_pond")
    mobile = width < 1000
    ctx = browser.new_context(
        viewport={"width": width, "height": height},
        has_touch=mobile,
        is_mobile=mobile,
        device_scale_factor=1,
    )
    try:
        page = ctx.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))

        def local(route):
            if route.request.url == origin + "/api/health":
                return route.fulfill(status=503, json={})
            assert route.request.url.startswith(origin + "/") and route.request.method == "GET"
            return route.continue_()

        page.route("**/*", local)
        page.add_init_script(path=ROOT / "tests/world-driver.js")
        page.goto(origin)
        guest_ready(page)
        hold(page)
        driver = Driver(page, ctx.new_cdp_session(page), mobile)

        # Real source vertices, including both 658/696 and 696/663 shared nodes.
        approach = [layout["spawn"], *routes["site_481241658"][1:], routes["site_481241696"][-2]]
        plaza_mouth = {"x": 126.7, "z": -11.18}
        plaza = {"x": 128.69, "z": -4.03}
        viewpoint = {"x": 125.6, "z": 5.05}
        bank = [viewpoint, *routes["site_481241663"][1:]]
        for point in [*approach[1:], plaza_mouth, plaza]:
            driver.walk(point)
        look_at(driver, {"x": 132, "z": 0})
        out = OUT / "p1a" / f"{width}x{height}" if OUT else None
        if out:
            out.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=out / "agora.png")
        # Return to the plaza mouth before joining the lakeside alignment.
        driver.walk(plaza_mouth)
        driver.walk(approach[-1])
        driver.walk(viewpoint)
        look_at(driver, {"x": 121.5, "z": 18.5})
        contact = water_contact(driver, pond)
        look_at(driver, {"x": 121.5, "z": 18.5})
        if out:
            page.screenshot(path=out / "pond.png")
        for point in [
            bank[1],
            routes["site_1063267429"][-1],
            bank[1],
            bank[2],
            *bank[-2::-1],
            approach[-1],
            plaza_mouth,
            plaza,
            plaza_mouth,
            *reversed(approach),
        ]:
            driver.walk(point)
        assert math.dist(position(page), (layout["spawn"]["x"], layout["spawn"]["z"])) < 0.2
        assert page.locator("#room-list button").count() == 3
        assert page.locator("#quest-list li").count() == 3
        assert page.evaluate("document.documentElement.scrollWidth === innerWidth")
        assert page.locator("#joy-base").is_hidden()
        stats = draw_stats(page)
        assert not stats["lost"] and not errors
        if out:
            (out / "walk.json").write_text(
                json.dumps(
                    {
                        "result": "PASS",
                        "chromium": browser.version,
                        "touch": mobile,
                        "viewport": [width, height],
                        "webgl": stats,
                        "water": contact,
                        "returned": position(page),
                        "inputs": driver.inputs,
                    },
                    indent=2,
                )
                + "\n"
            )
    finally:
        ctx.close()
