const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/media.js'), 'utf8');
function fixture(count = 1, blob = true, options = {}) {
  const event = () => { const listeners = []; return { addListener(f) { listeners.push(f); }, fire(value) { listeners.forEach(f => f(value)); } }; };
  const port = () => ({ messages: [], onMessage: event(), onDisconnect: event(), postMessage(m) { this.messages.push(JSON.parse(JSON.stringify(m))); }, disconnect() { this.onDisconnect.fire(); } });
  const native = port(), network = port(); const timers = []; const events = {}, observers = [];
  const videos = Array.from({ length: count }, (_, i) => ({ currentSrc: blob ? `blob:video-${i}` : 'https://cdn.test/movie.mp4', isConnected: true,
    videoWidth: 3840, videoHeight: 2160, paused: false, ended: false, readyState: 4, currentTime: 3, duration: 100,
    events: {}, closest() { return null; }, addEventListener(name, f) { (this.events[name] ||= []).push(f); },
    emit(name) { (this.events[name] || []).forEach(f => f()); }, pause() { this.paused = true; },
    play() { this.playCalls = (this.playCalls || 0) + 1; if (!options.deferPlay) { this.paused = false; this.emit('play'); } return Promise.resolve(); } }));
  const document = { nodeType: 9, querySelector: () => options.canonical ? {href: options.canonical} : null, querySelectorAll(s) { return s === 'video' ? videos : s === 'script:not([src])' ? options.scripts || [] : []; }, fullscreenElement: videos[0] };
  const location = { href: options.page || 'https://page.test/watch' }, clock = {now:Date.now()};
  const context = vm.createContext({ document, location, navigator: { userAgent: 'Fixture' }, URL, Date:class extends Date {static now(){return clock.now;}},
    browser: { runtime: { connectNative: () => native, connect: () => network } }, MutationObserver: class { constructor(callback) { observers.push(callback); } observe() {} disconnect() {} },
    performance: { now: () => 100 }, setTimeout(f) { timers.push(f); }, addEventListener(name, f) { (events[name] ||= []).push(f); } });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/bilibili.js'), 'utf8'), context);
  vm.runInContext(script, context);
  const flush = () => { for (let n = 0; timers.length && n < 10; n++) timers.splice(0).forEach(f => f()); };
  const report = () => native.messages.filter(m => m.type === 'media').at(-1)?.videos;
  const capture = (url = 'https://cdn.test/movie.mp4', original_url) => network.onMessage.fire({ type: 'network', page: 'https://page.test/watch',
    candidates: [{ url, original_url, kind: 'file', at: Date.now(), headers: { authorization: 'Bearer synthetic' } }] });
  const addVideo = (values = {}) => {
    const v = {...videos[0], events:{}, nodeType:1, matches:s=>s==='video', querySelectorAll:()=>[], ...values};
    videos.push(v); observers.forEach(f=>f([{addedNodes:[v],removedNodes:[]}])); flush(); return v;
  };
  flush(); return { videos, native, network, capture, flush, report, location, addVideo, clock,
    emit(name,value={}) { (events[name] || []).forEach(f=>f(value)); } };
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

test('handoff holds only its document until matching release, then permits user playback', () => {
  const source = fixture(), peer = fixture();
  source.native.onMessage.fire({ action: 'pause_media', token: 1 });
  assert.equal(source.videos[0].paused, true);
  assert.equal(source.report()[0].playing, false);
  assert.equal(peer.videos[0].paused, false);
  source.videos[0].paused = false; source.videos[0].emit('play');
  assert.equal(source.videos[0].paused, true);
  source.native.onMessage.fire({action:'release_pause_media',token:1,play:false});
  source.videos[0].paused = false; source.videos[0].emit('play');
  assert.equal(source.videos[0].paused, false);
});

test('late cancelled resume cannot defeat the next pause; stale releases cannot unlock it', async () => {
  const f=fixture(1,true,{deferPlay:true}), v=f.videos[0];
  f.native.onMessage.fire({action:'pause_media',token:10});
  f.native.onMessage.fire({action:'release_pause_media',token:10,play:true});
  assert.equal(v.playCalls,1);
  f.native.onMessage.fire({action:'pause_media',token:11});
  v.paused=false;v.emit('play'); // completion of the first, asynchronous resume
  assert.equal(v.paused,true);
  f.native.onMessage.fire({action:'release_pause_media',token:10,play:true});
  v.paused=false;v.emit('play');assert.equal(v.paused,true);
  f.flush();const ack=f.native.messages.filter(m=>m.type==='media').at(-1);
  assert.equal(ack.pause_token,11);assert.equal(ack.pause_held,true);
  f.native.onMessage.fire({action:'release_pause_media',token:11,play:true});
  assert.equal(v.playCalls,2); // the interrupted resume intent was retained
  await Promise.resolve();v.paused=false;v.emit('play');assert.equal(v.paused,false);
  f.native.onMessage.fire({action:'pause_media',token:10});assert.equal(v.paused,false);
});

test('delayed MediaSession play after a second pause cannot restart the video', () => {
  const f=fixture(), v=f.videos[0];
  f.native.onMessage.fire({action:'pause_media',token:1});
  f.native.onMessage.fire({action:'pause_media',token:2});
  v.paused=false;v.emit('play'); // a queued native play from cancellation of attempt 1
  assert.equal(v.paused,true);
});

test('cancel remembers playback even when native MediaSession paused before script delivery', () => {
  const f=fixture(2), [a,b]=f.videos;
  a.paused=true;b.paused=true; // native pause completed; only the first video was playing
  f.native.onMessage.fire({action:'pause_media',token:1,playing_ids:['1']});
  f.native.onMessage.fire({action:'release_pause_media',token:1,play:true});
  assert.equal(a.paused,false);assert.equal(b.paused,true);
  f.native.onMessage.fire({action:'pause_media',token:2,playing_ids:['1']});
  a.currentSrc='blob:new';a.emit('loadstart');
  f.native.onMessage.fire({action:'release_pause_media',token:2,play:true});
  assert.equal(a.paused,true); // a saved ID grants no authority to restart a replacement
});

test('a pause addressed to the new SPA page survives its first network-context update', () => {
  const f=fixture();f.location.href+='?next=1';
  f.native.onMessage.fire({action:'pause_media',token:1});
  const ack=f.native.messages.filter(m=>m.type==='media').at(-1);
  assert.equal(ack.pause_token,1);assert.equal(ack.pause_held,true);
});

test('cancel restores only the original playing source; navigation and disconnect release holds', () => {
  const f=fixture(2), [a,b]=f.videos;b.paused=true;
  f.native.onMessage.fire({action:'pause_media',token:1});
  f.native.onMessage.fire({action:'release_pause_media',token:1,play:true});
  assert.equal(a.paused,false);assert.equal(b.paused,true);
  f.native.onMessage.fire({action:'pause_media',token:2});
  a.currentSrc='blob:replacement';a.emit('loadstart');
  f.native.onMessage.fire({action:'release_pause_media',token:2,play:true});assert.equal(a.paused,true);
  f.native.onMessage.fire({action:'pause_media',token:3});
  f.location.href+='?next=1';a.paused=false;a.emit('play');assert.equal(a.paused,false);
  f.native.onMessage.fire({action:'pause_media',token:4});
  f.native.onDisconnect.fire();a.paused=false;a.emit('play');assert.equal(a.paused,false);
});

test('Bilibili SPA responses bind to the current part map, full duration and a single unencrypted player', () => {
  const page = 'https://www.bilibili.com/video/BV1234567890/';
  const state = { cid: 123, videoData: { bvid: 'BV1234567890', pages: [
    { page: 1, cid: 123, duration: 100 }, { page: 2, cid: 456, duration: 200 }] } };
  const options = { page, scripts: [{ textContent: 'window.__INITIAL_STATE__=' + JSON.stringify(state) + ';' }] };
  const f = fixture(1, true, options);
  f.native.onMessage.fire({ action: 'network_policy', bilibili: true, enabled: false }); f.flush();
  const response = { id: 'BV1234567890', page, part: 1, cid: '123', duration: 100, video: [], audio: [] };
  function capture(data, target = f) {
    target.network.onMessage.fire({ type: 'network', page: target.location.href, bilibili_requested: [data.cid], bilibili: [data], candidates: [] }); target.flush();
  }
  capture(response); assert.equal(f.report()[0].bilibili.cid, '123');
  f.location.href = page + '?p=2'; f.videos[0].duration = 200; f.videos[0].emit('loadstart'); f.flush();
  capture(response); assert.equal(f.report()[0].bilibili, null);
  // API request started before pushState; only the independently mapped current CID may rebind.
  capture({ ...response, cid: '456', duration: 200 });
  assert.equal(f.report()[0].bilibili.part, 2); assert.equal(f.report()[0].bilibili.page, page + '?p=2');
  f.videos[0].duration = 20; f.videos[0].emit('durationchange'); f.flush(); assert.equal(f.report()[0].bilibili, null);
  f.videos[0].duration = 200; f.videos[0].emit('encrypted'); f.flush(); assert.equal(f.report()[0].bilibili, null);
  const multiple = fixture(2, true, options); multiple.native.onMessage.fire({ action: 'network_policy', bilibili: true }); capture(response, multiple);
  assert.ok(multiple.report().every(v => v.bilibili === null));
});

test('paused video readiness updates on track arrival and resize without a playback timeupdate', () => {
  const page = 'https://www.bilibili.com/video/BV1234567890/';
  const state = {cid:123,videoData:{bvid:'BV1234567890',aid:1,pages:[{page:1,cid:123,duration:100}]}};
  const f = fixture(1, true, {page,scripts:[{textContent:'window.__INITIAL_STATE__='+JSON.stringify(state)+';'}]});
  const v = f.videos[0]; v.paused = true; v.videoWidth = 0; v.videoHeight = 0;
  f.native.onMessage.fire({action:'network_policy',bilibili:true}); f.flush();
  const video = 'https://cdn.test/video.m4s', audio = 'https://cdn.test/audio.m4s';
  const data = {id:'BV1234567890',page,part:1,cid:'123',duration:100,
    video:[{width:3840,height:2160,urls:[video]}],audio:[{urls:[audio]}]};
  const send = urls => {
    f.network.onMessage.fire({type:'network',page,bilibili_requested:['123'],bilibili:[data],
      candidates:urls.map(url=>({url,kind:'file'}))}); f.flush();
  };
  send([video]); assert.equal(f.report()[0].bilibili_ready, false);
  v.videoWidth = 3840; v.videoHeight = 2160; v.emit('resize'); f.flush();
  assert.equal(f.report()[0].bilibili_ready, false);
  send([video,audio]); assert.equal(f.report()[0].bilibili_ready, true);
  v.videoWidth = 1920; v.videoHeight = 1080; v.emit('resize'); f.flush();
  assert.equal(f.report()[0].bilibili_ready, false);
  v.videoWidth = 3840; v.videoHeight = 2160; v.emit('resize'); f.flush();
  assert.equal(f.report()[0].bilibili_ready, true);
  assert.equal(v.playCalls || 0, 0);
});

test('Bilibili verified tracks survive rolling capture eviction but not a new source or protection', () => {
  const page='https://www.bilibili.com/video/BV1234567890/';
  const state={cid:123,videoData:{bvid:'BV1234567890',aid:1,pages:[{page:1,cid:123,duration:100}]}};
  const f=fixture(1,true,{page,scripts:[{textContent:'window.__INITIAL_STATE__='+JSON.stringify(state)+';'}]});
  f.native.onMessage.fire({action:'network_policy',bilibili:true});f.flush();
  const data={id:'BV1234567890',page,part:1,cid:'123',duration:100,
    video:[{width:3840,height:2160,urls:['https://cdn.test/video.m4s']}],audio:[{urls:['https://cdn.test/audio.m4s']}]};
  const pair=[...data.video[0].urls,...data.audio[0].urls].map(url=>({url,kind:'file',at:Date.now()}));
  const send=candidates=>{f.network.onMessage.fire({type:'network',page,bilibili_requested:['123'],bilibili:[data],candidates});f.flush();};
  send(pair);assert.equal(f.report()[0].bilibili_ready,true);
  send([]);assert.equal(f.report()[0].bilibili_ready,true);
  assert.equal(f.report()[0].network.length,2);
  f.network.onMessage.fire({type:'network',page,bilibili_requested:['999'],bilibili:[],candidates:[]});f.flush();
  assert.equal(f.report()[0].bilibili_ready,true); // unrelated preview displaced the response too
  f.clock.now = Math.max(...pair.map(r=>r.at)) + 1800001;f.videos[0].emit('timeupdate');f.flush();assert.equal(f.report()[0].bilibili_ready,false);
  f.clock.now=Date.now();send(pair);
  const v=f.videos[0];v.videoWidth=0;v.emit('resize');f.flush();assert.equal(f.report()[0].bilibili_ready,false);
  v.videoWidth=3840;v.emit('resize');f.flush();assert.equal(f.report()[0].bilibili_ready,true);
  send([]);v.currentSrc='blob:replacement';v.emit('loadstart');f.flush();assert.equal(f.report()[0].bilibili_ready,false);
  send(pair);assert.equal(f.report()[0].bilibili_ready,true);
  v.emit('encrypted');f.flush();assert.equal(f.report()[0].bilibili_ready,false);assert.deepEqual(f.report()[0].network,[]);
});

test('late inline playinfo is rescanned and unrelated preview requests cannot suppress it', () => {
  const page='https://www.bilibili.com/video/BV1234567890/';
  const state={cid:123,videoData:{bvid:'BV1234567890',aid:1,pages:[{page:1,cid:123,duration:100}]}};
  const scripts=[{textContent:'window.__INITIAL_STATE__='+JSON.stringify(state)+';'}];
  const f=fixture(1,true,{page,scripts});f.native.onMessage.fire({action:'network_policy',bilibili:true});f.flush();
  const video='https://cdn.test/upgcxcode/123-120.m4s',audio='https://cdn.test/upgcxcode/123-30280.m4s';
  const raw={code:0,data:{quality:120,timelength:100000,dash:{
    video:[{id:120,baseUrl:video,codecs:'avc1.640033',width:3840,height:2160,frameRate:'30'}],
    audio:[{id:30280,baseUrl:audio,codecs:'mp4a.40.2'}]}}};
  scripts.push({textContent:'window.__playinfo__='+JSON.stringify(raw)+';'});
  f.network.onMessage.fire({type:'network',page,bilibili_requested:['999'],bilibili:[],
    candidates:[video,audio].map(url=>({url,kind:'file',at:f.clock.now}))});
  f.emit('DOMContentLoaded');f.flush();
  assert.equal(f.report()[0].bilibili_ready,true);
  f.location.href=page+'?p=2';f.videos[0].emit('loadstart');f.flush();
  assert.equal(f.report()[0].bilibili_ready,false);
});

test('Bilibili main video survives a retained scroll/hover preview and never lends it the captured pair', () => {
  const page = 'https://www.bilibili.com/video/BV1234567890/';
  const state = {cid:123,videoData:{bvid:'BV1234567890',aid:1,pages:[{page:1,cid:123,duration:100}]}};
  const f = fixture(1,true,{page,scripts:[{textContent:'window.__INITIAL_STATE__='+JSON.stringify(state)+';'}]});
  f.native.onMessage.fire({action:'network_policy',bilibili:true}); f.flush();
  const video = 'https://cdn.test/video.m4s', audio = 'https://cdn.test/audio.m4s';
  const data = {id:'BV1234567890',page,part:1,cid:'123',duration:100,
    video:[{width:3840,height:2160,urls:[video]}],audio:[{urls:[audio]}]};
  const send = () => {f.network.onMessage.fire({type:'network',page:f.location.href,bilibili_requested:['123'],bilibili:[data],
    candidates:[video,audio].map(url=>({url,kind:'file'}))});f.flush();};
  // Preview may already exist when the primary's first API response arrives.
  const preview = f.addVideo({currentSrc:'blob:preview',duration:8,videoWidth:852,videoHeight:480,paused:true});
  send(); assert.equal(f.report()[0].bilibili_ready,true); assert.equal(f.report()[1].bilibili_ready,false);
  assert.deepEqual(f.report()[1].network,[]);
  f.videos[0].paused=true; f.videos[0].emit('pause'); preview.paused=false; preview.emit('play'); f.flush();
  assert.equal(f.report()[0].bilibili_ready,true); assert.equal(f.report()[1].bilibili,null);
  // A second same-duration element cannot displace an already verified unchanged owner.
  preview.duration=100;preview.videoWidth=3840;preview.videoHeight=2160;preview.emit('durationchange');f.flush();
  assert.equal(f.report()[0].bilibili_ready,true);assert.equal(f.report()[1].bilibili_ready,false);
  // A replaced MSE source/epoch must not reuse that owner's privileged identity.
  f.videos[0].currentSrc='blob:new-source';f.videos[0].emit('loadstart');f.flush();
  assert.ok(f.report().every(v=>!v.bilibili_ready));
  assert.equal(f.report()[0].bilibili_binding,'multiple_players');
  preview.duration=8;preview.emit('durationchange');f.flush();assert.equal(f.report()[0].bilibili_ready,true);
  f.location.href='https://www.bilibili.com/video/BV0987654321/';f.videos[0].emit('timeupdate');send();
  assert.ok(f.report().every(v=>!v.bilibili_ready));
});

test('PGC season and SPA episode responses require current episode, whole status and player duration', () => {
  const page = 'https://www.bilibili.com/bangumi/play/ss456';
  const f = fixture(1, true, {page, canonical: 'https://www.bilibili.com/bangumi/play/ep123'});
  f.native.onMessage.fire({action: 'network_policy', bilibili: true}); f.flush();
  const response = {page: 'https://www.bilibili.com/bangumi/play/ep123', id: 'ep123', part: 1, pgc: true,
    whole: true, ep: '123', season: '456', cid: '1001', aid: '1', duration: 100, video: [], audio: []};
  function capture(data) {
    f.network.onMessage.fire({type: 'network', page: f.location.href, bilibili_requested: [data.ep], bilibili: [data], candidates: []}); f.flush();
  }
  capture(response); assert.equal(f.report()[0].bilibili.id, 'ss456');
  assert.equal(f.report()[0].bilibili.page, page);
  capture({...response, season: '999'}); assert.equal(f.report()[0].bilibili, null);
  capture({...response, whole: false}); assert.equal(f.report()[0].bilibili, null);
  capture({...response, ep: '124'}); assert.equal(f.report()[0].bilibili, null);
  f.location.href = 'https://www.bilibili.com/bangumi/play/ep124'; f.videos[0].emit('loadstart'); f.flush();
  capture(response); assert.equal(f.report()[0].bilibili, null);
  capture({...response, ep: '124', id: 'ep124', cid: '1002'}); assert.equal(f.report()[0].bilibili.ep, '124');
  f.videos[0].duration = 20; f.videos[0].emit('durationchange'); f.flush(); assert.equal(f.report()[0].bilibili, null);
});

test('sidebar replacement uses observed detail identity instead of stale inline initial state', () => {
  const page='https://www.bilibili.com/video/BV1234567890/';
  const state={cid:123,videoData:{bvid:'BV1234567890',aid:1,pages:[{page:1,cid:123,duration:100}]}};
  const f=fixture(1,true,{page,scripts:[{textContent:'window.__INITIAL_STATE__='+JSON.stringify(state)+';'}]});
  f.native.onMessage.fire({action:'network_policy',bilibili:true}); f.flush();
  f.location.href='https://www.bilibili.com/video/BV0987654321/'; f.videos[0].duration=200; f.videos[0].emit('loadstart'); f.flush();
  const response={id:'BV0987654321',page,part:1,cid:'456',avid:'2',duration:200,video:[],audio:[]};
  const view={bvid:'BV0987654321',aid:'2',pages:[{page:1,cid:'456',duration:200}]};
  const send=(r=response,v=view)=>{f.network.onMessage.fire({type:'network',page:f.location.href,bilibili_requested:['456'],bilibili:[r],bilibili_views:[v],candidates:[]});f.flush();};
  send(); assert.equal(f.report()[0].bilibili.cid,'456'); assert.equal(f.report()[0].bilibili.page,f.location.href);
  send({...response,id:'BV1234567890'}); assert.equal(f.report()[0].bilibili,null);
  send(response,{...view,bvid:'BV1234567890'}); assert.equal(f.report()[0].bilibili,null);
  send({...response,avid:'1'}); assert.equal(f.report()[0].bilibili,null);
  send({...response,id:'av2'}); assert.equal(f.report()[0].bilibili.cid,'456');
});
