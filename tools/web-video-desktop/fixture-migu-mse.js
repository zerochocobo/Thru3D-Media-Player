/* Two public samples in the emulator fixture. Export only active video codec families. */
const Thru3DFixtureMiguMse = (() => {
  const sample = () => /^https:\/\/www\.miguvideo\.com\/p\/vertical\/(968096380|966398567)$/.test(location.href);
  const sources = new Map();
  const buffers = new WeakMap();
  const families = {avc1: 'h264', avc3: 'h264', hvc1: 'hevc', hev1: 'hevc', av01: 'av1', vp09: 'vp9', vp9: 'vp9'};
  const audio = new Set(['mp4a', 'opus', 'vorbis', 'flac', 'ac-3', 'ec-3']);

  function remember(buffer, type) {
    const state = buffers.get(buffer) || {known: true, codecs: new Set()};
    buffers.set(buffer, state);
    if (typeof type === 'string' && /^audio\//i.test(type)) return;
    const match = typeof type === 'string' && /^video\/(?:mp4|webm)\s*;\s*codecs\s*=\s*(?:"([^"]+)"|([a-z0-9.]+))\s*$/i.exec(type);
    const names = (match ? match[1] || match[2] : '').toLowerCase().split(',');
    let videoCodec = false;
    for (const name of names) {
      const prefix = name.trim().split('.')[0];
      if (Object.hasOwn(families, prefix)) {
        state.codecs.add(families[prefix]);
        videoCodec = true;
      } else if (!audio.has(prefix)) state.known = false;
    }
    if (!videoCodec) state.known = false;
  }

  function install() {
    if (window.top !== window || !sample() || typeof exportFunction !== 'function') return;
    const page = window.wrappedJSObject;
    const hooks = [
      [window.URL, page?.URL, 'createObjectURL', (args, url) => {
        if (!(args[0] instanceof window.MediaSource)) return;
        if (sources.size >= 32) sources.delete(sources.keys().next().value);
        sources.set(url, new WeakRef(args[0]));
      }],
      [window.MediaSource?.prototype, page?.MediaSource?.prototype, 'addSourceBuffer',
        (args, buffer) => remember(buffer, args[0])],
      [window.SourceBuffer?.prototype, page?.SourceBuffer?.prototype, 'changeType',
        (args, _result, buffer) => remember(buffer, args[0])],
    ];
    const installed = [];
    try {
      for (const [clean, target, name, observed] of hooks) {
        const original = clean?.[name];
        if (name === 'changeType' && typeof original !== 'function') continue;
        const descriptor = target && Object.getOwnPropertyDescriptor(target, name);
        if (typeof original !== 'function' || !descriptor?.writable) throw new Error('Observer interface unavailable');
        target[name] = exportFunction(function (...args) {
          const result = Reflect.apply(original, this, args);
          try { if (sample()) observed(args, result, this); } catch (_) {}
          return result;
        }, window);
        installed.push([target, name, descriptor]);
      }
    } catch (_) {
      for (const [target, name, descriptor] of installed) Object.defineProperty(target, name, descriptor);
    }
  }

  function activeVideoCodecs(video) {
    if (!sample() || video.mediaKeys) return [];
    try {
      const active = sources.get(video.currentSrc)?.deref()?.activeSourceBuffers;
      if (!active) return [];
      const codecs = new Set();
      for (let i = 0; i < active.length; i++) {
        const state = buffers.get(active[i]);
        if (!state?.known) return [];
        for (const codec of state.codecs) codecs.add(codec);
      }
      return [...codecs].sort();
    } catch (_) {
      return [];
    }
  }

  install();
  return {activeVideoCodecs};
})();
