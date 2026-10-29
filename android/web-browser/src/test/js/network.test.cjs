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
  vm.runInNewContext(source, { browser, URL, Date: { now: () => now }, setTimeout(f) { timers.set(++next, f); return next; }, clearTimeout(id) { timers.delete(id); } });
  function connect(tab = 1, frame = 0, page = 'https://page.test/watch', enabled = true) {
    const messages = [];
    const port = { name: 'thru3d_network', sender: { id: 'fixture', tab: { id: tab }, frameId: frame, url: page, documentId: `doc-${tab}-${frame}` },
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
  return { connect, request, flush, browser, advance(ms) { now += ms; } };
}
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
