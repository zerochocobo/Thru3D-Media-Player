const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/network.js'), 'utf8');
const event = () => { const listeners = []; return { addListener(f) { listeners.push(f); }, fire(...args) { for (const f of [...listeners]) f(...args); } }; };
function fixture(cookies = []) {
  let now = 100000; const timers = new Map(); let next = 0;
  const webRequest = Object.fromEntries(['onBeforeRequest', 'onSendHeaders', 'onHeadersReceived', 'onCompleted', 'onErrorOccurred', 'onBeforeRedirect'].map(name => [name, event()]));
  const browser = { runtime: { id: 'fixture', onConnect: event() }, webRequest, cookies: { getAll: async () => cookies } };
  const context = vm.createContext({ browser, URL, Date: { now: () => now }, setTimeout(f) { timers.set(++next, f); return next; }, clearTimeout(id) { timers.delete(id); } });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/bilibili.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/douyin.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/plex.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/weibo.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/twitch.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/tiktok.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/archive.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/dailymotion.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/ted.js'), 'utf8'), context);
  vm.runInContext(source, context);
  function connect(tab = 1, frame = 0, page = 'https://page.test/watch', enabled = true, parent = page) {
    const messages = [];
    const port = { name: 'thru3d_network', sender: { id: 'fixture', tab: { id: tab, url:parent }, frameId: frame, url: page, documentId: `doc-${tab}-${frame}` },
      onMessage: event(), onDisconnect: event(), postMessage(m) { messages.push(JSON.parse(JSON.stringify(m))); }, disconnect() { this.disconnected = true; this.onDisconnect.fire(); } };
    browser.runtime.onConnect.fire(port);
    if (enabled) port.onMessage.fire({ type: 'context', page, enabled: true });
    return { port, messages, last: () => messages.at(-1)?.candidates || [] };
  }
  function request(url, options = {}) {
    const d = { tabId: 1, frameId: 0, documentId: 'doc-1-0', documentUrl: 'https://page.test/watch', method: 'GET', type: 'xmlhttprequest', requestId: String(++next),
      url, statusCode: 200, requestHeaders: [], responseHeaders: [{ name: 'Content-Type', value: 'video/mp4' }], ...options };
    if (!options.cache) webRequest.onSendHeaders.fire(d);
    webRequest.onHeadersReceived.fire(d); webRequest.onCompleted.fire(d); return d;
  }
  const flush = () => { const batch = [...timers.values()]; timers.clear(); batch.forEach(f => f()); };
  return { connect, request, flush, browser, archive: vm.runInContext('Thru3DArchive',context), advance(ms) { now += ms; } };
}

function archiveRedirect(f, page, original, target, id='archive-redirect') {
  const d={tabId:1,frameId:0,documentId:'doc-1-0',documentUrl:page,method:'GET',type:'media',requestId:id,url:original};
  f.browser.webRequest.onSendHeaders.fire({...d,requestHeaders:[{name:'Cookie',value:'only-original=1'}]});
  f.browser.webRequest.onBeforeRedirect.fire({...d,redirectUrl:target});
  f.browser.webRequest.onSendHeaders.fire({...d,url:target,requestHeaders:[{name:'Authorization',value:'redirect-own-request'}]});
  f.browser.webRequest.onHeadersReceived.fire({...d,url:target,statusCode:206,responseHeaders:[{name:'Content-Type',value:'video/mp4'}]});
  f.browser.webRequest.onCompleted.fire({...d,url:target});f.flush();
}

test('Archive keeps its observed download association when the same final file is read directly with fresh own headers',()=>{
  const f=fixture(),page='https://archive.org/details/PublicFilm',original='https://archive.org/download/PublicFilm/current.mp4',file='https://related.test:8443/current.mp4?ticket=observed';
  const p=f.connect(1,0,page,false);p.port.onMessage.fire({type:'context',page,enabled:false,archive:true});
  archiveRedirect(f,page,original,file);
  assert.equal(p.last()[0].original_url,original);assert.equal(p.last()[0].headers.authorization,'redirect-own-request');
  const video={isConnected:true,readyState:4,currentSrc:original,videoWidth:426,videoHeight:240,duration:596.416666};
  const document={location:{href:page},querySelectorAll:s=>s.startsWith('link')?[{href:page}]:[{href:original}]};
  assert.ok(f.archive.binding(video,p.last(),document,[video]));
  f.advance(20);f.request(file,{documentUrl:page,requestHeaders:[{name:'Authorization',value:'fresh-direct-request'}]});f.flush();
  const current=p.last().find(r=>r.url===file);
  assert.equal(current.original_url,original,'A native prefix/range read must not erase the already observed page download relationship');
  assert.equal(current.request_original_url,file,'Request provenance remains separate from its retained page download relationship');
  assert.equal(current.headers.authorization,'fresh-direct-request');assert.equal(current.headers.cookie,undefined);
  assert.ok(f.archive.binding(video,p.last(),document,[video]),'The actual current Archive component remains bound after the reader refresh');
});

test('Archive fresh periodic reads keep a long video associated while cache hits cannot renew stale evidence',()=>{
  const f=fixture(),page='https://archive.org/details/PublicFilm',original='https://archive.org/download/PublicFilm/current.mp4',file='https://related.test/current.mp4';
  const p=f.connect(1,0,page,false);p.port.onMessage.fire({type:'context',page,enabled:false,archive:true});
  archiveRedirect(f,page,original,file);
  f.advance(31000);f.request(file,{documentUrl:page,requestHeaders:[{name:'Authorization',value:'redirect-own-request'}]});f.flush();
  assert.equal(p.last()[0].original_url,original);
  f.advance(900000);f.request(file,{documentUrl:page});f.flush();assert.equal(p.last()[0].original_url,original);
  f.advance(900000);f.request(file,{documentUrl:page});f.flush();assert.equal(p.last()[0].original_url,original,'Fresh owned requests keep the same active resource valid beyond the initial redirect TTL');
  f.advance(1799990);f.request(file,{documentUrl:page,cache:true});f.flush();
  f.advance(20);f.request(file,{documentUrl:page});f.flush();assert.equal(p.last()[0].original_url,file,'A cache hit cannot keep stale relationship or credential evidence alive');
});

test('Archive redirect relationships do not cross items, navigation or a newer actual redirect',()=>{
  const page='https://archive.org/details/PublicFilm',original='https://archive.org/download/PublicFilm/current.mp4',file='https://related.test/current.mp4';
  for(const unrelated of ['https://archive.org/download/OtherFilm/current.mp4','https://other.test/download/PublicFilm/current.mp4']){
    const f=fixture(),p=f.connect(1,0,page,false);p.port.onMessage.fire({type:'context',page,enabled:false,archive:true});
    archiveRedirect(f,page,unrelated,file);f.advance(20);f.request(file,{documentUrl:page,requestHeaders:[{name:'Authorization',value:'new'}]});f.flush();
    assert.equal(p.last()[0].original_url,file);
  }
  const f=fixture(),p=f.connect(1,0,page,false);p.port.onMessage.fire({type:'context',page,enabled:false,archive:true});
  archiveRedirect(f,page,original,file);f.advance(20);
  const latest='https://archive.org/download/PublicFilm/selected.mp4';archiveRedirect(f,page,latest,file,'new-redirect');
  assert.equal(p.last()[0].original_url,latest,'The new actual redirect wins even with unchanged final headers');
  const next='https://archive.org/details/OtherFilm';p.port.onMessage.fire({type:'context',page:next,enabled:false,archive:true,reset:true});
  f.request(file,{documentUrl:next});f.flush();assert.equal(p.last()[0].original_url,file);
});

test('Dailymotion keeps client fragments as request evidence and sends the exact signed HTTP transport URL',()=>{
  const f=fixture(),frame='https://geo.dailymotion.com/player/official.html#settings=opaque',parent='https://www.dailymotion.com/video/x5kesuj';
  const p=f.connect(1,3,frame,false,parent);p.port.onMessage.fire({type:'context',page:frame,enabled:false,dailymotion:true});
  const wire='https://new-related.test:8443/current.m3u8?signature=a%2Fb&literal=%23value',raw=wire+'#client-marker';
  const d=f.request(raw,{frameId:3,documentId:'doc-1-3',documentUrl:frame,requestHeaders:[{name:'Authorization',value:'only-this-request'}],responseHeaders:[{name:'Content-Type',value:'application/vnd.apple.mpegurl'}]});
  f.flush();const c=p.last()[0];assert.equal(c.url,wire);assert.equal(c.request_url,raw);assert.equal(c.request_id,d.requestId);
  assert.equal(c.headers.authorization,'only-this-request');assert.equal(c.original_url,wire);
  const other=fixture(),q=other.connect();other.request(raw);other.flush();assert.equal(q.last().length,0,'Other sites keep their existing fragment rejection');
});
test('Twitch keeps a real clip document across tracking replaceState without accepting another clip or document',()=>{
  const f=fixture(),original='https://clips.twitch.tv/PublicClip?tt_medium=clips_api',current='https://clips.twitch.tv/PublicClip',p=f.connect(1,0,original,false);
  p.port.onMessage.fire({type:'context',page:current,twitch:true,enabled:false,reset:true});
  f.request('https://actual-related.example/clip.mp4?sig=exact',{documentUrl:original});f.flush();assert.equal(p.last().length,1);
  p.port.onMessage.fire({type:'context',page:current,twitch:true,enabled:false,reset:true});f.flush();assert.equal(p.last().length,1);
  for(const change of [{documentId:'another'},{documentUrl:'https://clips.twitch.tv/AnotherClip'},{frameId:1}]){
    f.request('https://actual-related.example/wrong.mp4',{documentUrl:original,...change});f.flush();assert.equal(p.last().length,1);
  }
});

test('TikTok keeps same-document observations across SPA paths while rejecting other documents, frames and tabs',()=>{
  const f=fixture(),original='https://www.tiktok.com/foryou',current='https://www.tiktok.com/@test/video/6742501081818877190',p=f.connect(1,0,original,false);
  p.port.onMessage.fire({type:'context',page:current,tiktok:true,enabled:false,reset:true});
  f.request('https://new-related.example/current',{documentUrl:original,requestHeaders:[{name:'Authorization',value:'only-this-file'}]});f.flush();
  assert.equal(p.last().length,1);assert.equal(p.last()[0].headers.authorization,'only-this-file');
  for(const change of [{documentId:'other'},{frameId:1},{tabId:2},{documentUrl:'https://different.test/foryou'}]){
    f.request('https://new-related.example/unrelated',{documentUrl:original,...change});f.flush();assert.equal(p.last().length,1);
  }
  p.port.onMessage.fire({type:'context',page:current,tiktok:false,enabled:false,reset:true});f.flush();assert.equal(p.last().length,0);
});

test('TED segment traffic stays bounded without evicting the actual current master or accepting another document',()=>{
  const f=fixture(),page='https://www.ted.com/talks/current_talk',p=f.connect(1,0,page,false),root='https://related.test/root.m3u8?exact=selector';
  p.port.onMessage.fire({type:'context',page,ted:true,enabled:false});
  f.request(root,{documentUrl:page,responseHeaders:[{name:'Content-Type',value:'application/vnd.apple.mpegurl'}]});
  for(let i=0;i<40;i++)f.request('https://related.test/segment'+i+'.ts',{documentUrl:page,responseHeaders:[{name:'Content-Type',value:'video/mp2t'}]});
  f.request('https://other.test/foreign.m3u8',{documentUrl:page,documentId:'different-document'});f.flush();
  assert.equal(p.last().length,24);assert(p.last().some(r=>r.url===root));assert.equal(p.last().filter(r=>r.kind==='segment').length,23);
});

test('Weibo Beta observes only its document requests independently of generic sniffing and never invents cached credentials',()=>{
  const f=fixture(),page='https://weibo.com/newlogin',p=f.connect(1,0,page,false);
  const source='https://new-trusted-cdn.test/whole.mp4?signature=synthetic';
  f.request(source,{documentUrl:page,requestHeaders:[{name:'Authorization',value:'only-this-file'}]});
  f.request(source,{documentUrl:page,cache:true});
  f.request('https://new-trusted-cdn.test/foreign.mp4',{documentUrl:page,documentId:'different-document'});
  f.request('https://new-trusted-cdn.test/tab.mp4',{documentUrl:page,tabId:2});
  f.flush();assert.equal(p.last().length,1);assert.equal(p.last()[0].headers.authorization,'only-this-file');
  p.port.onMessage.fire({type:'context',page,enabled:false,weibo:false});f.flush();
  assert.equal(p.last().length,0);
  f.request(source,{documentUrl:page});f.flush();assert.equal(p.last().length,0);
});
test('Plex exact-frame authenticated media is observed with generic network capture disabled',()=>{
  const f=fixture(),page='http://127.0.0.1:32400/web/index.html#!/server/local/details';const p=f.connect(1,0,page,false);
  const url='http://127.0.0.1:32400/video/:/transcode/universal/start.mpd?path=%2Flibrary%2Fmetadata%2F4&mediaIndex=0&partIndex=0';
  const options={documentUrl:page,requestHeaders:[{name:'X-Plex-Token',value:'synthetic'}],responseHeaders:[{name:'Content-Type',value:'application/dash+xml'}]};
  f.request(url,options);f.flush();assert.equal(p.last().length,1);assert.equal(p.last()[0].headers['x-plex-token'],'synthetic');
  for(const address of ['http://other.test'+new URL(url).pathname+new URL(url).search,'http://127.0.0.1:32400/movie.mp4',url.replace('metadata%2F4','metadata%2F5')])
    f.request(address,{...options,requestHeaders:[]});
  f.request(url.replace('metadata%2F4','metadata%2F6'),{...options,documentId:'old-document'});
  f.request(url.replace('metadata%2F4','metadata%2F7'),{...options,frameId:3});
  f.flush();assert.equal(p.last().length,1);
  p.port.onMessage.fire({type:'context',page:page+'-next',reset:true});f.flush();assert.equal(p.last().length,0);
});
test('extensionless HLS, DASH, progressive MIME and file suffixes are observed without changing requests', () => {
  const f = fixture(), p = f.connect();
  for (const [url, mime] of [['hls?signature=private', 'application/vnd.apple.mpegurl'], ['dash', 'application/dash+xml'], ['movie', 'video/mp4'], ['movie.webm', 'application/octet-stream']])
    f.request(`https://cdn.test/${url}`, { responseHeaders: [{ name: 'Content-Type', value: mime }] });
  f.flush(); assert.deepEqual(p.last().map(c => c.kind), ['hls', 'dash', 'file', 'file']);
});
test('POST, failed responses, HTML masquerading as media, and loose segments are not playable candidates', () => {
  const f = fixture(), p = f.connect();
  f.request('https://cdn.test/post.mp4', { method: 'POST' });
  f.request('https://cdn.test/error.mp4', { statusCode: 403 });
  f.request('https://cdn.test/login.m3u8', { responseHeaders: [{ name: 'Content-Type', value: 'text/html' }] });
  for (const file of ['segment.m4s', 'init.mp4', 'chunk-1.mp4', 'stream.ts', 'key.key']) f.request(`https://cdn.test/${file}`);
  f.flush(); assert.equal(p.last().length, 0);
});
test('canonical Bilibili CID directories identify decorated full-file DASH audio', () => {
  const f = fixture(), p = f.connect();
  const url = 'https://upos-test.bilivideo.com/upgcxcode/45/23/12345/12345_nb3-1-30280.m4s';
  f.request(url); f.request(url.replace('upgcxcode', 'unknown'));
  f.request(url.replace('/12345/', '/999/').replace('12345_nb3', '12345'));
  f.flush(); assert.equal(p.last().length, 1); assert.equal(p.last()[0].url, url);
});

test('actual credentials are exact-request-only, and protocol/range headers are discarded', () => {
  const f = fixture(), p = f.connect();
  f.request('https://cdn.test/movie.mp4', { requestHeaders: [
    { name: 'Cookie', value: 'session=synthetic' }, { name: 'Authorization', value: 'Bearer fixture' },
    { name: 'Range', value: 'bytes=500-999' }, { name: 'Host', value: 'elsewhere' }, { name: 'Sec-Fetch-Site', value: 'same-site' },
    { name: 'X-Media-Token', value: 'fixture' }, { name: 'Referer', value: 'https://page.test/watch' }, { name: 'X-Bad', value: 'bad\r\nheader' }] });
  f.flush(); assert.deepEqual(Object.keys(p.last()[0].headers).sort(), ['authorization', 'cookie', 'referer', 'x-media-token']);
});
test('redirects and cached responses cannot inherit another request origin credentials', () => {
  const f = fixture(), p = f.connect();
  const d = { tabId: 1, frameId: 0, documentUrl: 'https://page.test/watch', method: 'GET', type: 'media', requestId: 'redirect', url: 'https://first.test/movie.mp4', requestHeaders: [{ name: 'Cookie', value: 'first=private' }] };
  f.browser.webRequest.onSendHeaders.fire(d); f.browser.webRequest.onBeforeRedirect.fire(d);
  f.browser.webRequest.onHeadersReceived.fire({ ...d, url: 'https://second.test/movie.mp4', statusCode: 200, responseHeaders: [] });
  f.request('https://cache.test/movie.mp4', { cache: true });
  f.flush(); assert.equal(p.last().length, 2); p.last().forEach(c => assert.deepEqual(c.headers, {}));
});
test('tab, iframe, document and SPA navigation boundaries discard stale requests', () => {
  const f = fixture(), top = f.connect(), iframe = f.connect(1, 3, 'https://embed.test/player'), other = f.connect(2);
  f.request('https://cdn.test/frame.mp4', { frameId: 3, documentId: 'doc-1-3', documentUrl: 'https://embed.test/player' });
  f.request('https://cdn.test/other.mp4', { tabId: 2, documentId: 'doc-2-0' });
  f.request('https://cdn.test/stale.mp4', { documentId: 'old-document' });
  f.flush(); assert.equal(top.last().length, 0); assert.equal(iframe.last().length, 1); assert.equal(other.last().length, 1);
  top.port.onMessage.fire({ type: 'context', page: 'https://page.test/next', enabled: true, reset: true });
  f.request('https://cdn.test/late.mp4'); f.flush(); assert.equal(top.last().length, 0);
  f.request('https://cdn.test/new.mp4', { documentUrl: 'https://page.test/next' }); f.flush(); assert.equal(top.last().length, 1);
  f.browser.webRequest.onBeforeRequest.fire({ tabId: 1, frameId: 0, type: 'main_frame' });
  assert.equal(top.port.disconnected, true); assert.equal(iframe.port.disconnected, true); assert.equal(other.port.disconnected, undefined);
});
test('bounded deduplication retains only recent candidates and does not flood on range requests', () => {
  const f = fixture(), p = f.connect();
  for (let i = 0; i < 80; i++) f.request(`https://cdn.test/${i}.mp4`);
  f.flush(); assert.equal(p.last().length, 24);
  const messages = p.messages.length;
  for (let i = 0; i < 100; i++) f.request('https://cdn.test/79.mp4');
  f.flush(); assert.equal(p.messages.length, messages);
  f.advance(1800001); f.request('https://cdn.test/fresh.mp4'); f.flush(); assert.equal(p.last().length, 1);
});
test('unverified origins start disabled, and switching off immediately clears observations', () => {
  const f = fixture(), p = f.connect(1, 0, 'https://page.test/watch', false);
  f.request('https://cdn.test/movie.mp4'); f.flush(); assert.equal(p.last().length, 0);
  p.port.onMessage.fire({ type: 'context', page: 'https://page.test/watch', enabled: true });
  f.request('https://cdn.test/movie.mp4'); f.flush(); assert.equal(p.last().length, 1);
  p.port.onMessage.fire({ type: 'context', page: 'https://page.test/watch', enabled: false });
  f.request('https://cdn.test/next.mp4'); f.flush(); assert.equal(p.last().length, 0);
});

test('Bilibili sidebar pushState preserves in-flight exact-request headers in the same document', () => {
  const f=fixture(), first='https://www.bilibili.com/video/BV1234567890/', second='https://www.bilibili.com/video/BV0987654321/';
  const p=f.connect(1,0,first,false); p.port.onMessage.fire({type:'context',page:first,bilibili:true});
  const request={tabId:1,frameId:0,documentId:'doc-1-0',documentUrl:first,method:'GET',type:'xmlhttprequest',requestId:'switch',url:'https://cdn.test/new.m4s',requestHeaders:[{name:'Referer',value:first}]};
  f.browser.webRequest.onSendHeaders.fire(request);
  p.port.onMessage.fire({type:'context',page:second,bilibili:true,reset:true});
  f.browser.webRequest.onHeadersReceived.fire({...request,statusCode:206,responseHeaders:[{name:'Content-Type',value:'video/mp4'}]});f.flush();
  assert.equal(p.last()[0].headers.referer,first);
  f.request('https://cdn.test/stale.m4s',{documentUrl:first,documentId:'old'});f.flush();assert.equal(p.last().length,1);
});
test('hash-routed pages can opt in while media addresses with fragments are rejected', () => {
  const f = fixture(), p = f.connect(1, 0, 'https://page.test/watch#/movie/1');
  f.request('https://cdn.test/movie.mp4'); f.flush(); assert.equal(p.last().length, 1);
  p.port.onMessage.fire({ type: 'context', page: 'https://page.test/watch#/movie/2', enabled: true, reset: true });
  f.request('https://cdn.test/movie.mp4#not-a-network-url'); f.flush(); assert.equal(p.last().length, 0);
});
test('cookie scope is exported only for cookies actually sent, never unrelated/partitioned account cookies', async () => {
  const f = fixture([
    { name: 'session', value: 'synthetic', domain: 'cdn.test', path: '/media', secure: true, hostOnly: true },
    { name: 'unrelated', value: 'private', domain: 'cdn.test', path: '/' },
    { name: 'partitioned', value: 'private', domain: 'cdn.test', path: '/', partitionKey: {} }
  ]), p = f.connect();
  f.request('https://cdn.test/media/movie.mp4', { requestHeaders: [{ name: 'Cookie', value: 'session=synthetic; partitioned=private' }] });
  await Promise.resolve(); f.flush(); assert.equal(p.last()[0].cookies.length, 1); assert.equal(p.last()[0].cookies[0].path, '/media');
});

test('Douyin response diagnostics retain only bounded structural paths in the owning frame', () => {
  const f=fixture(), page='https://www.douyin.com/video/6961737553342991651', p=f.connect(1,0,page,false);
  p.port.onMessage.fire({type:'context',page,douyin:true});
  const opts={documentUrl:page,responseHeaders:[{name:'Content-Type',value:'application/json'}]};
  f.request('https://www.douyin.com/aweme/v1/web/mix/aweme/?token=private-fixture',opts);
  f.request('https://www.douyin.com/aweme/v1/web/user/123456/info/?secret=private-fixture',opts);
  f.request('https://www.douyin.com/aweme/v1/web/other/',{...opts,tabId:2});
  f.flush();
  assert.deepEqual(p.messages.at(-1).douyin_api_paths,['/aweme/v1/web/mix/aweme/','/aweme/v1/web/user/{id}/info/']);
  assert.equal(p.last().length,0,'JSON diagnostics cannot become media candidates');
  assert.ok(!JSON.stringify(p.messages).includes('private-fixture'));
  for(let i=0;i<40;i++)f.request('https://www.douyin.com/aweme/v1/web/route_'+String.fromCharCode(97+Math.floor(i/26))+String.fromCharCode(97+i%26)+'/',opts);
  f.flush();assert.equal(p.messages.at(-1).douyin_api_paths.length,32);
  p.port.onMessage.fire({type:'context',page,douyin:false});f.flush();
  assert.deepEqual(p.messages.at(-1).douyin_api_paths,[]);
});
