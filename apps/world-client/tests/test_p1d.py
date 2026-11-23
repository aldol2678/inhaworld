"""P1D input, real frame recovery, disputed-site physics and browser lifecycle regressions."""
import json
import math
import subprocess
import pytest
from test_graphics import setup
from test_world import Driver, OUT, ROOT, hold, position

PROBE = """
globalThis.placeP1D = (x,z,yaw=Math.PI) => {
  if (!campus.canStand(x,z)) throw Error('occupied test start');
  Object.assign(player,{x,z,yaw}); updateCamera(); campus.updateVisibility(x,z); refreshHud();
};
globalThis.dreamVisible = () => scene.getObjectByName('dream').visible;
let fixtureTime=0;
globalThis.feedPC = (count) => {
  for (let i=0;i<count;i++) quality.frame(fixtureTime+=40);
  return quality.tier;
};
globalThis.lifecycleEvents=[];
for(const name of ['fullscreenchange','visibilitychange','freeze','resume'])
  document.addEventListener(name,()=>lifecycleEvents.push([name,document.visibilityState]));
window.addEventListener('resize',()=>lifecycleEvents.push(['resize',document.visibilityState]));
"""


@pytest.mark.parametrize('mobile',[False,True])
def test_contact_at_surveyed_outline_and_existing_tree(browser,origin,mobile):
    ctx,p,errors=setup(browser,origin,mobile,extra_probe=PROBE)
    try:
        hold(p)
        p.locator('#graphics-quality').select_option('low' if mobile else 'high')
        tree=p.evaluate("async()=> (await (await fetch('/data/layout.json')).json()).trees[58]")
        p.evaluate('t=>placeP1D(t.x,t.z+3)',tree)
        d=Driver(p,ctx.new_cdp_session(p),mobile)
        d.walk({'x':tree['x'],'z':tree['z']-3},collision=True)
        stop=position(p)
        assert .85 < math.dist(stop,(tree['x'],tree['z'])) < 1.05
        assert not p.evaluate('dreamVisible()')
        p.evaluate('placeP1D(127,-30)')
        d.yaw=math.pi
        d.walk({'x':129,'z':-23})
        d.walk({'x':127,'z':-30})
        assert not p.evaluate('dreamVisible()') and not errors
        if OUT:
            (OUT/f'dream-contact-{p.viewport_size["width"]}.json').write_text(json.dumps(
                dict(tree=tree,stoppedAt=stop,uncertainGroundRoundTrip=d.inputs),indent=2))
    finally:
        ctx.close()


def test_native_auto_down_and_up_with_key_held(browser,origin):
    ctx,p,errors=setup(browser,origin,False,extra_probe=PROBE)
    try:
        p.locator('#graphics-quality').select_option('auto')
        p.evaluate('placeP1D(0,-76,0)')
        d=Driver(p,ctx.new_cdp_session(p),False)
        start=position(p)
        p.keyboard.down('w')
        p.evaluate("""() => {
          window.stress=true; window.recordFrames=true; window.presentations=[];
          let prev;
          function observe(t){
            if(prev!==undefined) presentations.push([t-prev,gfxTier(),document.pointerLockElement?.id||'']);
            prev=t;
            if(stress){const end=performance.now()+54;while(performance.now()<end){}}
            if(recordFrames)requestAnimationFrame(observe);
          }
          const gfxTier=()=>document.querySelector('#graphics-resolved').textContent;
          requestAnimationFrame(observe);
        }""")
        p.wait_for_function("document.querySelector('#graphics-resolved').textContent==='중간'",timeout=20000)
        p.evaluate('window.stress=false')
        assert p.evaluate("document.pointerLockElement===document.querySelector('#scene-input')")
        p.keyboard.up('w')
        stop=position(p)
        assert math.dist(start,stop)>1
        # Native RAF presents the normal game facing south from the gate, without injected load.
        p.wait_for_function("document.querySelector('#graphics-resolved').textContent==='높음'",timeout=58000)
        p.wait_for_function("presentations.at(-1)[1]==='높음'")
        rows=p.evaluate('()=>{recordFrames=false;return presentations}')
        assert any(r[1]=='중간' for r in rows) and all(r[2]=='scene-input' for r in rows)
        assert not errors
        if OUT:
            (OUT/'pc-native-auto.json').write_text(json.dumps(dict(start=start,stop=stop,
                viewport=p.viewport_size,pressureMs=54,frames=rows),ensure_ascii=False))
    finally:
        ctx.close()


def test_old_frame_windows_cannot_cross_viewport_boundaries(browser,origin):
    ctx,p,errors=setup(browser,origin,False,extra_probe=PROBE)
    try:
        hold(p)
        q=p.locator('#graphics-quality')
        def prime():
            q.select_option('auto')
            assert p.evaluate('feedPC(73)')=='high'
        def check():
            assert p.evaluate('feedPC(73)')=='high'
            assert p.evaluate('feedPC(60)')=='medium'
        prime()
        p.set_viewport_size({'width':1024,'height':768})
        p.wait_for_function("lifecycleEvents.some(e=>e[0]==='resize')")
        check()
        prime()
        p.evaluate('document.documentElement.requestFullscreen()')
        p.wait_for_function("document.fullscreenElement && lifecycleEvents.some(e=>e[0]==='fullscreenchange')")
        check()
        p.evaluate('document.exitFullscreen()')
        events=p.evaluate('lifecycleEvents')
        assert not errors
        if OUT:
            (OUT/'lifecycle.json').write_text(json.dumps(events,indent=2))
    finally:
        ctx.close()

def test_real_tab_return_discards_preexisting_slow_frames(origin):
    receipt=subprocess.check_output(['node',ROOT/'qa/p1d/tab-check.mjs',origin],timeout=55,text=True)
    data=json.loads(receipt)
    assert data['events'][-2:]==['hidden','visible']
    if OUT:
        (OUT/'tab.json').write_text(json.dumps(data,ensure_ascii=False,indent=2))
