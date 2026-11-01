const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const source = path.join(__dirname, '../android/web-browser/src/main/assets/web-browser');
const page = 'https://www.douyin.com/video/6961737553342991651';
const file = 'https://cdn.test/current.mp4?signature=synthetic';
const signal = () => ({listeners: [], addListener(fn) { this.listeners.push(fn); }, emit(value) { for (const fn of this.listeners) fn(value); }});
const timers = [], ports = [], networkPorts = [];
let observer;
function video(width, height, duration) {
  const events = {};
  return {isConnected: true, currentSrc: 'blob:local-' + width, readyState: 4, videoWidth: width, videoHeight: height,
    duration, currentTime: 1, paused: false, ended: false, events,
    addEventListener(name, fn) { (events[name] ??= []).push(fn); },
    pause() { this.paused = true; for (const fn of events.pause || []) fn(); },
    play() { this.paused = false; for (const fn of events.play || []) fn(); }};
}
const main = video(576, 1024, 19.735), auxiliary = video(0, 0, NaN);
const players = [auxiliary, main];
const context = vm.createContext({URL, Date: {now: () => 10000}, performance: {now: () => 10000}, location: {href: page}, navigator: {userAgent: 'fixture'},
  document: {nodeType: 9, querySelectorAll: selector => selector === 'video' ? players : []},
  MutationObserver: class {constructor(fn) { observer = fn; } observe() {} disconnect() {}},
  setTimeout(fn) { timers.push(fn); }, addEventListener() {},
  browser: {runtime: {
    connect() { const port = {postMessage() {}, onMessage: signal(), onDisconnect: signal(), disconnect() {}}; networkPorts.push(port); return port; },
    connectNative() { const port = {messages: [], onMessage: signal(), onDisconnect: signal(),
      postMessage(value) { this.messages.push(JSON.parse(JSON.stringify(value))); }, disconnect() {}}; ports.push(port); return port; }
  }}
});
for (const name of ['douyin.js', 'media.js']) vm.runInContext(fs.readFileSync(path.join(source, name), 'utf8'), context);
function flush() { let count = 0; while (timers.length) { assert.ok(++count < 100); timers.shift()(); } }
flush();
for (const fn of main.events.loadstart) fn(); // The site's MSE source is assigned after its file fetch.
flush();
const data = {id: page.split('/').at(-1), duration: 19.782, video: [{width: 576, height: 1024, urls: [file]}]};
networkPorts[0].onMessage.emit({type: 'network', page, douyin: [data], candidates: [
  {kind: 'file', url: file, at: 9970, headers: {referer: page}}
]});
flush();
let snapshot = ports[0].messages.at(-1).videos.find(v => v.width === 576);
assert.equal(snapshot.douyin_ready, true, 'A bound MSE file fetched 30 ms before loadstart remains eligible');
assert.equal(snapshot.source, '', 'The HTML blob is never rewritten into a fabricated currentSrc');
assert.equal(snapshot.blob, true);
assert.equal(snapshot.douyin.observed_file, file);
assert.equal(snapshot.network[0].headers.referer, page);
const audio='https://cdn.test/current.m4a?signature=synthetic';
const pairData={...data,audio:[{id:'current-audio',urls:[audio]}]};
const request={kind:'file',url:file,at:9970,headers:{referer:page}};
networkPorts[0].onMessage.emit({type:'network',page,douyin:[pairData],candidates:[request]});flush();
assert.equal(ports[0].messages.at(-1).videos.find(v=>v.width===576).douyin_ready,false,'MSE cannot announce readiness while its declared audio is still missing');
networkPorts[0].onMessage.emit({type:'network',page,douyin:[pairData],candidates:[request,{kind:'file',url:audio,at:9970,headers:{referer:page}}]});flush();
snapshot=ports[0].messages.at(-1).videos.find(v=>v.width===576);
assert.equal(snapshot.douyin_ready,true);assert.equal(snapshot.douyin.observed_audio,audio);
const duplicate = video(576, 1024, 19.735); players.push(duplicate);
observer([{addedNodes: [{nodeType: 1, querySelectorAll: () => [duplicate]}]}]); flush();
assert.ok(ports[0].messages.at(-1).videos.every(v => !v.douyin_ready), 'Ambiguous decoded owners cannot adopt a request');
duplicate.isConnected = false; main.mediaKeys = {};
ports[0].onMessage.emit({action: 'snapshot'}); flush();
assert.ok(ports[0].messages.at(-1).videos.every(v => !v.douyin_ready), 'Protected media cannot adopt the observed whole file');
console.log('Douyin MSE media ownership: passed');
