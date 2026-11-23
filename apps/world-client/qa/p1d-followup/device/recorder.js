export function frameSummary(intervals) {
  if (!intervals.length) return { count: 0, fps: null, medianMs: null, p95Ms: null };
  const sorted = intervals.slice().sort((a, b) => a - b);
  const count = sorted.length;
  const midpoint = Math.floor(count / 2);
  const median = count % 2 ? sorted[midpoint] : (sorted[midpoint - 1] + sorted[midpoint]) / 2;
  return {
    count,
    fps: 1000 * count / intervals.reduce((sum, x) => sum + x, 0),
    medianMs: median,
    p95Ms: sorted[Math.ceil(count * .95) - 1],
  };
}

export function installRecorder({ build, renderer, player, quality, moveTo, stations }) {
  const launcher = document.querySelector('#field-recorder');
  const dialog = document.querySelector('#field-options');
  const form = dialog.querySelector('form');
  const status = document.querySelector('#field-status');
  const save = document.querySelector('#field-save');
  let recording, finished, raf, previousTime, previousFrame, lastPosition;
  let context, segment, nextMetric, lastDrawTime;

  function position() {
    return { x: player.x, z: player.z, yaw: player.yaw };
  }
  function metrics(r, gl) {
    const info = r.info;
    return {
      activeMs: recording.activeMs, segment: recording.segments.length - 1,
      position: position(), calls: info.render.calls, triangles: info.render.triangles,
      geometries: info.memory.geometries, textures: info.memory.textures,
      vertexIndexBuffers: window.fieldBufferUsage(gl), contextLost: gl.isContextLost(),
    };
  }
  function finish(reason) {
    cancelAnimationFrame(raf);
    const r = renderer();
    if (segment && !document.hidden && r.getContext() === context && r.info.render.frame > 0)
      recording.metrics.push(metrics(r, context));
    recording.stopReason = reason;
    recording.finishedAt = new Date().toISOString();
    recording.end = position();
    for (const s of recording.segments) s.summary = frameSummary(s.frameMs);
    recording.summary = frameSummary(recording.segments.flatMap(s => s.frameMs));
    finished = recording;
    recording = null;
    launcher.textContent = '기기 측정';
    save.disabled = false;
    const fps = finished.summary.fps?.toFixed(1) ?? '—';
    status.textContent = `${(finished.activeMs / 1000).toFixed(1)}초 · ${fps} FPS · 이동 ${finished.walkedWU.toFixed(1)} WU`;
    if (document.pointerLockElement) document.exitPointerLock();
    dialog.showModal();
  }
  function sample(now) {
    if (!recording) return;
    raf = requestAnimationFrame(sample);
    if (document.hidden) return;
    const dt = previousTime === null ? 0 : now - previousTime;
    previousTime = now;
    recording.activeMs += dt;
    const r = renderer(), canvas = r.domElement, gl = r.getContext();
    if (gl !== context) {
      context = gl;
      const debug = gl.getExtension('WEBGL_debug_renderer_info');
      recording.contexts.push({
        activeMs: recording.activeMs, aa: gl.getContextAttributes()?.antialias ?? null,
        samples: gl.getParameter(gl.SAMPLES),
        renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
      });
      segment = null;
      previousFrame = lastDrawTime = null;
    }
    const renderFrame = r.info.render.frame;
    if (renderFrame > 0 && renderFrame !== previousFrame) {
      const pref = quality.preference, tier = quality.tier, dpr = devicePixelRatio;
      const same = segment && segment.preference === pref && segment.tier === tier &&
        segment.buffer[0] === canvas.width && segment.buffer[1] === canvas.height &&
        segment.viewport[0] === innerWidth && segment.viewport[1] === innerHeight && segment.dpr === dpr;
      if (!same) {
        segment = {
          startMs: recording.activeMs, preference: pref, tier, dpr,
          viewport: [innerWidth, innerHeight], css: [canvas.clientWidth, canvas.clientHeight],
          buffer: [canvas.width, canvas.height], context: recording.contexts.length - 1, frameMs: [],
        };
        recording.segments.push(segment);
        recording.metrics.push(metrics(r, gl));
      } else if (lastDrawTime !== null && now > lastDrawTime) {
        segment.frameMs.push(now - lastDrawTime);
      }
      previousFrame = renderFrame;
      lastDrawTime = now;
      const here = position();
      if (lastPosition) recording.walkedWU += Math.hypot(here.x-lastPosition.x, here.z-lastPosition.z);
      lastPosition = here;
      if (recording.activeMs >= nextMetric) {
        recording.metrics.push(metrics(r, gl));
        nextMetric = recording.activeMs + 1000;
        launcher.textContent = `측정 종료 · ${Math.floor(recording.activeMs / 1000)}초`;
      }
    }
    if (recording.activeMs >= recording.targetMs) finish('duration');
  }
  document.addEventListener('visibilitychange', () => {
    if (!recording) return;
    recording.visibility.push({ activeMs: recording.activeMs, state: document.visibilityState });
    previousTime = previousFrame = lastDrawTime = lastPosition = segment = null;
  });
  launcher.addEventListener('click', () => {
    if (recording) finish('manual');
    else dialog.showModal();
  });
  document.querySelector('#field-start').addEventListener('click', () => {
    const station = form.elements.station.value;
    if (station !== 'current' && !moveTo(stations[station])) {
      status.textContent = '시작 위치에서 보행 여유를 확인할 수 없습니다.';
      return;
    }
    recording = {
      schema: 1, build, startedAt: new Date().toISOString(),
      operatorEnvironment: form.elements.environment.value, operatorModel: form.elements.model.value.trim(),
      userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints, station, start: position(),
      targetMs: Number(form.elements.duration.value) * 1000, activeMs: 0, walkedWU: 0,
      contexts: [], segments: [], metrics: [], visibility: [],
    };
    context = segment = previousTime = previousFrame = lastDrawTime = null;
    lastPosition = position();
    nextMetric = 1000;
    dialog.close();
    document.querySelector('#scene-input').scrollIntoView({block:'nearest'});
    launcher.textContent = '측정 종료';
    raf = requestAnimationFrame(sample);
  });
  save.addEventListener('click', () => {
    if (!finished) return;
    const blob = new Blob([JSON.stringify(finished)], {type:'application/json'});
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'INHA-WORLD-' + finished.startedAt.replace(/[:.]/g,'-') + '.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
  });
}
