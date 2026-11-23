// Local QA page only. Count live vertex/index allocations per WebGL context.
(() => {
  const tracked = new WeakMap();
  const proto = globalThis.WebGL2RenderingContext?.prototype;
  if (!proto) return;
  const allocate = proto.bufferData;
  const release = proto.deleteBuffer;
  function state(gl) {
    if (!tracked.has(gl)) {
      const data = { sizes: new Map(), bytes: 0 };
      tracked.set(gl, data);
      gl.canvas.addEventListener('webglcontextrestored', () => {
        data.sizes.clear();
        data.bytes = 0;
      });
    }
    return tracked.get(gl);
  }
  proto.bufferData = function (target, ...args) {
    const result = allocate.call(this, target, ...args);
    if (target === this.ARRAY_BUFFER || target === this.ELEMENT_ARRAY_BUFFER) {
      const binding = target === this.ARRAY_BUFFER ? this.ARRAY_BUFFER_BINDING : this.ELEMENT_ARRAY_BUFFER_BINDING;
      const buffer = this.getParameter(binding);
      if (buffer) {
        const data = state(this);
        const bytes = this.getBufferParameter(target, this.BUFFER_SIZE);
        data.bytes += bytes - (data.sizes.get(buffer) || 0);
        data.sizes.set(buffer, bytes);
      }
    }
    return result;
  };
  proto.deleteBuffer = function (buffer) {
    const data = tracked.get(this);
    if (data?.sizes.has(buffer)) {
      data.bytes -= data.sizes.get(buffer);
      data.sizes.delete(buffer);
    }
    return release.call(this, buffer);
  };
  globalThis.fieldBufferUsage = gl => {
    const data = tracked.get(gl);
    return { bytes: data?.bytes ?? 0, buffers: data?.sizes.size ?? 0 };
  };
})();
