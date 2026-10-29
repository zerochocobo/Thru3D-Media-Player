/* Passive response discovery. Nothing is injected into the page's JS world, replayed,
 * persisted or logged. Runtime ports are scoped by Gecko's tab/frame sender identity. */
(() => {
  "use strict";
  const frames = new Map(), pending = new Map();
  const TTL = 1800000, MAX = 24, REQUESTS = 256;
  const filter = { urls: ["http://*/*", "https://*/*"] };
  const key = d => `${d.tabId}:${d.frameId}`;
  const url = (value, page = false) => {
    try { const u = new URL(value); return /^https?:$/.test(u.protocol) && !u.username && !u.password &&
      (page || !u.hash) && value.length <= 16384 ? u : null; } catch (_) { return null; }
  };
  const header = (list, name) => (list || []).find(h => h.name.toLowerCase() === name)?.value || "";
  const headers = list => {
    const result = {};
    let size = 0;
    for (const h of list || []) {
      const name = h.name.toLowerCase(), value = h.value;
      // In particular, never replay Range/If-Range, hop-by-hop or browser fetch headers.
      if (!/^(user-agent|referer|origin|cookie|authorization|accept|accept-language|x-[a-z0-9-]{1,100})$/.test(name) ||
          typeof value !== "string" || value.length > 8192 || /[\x00-\x1f\x7f]/.test(value)) continue;
      if (Object.keys(result).length >= 24 || (size += value.length) > 24576) return null;
      result[name] = value;
    }
    return result;
  };
  const kind = (u, mime, d) => {
    if (/mpegurl/.test(mime)) return "hls";
    if (mime === "application/dash+xml") return "dash";
    // A successful HTML/JSON error or API response is not a manifest, even with that suffix.
    if (/^(text\/html|application\/(?:json|problem\+json))$/.test(mime)) return "";
    if (/\.m3u8$/i.test(u.pathname)) return "hls";
    if (/\.mpd$/i.test(u.pathname)) return "dash";
    if (/\.(?:ts|m2ts|aac|mp3|vtt|srt|key)$/i.test(u.pathname)) return "segment";
    if (/\.(?:m4s|cmfv|cmfa)$/i.test(u.pathname) || /(?:^|[/_-])(?:init|segment|chunk)[-_.\d]/i.test(u.pathname))
      return /(?:^|\.)bilivideo\.(?:com|cn)$/.test(u.hostname) && /\/\d+-[^/]+\.m4s$/i.test(u.pathname) ? "file" : "segment";
    if (/^(?:video|audio)\/(?:mp4|webm|x-matroska|quicktime)$/.test(mime) ||
        /\.(?:mp4|m4v|m4a|webm|mkv|mov)$/i.test(u.pathname)) return "file";
    return "";
  };
  const publish = state => {
    const now = Date.now();
    for (const [id, c] of state.items) if (now - c.at > TTL) state.items.delete(id);
    while (JSON.stringify([...state.items.values()]).length > 192 * 1024) state.items.delete(state.items.keys().next().value);
    try { state.port.postMessage({ type: "network", page: state.page, candidates: [...state.items.values()] }); } catch (_) {}
  };
  browser.runtime.onConnect.addListener(port => {
    const s = port.sender;
    if (port.name !== "thru3d_network" || s?.id !== browser.runtime.id || !Number.isInteger(s.tab?.id) ||
        s.tab.id < 0 || !Number.isInteger(s.frameId) || !url(s.url, true)) return;
    const id = `${s.tab.id}:${s.frameId}`;
    const state = { port, page: s.url, document: s.documentId, enabled: false, items: new Map(), timer: null };
    const old = frames.get(id);
    if (old) { clearTimeout(old.timer); old.port.disconnect(); }
    frames.set(id, state);
    while (frames.size > 64) { const oldest = frames.keys().next().value; frames.get(oldest).port.disconnect(); frames.delete(oldest); }
    port.onMessage.addListener(message => {
      if (frames.get(id) !== state || message?.type !== "context" || !url(message.page, true) ||
          new URL(message.page).origin !== new URL(s.url).origin) return;
      if (message.page !== state.page || message.reset === true || (message.enabled === true) !== state.enabled) {
        state.page = message.page; state.enabled = message.enabled === true; state.items.clear();
        for (const [request, value] of pending) if (value.state === state) pending.delete(request);
        publish(state);
      }
    });
    port.onDisconnect.addListener(() => {
      clearTimeout(state.timer);
      if (frames.get(id) === state) frames.delete(id);
      for (const [request, value] of pending) if (value.state === state) pending.delete(request);
    });
  });
  const stateFor = d => {
    const state = frames.get(key(d));
    if (!state || !state.enabled || d.tabId < 0 || (d.documentId && state.document && d.documentId !== state.document) ||
        (d.documentUrl && d.documentUrl.split('#')[0] !== state.page.split('#')[0])) return null;
    return state;
  };
  browser.webRequest.onBeforeRequest.addListener(d => {
    if (d.type !== "main_frame" && d.type !== "sub_frame") return;
    for (const [id, state] of frames) if (id === key(d) || d.type === "main_frame" && id.startsWith(`${d.tabId}:`)) {
      state.port.disconnect(); frames.delete(id);
    }
  }, filter);
  browser.webRequest.onSendHeaders.addListener(d => {
    const state = stateFor(d);
    if (!state || d.method !== "GET" || !["media", "xmlhttprequest", "other"].includes(d.type) || !url(d.url)) return;
    const safe = headers(d.requestHeaders);
    if (!safe) return;
    const previous = pending.get(d.requestId);
    pending.set(d.requestId, { state, url: d.url, original: previous?.state === state ? previous.original : d.url, headers: safe, at: Date.now() });
    for (const [id, p] of pending) if (Date.now() - p.at > 30000) pending.delete(id);
    while (pending.size > REQUESTS) pending.delete(pending.keys().next().value);
  }, filter, ["requestHeaders"]);
  browser.webRequest.onHeadersReceived.addListener(d => {
    const state = stateFor(d), u = url(d.url), request = pending.get(d.requestId);
    if (!state || !u || d.method !== "GET" || ![200, 206].includes(d.statusCode)) return;
    const mime = header(d.responseHeaders, "content-type").split(";")[0].trim().toLowerCase();
    const type = kind(u, mime, d);
    if (!type || type === "segment") return;
    // A cached response can have no onSendHeaders. Do not invent Cookie/Authorization.
    const safe = request?.state === state && request.url === d.url ? request.headers : {};
    const c = { url: d.url, kind: type, mime, headers: safe, at: Date.now(), cookies: [],
      original_url: request?.state === state ? request.original : d.url,
      length: header(d.responseHeaders, "content-length").slice(0, 24),
      range: header(d.responseHeaders, "content-range").slice(0, 80) };
    const previous = state.items.get(d.url);
    c.cookies = previous && previous.headers.cookie === safe.cookie ? previous.cookies : [];
    state.items.delete(d.url); state.items.set(d.url, c);
    while (state.items.size > MAX || JSON.stringify([...state.items.values()]).length > 192 * 1024)
      state.items.delete(state.items.keys().next().value);
    // Range traffic often repeats several times a second. Report changed credentials/resources,
    // not every segment; a periodic refresh still keeps a long-playing resource eligible.
    if (!previous || c.at - previous.reported > 30000 || JSON.stringify(safe) !== JSON.stringify(previous.headers)) {
      c.reported = c.at;
      if (!state.timer) state.timer = setTimeout(() => { state.timer = null; publish(state); }, 100);
    } else c.reported = previous.reported;
    if ((!previous || previous.headers.cookie !== safe.cookie || c.at - (previous.cookiesAt || 0) > 30000) && safe.cookie) {
      c.cookiesAt = c.at;
      // Preserve scope, and only include cookies actually present on this exact request.
      // Partitioned cookies unavailable through cookies.getAll remain exact-request-only.
      browser.cookies.getAll({ url: d.url, ...(d.cookieStoreId ? { storeId: d.cookieStoreId } : {}) }).then(cookies => {
        if (state.items.get(d.url) !== c) return;
        const sent = new Set(safe.cookie.split(/;\s*/));
        c.cookies = cookies.filter(cookie => !cookie.partitionKey && !cookie.firstPartyDomain &&
          sent.has(`${cookie.name}=${cookie.value}`)).slice(0, 128).map(({ name, value, domain, path, secure, hostOnly, expirationDate }) =>
            ({ name, value, domain, path, secure, hostOnly, expirationDate }));
        if (JSON.stringify(c.cookies).length > 24576) c.cookies = [];
        if (!state.timer) state.timer = setTimeout(() => { state.timer = null; publish(state); }, 100);
      }).catch(() => {});
    } else c.cookiesAt = previous?.cookiesAt || 0;
  }, filter, ["responseHeaders"]);
  const finish = d => pending.delete(d.requestId);
  browser.webRequest.onCompleted.addListener(finish, filter);
  browser.webRequest.onErrorOccurred.addListener(finish, filter);
  browser.webRequest.onBeforeRedirect.addListener(d => {
    const request = pending.get(d.requestId);
    if (request && url(d.redirectUrl)) pending.set(d.requestId, { ...request, url: d.redirectUrl, headers: {} });
    else finish(d);
  }, filter);
})();
