"""Use two native Chrome tabs to check elapsed time and the exported foreground-only recording."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
from zipfile import ZipFile

from websockets.sync.client import connect


def until(probe, label, timeout=10):
    limit=time.monotonic()+timeout
    while time.monotonic()<limit:
        value=probe()
        if value:
            return value
        time.sleep(.08)
    raise TimeoutError(label)


def record(socket,origin,downloads):
    seq=0
    def send(method,params=None,session=None):
        nonlocal seq
        seq+=1
        cmd={'id':seq,'method':method,'params':params or {}}
        if session:
            cmd['sessionId']=session
        socket.send(json.dumps(cmd))
        while True:
            reply=json.loads(socket.recv(timeout=8))
            if reply.get('id')==seq:
                if 'error' in reply:
                    raise RuntimeError(reply['error'])
                return reply['result']
    game=next(t['targetId'] for t in send('Target.getTargets')['targetInfos'] if t['type']=='page')
    session=send('Target.attachToTarget',{'targetId':game,'flatten':True})['sessionId']
    def evaluate(js):
        result=send('Runtime.evaluate',dict(expression=js,returnByValue=True,userGesture=True),session)
        if 'exceptionDetails' in result:
            raise ValueError(result['exceptionDetails'].get('exception',{}).get('description',js))
        return result['result'].get('value')
    send('Browser.setDownloadBehavior',dict(behavior='allow',downloadPath=str(downloads)))
    send('Page.enable',session=session)
    send('Runtime.enable',session=session)
    send('Page.navigate',{'url':origin+'/device/'},session)
    until(lambda:evaluate("document.querySelector('#room-list')?.children.length===3"),'game')
    evaluate("document.querySelector('#field-recorder').click(); document.querySelector('#field-start').click()")
    until(lambda:evaluate("document.querySelector('#field-recorder').textContent.includes('1초')"),'first sample')
    tab=send('Target.createTarget',dict(url='about:blank',background=False,newWindow=False))['targetId']
    send('Target.activateTarget',{'targetId':tab})
    until(lambda:evaluate('document.hidden'),'hidden tab')
    time.sleep(3)
    send('Target.activateTarget',{'targetId':game})
    until(lambda:evaluate('!document.hidden'),'returned tab')
    time.sleep(.9)
    evaluate("document.querySelector('#field-recorder').click(); document.querySelector('#field-save').click()")
    return until(lambda:next(downloads.glob('*.json'),None),'JSON download').read_bytes()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip',type=Path)
    parser.add_argument('out',type=Path)
    a=parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp, ZipFile(a.zip) as z:
        root=Path(tmp)
        z.extractall(root)
        downloads=root/'downloads'
        downloads.mkdir()
        server=subprocess.Popen([sys.executable,'-u','start.py','--port','0'],cwd=root,stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL,text=True)
        profile=root/'chrome'
        browser=subprocess.Popen([os.getenv('CHROMIUM','/usr/bin/chromium'),'--headless=new','--no-sandbox',
            '--disable-dev-shm-usage','--disable-background-networking','--use-angle=swiftshader',
            '--enable-unsafe-swiftshader','--remote-debugging-port=0','--user-data-dir='+str(profile),'about:blank'],
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            origin=server.stdout.readline().strip().split()[-1]
            until((profile/'DevToolsActivePort').exists,'native browser port')
            port=(profile/'DevToolsActivePort').read_text().splitlines()[0]
            with urlopen('http://127.0.0.1:'+port+'/json/version',timeout=5) as r:
                ws=json.load(r)['webSocketDebuggerUrl']
            with connect(ws) as socket:
                raw=record(socket,origin,downloads)
            data=json.loads(raw)
            wall=(datetime.fromisoformat(data['finishedAt'])-datetime.fromisoformat(data['startedAt'])).total_seconds()*1000
            states=[v['state'] for v in data['visibility']]
            assert states==['hidden','visible'], states
            assert wall-data['activeMs']>=2700
            assert len(data['segments'])>=2 and all(s['frameMs'] for s in data['segments'])
            assert max(max(s['frameMs']) for s in data['segments'])<2000
            a.out.write_bytes(raw)
            print(dict(states=states,wallMs=wall,activeMs=data['activeMs'],frames=data['summary']['count']))
        finally:
            for proc in [browser,server]:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=8)


if __name__=='__main__':
    main()
