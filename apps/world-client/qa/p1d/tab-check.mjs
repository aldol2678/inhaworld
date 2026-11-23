// Use native CDP without a focus-emulation override, so Chromium can hide the game tab.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const origin = process.argv[2];
const profile = await mkdtemp(join(tmpdir(), 'inha-tab-'));
const chrome = spawn(process.env.CHROMIUM || '/usr/bin/chromium', [
  '--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run', '--disable-background-networking',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--remote-debugging-port=0',
  '--user-data-dir=' + profile, 'about:blank',
], {stdio:'ignore'});
let socket;
async function until(condition, label) {
  for (let i = 0; i < 100; i++) {
    const value = await condition();
    if (value) return value;
    await delay(80);
  }
  throw Error('Timed out waiting for ' + label);
}
try {
  const port = await until(() => readFile(join(profile, 'DevToolsActivePort'), 'utf8').catch(() => ''), 'DevTools');
  const [number, endpoint] = port.trim().split('\n');
  socket = new WebSocket('ws://127.0.0.1:' + number + endpoint);
  await new Promise((resolve,reject) => { socket.onopen=resolve; socket.onerror=reject; });
  let id = 0;
  const pending = new Map();
  socket.onmessage = ({data}) => {
    const message = JSON.parse(data), task = pending.get(message.id);
    if (!task) return;
    pending.delete(message.id);
    if (message.error) task.reject(Error(message.error.message)); else task.resolve(message.result);
  };
  function send(method, params = {}, sessionId) {
    return new Promise((resolve,reject) => {
      pending.set(++id, {resolve,reject});
      socket.send(JSON.stringify({id,method,params,sessionId}));
    });
  }
  const info = await send('Target.getTargets');
  const game = info.targetInfos.find(t => t.type==='page').targetId;
  const {sessionId} = await send('Target.attachToTarget', {targetId:game, flatten:true});
  const page = (method,params) => send(method,params,sessionId);
  async function evaluate(expression) {
    const result = await page('Runtime.evaluate', {expression,returnByValue:true,awaitPromise:true});
    if (result.exceptionDetails) throw Error(result.exceptionDetails.exception?.description || 'Page exception');
    return result.result.value;
  }
  await page('Page.enable');
  await page('Runtime.enable');
  await page('Emulation.setDeviceMetricsOverride', {width:1280,height:720,mobile:false,deviceScaleFactor:1});
  const driver = await readFile(new URL('../../tests/world-driver.js',import.meta.url),'utf8');
  await page('Page.addScriptToEvaluateOnNewDocument', {source:driver+
    "\nwindow.events=[];document.addEventListener('visibilitychange',()=>events.push(document.visibilityState));"});
  await page('Page.navigate', {url:origin});
  await until(()=>evaluate("document.querySelector('#room-list')?.children.length===3"),'game');
  await evaluate("worldTest.hold()");
  await until(()=>evaluate('worldTest.ready()'),'held native game tick');
  await evaluate("const s=document.querySelector('#graphics-quality');s.value='auto';s.dispatchEvent(new Event('change'));");
  const step = (n) => evaluate("worldTest.advance("+n+",.04);document.querySelector('#graphics-resolved').textContent");
  assert.equal(await step(72),'높음');
  const other = await send('Target.createTarget', {url:'about:blank',background:false,newWindow:false});
  await send('Target.activateTarget', {targetId:other.targetId});
  await until(()=>evaluate("document.hidden && events.includes('hidden')"),'background tab');
  await send('Target.activateTarget', {targetId:game});
  await until(()=>evaluate("!document.hidden && events.at(-1)==='visible'"),'foreground tab');
  const afterReturn = await step(72), sustained = await step(60);
  assert.equal(afterReturn,'높음');
  assert.equal(sustained,'중간');
  console.log(JSON.stringify({events:await evaluate('events'),afterReturn,sustained,
    browser:(await send('Browser.getVersion')).product}));
} finally {
  socket?.close();
  const stopped = new Promise(resolve=>chrome.once('exit',resolve));
  chrome.kill();
  await stopped;
  await rm(profile,{recursive:true,force:true,maxRetries:4,retryDelay:100});
}
