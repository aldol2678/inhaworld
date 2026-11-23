"""Measure native presentation and fenced draws separately, in one live WebGL context per preset family."""
import argparse
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('corridor_capture', ROOT/'qa/p1bc/capture.py')
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
qa.CAMERAS['dream-east']=(160.17,-53,128,-26)

CADENCE = """async ([warm, count]) => {
    const ts=[], tiers=[];
    await new Promise(resolve => {
        function next(t) {
            ts.push(t);
            tiers.push(gfxStateTier());
            if(ts.length === warm+count+1) resolve(); else requestAnimationFrame(next);
        }
        requestAnimationFrame(next);
    });
    return {frameMs:ts.slice(warm+1).map((t,i)=>t-ts[i+warm]), tiers:tiers.slice(warm+1)};
}"""


def live(browser, origin, dist, size, preset, init_script=None):
    w,h=size
    ctx=browser.new_context(viewport={'width':w,'height':h}, is_mobile=w<1000,has_touch=w<1000,device_scale_factor=1)
    page=ctx.new_page()
    errors=[]
    page.on('pageerror',lambda err: errors.append(str(err)))
    page.add_init_script(qa.BUFFER_PROBE)
    page.add_init_script(qa.ATTACHMENTS)
    if init_script:
        page.add_init_script(init_script)
    page.add_init_script("localStorage.setItem('inha-world-graphics-quality-v1',"+json.dumps(preset)+")")
    def route(r):
        if r.request.url == origin+'/src/main.js':
            r.fulfill(content_type='text/javascript',body=(dist/'src/main.js').read_text()+'\n'+qa.PROBE+qa.DETAIL+
                      '\nglobalThis.gfxStateTier=()=>quality.tier;'+
                      "globalThis.dreamLod=()=>{const mesh=scene.getObjectByName('dream');"+
                      "return mesh?{visible:mesh.visible,vertices:mesh.geometry.drawRange.count}:null;};")
        elif r.request.url == origin+'/api/health':
            r.fulfill(status=503,json={})
        elif r.request.method == 'GET' and r.request.url.startswith(origin+'/'):
            r.continue_()
        else:
            errors.append(r.request.url)
            r.abort()
    page.route('**/*',route)
    page.goto(origin)
    page.wait_for_function("typeof gfxStateTier==='function' && document.querySelector('#room-list').children.length===3")
    return ctx,page,errors


def measurement(page, preset, view):
    page.locator('#graphics-quality').select_option(preset)
    pose=qa.CAMERAS[view]
    page.evaluate('p=>captureMapView(p)',pose)
    cadence=page.evaluate(CADENCE,[12,40])
    state=page.evaluate('p=>captureMapView(p)',pose)
    state['graphics']=page.evaluate('gfxState()')
    sync=page.evaluate('sampleMapRender(24)')
    assert not state['contextLost'] and state['graphics']['error']==0
    return dict(preset=preset,view=view,state=state,**cadence,renderReadbackMs=sync)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('dist',type=Path)
    ap.add_argument('out',type=Path)
    ap.add_argument('--mode',choices=['paired','tiers','sites'],required=True)
    a=ap.parse_args()
    report={'mode':a.mode,'deviceScaleFactor':1,'samples':[]}
    with ExitStack() as stack, sync_playwright() as pw:
        origin=qa.serve(stack,a.dist)
        browser=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                                   args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
        report['browser']=browser.version
        if a.mode=='paired':
            # ABBA then BAAB. Auto and manual high start from native MSAA on this PC.
            ctx,page,errors=live(browser,origin,a.dist,(1280,720),'high')
            page.evaluate("globalThis.firstGL=document.querySelector('#scene').getContext('webgl2')")
            for preset in ['auto','high','high','auto','high','auto','auto','high']:
                row=measurement(page,preset,'canal-west')
                row['sameContext']=page.evaluate("firstGL===document.querySelector('#scene').getContext('webgl2')")
                report['samples'].append(row)
            assert not errors,errors
            ctx.close()
        elif a.mode=='sites':
            for size in qa.SIZES:
                for preset in qa.TIERS:
                    ctx,page,errors=live(browser,origin,a.dist,size,preset)
                    for view in ['dream-east','agora']:
                        row=measurement(page,preset,view)
                        row.update(size=size,skyline=page.evaluate('dreamLod()'))
                        report['samples'].append(row)
                    assert not errors,errors
                    ctx.close()
                    qa.dump(a.out,report)
        else:
            for size in qa.SIZES:
                for run in range(2):
                    for preset in qa.TIERS if run==0 else reversed(qa.TIERS):
                        ctx,page,errors=live(browser,origin,a.dist,size,preset)
                        row=measurement(page,preset,'canal-west')
                        row.update(size=size,run=run)
                        report['samples'].append(row)
                        assert not errors,errors
                        ctx.close()
                        qa.dump(a.out,report)
        qa.dump(a.out,report)
        browser.close()


if __name__=='__main__':
    main()
