const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/media.js'), 'utf8');
function fixture(count = 1, blob = true) {
  const event = () => { const listeners = []; return { addListener(f) { listeners.push(f); }, fire(value) { listeners.forEach(f => f(value)); } }; };
  const port = () => ({ messages: [], onMessage: event(), onDisconnect: event(), postMessage(m) { this.messages.push(JSON.parse(JSON.stringify(m))); }, disconnect() { this.onDisconnect.fire(); } });
  const native = port(), network = port(); const timers = []; const events = {};
  const videos = Array.from({ length: count }, (_, i) => ({ currentSrc: blob ? `blob:video-${i}` : 'https://cdn.test/movie.mp4', isConnected: true,
    videoWidth: 3840, videoHeight: 2160, paused: false, ended: false, readyState: 4, currentTime: 3, duration: 100,
    events: {}, closest() { return null; }, addEventListener(name, f) { (this.events[name] ||= []).push(f); },
    emit(name) { (this.events[name] || []).forEach(f => f()); }, pause() { this.paused = true; } }));
  const document = { nodeType: 9, querySelectorAll(s) { return s === 'video' ? videos : []; }, fullscreenElement: videos[0] };
  vm.runInNewContext(script, { document, location: { href: 'https://page.test/watch' }, navigator: { userAgent: 'Fixture' }, URL,
    browser: { runtime: { connectNative: () => native, connect: () => network } }, MutationObserver: class { observe() {} disconnect() {} },
    performance: { now: () => 100 }, setTimeout(f) { timers.push(f); }, addEventListener(name, f) { (events[name] ||= []).push(f); } });
  const flush = () => { for (let n = 0; timers.length && n < 10; n++) timers.splice(0).forEach(f => f()); };
  const report = () => native.messages.filter(m => m.type === 'media').at(-1)?.videos;
  const capture = (url = 'https://cdn.test/movie.mp4', original_url) => network.onMessage.fire({ type: 'network', page: 'https://page.test/watch',
    candidates: [{ url, original_url, kind: 'file', at: Date.now(), headers: { authorization: 'Bearer synthetic' } }] });
  flush(); return { videos, native, network, capture, flush, report };
}
test('native per-site policy gates requests and disable clears private media observations', () => {
  const f = fixture();
  assert.equal(f.network.messages.at(-1).enabled, false);
  f.capture(); f.flush(); assert.equal(f.report()[0].network.length, 0);
  f.native.onMessage.fire({ action: 'network_policy', enabled: true }); f.capture(); f.flush();
  assert.equal(f.report()[0].network[0].headers.authorization, 'Bearer synthetic');
  f.native.onMessage.fire({ action: 'network_policy', enabled: false }); f.flush(); assert.equal(f.report()[0].network.length, 0);
});
test('blob requests are not assigned arbitrarily when a frame contains several players', () => {
  const f = fixture(2); f.native.onMessage.fire({ action: 'network_policy', enabled: true }); f.capture(); f.flush();
  f.report().forEach(video => assert.equal(video.network.length, 0));
});
test('encrypted media is removed and a replacement source receives a new media epoch', () => {
  const f = fixture(); f.native.onMessage.fire({ action: 'network_policy', enabled: true }); f.capture(); f.flush();
  const epoch = f.report()[0].network_epoch;
  f.videos[0].emit('loadstart'); f.flush(); assert.notEqual(f.report()[0].network_epoch, epoch);
  f.videos[0].emit('encrypted'); f.capture(); f.flush();
  assert.equal(f.report()[0].protected, true); assert.equal(f.report()[0].network.length, 0); assert.equal(f.report()[0].source, '');
});
test('redirect aliases associate the DOM source with the final observed request', () => {
  const f = fixture(1, false); f.native.onMessage.fire({ action: 'network_policy', enabled: true });
  f.capture('https://second.test/movie.mp4', 'https://cdn.test/movie.mp4'); f.flush();
  assert.equal(f.report()[0].network[0].url, 'https://second.test/movie.mp4');
});

test('player handoff pauses only its document without suspending later user playback', () => {
  const source = fixture(), peer = fixture();
  source.native.onMessage.fire({ action: 'pause_media' });
  assert.equal(source.videos[0].paused, true);
  assert.equal(source.report()[0].playing, false);
  assert.equal(peer.videos[0].paused, false);
  source.videos[0].paused = false; source.videos[0].emit('play');
  assert.equal(source.videos[0].paused, false);
});
