import argparse
from pathlib import Path
import json,subprocess,sys,tempfile,zipfile
from playwright.sync_api import sync_playwright
def main():
    ap=argparse.ArgumentParser();ap.add_argument('zip',type=Path);ap.add_argument('out',type=Path)
    a=ap.parse_args()
    report={}
    with tempfile.TemporaryDirectory() as dest,zipfile.ZipFile(a.zip) as z,sync_playwright() as pw:
        z.extractall(dest)
        server=subprocess.Popen([sys.executable,'-u','start.py','--port','0'],cwd=dest,
                                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        try:
            origin=server.stdout.readline().strip().split()[-1]
            br=pw.chromium.launch(executable_path='/usr/bin/chromium',args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
            for mobile in [False,True]:
                size=[891,411] if mobile else [1280,720]
                ctx=br.new_context(viewport={'width':size[0],'height':size[1]},has_touch=mobile,is_mobile=mobile)
                page=ctx.new_page();errors=[];urls=[]
                page.on('pageerror',lambda e:errors.append(str(e)))
                page.on('request',lambda r:urls.append(r.url))
                page.goto(origin)
                page.wait_for_function("document.querySelector('#room-list').children.length===3")
                tier='low' if mobile else 'high'
                page.locator('#graphics-quality').select_option(tier)
                page.reload()
                page.wait_for_function("document.querySelector('#hud-pos').innerText.includes('x ')")
                assert page.locator('#graphics-quality').input_value()==tier
                start=page.locator('#hud-pos').inner_text()
                rect=page.locator('#scene-input').bounding_box()
                x,y=rect['x']+rect['width']*.27,rect['y']+rect['height']*.5
                if mobile:
                    cdp=ctx.new_cdp_session(page)
                    for event,points in [('touchStart',[dict(x=x,y=y,id=1)]),('touchMove',[dict(x=x,y=y-40,id=1)])]:
                        cdp.send('Input.dispatchTouchEvent',dict(type=event,touchPoints=points))
                else:
                    page.mouse.click(x,y)
                    page.keyboard.down('w')
                    assert page.evaluate("document.pointerLockElement===document.querySelector('#scene-input')")
                page.wait_for_function("prev=>document.querySelector('#hud-pos').innerText!==prev",arg=start)
                if mobile:
                    cdp.send('Input.dispatchTouchEvent',dict(type='touchEnd',touchPoints=[]))
                    assert page.locator('#joy-base').is_hidden()
                else:
                    page.keyboard.up('w')
                    page.evaluate('document.exitPointerLock()')
                end=page.locator('#hud-pos').inner_text()
                assert start!=end and not errors
                assert all(url.startswith(origin+'/') for url in urls)
                report[str(size)]=dict(chromium=br.version,mode=tier,start=start,end=end,normalRAF=True,
                                       localOnly=True,errors=errors,filesRequested=len(urls))
                ctx.close()
            br.close()
        finally:
            server.terminate();server.wait(timeout=5)
    a.out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
