/* Observe the public SDK messages on the two emulator sample pages. URLs stay in this script. */
const Thru3DFixtureMiguEvents = (() => {
  const sample = () => /^https:\/\/www\.miguvideo\.com\/p\/vertical\/(968096380|966398567)$/.exec(location.href)?.[1];
  const container = /^#www-player-wrap[123]$/;
  const relevant = /^\{"type":"video_(?:request_playurl|status|type|playurl_code)","data":/;
  const statuses = new Set(['video_data_ready', 'video_can_play', 'start_playing', 'playing', 'paused', 'waiting', 'ended']);
  const successCode = value => value === 200 || value === '200';
  const events = new Map();
  let page = location.href;

  function refresh() {
    if (page !== location.href) {
      events.clear();
      page = location.href;
    }
    return sample();
  }

  function observe(event) {
    const id = refresh();
    if (!id || event.source !== window || event.origin !== location.origin ||
        typeof event.data !== 'string' || event.data.length > 262144 || !relevant.test(event.data)) return;
    let message;
    try { message = JSON.parse(event.data); } catch (_) { return; }
    if (!message || typeof message.contonairId !== 'string' || !container.test(message.contonairId)) return;
    const key = message.contonairId;
    if (message.type === 'video_request_playurl') {
      events.delete(key);
      return;
    }
    const state = events.get(key) || {status: '', programMatches: false, success: false, url: '', scheme: '', at: 0};
    if (message.type === 'video_status' && statuses.has(message.data)) state.status = message.data;
    if (message.type === 'video_type') state.programMatches = String(message.data?.contId) === id;
    if (message.type === 'video_playurl_code') {
      state.success = successCode(message.data?.code) && successCode(message.data?.playurlCode);
      state.url = '';
      state.scheme = '';
      state.at = Date.now();
      const declared = message.data?.body?.urlInfo?.url;
      if (state.success && typeof declared === 'string' && declared.length <= 16384) {
        try {
          const url = new URL(declared);
          const programs = url.searchParams.getAll('ProgramID');
          if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password && !url.hash && !url.port &&
              /\.m3u8$/i.test(url.pathname) && programs.length === 1 && programs[0] === id) {
            state.url = declared;
            state.scheme = url.protocol.slice(0, -1);
          }
        } catch (_) {}
      }
    }
    events.set(key, state);
  }

  function snapshot(video, requests) {
    if (!refresh()) return null;
    const owner = video.closest('#www-player-wrap1, #www-player-wrap2, #www-player-wrap3');
    if (!owner || document.getElementById(owner.id) !== owner) return null;
    const state = events.get('#' + owner.id);
    if (!state) return null;
    const age = Date.now() - state.at;
    const url = age >= 0 && age <= 90000 ? state.url : '';
    const scheme = url ? state.scheme : '';
    const secureHls = requests.filter(r => r.kind === 'hls' && typeof r.url === 'string' && /^https:\/\//i.test(r.url));
    const schemeOnly = scheme === 'http' ? url.replace(/^http:/i, 'https:') : '';
    return {status: state.status, program_matches: state.programMatches, playurl_success: state.success,
      declared_program_hls: !!url, declared_hls_scheme: scheme,
      exact_observed_hls: !!url && secureHls.some(r => r.url === url || r.original_url === url),
      https_scheme_only_match: !!schemeOnly && secureHls.some(r => r.url === schemeOnly)};
  }

  if (window.top === window && sample()) window.addEventListener('message', observe);
  return {snapshot};
})();
