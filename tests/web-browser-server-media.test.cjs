const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('android/web-browser/src/main/assets/web-browser/media.js', 'utf8');

function fixture(base = 'http://192.168.1.20:8096') {
  const timers = [], events = {}, messages = [], commands = [];
  let now = 1000, resources;
  const video = { isConnected: true, videoWidth: 1920, videoHeight: 1080, currentTime: 12,
    duration: 120, paused: true, ended: false, currentSrc: '', readyState: 2, seeking: false, listeners: {},
    addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); },
    emit(name) { for (const fn of this.listeners[name] || []) fn(); },
    play() { this.paused = false; this.emit('play'); return Promise.resolve(); },
    pause() { this.paused = true; this.emit('pause'); }
  };
  const ctx = { URL, performance: { now: () => now },
    document: { nodeType: 9, querySelectorAll: s => s === 'video' ? [video] : [] },
    location: { href: base + '/web/index.html#!/videoosd' }, navigator: { userAgent: 'Test' },
    MutationObserver: class { observe() {} disconnect() {} },
    PerformanceObserver: class { constructor(fn) { resources = fn; } observe() {} },
    setTimeout(fn) { timers.push(fn); }, addEventListener(name, fn) { (events[name] ??= []).push(fn); },
    browser: { runtime: { connect() {
      return { onMessage: { addListener() {} }, onDisconnect: { addListener() {} }, postMessage() {} };
    }, connectNative() { return {
      onMessage: { addListener(fn) { commands.push(fn); } }, onDisconnect: { addListener() {} },
      postMessage(value) { messages.push(JSON.parse(JSON.stringify(value))); }
    }; } } }
  };
  vm.runInNewContext(source, ctx);
  const flush = () => { let count = 0; while (timers.length) { assert.ok(++count < 100); timers.shift()(); } };
  const command = value => { commands.forEach(fn => fn(value)); flush(); };
  const gesture = () => { now += 100; events.pointerdown.forEach(fn => fn({ isTrusted: true })); };
  const resource = (name, time = now + 1) => { resources({ getEntries: () => [{ name, startTime: time }] }); flush(); };
  const snapshot = () => { command({ action: 'snapshot' }); return messages.findLast(x => x.type === 'media').videos[0]; };
  flush();
  return { video, flush, command, gesture, resource, snapshot, base };
}

test('Emby and Jellyfin play automatically, with source-bound return and no retry loop', async () => {
  for (const base of ['http://192.168.1.20:8096', 'https://media.test/jellyfin']) {
    const f = fixture(base), v = f.video;
    v.currentSrc = base + '/Videos/abc123/stream.mp4?Static=true&mediaSourceId=version_2&' + (base.includes('jellyfin') ? 'ApiKey' : 'api_key') + '=synthetic';
    assert.equal(f.snapshot().server_play, false, 'Preloading alone does not launch native playback');
    f.gesture(); v.emit('loadstart'); v.play(); f.flush();
    const playing = f.snapshot();
    assert.equal(playing.server_play, true);
    assert.equal(playing.fullscreen, false, 'No fullscreen click is needed');
    assert.equal(playing.source, v.currentSrc);
    f.command({ action: 'capture_video', id: String(playing.id), request: 7 });
    f.command({ action: 'suspend' });
    assert.equal(v.paused, true);
    assert.equal(f.snapshot().server_play, true, 'Suspending preserves the captured return request');
    f.command({ action: 'restore_video', request: 7, time: 40, play: true });
    await new Promise(setImmediate); f.flush();
    assert.equal(v.currentTime, 40);
    assert.equal(f.snapshot().server_play, false, 'Fallback playback cannot immediately hand off again');
    v.pause(); f.flush(); f.gesture(); v.play(); f.flush();
    assert.equal(f.snapshot().server_play, true);
    assert.notEqual(f.snapshot().id, playing.id, 'A new deliberate play gets a new request');
    v.currentSrc = v.currentSrc.replace('version_2', 'version_3');
    const next = f.snapshot();
    assert.notEqual(next.id, playing.id);
    assert.ok(next.source.includes('version_3'), 'Selected media version is preserved');
    v.mediaKeys = {};
    assert.equal(f.snapshot().server_play, false);
    assert.equal(f.snapshot().source, '');
  }
});

test('Blob HLS uses only a new same-server manifest and preserves resumed time', () => {
  const f = fixture(), v = f.video;
  v.currentSrc = 'blob:page-player';
  const manifest = f.base + '/emby/Videos/21/master.m3u8?MediaSourceId=version_1&api_key=synthetic&StartTimeTicks=450000000';
  f.resource(manifest, 100); // Not associated with a user play.
  v.play(); f.flush();
  assert.equal(f.snapshot().server_play, false);
  f.gesture(); v.emit('loadstart');
  f.resource(manifest.replace(f.base, 'https://other.test'));
  assert.equal(f.snapshot().server_play, false);
  f.resource(manifest.replace('&api_key=synthetic', ''));
  assert.equal(f.snapshot().server_play, false);
  f.resource(manifest);
  assert.equal(f.snapshot().server_play, true);
  assert.equal(f.snapshot().time, 12, 'HLS retains the original media timeline');
  assert.equal(f.snapshot().source, manifest);
  const first = f.snapshot();
  f.command({ action: 'capture_video', id: String(first.id), request: 9 });
  f.command({ action: 'suspend' });
  f.command({ action: 'restore_video', request: 9, time: 80, play: false });
  assert.equal(v.currentTime, 80, 'HLS return retains the original timeline');
  assert.equal(f.snapshot().server_play, false);
  assert.equal(v.paused, true);
});

test('progressive transcode offsets map both handoff and return, unless timestamps are copied', () => {
  for (const copy of [false, true]) {
    const f = fixture(), v = f.video;
    v.currentSrc = f.base + '/Videos/21/stream.mp4?MediaSourceId=v1&api_key=synthetic&StartTimeTicks=450000000' + (copy ? '&CopyTimestamps=true' : '');
    f.gesture(); v.emit('loadstart'); v.play(); f.flush();
    const first = f.snapshot();
    assert.equal(first.time, copy ? 12 : 57);
    f.command({ action: 'capture_video', id: String(first.id), request: 10 });
    f.command({ action: 'suspend' });
    f.command({ action: 'restore_video', request: 10, time: 80, play: false });
    assert.equal(v.currentTime, copy ? 80 : 35);
  }
});
