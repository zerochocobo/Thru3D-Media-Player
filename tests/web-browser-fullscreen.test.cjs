const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

test('fullscreen capture and source-bound return preserve the actual video', async () => {
  const events = {}, timers = [], ports = [];
  const makeVideo = (width) => ({
    isConnected: true, videoWidth: width, videoHeight: 1080, currentTime: 12,
    duration: 120, paused: false, ended: false, currentSrc: 'blob:video-' + width,
    listeners: {}, addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); },
    pause() { this.paused = true; }, play() { this.paused = false; return Promise.resolve(); }
  });
  const main = makeVideo(1920), ad = makeVideo(3840);
  const signal = () => ({ list: [], addListener(fn) { this.list.push(fn); }, emit(value) { this.list.forEach(fn => fn(value)); } });
  const document = { nodeType: 9, fullscreenElement: null, querySelectorAll: s => s === 'video' ? [main, ad] : [] };
  const context = { document, location: { href: 'https://example.test/video' }, navigator: { userAgent: 'fixture' },
    MutationObserver: class { observe() {} disconnect() {} },
    setTimeout(fn) { timers.push(fn); }, addEventListener(name, fn) { (events[name] ??= []).push(fn); },
    browser: { runtime: { connectNative() {
      const port = { onMessage: signal(), onDisconnect: signal(), messages: [],
        postMessage(v) { this.messages.push(JSON.parse(JSON.stringify(v))); }, disconnect() { this.onDisconnect.emit(); } };
      ports.push(port); return port;
    } } }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../android/web-browser/src/main/assets/web-browser/media.js'), 'utf8'), context);
  const flush = () => { while (timers.length) timers.shift()(); };
  const port = ports[0], message = v => port.onMessage.emit(v);
  const fullscreen = element => { document.fullscreenElement = element; events.fullscreenchange.forEach(fn => fn()); };
  flush();
  fullscreen({ contains: () => false });
  assert.equal(port.messages.at(-1).videos.some(v => v.fullscreen), false, 'Non-video fullscreen does not target unrelated players');
  fullscreen({ contains: element => element === main });
  const selected = port.messages.at(-1).videos.find(v => v.fullscreen);
  assert.equal(selected.width, 1920, 'The fullscreen container identifies the video rather than the largest advertisement');
  assert.equal(port.messages.at(-1).videos.filter(v => v.fullscreen).length, 1);
  message({ action: 'capture_video', id: String(selected.id), request: 1 });
  assert.equal(main.paused, false, 'Capturing the return target does not interrupt playback while resolving');
  message({ action: 'suspend' });
  assert.ok(main.paused && ad.paused);
  message({ action: 'restore_video', request: 999, time: 50, play: true });
  assert.equal(main.currentTime, 12, 'A stale request cannot seek or resume a video');
  message({ action: 'restore_video', request: 1, time: 43.5, play: true });
  await Promise.resolve();
  assert.equal(main.currentTime, 43.5); assert.equal(main.paused, false);
  assert.equal(ad.paused, true, 'Failure recovery resumes only the captured video');
  message({ action: 'restore_video', request: 1, time: 1, play: true });
  assert.equal(main.currentTime, 43.5, 'Each capture is restored at most once');
  message({ action: 'capture_video', id: String(selected.id), request: 2 });
  message({ action: 'suspend' });
  message({ action: 'restore_video', request: 2, time: 90, play: false });
  assert.equal(main.currentTime, 90); assert.equal(main.paused, true, 'Normal exit returns to the web page paused at the native position');
  message({ action: 'capture_video', id: String(selected.id), request: 3 });
  main.currentSrc = 'blob:another-source';
  message({ action: 'restore_video', request: 3, time: 7, play: true });
  assert.equal(main.currentTime, 90); assert.equal(main.paused, true, 'A source replaced in the same DOM element is never resumed by an old request');
  message({ action: 'capture_video', id: String(selected.id), request: 4 });
  main.play = () => Promise.reject(new Error('Autoplay blocked'));
  message({ action: 'restore_video', request: 4, time: 91, play: true });
  await new Promise(setImmediate);
  assert.equal(port.messages.findLast(v => v.type === 'restore_video_result' && v.request === 4).retry, true,
    'A site play rejection requests the native MediaSession fallback');
  message({ action: 'capture_video', id: String(selected.id), request: 5 });
  let rejectPlay;
  main.play = () => new Promise((_, reject) => { rejectPlay = reject; });
  message({ action: 'restore_video', request: 5, time: 92, play: true });
  main.currentSrc = 'blob:new-source-before-play-result';
  rejectPlay(new Error('Autoplay blocked'));
  await new Promise(setImmediate);
  assert.equal(port.messages.findLast(v => v.type === 'restore_video_result' && v.request === 5).retry, false,
    'A late play rejection cannot ask native controls to start a replacement source');
  fullscreen(null);
  assert.equal(port.messages.at(-1).videos.some(v => v.fullscreen), false);
});
