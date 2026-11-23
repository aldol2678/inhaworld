"""Unpack the field kit and exercise the downloadable recorder in native Chromium."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile
from playwright.sync_api import sync_playwright


def download(page, path):
    with page.expect_download() as event:
        page.locator('#field-save').click()
    event.value.save_as(path)
    return json.loads(path.read_text())


def measure(browser, origin, mobile, out):
    w,h = (891,411) if mobile else (1280,720)
    ctx = browser.new_context(viewport=dict(width=w,height=h), has_touch=mobile, is_mobile=mobile)
    page = ctx.new_page()
    errors, urls = [], []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('request', lambda r: urls.append(r.url))
    try:
        page.goto(origin)
        page.wait_for_function("document.querySelector('#room-list').children.length===3")
        assert page.locator('#field-recorder').count() == 0
        page.goto(origin + '/device/')
        page.wait_for_function("document.querySelector('#room-list').children.length===3")
        tier = page.locator('#graphics-quality')
        tier.select_option('high')
        button, dialog = page.locator('#field-recorder'), page.locator('#field-options')
        button.click()
        category = 'emulation' if mobile else 'desktop'
        station = 'canal-west' if mobile else 'student-entry2'
        dialog.locator('[name=environment]').select_option(category)
        dialog.locator('[name=station]').select_option(station)
        dialog.locator('#field-start').click()
        page.wait_for_function("document.querySelector('#field-recorder').textContent.includes('1초')")
        rect = page.locator('#scene-input').bounding_box()
        x, y = rect['x'] + rect['width']*.26, rect['y'] + rect['height']*.5
        cdp = ctx.new_cdp_session(page)
        if mobile:
            for typ, yy in [('touchStart',y),('touchMove',y-40)]:
                cdp.send('Input.dispatchTouchEvent',dict(type=typ,touchPoints=[dict(x=x,y=yy,id=1)]))
        else:
            page.mouse.click(x,y)
            page.keyboard.down('w')
            page.wait_for_function("document.pointerLockElement?.id==='scene-input'")
        page.wait_for_timeout(850)
        if mobile:
            cdp.send('Input.dispatchTouchEvent',dict(type='touchEnd',touchPoints=[]))
            assert page.locator('#joy-base').is_hidden()
        else:
            page.keyboard.up('w')
            page.evaluate('document.exitPointerLock()')
            page.wait_for_function('!document.pointerLockElement')
        tier.select_option('very_low')
        if mobile:
            page.set_viewport_size(dict(width=h,height=w))
            page.wait_for_timeout(1100)
            page.set_viewport_size(dict(width=w,height=h))
        dialog.wait_for(state='visible',timeout=45000)
        data = download(page,out/f'device-{w}.json')
        assert data['stopReason']=='duration' and 30000<=data['activeMs']<33000
        assert data['station']==station and data['operatorEnvironment']==category and data['walkedWU']>.25
        assert bool(data['maxTouchPoints'])==mobile and data['summary']['count']>100
        assert data['summary']['medianMs']>0 and data['summary']['p95Ms']>=data['summary']['medianMs']
        assert {c['aa'] for c in data['contexts']} == {False,True}
        assert {'high','very_low'} <= {s['tier'] for s in data['segments']}
        if mobile:
            assert {(891,411),(411,891)} <= {tuple(s['viewport']) for s in data['segments']}
        assert len(data['metrics'])>=15
        assert any(s['calls']>0 and s['triangles']>0 and s['vertexIndexBuffers']['bytes']>0 for s in data['metrics'])
        if not mobile:
            # Retry in the same page, use the manual stop, and check that a fresh export has fresh samples.
            dialog.locator('[name=station]').select_option('current')
            dialog.locator('#field-start').click()
            page.wait_for_timeout(1600)
            button.click()
            short = download(page,out/'device-restart.json')
            assert short['stopReason']=='manual' and 0<short['activeMs']<10000
            assert short['station']=='current' and short['startedAt']!=data['startedAt']
            assert len(short['contexts'])==1 and len(short['segments'])==1
        assert not errors, errors
        assert all(url.startswith(origin+'/') for url in urls if not url.startswith('blob:'))
        return dict(viewport=[w,h],browser=browser.version,station=station,errors=errors,
                    normalGameOpened=True,localRequests=len(urls),activeMs=data['activeMs'],
                    walkedWU=data['walkedWU'],summary=data['summary'])
    finally:
        ctx.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip',type=Path)
    parser.add_argument('out',type=Path)
    a=parser.parse_args()
    a.out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory() as dest, ZipFile(a.zip) as z, sync_playwright() as pw:
        z.extractall(dest)
        manifest=json.loads(z.read('play/device/build.json'))
        assert all(sha256(z.read('play/'+k)).hexdigest()==v for k,v in manifest['releaseFileSHA256'].items())
        server=subprocess.Popen([sys.executable,'-u','start.py','--port','0'],cwd=dest,stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL,text=True)
        try:
            origin=server.stdout.readline().strip().split()[-1]
            browser=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                          args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
            cases=[measure(browser,origin,mobile,a.out) for mobile in (False,True)]
            browser.close()
            receipt=dict(source=manifest['source'],filesVerified=len(manifest['releaseFileSHA256']),cases=cases)
            (a.out/'device-check.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
            print(json.dumps(receipt,ensure_ascii=False))
        finally:
            server.terminate()
            server.wait(timeout=5)


if __name__=='__main__':
    main()
