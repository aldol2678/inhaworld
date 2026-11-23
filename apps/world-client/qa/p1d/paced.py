"""Expose both PC controllers to the same sustained 30-Hz game cadence using native RAF timestamps."""
import argparse
from contextlib import ExitStack
from pathlib import Path
import os
from playwright.sync_api import sync_playwright
from measure import qa, live

PACE = """
(() => {
    const native=requestAnimationFrame.bind(window);
    let last=-Infinity;
    window.pacedFrames=[];
    window.requestAnimationFrame=cb=>{
      if (cb.name!=='tick') return native(cb);
      return native(function paced(now) {
        if (now-last<28) {native(paced); return;}
        const previous=last;
        last=now;
        cb(now);
        if(window.recordPace) pacedFrames.push([now-previous,gfxStateTier()]);
      });
    };
})();
"""
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ['before','after','out']:ap.add_argument(name,type=Path)
    a=ap.parse_args()
    report={'pose':[0,-145,0,-170],'viewport':[1280,720],'deviceScaleFactor':1,'runs':[]}
    with ExitStack() as stack,sync_playwright() as pw:
        origins={k:qa.serve(stack,getattr(a,k)) for k in ['before','after']}
        br=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                              args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
        report['browser']=br.version
        for k in ['before','after','after','before']:
            ctx,page,errors=live(br,origins[k],getattr(a,k),(1280,720),'auto',PACE)
            page.evaluate('p=>captureMapView(p)',report['pose'])
            page.wait_for_timeout(600)
            page.locator('#graphics-quality').select_option('auto')
            page.evaluate('window.recordPace=true')
            page.wait_for_function("pacedFrames.length>=230",timeout=20000)
            frames=page.evaluate('()=>{recordPace=false;return pacedFrames}')
            report['runs'].append(dict(build=k,frames=frames,final=page.evaluate('gfxState()')))
            assert not errors
            ctx.close()
        qa.dump(a.out,report)
        br.close()
