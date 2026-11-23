"""Compare two locally served builds and profile the actual game draw path under SwiftShader."""
import argparse
from contextlib import ExitStack
from functools import partial
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
from threading import Thread

from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'qa/p1a'))
from capture import PROBE, BUFFER_PROBE, VIEWS, QuietHandler
from compare import save_pair

CAMERAS = VIEWS | {
    'canal-west': (7, -67, 45, -10),
    'canal-east': (30.5, -50, 9, -36),
    'lawns': (1, -99, 46, -12, 34, -.40),
    'connector': (99.5, 1.7, 132, -14),
    'student-entry': (136.7, 23.6, 140.47, 19.59),
}
ATTACHMENTS = """
(() => {
  const proto=WebGL2RenderingContext.prototype, live=new Map();
  for(const method of ['renderbufferStorage','renderbufferStorageMultisample']) {
    const original=proto[method];
    proto[method]=function(...args) {
      const result=original.apply(this,args), v=k=>this.getRenderbufferParameter(this.RENDERBUFFER,this['RENDERBUFFER_'+k]);
      const bits=['RED_SIZE','GREEN_SIZE','BLUE_SIZE','ALPHA_SIZE','DEPTH_SIZE','STENCIL_SIZE'].reduce((n,k)=>n+v(k),0);
      const bytes=v('WIDTH')*v('HEIGHT')*Math.max(1,v('SAMPLES'))*bits/8;
      live.set(this.getParameter(this.RENDERBUFFER_BINDING),bytes);
      return result;
    };
  }
  const del=proto.deleteRenderbuffer;
  proto.deleteRenderbuffer=function(buffer){live.delete(buffer); return del.call(this,buffer);};
  globalThis.qaAttachments=()=>({buffers:live.size,logicalBytes:[...live.values()].reduce((a,b)=>a+b,0)});
})();
"""
DETAIL = """
globalThis.gfxState = () => {
  const gl=renderer.getContext();
  const geo=Object.fromEntries(['base','hall','library','canal','connector','crowns','secondary-crowns']
    .map(n=>scene.getObjectByName(n)).filter(Boolean).map(m=>[m.name,{
      visible:m.visible, instances:m.isInstancedMesh?m.count:1, range:m.geometry.drawRange.count,
      vertices:m.geometry.attributes.position.count}]));
  return { tier:typeof quality==='undefined'?'legacy':quality.tier,
    preference:typeof quality==='undefined'?'legacy':quality.preference,
    aa:gl.getContextAttributes().antialias ? 'native-msaa-'+gl.getParameter(gl.SAMPLES) : 'off',
    renderer:gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL),
    css:[canvas.clientWidth,canvas.clientHeight], renderbuffers:qaAttachments(), geo, error:gl.getError() };
};
"""
TIERS = ['auto','very_low','low','medium','high','ultra']
SIZES = [(1280,720),(891,411)]


def serve(stack, dist):
    server = stack.enter_context(ThreadingHTTPServer(('127.0.0.1',0),partial(QuietHandler,directory=str(dist))))
    Thread(target=server.serve_forever,daemon=True).start()
    stack.callback(server.shutdown)
    return f'http://127.0.0.1:{server.server_port}'


def visit(browser, origin, dist, size, tier, measure_cadence=False):
    w,h=size
    ctx=browser.new_context(viewport=dict(width=w,height=h),has_touch=w<1000,is_mobile=w<1000,device_scale_factor=1)
    p=ctx.new_page()
    errors=[]
    p.on('pageerror',lambda e: errors.append(str(e)))
    p.on('console',lambda msg: errors.append(msg.text) if 'Shader Error' in msg.text or 'GL_INVALID' in msg.text else None)
    if tier not in ['auto','legacy']:
        p.add_init_script("localStorage.setItem('inha-world-graphics-quality-v1',"+json.dumps(tier)+")")
    p.add_init_script(path=ROOT/'tests/world-driver.js')
    p.add_init_script(BUFFER_PROBE)
    p.add_init_script(ATTACHMENTS)
    def route(r):
        if r.request.url==origin+'/src/main.js':
            r.fulfill(content_type='text/javascript', body=(dist/'src/main.js').read_text()+'\n'+PROBE+DETAIL)
        elif r.request.url==origin+'/api/health':
            r.fulfill(status=503,json={})
        elif r.request.url.startswith(origin+'/') and r.request.method=='GET':
            r.continue_()
        else:
            errors.append(r.request.url)
            r.abort()
    p.route('**/*',route)
    p.goto(origin)
    p.wait_for_function("typeof gfxState==='function' && document.querySelector('#room-list').children.length===3")
    cadence=None
    if measure_cadence:
        pose(p,'canal-west')
        # Let the unchanged production RAF tick do input, movement, HUD, LOD and rendering.
        # First 8 frames warm the fixed pose; the next 40 intervals measure presentation.
        cadence=p.evaluate('''async () => {
          const samples=[], tiers=[];
          await new Promise(resolve => {
            function observe(time) {
              samples.push(time);
              const selector=document.getElementById('graphics-quality');
              tiers.push(selector?.value==='auto'?document.getElementById('graphics-resolved').textContent:selector?.value??'legacy');
              if(samples.length===49) resolve(); else requestAnimationFrame(observe);
            }
            requestAnimationFrame(observe);
          });
          return {intervalsMs:samples.slice(9).map((v,i)=>v-samples[i+8]),tiers:tiers.slice(9)};
        }''')
    p.evaluate('worldTest.hold()')
    p.wait_for_function('worldTest.ready()',polling=20)
    if tier!='legacy':
        p.locator('#graphics-quality').select_option(tier)
    return ctx,p,errors,cadence


def pose(p, view):
    return p.evaluate('v=>captureMapView(v)',CAMERAS[view])


def dump(path,data):
    path.parent.mkdir(exist_ok=True,parents=True)
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')


def captures(browser, origins, builds, out, scratch):
    reports={}
    for size in SIZES:
        tag='%dx%d'%size
        reports[tag]={}
        for build,tier in [('before','legacy'),('after','high')]:
            ctx,p,errors,_=visit(browser,origins[build],builds[build],size,tier)
            folder=scratch/tag/build
            folder.mkdir(parents=True,exist_ok=True)
            result={}
            for view in CAMERAS:
                result[view]=pose(p,view)
                p.locator('#scene').screenshot(path=folder/(view+'.png'))
            result['graphics']=p.evaluate('gfxState()')
            if build=='after':
                p.screenshot(path=out/'screens'/f'{tag}-settings.png')
            assert not errors and result['graphics']['error']==0,(errors,result['graphics'])
            reports[tag][build]=result
            ctx.close()
        dest=out/'screens'/tag
        dest.mkdir(parents=True,exist_ok=True)
        for view in CAMERAS:
            a,b=[reports[tag][stage][view] for stage in ['before','after']]
            assert all(a[k]==b[k] for k in ['position','yaw','pitch','fov','buffer','pixelRatio']),view
            imgs=[Image.open(scratch/tag/stage/(view+'.png')).convert('RGB') for stage in ['before','after']]
            assert imgs[0].size==imgs[1].size
            save_pair(imgs,['Before | PR #10','After | P1B + P1C | High'],dest/(view+'.png'))
        ctx,p,errors,_=visit(browser,origins['after'],builds['after'],size,'auto')
        tiles=[]
        for tier in TIERS:
            p.locator('#graphics-quality').select_option(tier)
            state=pose(p,'lawns')
            state['graphics']=p.evaluate('gfxState()')
            reports[tag].setdefault('presets',{})[tier]=state
            shot=scratch/tag/(tier+'.png')
            p.locator('#scene').screenshot(path=shot)
            im=Image.open(shot).convert('RGB')
            im.thumbnail((530,300))
            tile=Image.new('RGB',(im.width,im.height+25),'#192825')
            tile.paste(im,(0,25))
            ImageDraw.Draw(tile).text((6,5),f"{tier}  |  {state['buffer'][0]} x {state['buffer'][1]}  |  {state['graphics']['aa']}",fill='white')
            tiles.append(tile)
        contact=Image.new('RGB',(tiles[0].width*2,tiles[0].height*3))
        for i,tile in enumerate(tiles):
            contact.paste(tile,((i%2)*tile.width,(i//2)*tile.height))
        contact.save(dest/'quality.png')
        assert not errors,errors
        ctx.close()
    dump(out/'raw'/'cameras.json',reports)


def timings(browser, origins, builds, out):
    report={'browser':browser.version,'views':['canal-west','pond'],'samples':[]}
    for size in SIZES:
        # Reverse the second round to reduce thermal / run-order bias.
        for run in range(2):
            sequence=['legacy',*TIERS]
            for tier in sequence if run==0 else reversed(sequence):
                build='before' if tier=='legacy' else 'after'
                ctx,p,errors,cadence=visit(browser,origins[build],builds[build],size,tier,True)
                metrics={}
                for name in report['views']:
                    state=pose(p,name)
                    state['graphics']=p.evaluate('gfxState()')
                    state['renderReadbackMs']=p.evaluate('sampleMapRender(30)')
                    metrics[name]=state
                cdp=ctx.new_cdp_session(p)
                cdp.send('HeapProfiler.collectGarbage')
                heap=cdp.send('Runtime.getHeapUsage')
                assert not errors and all(s['graphics']['error']==0 and not s['contextLost'] for s in metrics.values()),errors
                report['samples'].append(dict(size=size,run=run,tier=tier,views=metrics,heap=heap,canalCadence=cadence))
                ctx.close()
                print(size,run,tier,flush=True)
                dump(out/'raw'/'performance.json',report)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ['before','after','out','scratch']:
        ap.add_argument(name,type=Path)
    ap.add_argument('--mode',choices=['screens','perf'],required=True)
    a=ap.parse_args()
    builds={'before':a.before,'after':a.after}
    (a.out/'screens').mkdir(exist_ok=True,parents=True)
    with ExitStack() as stack, sync_playwright() as pw:
        origins={k:serve(stack,path) for k,path in builds.items()}
        br=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                              args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
        if a.mode=='screens':
            captures(br,origins,builds,a.out,a.scratch)
        else:
            timings(br,origins,builds,a.out)
        br.close()
