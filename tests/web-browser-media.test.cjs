const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const timers = [];
const pageEvents = {};
const ports = [];
const listeners = {};
let observer;
const video = {
  isConnected: true, videoWidth: 1920, videoHeight: 1080, currentTime: 12.5,
  duration: 120, paused: false, ended: false, currentSrc: 'blob:page-local',
  addEventListener(name, callback) { (listeners[name] ??= []).push(callback); },
  pause() { this.paused = true; for (const fn of listeners.pause || []) fn(); },
  play() { this.paused = false; for (const fn of listeners.play || []) fn(); }
};
const signal = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); }, emit(value) { this.listeners.forEach(fn => fn(value)); } });
const context = {
  document: { nodeType: 9, querySelectorAll(selector) { return selector === 'video' ? [video] : []; } },
  location: { href: 'https://www.youtube.com/watch?v=jNQXAC9IVRw' },
  navigator: { userAgent: 'Synthetic browser' },
  MutationObserver: class { constructor(fn) { this.callback = fn; observer = this; } observe() {} disconnect() {} },
  setTimeout(fn) { timers.push(fn); },
  addEventListener(name, fn) { (pageEvents[name] ??= []).push(fn); },
  browser: { runtime: { connect() {
    return { onMessage: { addListener() {} }, onDisconnect: { addListener() {} }, postMessage() {}, disconnect() {} };
  }, connectNative(name) {
    assert.equal(name, 'thru3d_video');
    const port = { onMessage: signal(), onDisconnect: signal(), messages: [],
      postMessage(message) { this.messages.push(JSON.parse(JSON.stringify(message))); },
      disconnect() { this.onDisconnect.emit(); }
    };
    ports.push(port); return port;
  } } }
};
const flush = () => { let n = 0; while (timers.length) { assert.ok(++n < 100); timers.shift()(); } };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../android/web-browser/src/main/assets/web-browser/media.js'), 'utf8'), context);
flush();
assert.equal(ports[0].messages.at(-1).videos[0].playing, true);
assert.equal(ports[0].messages.at(-1).videos[0].time, 12.5);
assert.equal(ports[0].messages.at(-1).videos[0].source, '', 'Blob addresses cannot be handed off');
video.currentSrc = 'https://cdn.test/video.mp4?signature=synthetic';
ports[0].onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports[0].messages.at(-1).videos[0].source, video.currentSrc);
video.mediaKeys = {};
ports[0].onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports[0].messages.at(-1).videos[0].source, '', 'EME resources never enter the handoff');
assert.equal(ports[0].messages.at(-1).videos[0].protected, true);
video.mediaKeys = null;
ports[0].onMessage.emit({ action: 'suspend' });
assert.equal(ports[0].messages.at(-1).videos[0].playing, false, 'Pause acknowledgement does not depend on background timers');
flush();
assert.equal(video.paused, true);
video.play(); flush();
assert.equal(video.paused, true, 'Hidden pages cannot restart a captured video');
ports[0].onMessage.emit({ action: 'resume' }); flush();
assert.equal(video.paused, true, 'Returning to a web page must not auto-play it');
video.play(); flush();
assert.equal(video.paused, false, 'User playback works after returning');
pageEvents.pagehide.forEach(fn => fn({ persisted: true }));
pageEvents.pageshow.forEach(fn => fn({ persisted: true }));
ports[0].onDisconnect.emit(); // A late disconnect must not poison the new document connection.
ports[1].onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports.length, 2);
assert.equal(ports[1].messages.at(-1).videos.length, 1, 'Back/forward cache restoration reconnects media detection');
video.isConnected = false;
ports[1].onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports[1].messages.at(-1).videos.length, 0, 'Removed players cannot remain as capture candidates');
context.document.querySelectorAll = () => [{ querySelector: () => ({ src: 'https://cdn.test/vr.mp4', getAttribute: () => null }), getAttribute: () => 'STEREO_180_LR' }];
ports[1].onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports[1].messages.at(-1).videos[0].layout, 'STEREO_180_LR', 'Declared player fallback preserves projection');
assert.equal(ports[1].messages.at(-1).videos[0].playing, false, 'Declared sources do not pretend to play');
video.isConnected = true; video.currentSrc = 'blob:page-local';
context.document.querySelectorAll = (selector) => selector === 'video' ? [video] : [{ querySelector: () => ({ src: 'https://cdn.test/vr.mp4', getAttribute: () => null }), getAttribute: () => 'STEREO_180_LR' }];
observer.callback([{ addedNodes: [{ nodeType: 1, querySelectorAll: () => [video] }] }]); flush();
assert.equal(ports.at(-1).messages.at(-1).videos.length, 2, 'A clear Blob player may expose its declared direct source');
video.mediaKeys = {};
ports.at(-1).onMessage.emit({ action: 'snapshot' }); flush();
assert.equal(ports.at(-1).messages.at(-1).videos.length, 1, 'An encrypted source is never replaced by a declared clear-media fallback');
assert.equal(ports.at(-1).messages.at(-1).videos[0].protected, true);
console.log('Web browser media lifecycle: passed');
