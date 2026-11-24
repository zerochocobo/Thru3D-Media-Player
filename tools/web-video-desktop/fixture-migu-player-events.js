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

  function relationships(declared, requests, id) {
    function parse(text) {
      try {
        if (typeof text !== 'string' || text.length > 16384) return null;
        const u = new URL(text);
        return ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password && !u.port && !u.hash &&
          /\.m3u8$/i.test(u.pathname) && u.searchParams.getAll('ProgramID').length === 1 && u.searchParams.get('ProgramID') === id ? u : null;
      } catch (_) { return null; }
    }
    const reference = parse(declared);
    if (!reference || !Array.isArray(requests)) return [];
    function compare(text) {
      const u = parse(text);if (!u) return null;
      // Firefox Xray DOM iterators may not expose Symbol.iterator in this world.
      const keySet = new Set();
      reference.searchParams.forEach((_value, key) => keySet.add(key));
      u.searchParams.forEach((_value, key) => keySet.add(key));
      const keys = [...keySet];
      const crossdomain = u.searchParams.getAll('crossdomain');
      return {exact: text === declared, same_scheme: u.protocol === reference.protocol,
        same_host: u.host === reference.host, same_path: u.pathname === reference.pathname,
        same_query: u.search === reference.search,
        scheme_only: reference.protocol === 'http:' && text === declared.replace(/^http:/, 'https:'),
        query_keys_overflow: keys.length > 48,
        crossdomain_count: crossdomain.length,
        crossdomain_is_www_migu: crossdomain.length === 1 && crossdomain[0] === 'www.miguvideo.com',
        crossdomain_is_one: crossdomain.length === 1 && crossdomain[0] === '1',
        crossdomain_is_document_origin: crossdomain.length === 1 && crossdomain[0] === location.origin,
        changed_query_keys: keys.filter(k => JSON.stringify(reference.searchParams.getAll(k)) !== JSON.stringify(u.searchParams.getAll(k)))
          .filter(k => /^[A-Za-z0-9_:-]{1,64}$/.test(k)).slice(0, 48)};
    }
    return requests.filter(r => r?.kind === 'hls' && Number.isFinite(r.at) && Date.now() - r.at >= 0 && Date.now() - r.at <= 90000)
      .slice(-24).flatMap(r => {
        const final = compare(r.url);if (!final) return [];
        return [{final, original: compare(r.original_url), age_ms: Math.round(Date.now() - r.at)}];
      });
  }

  function snapshot(video, requests, compare = false) {
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
      https_scheme_only_match: !!schemeOnly && secureHls.some(r => r.url === schemeOnly),
      ...(compare ? {owner_selector: '#' + owner.id, relationships: relationships(url, requests, refresh())} : {})};
  }

  if (window.top === window && sample()) window.addEventListener('message', observe);
  return {snapshot, relationships};
})();
