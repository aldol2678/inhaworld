"""Quality application on real WebGL contexts and uninterrupted movement across AA modes."""
import json
import math
import pytest
from test_world import ROOT, OUT, Driver, frame, guest_ready, hold, position, touches

TIERS = ['very_low', 'low', 'medium', 'high', 'ultra']
PROBE = """
globalThis.graphicsQA = () => {
  campus.updateVisibility(player.x,player.z);
  renderer.render(scene,camera);
  const gl=renderer.getContext(), base=scene.getObjectByName('base'), plants=scene.getObjectByName('crowns');
  return { tier:quality.tier, preference:quality.preference, aa:gl.getContextAttributes().antialias,
    samples:gl.getParameter(gl.SAMPLES), css:[canvas.clientWidth,canvas.clientHeight], buffer:[canvas.width,canvas.height],
    calls:renderer.info.render.calls, triangles:renderer.info.render.triangles,
    sections:scene.getObjectByName('canal').geometry.drawRange.count, crown:plants.geometry.attributes.position.count,
    base:base.visible, water:scene.getObjectByName('reflecting-pool').visible,
    lost:gl.isContextLost(), err:gl.getError() };
};
globalThis.sweepQA = async () => {
  const src=await (await fetch('/data/layout.json')).json();
  const edges=(ring)=>ring.map((a,i)=>{
    const b=ring[(i+1)%ring.length], len=Math.hypot(b.x-a.x,b.z-a.z), dx=(b.z-a.z)/len,dz=(a.x-b.x)/len;
    for(const sign of [-1,1]) for(const t of [.26,.52,.76]){
      const x=a.x+(b.x-a.x)*t,z=a.z+(b.z-a.z)*t, from={x:x+sign*dx*1.45,z:z+sign*dz*1.45};
      if(!campus.canStand(from.x,from.z) || campus.canStand(x-sign*dx*.1,z-sign*dz*.1))continue;
      const stop=campus.move(from.x,from.z,-sign*dx*2.9,-sign*dz*2.9);
      return campus.canStand(stop.x,stop.z) && sign*((stop.x-x)*dx+(stop.z-z)*dz)>=.599;
    }
    return false;
  });
  const result={};
  for(const id of ['lmk_inkyung_pond','site_218220690','bldg_lawschool','bldg_06','bldg_hawaii','bldg_07']){
    const checks=edges(src.obstacles.find(o=>o.id===id).polygon);
    result[id]=checks.filter(Boolean).length;
  }
  return result;
};
globalThis.recoveryQA = () => {
  let t=performance.now();
  quality.resume();
  const initial=quality.tier;
  for(let i=0;i<250;i++) quality.frame(t+=40);
  const slow=quality.tier;
  for(let i=0;i<1800;i++) quality.frame(t+=16);
  return [initial,slow,quality.tier];
};
"""


def setup(browser, origin, mobile, dpr=1, extra_probe=""):
    size=(891,411) if mobile else (1280,720)
    ctx=browser.new_context(viewport=dict(zip(['width','height'],size)),is_mobile=mobile,
                            has_touch=mobile,device_scale_factor=dpr)
    p=ctx.new_page()
    errors=[]
    p.on('pageerror',lambda e: errors.append(str(e)))
    def route(r):
        if r.request.url==origin+'/src/main.js':
            response=r.fetch()
            r.fulfill(response=response,body=response.text()+'\n'+PROBE+'\n'+extra_probe)
        elif r.request.url==origin+'/api/health':
            r.fulfill(status=503,json={})
        elif r.request.url.startswith(origin+'/') and r.request.method=='GET':
            r.continue_()
        else:
            r.abort()
    p.route('**/*',route)
    p.add_init_script(path=ROOT/'tests/world-driver.js')
    p.goto(origin)
    guest_ready(p)
    return ctx,p,errors


@pytest.mark.parametrize('mobile',[False,True])
def test_all_quality_settings_and_switch_during_input(browser,origin,mobile):
    ctx,p,errors=setup(browser,origin,mobile,2)
    try:
        hold(p)
        select=p.locator('#graphics-quality')
        assert select.locator('option').all_text_contents()==['자동','매우 낮음','낮음','중간','높음','울트라']
        box=select.bounding_box()
        assert 0<=box['x'] and box['x']+box['width']<=p.viewport_size['width'] and box['y']>=0
        observations={}
        for tier,cap in zip(TIERS,[.65,.8,1.25,2,2]):
            select.select_option(tier)
            state=p.evaluate('graphicsQA()')
            observations[tier]=state
            assert state['tier']==tier and state['preference']==tier
            assert state['buffer']==[math.floor(v*cap) for v in state['css']]
            assert state['aa']==(tier in ['high','ultra'])
            assert state['base'] and state['water'] and not state['lost'] and state['err']==0
            checks=p.evaluate('sweepQA()')
            assert checks['lmk_inkyung_pond']==13 and checks['site_218220690']==4
            assert all(checks[k]>0 for k in checks if k.startswith('bldg_'))
        assert observations['very_low']['crown'] < observations['medium']['crown']
        assert [observations[t]['sections'] for t in TIERS]==sorted({observations[t]['sections'] for t in TIERS})
        select.select_option('very_low')
        p.evaluate("window.previousGraphicsContext=document.querySelector('#scene').getContext('webgl2')")
        cdp=ctx.new_cdp_session(p)
        d=Driver(p,cdp,mobile)
        start=position(p)
        if mobile:
            touches(cdp,'touchStart',[(1,d.left,d.cy)])
            touches(cdp,'touchMove',[(1,d.left,d.cy-42)])
        else:
            p.keyboard.down('w')
        # The normal select event can also arrive while a finger or pointer lock is live.
        p.evaluate("()=>{const s=document.querySelector('#graphics-quality');s.value='high';s.dispatchEvent(new Event('change'))}")
        if not mobile:
            assert p.evaluate("document.pointerLockElement===document.querySelector('#scene-input')")
        frame(p,4,.04)
        assert math.dist(position(p),start)>.5
        if mobile:
            touches(cdp,'touchEnd',[])
            assert not p.locator('#joy-base').is_visible()
        else:
            p.keyboard.up('w')
            p.evaluate('document.exitPointerLock()')
        assert p.evaluate('previousGraphicsContext.isContextLost()')
        for _ in range(3):
            select.select_option('low')
            select.select_option('high')
        p.reload()
        guest_ready(p)
        assert select.input_value()=='high' and p.evaluate('graphicsQA().aa')
        assert not errors,errors
        if OUT:
            (OUT/f'quality-{p.viewport_size["width"]}.json').write_text(json.dumps(dict(
                profiles=observations, shoreline=checks, switchedWhileMoving=True,reload='high'),indent=2))
    finally:
        ctx.close()


def test_auto_live_slow_frames_and_recovery(browser,origin):
    ctx,p,errors=setup(browser,origin,True)
    try:
        s=p.locator('#graphics-quality')
        s.select_option('auto')
        before=p.evaluate('graphicsQA().tier')
        assert before=='medium'
        # Slow actual presentation intervals on this local test page.
        p.evaluate("""() => { window.testLoad=true; function work(){
          if(!window.testLoad)return; const end=performance.now()+49;
          while(performance.now()<end){} requestAnimationFrame(work);
        } requestAnimationFrame(work); }""")
        p.wait_for_function("document.querySelector('#graphics-resolved').textContent==='낮음'",timeout=22000)
        p.evaluate('window.testLoad=false')
        after=p.evaluate('graphicsQA().tier')
        assert after=='low' and s.input_value()=='auto'
        hold(p)
        s.select_option('auto')
        transitions=p.evaluate('recoveryQA()')
        assert transitions==['medium','low','medium']
        s.select_option('ultra')
        assert p.evaluate('recoveryQA()')==['ultra']*3
        p.reload()
        guest_ready(p)
        assert s.input_value()=='ultra'
        assert not errors,errors
        if OUT:
            (OUT/'auto.json').write_text(json.dumps(dict(realLoadedRaf=[before,after],
              controlledFrameRecovery=transitions,manualReload='ultra'),indent=2))
    finally:
        ctx.close()


@pytest.mark.parametrize('mobile',[False,True])
def test_full_both_bank_centerlines(browser,origin,mobile):
    ctx,p,errors=setup(browser,origin,mobile)
    try:
        p.locator('#graphics-quality').select_option('low' if mobile else 'high')
        hold(p)
        d=Driver(p,ctx.new_cdp_session(p),mobile)
        layout=json.loads((ROOT/'data/layout.json').read_text())
        routes={r['id']:r['line'] for r in layout['routes']}
        points=[layout['rooms']['main-gate'],*routes['site_481241657'],
                *reversed(routes['site_258995842']),layout['rooms']['main-gate']]
        for target in points:
            d.walk(target)
        assert math.dist(position(p),(0,-76)) < .5
        assert not errors,errors
        if OUT:
            (OUT/f'both-banks-{p.viewport_size["width"]}.json').write_text(json.dumps(d.inputs,indent=2))
    finally:
        ctx.close()
