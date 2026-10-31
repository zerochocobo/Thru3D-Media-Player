/* Desktop test host only. Production scripts remain the extraction implementation.
 * Raw messages and request URLs live only in this background page's bounded memory. */
const requests = new Map();
const apiEvents = [];
const normalizedShapes = [];
let documentSequence = 0;
const endpoint = '__REPORT_ENDPOINT__';
const apiPath = u => u.hostname === 'api.bilibili.com' && (/\/(?:playurl|playview)$/.test(u.pathname) || u.pathname.includes('/web-interface/') && u.pathname.includes('/view'));
browser.webRequest.onHeadersReceived.addListener(d => {
  const u = new URL(d.url);
  if (apiPath(u)) {
    apiEvents.push({path: u.pathname, view_aid: u.searchParams.get('aid') === '0' ? 'zero' : /^[1-9][0-9]+$/.test(u.searchParams.get('aid') || '') ? 'positive' : 'absent', query_keys: [...u.searchParams.keys()].filter(k => /^[a-z_0-9]{1,40}$/i.test(k)), status: d.statusCode, frame: d.frameId, type: d.type,
      json: (d.responseHeaders || []).some(h => h.name.toLowerCase() === 'content-type' && /^application\/json(?:;|$)/i.test(h.value))});
    if (apiEvents.length > 16) apiEvents.shift();
  }
  if (!/\.m4s$/i.test(u.pathname)) return;
  requests.delete(d.url);
  requests.set(d.url, {status: d.statusCode, frame: d.frameId, type: d.type, cached: !!d.fromCache});
  while (requests.size > 96) requests.delete(requests.keys().next().value);
}, {urls: ['https://*/*']}, ['responseHeaders']);
function summarize(item) {
  const data = item.bilibili;
  const group = value => Thru3DBilibili.mediaCid(value);
  const tracks = key => (data?.[key] || []).flatMap(t => t.urls);
  const matching = (values, key) => values.filter(u => tracks(key).includes(u)).length;
  const observed = (item.network || []).map(c => c.url);
  const originals = (item.network || []).map(c => c.original_url);
  const raw = [...requests.keys()];
  const shape = (value, event) => ({...event,
    host: /(?:^|\.)bilivideo\.(com|cn)$/.test(new URL(value).hostname) ? 'bilivideo' : 'other',
    current_part: !!data && group(value) === data.cid,
    api_video: tracks('video').includes(value), api_audio: tracks('audio').includes(value)});
  return {page_path: new URL(item.frame).pathname, part: Number(new URL(item.frame).searchParams.get('p') || 1), width: item.width, height: item.height, duration: item.duration, playing: item.playing,
    time: item.time, binding: item.bilibili_binding, response_status: item.bilibili_status,
    api_count: item.bilibili_api_count, view_count: item.bilibili_view_count, metadata: !!data, api_events: apiEvents, normalized_shapes: normalizedShapes,
    video_representations: data?.video.length || 0, audio_representations: data?.audio.length || 0,
    captured_video: matching(observed, 'video'), captured_audio: matching(observed, 'audio'),
    original_video: matching(originals, 'video'), original_audio: matching(originals, 'audio'),
    observed_shapes: (item.network || []).map(c => {
      const u = new URL(c.url);
      const match = key => tracks(key).some(value => new URL(value).pathname === u.pathname);
      const queryMatch = key => tracks(key).some(value => new URL(value).pathname === u.pathname && new URL(value).search === u.search);
      return {header_names: Object.keys(c.headers || {}), current_part: !!data && group(c.url) === data.cid, video_path: match('video'), audio_path: match('audio'),
        video_path_query: queryMatch('video'), audio_path_query: queryMatch('audio'), redirected: c.original_url !== c.url};
    }),
    raw_video: matching(raw, 'video'), raw_audio: matching(raw, 'audio'),
    requests: [...requests].map(([u, e]) => shape(u, e))};
}
browser.runtime.onConnect.addListener(port => {
  if (port.name !== 'thru3d_desktop_media') return;
  const sequence = ++documentSequence;
  // Match Android's policy delivery without Android-only nativeMessaging permissions.
  port.postMessage({action: 'network_policy', enabled: false, bilibili: true});
  port.onMessage.addListener(message => {
    if (!Array.isArray(message.videos)) return;
    for (const item of message.videos) {
      if (!/^https:\/\/www\.bilibili\.com\/(?:video|bangumi\/play)\//.test(item.frame || '')) continue;
      fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({...summarize(item), document_sequence: sequence})}).catch(() => {});
    }
  });
});
