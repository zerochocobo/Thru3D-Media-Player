const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture() {
  const page = 'https://www.miguvideo.com/p/vertical/968096380';
  const state = {page, documentPage: page};
  const listeners = new Map();
  const streams = new Map();
  const webRequest = {filterResponseData(id) {
    const stream = {write() {}, close() {}, disconnect() {}};
    streams.set(id, stream);
    return stream;
  }};
  for (const name of ['onBeforeRequest', 'onHeadersReceived', 'onCompleted']) {
    webRequest[name] = {addListener(fn) { listeners.set(name, fn); }};
  }
  const source = fs.readFileSync(path.join(__dirname, '../tools/web-video-desktop/fixture-migu-trace.js'), 'utf8');
  const trace = vm.runInNewContext(source + '\nThru3DFixtureMiguTrace', {
    browser: {webRequest}, URL, TextDecoder, Uint8Array, setTimeout, clearTimeout,
  });
  trace.install(() => state, () => {});
  function playlist(requestId, uri, text, overrides = {}) {
    const details = {frameId: 0, documentUrl: page, requestId, url: uri, statusCode: 200, ...overrides};
    listeners.get('onBeforeRequest')(details);
    listeners.get('onHeadersReceived')(details);
    const stream = streams.get(requestId);
    if (!stream) return false;
    stream.ondata({data: new TextEncoder().encode(text).buffer});
    stream.onstop();
    return true;
  }
  function complete(url) {
    listeners.get('onCompleted')({frameId: 0, documentUrl: page, url, statusCode: 200});
  }
  return {playlist, complete, summary: () => JSON.parse(JSON.stringify(trace.snapshot(state)))};
}

const manifest = (first, second) => `#EXTM3U\n#EXTINF:10,\n${first}\n#EXTINF:10,\n${second}\n#EXT-X-ENDLIST`;
const root = 'https://media.miguvideo.com/current.m3u8?ProgramID=968096380';

test('Migu document observation stays available after a regular media report error', () => {
  const location = {href: 'https://www.miguvideo.com/p/vertical/968096380'};
  const window = {};
  window.top = window;
  const video = {videoWidth:1280, videoHeight:720, currentTime:16, duration:343.08,
    paused:false, ended:false, currentSrc:'blob:https://www.miguvideo.com/private-id'};
  const document = {querySelectorAll: () => [video]};
  const source = fs.readFileSync(path.join(__dirname, '../tools/web-video-desktop/fixture-migu-observation.js'), 'utf8');
  const probe = vm.runInNewContext(source + '\nThru3DFixtureMiguObservation', {
    location, window, document, Thru3DPlayButton:{visible: () => true},
    Thru3DFixtureMiguMse:{activeVideoCodecs: () => ['h264']},
    Thru3DFixtureMiguEvents:{snapshot: () => ({program_matches: true})},
  });
  const packets = [];
  const port = {postMessage: data => packets.push(JSON.parse(JSON.stringify(data)))};
  const sample = () => probe.sample(port, {route_hls:2}, [], () => true);
  probe.report(token => {
    assert.equal(token, 'requested');
    probe.sent(true);
  }, 'requested', false);
  probe.report(() => { throw new Error('private exception text'); }, '', false);
  sample();
  assert.deepEqual(packets[0], {
    type:'fixture_migu_observation', attempts:2, posted:1, failure:'build_error', trace:{route_hls:2},
    videos:[{width:1280, height:720, time:16, duration:343.08, playing:true, protected:true,
      blob:true, fixture_migu_visible:true, fixture_migu_mse_video_codecs:['h264'],
      fixture_migu_player_event:{program_matches:true}}],
  });
  probe.report(() => probe.sent(false), '', false);
  probe.report(() => {}, '', true);
  sample();
  assert.deepEqual([packets[1].attempts, packets[1].posted, packets[1].failure], [3, 1, 'post_error']);
  location.href = 'https://www.miguvideo.com/p/vertical/966398567';
  sample();
  assert.deepEqual([packets[2].attempts, packets[2].posted, packets[2].failure], [0, 0, '']);
  location.href += '?other=1';
  sample();
  assert.throws(() => probe.report(() => { throw new Error('outside fixture'); }, '', false), /outside fixture/);
  assert.equal(packets.length, 3);
});

test('Migu one-off probes acknowledge persistent-port requests and keep running without new ones', async () => {
  const location = {href: 'https://www.miguvideo.com/p/vertical/968096380'};
  const window = {addEventListener() {}, removeEventListener() {}};
  window.top = window;
  const packets = [];
  let next;
  let unblock;
  const document = {hidden: false, querySelectorAll: () => []};
  const source = fs.readFileSync(path.join(__dirname, '../tools/web-video-desktop/fixture-migu-observation.js'), 'utf8');
  const probe = vm.runInNewContext(source + '\nThru3DFixtureMiguObservation', {
    location, window, document,
    setInterval(fn) { next = fn; return 1; },
    clearInterval() { next = undefined; },
    browser: {runtime: {sendNativeMessage(name, packet) {
      packets.push({name, ...packet});
      return new Promise(resolve => { unblock = resolve; });
    }}},
  });
  const read = () => [{route_hls: 2}, [], () => false];
  const flush = () => new Promise(resolve => setImmediate(resolve));
  probe.startProbe('wrong', read);
  assert.equal(next, undefined);
  probe.receiveSnapshot(3);
  probe.startProbe('a'.repeat(32), read);
  await flush();
  assert.equal(packets.length, 1);
  assert.equal(packets[0].name, 'thru3d_video');
  assert.equal(packets[0].snapshot_request, 3);
  next();
  await flush();
  assert.equal(packets.length, 1);
  unblock();
  await flush();
  next();
  await flush();
  assert.equal(packets.length, 2);
  assert.equal(packets[1].snapshot_request, 3);
  location.href = 'https://www.miguvideo.com/p/vertical/966398567';
  next();
  assert.equal(next, undefined);
  unblock();
  await flush();
  assert.equal(packets.length, 2);
});

test('Migu fixture reports which complete playlist has delivered the segment at the playhead', () => {
  const probe = fixture();
  probe.playlist('1', root + '&quality=1', manifest('a1.ts', 'a2.ts'));
  probe.playlist('2', root + '&quality=2', manifest('b1.ts', 'b2.ts'));
  for (const segment of ['a1.ts', 'a2.ts', 'b1.ts']) probe.complete(`https://media.miguvideo.com/${segment}`);
  assert.deepEqual(probe.summary(), {response_filter: true, route_hls: 2, leaves: [
    {duration: 20, segments: 2, received: 2, ranges: [[0, 20]]},
    {duration: 20, segments: 2, received: 1, ranges: [[0, 10]]},
  ]});
});

test('Migu fixture excludes other documents, other programmes, keys and incomplete playlists', () => {
  const probe = fixture();
  assert.equal(probe.playlist('1', root.replace('968096380', '966398567'), manifest('a1.ts', 'a2.ts')), false);
  assert.equal(probe.playlist('2', root, manifest('a1.ts', 'a2.ts'), {frameId: 1}), false);
  probe.playlist('3', root + '&key=1', manifest('a1.ts', 'a2.ts').replace('#EXTINF:10,', '#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:10,'));
  probe.playlist('4', root + '&unfinished=1', manifest('a1.ts', 'a2.ts').replace('#EXT-X-ENDLIST', ''));
  assert.deepEqual(probe.summary(), {response_filter: true, route_hls: 2, leaves: []});
});

function mseFixture() {
  let next = 0;
  const location = {href: 'https://www.miguvideo.com/p/vertical/968096380'};
  class SourceBuffer {
    changeType(type) {
      if (!type) throw new TypeError('Missing MIME type');
    }
  }
  class MediaSource {
    activeSourceBuffers = [];
    addSourceBuffer() { return new SourceBuffer(); }
  }
  const URL = {createObjectURL() { return 'blob:https://www.miguvideo.com/' + (++next); }};
  const window = {URL, MediaSource, SourceBuffer};
  window.top = window;
  window.wrappedJSObject = window;
  const source = fs.readFileSync(path.join(__dirname, '../tools/web-video-desktop/fixture-migu-mse.js'), 'utf8');
  const observer = vm.runInNewContext(source + '\nThru3DFixtureMiguMse', {window, location, exportFunction: fn => fn});
  function create(mime) {
    const media = new MediaSource();
    const video = {currentSrc: URL.createObjectURL(media)};
    const buffer = media.addSourceBuffer(mime);
    media.activeSourceBuffers.push(buffer);
    return {media, video, buffer};
  }
  return {create, location, read: video => Array.from(observer.activeVideoCodecs(video))};
}

test('Migu MSE codecs follow the exact video source and its active buffers', () => {
  const probe = mseFixture();
  const main = probe.create('video/mp4; codecs="avc1.640028, mp4a.40.2"');
  const preload = probe.create('video/mp4; codecs="hev1.1.6.L93.B0"');
  main.media.addSourceBuffer('video/mp4; codecs="av01.0.08M.08"');
  main.media.activeSourceBuffers.push(main.media.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"'));
  assert.deepEqual(probe.read(main.video), ['h264']);
  assert.deepEqual(probe.read(preload.video), ['hevc']);
  assert.deepEqual(probe.read({...main.video, mediaKeys: {}}), []);
  probe.location.href = 'https://www.miguvideo.com/p/detail/965381001';
  assert.deepEqual(probe.read(main.video), []);
});

test('Migu MSE preserves native failures and does not narrow a changing codec to one family', () => {
  const probe = mseFixture();
  const {media, video, buffer} = probe.create('video/mp4; codecs="avc1.640028"');
  assert.throws(() => buffer.changeType(''), TypeError);
  assert.deepEqual(probe.read(video), ['h264']);
  buffer.changeType('video/mp4; codecs="hvc1.1.6.L93.B0"');
  assert.deepEqual(probe.read(video), ['h264', 'hevc']);
  media.activeSourceBuffers.push(media.addSourceBuffer('video/mp4'));
  assert.deepEqual(probe.read(video), []);
  Object.defineProperty(media, 'activeSourceBuffers', {get() { throw new Error('Unavailable'); }});
  assert.deepEqual(probe.read(video), []);
});

function playerEventsFixture() {
  const handlers = new Map();
  const window = {addEventListener(name, handler) { handlers.set(name, handler); }};
  window.top = window;
  const location = new URL('https://www.miguvideo.com/p/vertical/968096380');
  const containers = ['www-player-wrap1', 'www-player-wrap2'].map(id => ({id}));
  const document = {getElementById: id => containers.find(owner => owner.id === id)};
  const source = fs.readFileSync(path.join(__dirname, '../tools/web-video-desktop/fixture-migu-player-events.js'), 'utf8');
  let now = 1000;
  const observer = vm.runInNewContext(source + '\nThru3DFixtureMiguEvents', {window, document, location, URL, Date: {now: () => now}});
  function event(type, data, index = 0, overrides = {}) {
    handlers.get('message')({source: window, origin: location.origin, ...overrides,
      data: JSON.stringify({type, data, contonairId: '#' + containers[index].id})});
  }
  function summary(index, requests) {
    const value = observer.snapshot({closest: () => containers[index]}, requests);
    return JSON.parse(JSON.stringify(value));
  }
  return {event, summary, location, advance: ms => { now += ms; }};
}

const declaredUrl = url => ({code: 200, playurlCode: 200, body: {urlInfo: {url}}});

test('Migu public player status and exact HLS request stay with their own container', () => {
  const probe = playerEventsFixture();
  const requests = [{kind: 'hls', url: root}];
  probe.event('video_playurl_code', declaredUrl(root), 1);
  probe.event('video_status', 'playing');
  probe.event('video_type', {contId: '968096380'});
  assert.deepEqual(probe.summary(0, requests), {status: 'playing', program_matches: true,
    playurl_success: false, declared_program_hls: false, declared_hls_scheme: '',
    exact_observed_hls: false, https_scheme_only_match: false});
  probe.event('video_playurl_code', declaredUrl(root));
  assert.equal(probe.summary(0, requests).exact_observed_hls, true);
  assert.equal(probe.summary(0, [{kind: 'hls', url: root + '&signature=different'}]).exact_observed_hls, false);
  assert.equal(JSON.stringify(probe.summary(0, requests)).includes(root), false);
  probe.advance(90001);
  assert.equal(probe.summary(0, requests).exact_observed_hls, false);
});

test('Migu public player observation ignores unowned messages and invalidates on a new request', () => {
  const probe = playerEventsFixture();
  const requests = [{kind: 'hls', url: root}];
  probe.event('video_playurl_code', declaredUrl(root), 0, {origin: 'https://other.example'});
  probe.event('video_playurl_code', declaredUrl(root), 0, {source: {}});
  assert.equal(probe.summary(0, requests), null);
  probe.event('video_playurl_code', declaredUrl(root + '&ProgramID=968096380'));
  assert.equal(probe.summary(0, requests).declared_program_hls, false);
  probe.event('video_playurl_code', declaredUrl(root));
  probe.event('video_request_playurl', {});
  assert.equal(probe.summary(0, requests), null);
  probe.event('video_playurl_code', declaredUrl(root));
  probe.location.href = 'https://www.miguvideo.com/p/vertical/966398567';
  assert.equal(probe.summary(0, requests), null);
});

test('Migu accepts the public string status and requires a real secure request chain for an HTTP declaration', () => {
  const probe = playerEventsFixture();
  const declared = root.replace('https:', 'http:');
  probe.event('video_playurl_code', {...declaredUrl(declared), code: '200', playurlCode: '200'});
  const insecure = probe.summary(0, [{kind: 'hls', url: declared}]);
  assert.equal(insecure.playurl_success, true);
  assert.equal(insecure.declared_hls_scheme, 'http');
  assert.equal(insecure.exact_observed_hls, false);
  const schemeOnly = probe.summary(0, [{kind: 'hls', url: root}]);
  assert.equal(schemeOnly.https_scheme_only_match, true);
  assert.equal(schemeOnly.exact_observed_hls, false);
  const observedUpgrade = probe.summary(0, [{kind: 'hls', url: root, original_url: declared}]);
  assert.equal(observedUpgrade.exact_observed_hls, true);
  probe.event('video_playurl_code', {...declaredUrl(declared), code: '0200', playurlCode: '200'});
  assert.equal(probe.summary(0, []).playurl_success, false);
});
