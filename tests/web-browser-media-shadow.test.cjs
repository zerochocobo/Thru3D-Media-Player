const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// A web-component player keeps its <video> inside a shadow root (archive.org).
const timers = [];
const ports = [];
const observed = [];
const video = {
  isConnected: true, videoWidth: 640, videoHeight: 480, currentTime: 3, duration: 900,
  paused: false, ended: false, currentSrc: 'https://archive.example/movie.mp4',
  addEventListener() {}, pause() { this.paused = true; }
};
const shadow = { nodeType: 11, querySelectorAll(selector) { return selector === 'video' ? [video] : []; } };
const player = { localName: 'media-player', openOrClosedShadowRoot: shadow };
const signal = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
const context = {
  document: { nodeType: 9, querySelectorAll(selector) { return selector === '*' ? [player, { localName: 'div' }] : []; } },
  location: { href: 'https://archive.example/details/movie' },
  navigator: { userAgent: 'Synthetic browser' },
  MutationObserver: class { constructor() {} observe(target) { observed.push(target); } disconnect() {} },
  setTimeout(fn) { timers.push(fn); },
  addEventListener() {},
  browser: { runtime: { connect() {
    return { onMessage: { addListener() {} }, onDisconnect: { addListener() {} }, postMessage() {} };
  }, connectNative() {
    const port = { onMessage: signal(), onDisconnect: signal(), messages: [],
      postMessage(message) { this.messages.push(JSON.parse(JSON.stringify(message))); }, disconnect() {} };
    ports.push(port); return port;
  } } }
};
const flush = () => { let n = 0; while (timers.length) { assert.ok(++n < 100); timers.shift()(); } };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../android/web-browser/src/main/assets/web-browser/media.js'), 'utf8'), context);
flush();
assert.ok(observed.includes(shadow), 'The shadow root joins the mutation observer');
const last = ports[0].messages.at(-1);
assert.equal(last.videos.length, 1, 'A shadow-DOM video is reported');
assert.equal(last.videos[0].source, video.currentSrc, 'Its progressive source is available for handoff fallback');
assert.equal(last.videos[0].playing, true);
