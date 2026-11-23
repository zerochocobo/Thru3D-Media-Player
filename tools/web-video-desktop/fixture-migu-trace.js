/* Emulator fixture only. Records completed ranges without retaining URLs or headers in a report. */
const Thru3DFixtureMiguTrace = (() => {
  const sample = page => /^https:\/\/www\.miguvideo\.com\/p\/vertical\/(968096380|966398567)$/.exec(page || '')?.[1];
  const bags = new WeakMap();
  const pending = new Map();
  const maxBytes = 512 * 1024;
  const filter = {urls: ['https://*.miguvideo.com/*.m3u8*'], types: ['xmlhttprequest', 'media', 'other']};

  function address(text, base) {
    try {
      const url = new URL(text, base);
      if (url.protocol === 'https:' && !url.username && !url.password && !url.hash && !url.port) return url;
    } catch (_) {}
    return null;
  }

  function parseLeaf(text, base) {
    const lines = text.split(/\r?\n/).map(line => line.trim());
    if (lines[0] !== '#EXTM3U' || !lines.includes('#EXT-X-ENDLIST') ||
        lines.some(line => /^#EXT-X-(?:STREAM-INF|KEY|SESSION-KEY|MAP|BYTERANGE|DISCONTINUITY|GAP|DEFINE)/.test(line))) return null;
    const segments = new Map();
    let duration = 0, length = 0;
    for (const line of lines.slice(1)) {
      if (line.startsWith('#EXTINF:')) {
        if (length !== 0) return null;
        length = Number(line.slice(8).split(',', 1)[0]);
        if (!Number.isFinite(length) || length <= 0 || length > 120) return null;
      } else if (line && !line.startsWith('#')) {
        const url = address(line, base);
        if (!url || !length || segments.has(url.href) || segments.size >= 2000) return null;
        segments.set(url.href, [duration, duration + length]);
        duration += length;
        length = 0;
      }
    }
    return length === 0 && segments.size && duration <= 172800 ? {duration, segments} : null;
  }

  function snapshot(state) {
    if (!sample(state.page)) return null;
    const saved = bags.get(state);
    const bag = saved?.page === state.page ? saved : null;
    const leaves = [...(bag?.leaves.values() || [])].map(leaf => {
      const ranges = [];
      let received = 0;
      for (const [url, [start, end]] of leaf.segments) {
        if (!bag.received.has(url)) continue;
        received++;
        if (ranges.at(-1)?.[1] === start) ranges.at(-1)[1] = end;
        else if (ranges.length < 16) ranges.push([start, end]);
      }
      return {duration: leaf.duration, segments: leaf.segments.size, received, ranges};
    });
    return {response_filter: typeof browser.webRequest.filterResponseData === 'function', route_hls: bag?.requests.size || 0, leaves};
  }

  function install(lookup, publish) {
    function context(details) {
      if (details.frameId !== 0 || !sample(details.documentUrl)) return null;
      const state = lookup(details);
      if (!state || state.page !== details.documentUrl || state.documentPage !== state.page) return null;
      if (bags.get(state)?.page !== state.page) bags.set(state, {page: state.page, requests: new Set(), leaves: new Map(), received: new Set()});
      return state;
    }
    browser.webRequest.onBeforeRequest.addListener(details => {
      const state = context(details);
      const uri = address(details.url);
      const ids = uri?.searchParams.getAll('ProgramID');
      if (!state || ids?.length !== 1 || ids[0] !== sample(state.page) || pending.has(details.requestId)) return;
      const bag = bags.get(state);
      if (bag.requests.size >= 32 || pending.size >= 8 || bag.leaves.size >= 8) return;
      bag.requests.add(details.url);
      if (typeof browser.webRequest.filterResponseData !== 'function') return;
      let stream;
      try { stream = browser.webRequest.filterResponseData(details.requestId); } catch (_) { return; }
      const request = {size: 0, status: 0, final: details.url}, parts = [];
      pending.set(details.requestId, request);
      const timer = setTimeout(() => { forget(); stream.disconnect(); }, 10000);
      function forget() {
        clearTimeout(timer);
        if (pending.get(details.requestId) === request) pending.delete(details.requestId);
      }
      stream.ondata = event => {
        try { stream.write(event.data); } catch (_) { forget(); return; }
        request.size += event.data.byteLength;
        if (request.size <= maxBytes) parts.push(new Uint8Array(event.data).slice());
        else { forget(); stream.disconnect(); }
      };
      stream.onerror = forget;
      stream.onstop = () => {
        forget();
        try { stream.close(); } catch (_) { return; }
        if (request.status !== 200 || context(details) !== state || bags.get(state) !== bag || request.size > maxBytes) return;
        const bytes = new Uint8Array(request.size);
        let offset = 0;
        for (const part of parts) { bytes.set(part, offset); offset += part.length; }
        const leaf = parseLeaf(new TextDecoder().decode(bytes), request.final);
        if (leaf && bag.leaves.size < 8) bag.leaves.set(request.final, leaf);
        publish(state);
      };
    }, filter, ['blocking']);
    browser.webRequest.onHeadersReceived.addListener(details => {
      const request = pending.get(details.requestId);
      if (request) { request.final = details.url; request.status = details.statusCode; }
    }, filter);
    browser.webRequest.onCompleted.addListener(details => {
      const state = context(details);
      if (!state || details.statusCode !== 200 && details.statusCode !== 206) return;
      const bag = bags.get(state);
      if (bag.received.size >= 1200 || bag.received.has(details.url)) return;
      bag.received.add(details.url);
      if ([...bag.leaves.values()].some(leaf => leaf.segments.has(details.url))) publish(state);
    }, {urls: ['https://*/*'], types: ['xmlhttprequest', 'media', 'other']});
  }

  return {install, snapshot};
})();
