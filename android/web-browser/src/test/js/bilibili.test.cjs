const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../../main/assets/web-browser');
const page = 'https://www.bilibili.com/video/BV1234567890/';
const identity = { page, id: 'BV1234567890', part: 1, cid: '12345', expected_duration: 120 };
const mediaUrl = (id, cid = '12345') => `https://upos-test.bilivideo.com/upgcxcode/${cid}-${id}.m4s?token=synthetic`;
const raw = (cid = '12345') => ({ code: 0, data: { quality: 80, timelength: 120000, dash: {
  video: [{ id: 80, baseUrl: mediaUrl(80, cid), codecs: 'avc1.640028', width: 1920, height: 1080, frameRate: '30000/1001' },
    { id: 120, baseUrl: mediaUrl(120, cid), codecs: 'avc1.640033', width: 3840, height: 2160, frameRate: '30' }],
  audio: [{ id: 30280, base_url: mediaUrl(30280, cid), codecs: 'mp4a.40.2' }] } } });
const context = vm.createContext({ URL });
vm.runInContext(fs.readFileSync(path.join(root, 'bilibili.js'), 'utf8'), context);
const api = vm.runInContext('Thru3DBilibili', context);
test('normalization keeps SDR representations for observed ABR selection and rational fps', () => {
  const data = api.normalize(raw(), identity);
  assert.equal(data.video.length, 2); assert.equal(data.audio.length, 1);
  assert.equal(data.video[0].height, 1080); assert.equal(data.video[0].fps, 30000 / 1001);
  assert.equal(data.duration, 120);
});
test('rejects previews, DRM, HDR, missing audio, different CID and invalid media addresses', () => {
  const mutations = [d => d.code = -1, d => d.data.is_preview = true, d => d.data.has_drm = true,
    d => d.data.quality = 125, d => d.data.dash.audio = [], d => d.data.timelength = 0,
    d => d.data.dash.video[0].baseUrl = mediaUrl(80, '999'),
    d => d.data.dash.video[0].baseUrl = 'https://user:password@cdn.test/12345-80.m4s',
    d => d.data.dash.video[0].frameRate = '1/0'];
  for (const change of mutations) { const value = raw(); value.data.dash.video.length = 1; change(value); assert.equal(api.normalize(value, identity), null); }
});

test('decorated full-file names bind to the canonical CID directory, never a conflicting part', () => {
  const url = 'https://upos-test.bilivideo.com/upgcxcode/45/23/12345/12345_nb3-1-30280.m4s?token=synthetic';
  assert.equal(api.mediaCid(url), '12345'); assert.equal(api.address(url, '12345'), url);
  assert.equal(api.address(url, '999'), null);
  assert.equal(api.mediaCid(url.replace('/12345/', '/999/').replace('12345_nb3', '12345')), null);
  assert.equal(api.mediaCid(url.replace('upgcxcode', 'arbitrary')), null);
  assert.equal(api.mediaCid(url.replace('bilivideo.com', 'new-cdn.test')), '12345');
  const value = raw(); value.data.dash.audio[0].base_url = url;
  assert.equal(api.normalize(value, identity).audio[0].urls[0], url);
});
test('inline JSON is parsed without evaluating scripts; immutable original CID prevents reuse on part two', () => {
  const state = { cid: 12345, videoData: { bvid: identity.id, aid: 1, cid: 12345,
    pages: [{ page: 1, cid: 12345, duration: 120 }, { page: 2, cid: 67890, duration: 240 }] } };
  const document = { querySelectorAll: () => [
    { textContent: `window.__INITIAL_STATE__=${JSON.stringify(state)};(function(){throw 'must not run'})();` },
    { textContent: `window.__playinfo__=${JSON.stringify(raw())};` }] };
  assert.equal(api.initial(document, page).data.cid, '12345');
  const next = api.initial(document, page + '?p=2');
  assert.equal(next.identity.cid, '67890'); assert.equal(next.data, null);
  assert.equal(api.initial(document, page.replace('BV1234567890', 'BVabcdefghij')), null);
  assert.equal(api.page('https://www.bilibili.com/bangumi/play/ep123').id, 'ep123');
});
test('document-start observer retains only public part mapping when SSR script removes itself before DOM scan', () => {
  let mutation, disconnected = false; const events = {};
  const document = { querySelectorAll: () => [] };
  const c = vm.createContext({ URL, document, location: { href: page },
    MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} disconnect() { disconnected = true; } },
    addEventListener(name, callback) { events[name] = callback; } });
  vm.runInContext(fs.readFileSync(path.join(root, 'bilibili.js'), 'utf8'), c);
  const reader = vm.runInContext('Thru3DBilibili', c);
  assert.equal(reader.initial(document, page), null);
  const value = { cid: 12345, user: { token: 'must-not-be-exported' }, videoData: { bvid: identity.id, aid: 1, cid: 12345,
    pages: [{ page: 1, cid: 12345, duration: 120 }, { page: 2, cid: 67890, duration: 240 }] } };
  const node = { nodeName: 'SCRIPT', textContent: `window.__INITIAL_STATE__=${JSON.stringify(value)};(function(){throw 'never execute'})();` };
  mutation([{ target: document, addedNodes: [], removedNodes: [node] }]);
  events.DOMContentLoaded(); assert.equal(disconnected, true);
  const result = reader.initial(document, page + '?p=2');
  assert.equal(result.identity.cid, '67890'); assert.equal(result.identity.expected_duration, 240);
  assert.ok(!JSON.stringify(result).includes('must-not-be-exported'));
  events.pagehide({ persisted: false }); assert.equal(reader.initial(document, page), null);
});
const event = () => { const listeners = []; return { listeners, addListener(fn, filter, flags) { listeners.push({ fn, filter, flags }); },
  fire(d) { listeners.forEach(({ fn }) => fn(d)); } }; };
function fixture() {
  const streams = new Map(), timers = new Map(); let seq = 0;
  const webRequest = Object.fromEntries(['onBeforeRequest', 'onHeadersReceived', 'onSendHeaders', 'onBeforeRedirect', 'onErrorOccurred', 'onCompleted'].map(k => [k, event()]));
  webRequest.filterResponseData = id => {
    const stream = { written: [], write(bytes) { this.written.push(Buffer.from(bytes)); }, close() { this.closed = true; }, disconnect() { this.disconnected = true; } };
    streams.set(id, stream); return stream;
  };
  const browser = { runtime: { id: 'fixture', onConnect: event() }, webRequest, cookies: { getAll: async () => [] } };
  const c = vm.createContext({ browser, URL, TextDecoder, Uint8Array, Date, setTimeout(fn) { timers.set(++seq, fn); return seq; }, clearTimeout(id) { timers.delete(id); } });
  for (const name of ['bilibili.js', 'bilibili-response.js', 'network.js']) vm.runInContext(fs.readFileSync(path.join(root, name), 'utf8'), c);
  const messages = [], port = { name: 'thru3d_network', sender: { id: 'fixture', tab: { id: 1 }, frameId: 0, url: page, documentId: 'doc' },
    onMessage: event(), onDisconnect: event(), postMessage(m) { messages.push(m); }, disconnect() { this.onDisconnect.fire(); } };
  browser.runtime.onConnect.fire(port);
  const update = (url = page, enabled = true) => port.onMessage.fire({ type: 'context', page: url, enabled: false, bilibili: enabled, reset: true });
  update();
  const begin = (cid = '12345', extra = {}) => {
    const d = { requestId: String(++seq), url: `https://api.bilibili.com/x/player/wbi/playurl?bvid=BV1234567890&cid=${cid}`, method: 'GET',
      tabId: 1, frameId: 0, documentId: 'doc', documentUrl: page, type: 'xmlhttprequest', ...extra };
    webRequest.onBeforeRequest.fire(d);
    if (!extra.deferHeaders) webRequest.onHeadersReceived.fire({ ...d, statusCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'application/json; charset=utf-8' }] });
    return { d, stream: streams.get(d.requestId) };
  };
  const finish = (stream, data = raw()) => {
    const body = Buffer.from(JSON.stringify(data));
    for (const chunk of [body.subarray(0, 31), body.subarray(31)]) stream.ondata({ data: chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength) });
    stream.onstop(); assert.deepEqual(Buffer.concat(stream.written), body); assert.equal(stream.closed, true);
  };
  return { webRequest, port, streams, timers, messages, update, begin, finish, last: () => messages.at(-1) };
}
test('only four explicit API patterns block; split UTF-8 response is forwarded unchanged before normalization', () => {
  const f = fixture(), capture = f.begin();
  const blocking = f.webRequest.onBeforeRequest.listeners.filter(l => l.flags?.includes('blocking'));
  assert.equal(blocking.length, 1); assert.equal(blocking[0].filter.urls.length, 4);
  assert.ok(blocking[0].filter.urls.every(u => /^https:\/\/api\.bilibili\.com\/(?:(?:x\/player\/(?:wbi\/)?|pgc\/player\/web\/v2\/)playurl|ogv\/player\/playview)\*$/.test(u)));
  f.finish(capture.stream); assert.equal(f.last().bilibili[0].cid, '12345'); assert.equal(f.timers.size, 0);
});
test('next-part response can start before pushState and finish after it, without reusing first-part metadata', () => {
  const f = fixture(); f.finish(f.begin().stream);
  const next = f.begin('67890'); f.update(page + '?p=2'); f.finish(next.stream, raw('67890'));
  assert.equal(f.last().page, page + '?p=2');
  assert.equal(f.last().bilibili.find(d => d.cid === '67890').audio.length, 1);
});

test('a body arriving before HTTP metadata is forwarded immediately and validated when headers arrive', () => {
  const f = fixture(), {d, stream} = f.begin('12345', {deferHeaders: true});
  f.finish(stream); assert.equal(f.last().bilibili.length, 0); assert.equal(f.timers.size, 1);
  f.webRequest.onHeadersReceived.fire({...d, statusCode: 200, responseHeaders: [{name: 'Content-Type', value: 'application/json'}]});
  assert.equal(f.last().bilibili.length, 1); assert.equal(f.timers.size, 0);
});

test('avid requests retain their identity for independent current-page validation', () => {
  const f = fixture(); const e = f.begin('12345', { url: 'https://api.bilibili.com/x/player/wbi/playurl?avid=1&cid=12345' });
  f.finish(e.stream); assert.equal(f.last().bilibili[0].avid, '1');
});
test('another tab/document is ignored; navigation and disabling disconnect all active filters', () => {
  const f = fixture(); assert.equal(f.begin('12345', { tabId: 2 }).stream, undefined);
  assert.equal(f.begin('12345', { documentId: 'stale' }).stream, undefined);
  let e = f.begin(); f.update(page, false); assert.equal(e.stream.disconnected, true);
  f.update(); e = f.begin(); f.port.disconnect(); assert.equal(e.stream.disconnected, true);
  assert.equal(f.timers.size, 0);
});
test('oversize, timeout, bad HTTP, redirects and failed streams release filters without parsing', () => {
  for (const type of ['oversize', 'timeout', 'status', 'redirect', 'error']) {
    const f = fixture(), { d, stream } = f.begin();
    if (type === 'oversize') stream.ondata({ data: new ArrayBuffer(1024 * 1024 + 1) });
    if (type === 'timeout') [...f.timers.values()].forEach(fn => fn());
    if (type === 'status') f.webRequest.onHeadersReceived.fire({ ...d, statusCode: 403, responseHeaders: [] });
    if (type === 'redirect') f.webRequest.onBeforeRedirect.fire(d);
    if (type === 'error') stream.onerror();
    assert.equal(stream.disconnected, true, type); assert.equal(f.timers.size, 0, type);
    stream.onstop(); assert.equal(f.last().bilibili.length, 0);
  }
});
test('malformed JSON and out-of-order responses cannot restore invalidated metadata', () => {
  const f = fixture(), first = f.begin(), second = f.begin();
  assert.equal(first.stream.disconnected, true); first.stream.onstop();
  second.stream.ondata({ data: new TextEncoder().encode('{bad').buffer }); second.stream.onstop();
  assert.equal(second.stream.closed, true); assert.equal(f.last().bilibili.length, 0);
  assert.equal(f.last().bilibili_requested[0], '12345');
});

// CDN authority (including port) remains part of the exact URL match, not an allowlist of ports.
test('CDN prefixes and any valid HTTPS port are accepted without changing the signed URL', () => {
  for (const port of ['', ':443', ':4483', ':8082', ':19443', ':65535']) {
    const u = `https://upos-test.bilivideo.cn${port}/v1/resource/upgcxcode/45/23/12345/12345_nb3-1-30280.m4s?token=synthetic`;
    assert.equal(api.address(u, '12345'), u);
  }
  for (const port of [':0', ':65536', ':bad', ':-1'])
    assert.equal(api.address(`https://upos-test.bilivideo.cn${port}/upgcxcode/12345-80.m4s`, '12345'), null);
  assert.equal(api.address('https://edge.mountaintoys.cn:19443/upgcxcode/45/23/12345/12345_nb3-1-30280.m4s', '12345') !== null, true);
});
const pgcRaw = () => ({code: 0, result: {play_video_type: 'whole', play_check: {play_detail: 'PLAY_WHOLE'},
  arc: {cid: 12345, aid: 1}, supplement: {ogv_episode_info: {episode_id: 123}, ogv_season_info: {season_id: 456}},
  video_info: raw().data}});
test('PGC requires explicit whole status and current episode/season; full length alone is not enough', () => {
  const identity = {page: 'https://www.bilibili.com/bangumi/play/ss456', ep: '123'};
  assert.equal(api.normalizePgc(pgcRaw(), identity).ep, '123');
  assert.equal(api.normalizePgc({status: 'success', data: pgcRaw()}, identity).whole, true);
  for (const change of [d => d.result.play_video_type = 'preview', d => delete d.result.play_check,
    d => d.result.play_check.play_detail = 'PLAY_PREVIEW', d => d.result.video_info.is_drm = true,
    d => d.result.video_info.is_preview = true, d => d.result.supplement.ogv_episode_info.episode_id = 124,
    d => d.result.supplement.ogv_season_info.season_id = 457]) {
    const value = pgcRaw(); change(value); assert.equal(api.normalizePgc(value, identity), null);
  }
  const doc = {querySelector: () => ({href: 'https://www.bilibili.com/bangumi/play/ep123'}),
    querySelectorAll: () => [{textContent: `window.playurlSSRData=${JSON.stringify({status: 'success', data: pgcRaw()})};`}]};
  assert.equal(api.initial(doc, identity.page).data.cid, '12345');
  doc.querySelector = () => ({href: 'https://www.bilibili.com/bangumi/play/ep124'});
  assert.equal(api.initial(doc, identity.page).data, null); // stale SSR after switching episodes
});
test('PGC observes only exact v2 playurl and keys responses by requested episode', () => {
  const f = fixture(), page = 'https://www.bilibili.com/bangumi/play/ss456'; f.update(page);
  const extra = {documentUrl: page, url: 'https://api.bilibili.com/pgc/player/web/v2/playurl?ep_id=123'};
  const e = f.begin('12345', extra); assert.ok(e.stream); f.finish(e.stream, pgcRaw());
  assert.equal(f.last().bilibili[0].ep, '123');
  const wrong = f.begin('12345', {...extra, url: extra.url.replace('123', '124')});
  f.finish(wrong.stream, pgcRaw()); assert.equal(f.last().bilibili_status, 'unsupported_data');
  assert.equal(f.begin('12345', {...extra, url: extra.url.replace('/playurl?', '/playurl/unknown?')}).stream, undefined);
});

test('PGC SSR accepts lexical JSON declarations without executing page script', () => {
  for (const prefix of ['window.', 'const ', 'let ', 'var ']) {
    const doc = {querySelector: () => ({href: 'https://www.bilibili.com/bangumi/play/ep123'}),
      querySelectorAll: () => [{textContent: `${prefix}playurlSSRData = ${JSON.stringify({status: 'success', data: pgcRaw()})}; throw new Error('never execute');`}]};
    assert.equal(api.initial(doc, 'https://www.bilibili.com/bangumi/play/ss456').data.ep, '123');
    doc.querySelectorAll = () => [{textContent: `${prefix}playurlSSRData = (() => { throw new Error('never execute'); })();`}];
    assert.equal(api.initial(doc, 'https://www.bilibili.com/bangumi/play/ss456').data, null);
  }
});

test('OGV playview binds whole responses to the requested episode without a legacy play_check', () => {
  const value = {code: 0, data: pgcRaw().result}; delete value.data.play_check;
  const first = 'https://www.bilibili.com/bangumi/play/ep122';
  const f = fixture(); f.update(first);
  const extra = {documentUrl: first, url: 'https://api.bilibili.com/ogv/player/playview?ep_id=123&season_id=456'};
  const e = f.begin('12345', extra);
  f.update('https://www.bilibili.com/bangumi/play/ep123'); f.finish(e.stream, value);
  assert.equal(f.last().bilibili[0].ep, '123'); assert.equal(f.last().bilibili[0].whole, true);
  for (const change of [d => d.data.play_video_type = 'preview', d => d.data.play_check = {play_detail: 'PLAY_PREVIEW'},
    d => d.data.video_info.is_drm = true, d => d.data.supplement.ogv_episode_info.episode_id = 124]) {
    const bad = JSON.parse(JSON.stringify(value)); change(bad);
    const next = f.begin('12345', {...extra, documentUrl: 'https://www.bilibili.com/bangumi/play/ep123'});
    f.finish(next.stream, bad); assert.equal(f.last().bilibili.length, 0);
  }
  assert.equal(f.begin('12345', {...extra, url: extra.url.replace('/playview?', '/playview/unknown?')}).stream, undefined);
  assert.equal(api.normalizePgc(value, {page: first.replace('122', '123')}), null);
});

test('Bilibili-declared new CDN hosts and opaque paths need no domain or port whitelist', () => {
  const value = raw();
  const video = 'https://new-edge.example:19443/opaque/video.m4s?token=synthetic';
  const audio = 'https://other-edge.example:23456/opaque/audio.m4s?token=synthetic';
  value.data.dash.video[0].baseUrl = video; value.data.dash.audio[0].base_url = audio;
  const result = api.normalize(value, identity);
  assert.equal(result.video[0].urls[0], video); assert.equal(result.audio[0].urls[0], audio);
  assert.equal(api.page('https://www.bilibili.com.attacker.test/video/BV1234567890/'), null);
});

test('PGC response started before SPA navigation survives but stays bound to its requested episode', () => {
  const f = fixture(), first = 'https://www.bilibili.com/bangumi/play/ep122'; f.update(first);
  const e = f.begin('12345', {documentUrl: first, url: 'https://api.bilibili.com/pgc/player/web/v2/playurl?ep_id=123'});
  f.update('https://www.bilibili.com/bangumi/play/ep123'); f.finish(e.stream, pgcRaw());
  assert.equal(f.last().bilibili[0].ep, '123'); assert.equal(f.last().bilibili[0].id, 'ep123');
});

test('Bilibili cache hits cannot replace observed credentials or nominate a headerless alternate', () => {
  const f = fixture();
  const d = {requestId: 'media', url: mediaUrl(30280), method: 'GET', tabId: 1, frameId: 0,
    documentId: 'doc', documentUrl: page, type: 'xmlhttprequest'};
  const response = extra => f.webRequest.onHeadersReceived.fire({...d, statusCode: 206,
    responseHeaders: [{name: 'Content-Type', value: 'video/mp4'}], ...extra});
  f.webRequest.onSendHeaders.fire({...d, requestHeaders: [{name: 'User-Agent', value: 'observed-agent'}, {name: 'Referer', value: page}]});
  response({}); f.webRequest.onCompleted.fire(d);
  f.finish(f.begin().stream);
  const first = f.last().candidates[0]; assert.equal(first.headers.referer, page);
  response({requestId: 'cache', fromCache: true});
  response({requestId: 'alternate-cache', url: d.url.replace('upos-test.bilivideo.com', 'new-cdn.example:8082'), fromCache: true});
  // A redirect placeholder is not evidence of headers sent to the destination.
  f.webRequest.onSendHeaders.fire({...d, requestId: 'redirect', requestHeaders: [{name: 'Cookie', value: 'synthetic'}]});
  const target = d.url.replace('upos-test.bilivideo.com', 'other-cdn.example');
  f.webRequest.onBeforeRedirect.fire({...d, requestId: 'redirect', redirectUrl: target});
  response({requestId: 'redirect', url: target});
  f.finish(f.begin().stream);
  assert.equal(f.last().candidates.length, 1);
  assert.equal(f.last().candidates[0].headers.referer, page);
  assert.equal(f.last().candidates[0].at, first.at);
});
