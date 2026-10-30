/* Response observation is registered only for known playurl endpoints, never all_urls. */
const Thru3DBilibiliResponses = (stateFor, publish) => {
  "use strict";
  const filter = { urls: ['https://api.bilibili.com/x/player/wbi/playurl*', 'https://api.bilibili.com/x/player/playurl*', 'https://api.bilibili.com/pgc/player/web/v2/playurl*', 'https://api.bilibili.com/ogv/player/playview*'], types: ['xmlhttprequest'] };
  const active = new Map();
  const stop = (entry, reason = 'cancelled') => {
    if (entry.released) return;
    entry.released = true;
    entry.done = true;
    clearTimeout(entry.timer); active.delete(entry.id);
    try { entry.stream.disconnect(); } catch (_) {}
    entry.chunks = [];
    entry.state.biliStatus = reason; publish(entry.state);
  };
  const cancel = state => { for (const e of active.values()) if (e.state === state) stop(e); };
  browser.webRequest.onBeforeRequest.addListener(d => {
    const state = stateFor(d), p = state && Thru3DBilibili.page(state.page);
    if (!state?.bilibili || !p || d.method !== 'GET') return;
    const u = new URL(d.url), ep = u.searchParams.get('ep_id');
    const cid = p.pgc ? ep : u.searchParams.get('cid');
    const bvid = u.searchParams.get('bvid'), avid = u.searchParams.get('avid');
    if (u.origin !== 'https://api.bilibili.com' || !(p.pgc ? ['/pgc/player/web/v2/playurl', '/ogv/player/playview'] : ['/x/player/wbi/playurl', '/x/player/playurl']).includes(u.pathname) ||
        !/^[1-9][0-9]{0,19}$/.test(cid || '') ||
        (p.pgc ? false : p.id.startsWith('BV') ? (bvid ? bvid !== p.id : !/^[1-9][0-9]{0,19}$/.test(avid || '')) : avid !== p.id.slice(2))) return;
    state.biliResponses ||= new Map(); state.biliRequests ||= new Map();
    for (const entry of active.values()) if (entry.state === state && entry.cid === cid) stop(entry);
    state.biliResponses.delete(cid); state.biliRequests.set(cid, d.requestId);
    while (state.biliRequests.size > 8) state.biliRequests.delete(state.biliRequests.keys().next().value);
    publish(state);
    if (active.size >= 8) { state.biliStatus = 'unavailable'; publish(state); return; }
    let stream;
    try { stream = browser.webRequest.filterResponseData(d.requestId); }
    catch (_) { state.biliStatus = 'unavailable'; publish(state); return; }
    state.biliStatus = 'observing'; publish(state);
    const e = { id: d.requestId, stream, state, cid, page: state.page, chunks: [], size: 0, ok: null };
    active.set(e.id, e);
    e.timer = setTimeout(() => stop(e, 'timeout'), 15000);
    stream.ondata = event => {
      if (e.done) return;
      // Forward each chunk before parsing or copying. Oversize responses continue unmodified.
      try { stream.write(event.data); } catch (_) { stop(e, 'stream_error'); return; }
      if ((e.size += event.data.byteLength) > 1024 * 1024) { stop(e, 'oversize'); return; }
      e.chunks.push(new Uint8Array(event.data).slice());
    };
    e.complete = () => {
      // StreamFilter events and webRequest metadata arrive through separate channels.
      // Closing the forwarded stream must not discard a body before headers arrive.
      if (e.released || !e.bodyDone || e.ok === null) return;
      e.released = true;
      clearTimeout(e.timer); active.delete(e.id);
      if (state.biliRequests.get(cid) !== e.id) { e.chunks = []; return; }
      if (!e.ok || stateFor({ ...d, documentUrl: state.page }) !== state || !Thru3DBilibili.sameDocumentPage(state.page, e.page)) {
        state.biliStatus = !e.ok ? 'http_rejected' : 'context_changed';
        e.chunks = []; publish(state); return;
      }
      try {
        const bytes = new Uint8Array(e.size); let offset = 0;
        for (const chunk of e.chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        const data = (p.pgc ? Thru3DBilibili.normalizePgc : Thru3DBilibili.normalize)(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)),
          { page: p.pgc ? 'https://www.bilibili.com/bangumi/play/ep' + ep : e.page, id: p.id, part: p.part,
            ...(p.pgc ? {ep, api: u.pathname === '/ogv/player/playview' ? 'ogv_playview' : 'pgc_v2'} : {cid, ...(avid ? {avid} : {})}) });
        if (data) state.biliResponses.set(cid, data);
        state.biliStatus = data ? 'normalized' : 'unsupported_data';
        while (state.biliResponses.size > 4) state.biliResponses.delete(state.biliResponses.keys().next().value);
        while (JSON.stringify([...state.biliResponses.values()]).length > 96 * 1024)
          state.biliResponses.delete(state.biliResponses.keys().next().value);
        publish(state);
      } catch (_) { state.biliStatus = 'invalid_json'; publish(state); }
      finally { e.chunks = []; }
    };
    stream.onstop = () => {
      if (e.done) return;
      e.done = true; e.bodyDone = true;
      try { stream.close(); } catch (_) { stop(e); return; }
      e.complete();
    };
    stream.onerror = () => stop(e, 'stream_error');
  }, filter, ['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d => {
    const e = active.get(d.requestId); if (!e) return;
    e.ok = d.statusCode === 200 && (d.responseHeaders || []).some(h =>
      h.name.toLowerCase() === 'content-type' && /^application\/json(?:;|$)/i.test(h.value || ''));
    if (!e.ok) stop(e, 'http_rejected'); else e.complete();
  }, filter, ['responseHeaders']);
  browser.webRequest.onErrorOccurred.addListener(d => { const e = active.get(d.requestId); if (e) stop(e); }, filter);
  browser.webRequest.onBeforeRedirect.addListener(d => { const e = active.get(d.requestId); if (e) stop(e); }, filter);
  return { cancel };
};
