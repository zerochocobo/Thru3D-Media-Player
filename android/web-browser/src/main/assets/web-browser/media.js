/* Extension isolated world. No page-provided code is evaluated by the native bridge. */
(() => {
  "use strict";
  let port;
  const videos = new Map();
  const encrypted = new WeakSet();
  let nextId = 0;
  let closed = false;
  let scheduled = false;
  let suspended = false;
  let handoff = null;
  let pauseLease = null, lastPauseToken = 0;
  const resuming = new WeakMap();
  const holdPaused = video => {
    if (pauseLease && pauseLease.page !== location.href) pauseLease = null;
    if (!pauseLease || !video.isConnected) return;
    if (!pauseLease.videos.has(video)) pauseLease.videos.set(video, {
      source: video.currentSrc, epoch: mediaEpoch.get(video)?.id,
      playing: !video.paused && !video.ended || resuming.has(video) || pauseLease.playingIds.has(String(videos.get(video)))
    });
    video.pause();
  };
  let networkPort, network = [], networkPage = location.href;
  let networkEnabled = false;
  let bilibiliEnabled = false, bilibiliData = [];
  let bilibiliViews = [];
  let bilibiliStatus = 'idle', bilibiliResponseApi = false;
  let bilibiliInitial = null, bilibiliInitialPage = '', bilibiliScanAt = 0;
  let bilibiliOwner = null;
  const networkContext = (reset = false) => {
    try { networkPort?.postMessage({ type: "context", page: location.href, enabled: networkEnabled, bilibili: bilibiliEnabled, reset }); } catch (_) {}
  };
  const mediaEpoch = new WeakMap();
  const connectNetwork = () => {
    network = [];
    bilibiliData = []; bilibiliViews = [];
    networkPort = browser.runtime.connect({ name: "thru3d_network" });
    const connection = networkPort;
    networkPort.onMessage.addListener(message => {
      if (connection !== networkPort || message?.type !== "network" || message.page !== location.href) return;
      network = Array.isArray(message.candidates) ? message.candidates.slice(0, 24) : [];
      bilibiliData = Array.isArray(message.bilibili) ? message.bilibili.slice(0, 4) : [];
      bilibiliViews = Array.isArray(message.bilibili_views) ? message.bilibili_views.slice(0, 4) : [];
      bilibiliStatus = message.bilibili_status || 'idle'; bilibiliResponseApi = message.bilibili_response_api === true;
      changed();
    });
    networkPort.onDisconnect.addListener(() => { if (connection === networkPort) { network = []; bilibiliData = []; bilibiliViews = []; bilibiliInitial = null; changed(); } });
    networkContext();
  };
  // Both clients put the access token and selected media version on their video URL.
  // HLS players expose a Blob; resource timing still identifies that manifest without
  // reading account storage or intercepting the site's fetch implementation.
  const serverState = new WeakMap();
  let gestureAt = -Infinity;
  let serverResource = null;
  const serverSource = (value) => {
    if (!/\/videos\/[^/]+\/(?:stream|original|master|main)/i.test(value)) return null;
    try {
      const url = new URL(value, location.href), page = new URL(location.href);
      // Emby resumes with a media fragment start (#t=seconds) on the original timeline.
      if (/^#t=[0-9.]{1,16}$/.test(url.hash)) url.hash = '';
      const params = new Map([...url.searchParams].map(([k, v]) => [k.toLowerCase(), v]));
      if (url.origin !== page.origin || url.username || url.password || url.hash ||
          !/^.*\/videos\/[a-z0-9-]{1,64}\/(?:(?:stream|original)(?:\.[a-z0-9]+)?|(?:master|main)\.m3u8)$/i.test(url.pathname) ||
          !(params.get('api_key') || params.get('apikey')) || !params.get('mediasourceid') || params.get('livestreamid')) return null;
      return { source: url.href, key: url.pathname.replace(/[^/]+$/, '') + params.get('mediasourceid'),
        // HLS and CopyTimestamps retain the original timeline. Only a progressive
        // transcode starts a fresh zero-based media timeline at StartTimeTicks.
        offset: /\.m3u8$|\/original(?:\.[a-z0-9]+)?$/i.test(url.pathname) || params.get('static')?.toLowerCase() === 'true' || params.get('copytimestamps')?.toLowerCase() === 'true'
          ? 0 : Math.max(0, Number(params.get('starttimeticks') || 0) / 1e7) };
    } catch (_) { return null; }
  };
  addEventListener('pointerdown', (event) => { if (event.isTrusted) gestureAt = performance.now(); }, true);
  if (typeof PerformanceObserver !== 'undefined') {
    const resources = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const source = serverSource(entry.name);
        if (source && entry.startTime >= gestureAt && performance.now() - gestureAt < 30000) {
          serverResource = { ...source, at: entry.startTime }; changed();
        }
      }
    });
    resources.observe({ type: 'resource', buffered: false });
  }
  const fullscreen = (element) => {
    const root = document.fullscreenElement;
    return !!root && (root === element || !!root.contains?.(element));
  };
  const send = () => {
    scheduled = false;
    if (closed) return;
    if (networkPage !== location.href) {
      if (pauseLease?.page !== location.href) pauseLease = null;
      networkPage = location.href; network = [];
      bilibiliData = []; bilibiliInitial = null;
      networkContext(true);
    }
    if (bilibiliEnabled && typeof Thru3DBilibili !== 'undefined' &&
        (bilibiliInitialPage !== location.href || (!bilibiliInitial || !bilibiliInitial.data && !bilibiliData.length || bilibiliInitial.identity.pgc) && Date.now() - bilibiliScanAt >= 1000)) {
      bilibiliInitialPage = location.href; bilibiliScanAt = Date.now();
      bilibiliInitial = Thru3DBilibili.initial(document, location.href);
    }
    const items = [];
    const live = [...videos.keys()].filter(v => v.isConnected && !v.ended && (v.currentSrc || v.readyState > 0));
    for (const [video, id] of videos) {
      if (!video.isConnected) { videos.delete(video); continue; }
      if (items.length >= 16) break;
      const protectedMedia = encrypted.has(video) || !!video.mediaKeys;
      const owner = video.closest?.("dl8-video");
      const server = serverState.get(video);
      const direct = serverSource(video.currentSrc || '');
      const resource = direct || ((video.currentSrc || '').startsWith('blob:') && serverResource && server && serverResource.at >= server.started ? serverResource : null);
      if (server && resource && server.key !== resource.key) {
        server.key = resource.key; videos.set(video, ++nextId);
      }
      // Wait for the start position (resume fragment or seek) to settle before handing it off.
      const serverPlay = !!server?.intent && !!resource && !protectedMedia && video.readyState >= 2 && !video.seeking;
      if (serverPlay) server.offset = Number.isFinite(resource.offset) ? resource.offset : 0;
      const epoch = mediaEpoch.get(video);
      const currentSource = video.currentSrc || '';
      const retained = bilibiliOwner?.video === video && bilibiliOwner.page === location.href &&
        bilibiliOwner.source === currentSource && bilibiliOwner.epoch === epoch.id ? bilibiliOwner : null;
      let biliIdentity = typeof Thru3DBilibili !== 'undefined' && Thru3DBilibili.viewIdentity(bilibiliViews, location.href) || bilibiliInitial?.identity || retained?.data;
      // Requests for previews/other parts must not discard the current part's inline
      // response or an already validated response evicted from the bounded API list.
      const bili = bilibiliData.find(d => biliIdentity?.pgc
        ? d.ep === biliIdentity.ep && (!biliIdentity.id.startsWith('ss') || biliIdentity.id === 'ss' + d.season) : d.cid === biliIdentity?.cid) ||
        bilibiliInitial?.data || (retained?.data && biliIdentity && retained.data.id === biliIdentity.id &&
          (biliIdentity?.pgc ? retained.data.ep === biliIdentity.ep : retained.cid === biliIdentity?.cid) ? retained.data : null);
      if (biliIdentity?.pgc && bili?.whole && bili.ep === biliIdentity.ep)
        biliIdentity = {...biliIdentity, cid: bili.cid, aid: bili.aid, expected_duration: bili.duration};
      const biliCid = biliIdentity?.cid;
      const sameVideo = biliIdentity?.pgc || bili?.id === biliIdentity?.id || bili?.id === 'av' + biliIdentity?.aid;
      // Scrolling/hover previews leave additional <video> elements in the page. Bind
      // the full current part, not the number or CSS visibility of those elements.
      // An already verified owner survives reparenting, but never a new source/epoch/CID.
      const matching = !bilibiliEnabled || !bili ? [] : live.filter(v => !encrypted.has(v) && !v.mediaKeys &&
        Math.abs(bili.duration - v.duration) <= Math.max(2, bili.duration * .01));
      const remembered = matching.find(v => bilibiliOwner?.video === v && bilibiliOwner.page === location.href &&
        bilibiliOwner.cid === biliCid && bilibiliOwner.source === v.currentSrc && bilibiliOwner.epoch === mediaEpoch.get(v)?.id);
      const primary = remembered || (matching.length === 1 ? matching[0] : null);
      // Generic MSE capture still requires a single player. Only the bound Bilibili
      // owner may use its current-part observations in a page with preview players.
      let requests = protectedMedia || !(networkEnabled || bilibiliEnabled) ? [] : network.filter(c => c.url === currentSource || c.original_url === currentSource ||
        currentSource.startsWith('blob:') && (bilibiliEnabled ? primary === video : live.length === 1 && c.at >= epoch.since));
      const biliBinding = !bilibiliEnabled ? 'off' : typeof Thru3DBilibili === 'undefined' ? 'adapter_unavailable' :
        !biliIdentity ? Thru3DBilibili.initialStatus() : protectedMedia ? 'protected' : matching.length > 1 && !primary ? 'multiple_players' :
        !bili ? 'response_cid_missing' : !sameVideo || bili.avid && bili.avid !== biliIdentity.aid ? 'video_id_mismatch' :
        !(biliIdentity.expected_duration > 0) ? 'full_duration_missing' :
        Math.abs(bili.duration - biliIdentity.expected_duration) > Math.max(2, bili.duration * .01) ? 'full_duration_mismatch' :
        primary !== video ? 'other_player' : 'matched';
      const biliMatched = bilibiliEnabled && !protectedMedia && primary === video && bili &&
        sameVideo && bili.cid === biliCid &&
        (!bili.avid || bili.avid === biliIdentity.aid) &&
        biliIdentity.expected_duration > 0 &&
        Math.abs(bili.duration - biliIdentity.expected_duration) <= Math.max(2, bili.duration * .01) &&
        Math.abs(bili.duration - video.duration) <= Math.max(2, video.duration * .01)
          ? { ...bili, ...biliIdentity } : null;
      if (biliMatched) {
        // Discovery is a rolling 24-item list, not the lifetime of a playing stream.
        // Retain only previously verified tracks for this exact owner/part/source;
        // preserve original timestamps and the same 30-minute observation limit.
        const urls = new Set([...biliMatched.video,...biliMatched.audio].flatMap(t => t.urls));
        const seen = new Set();
        requests = [...requests,...(retained?.cid === biliCid ? retained.requests || [] : [])].filter(c => {
          if (!urls.has(c.url) || seen.has(c.url) || (Number.isFinite(c.at) && Date.now() - c.at > 1800000)) return false;
          seen.add(c.url);return true;
        }).slice(0,24);
      }
      const biliReady = !!biliMatched && Thru3DBilibili.ready(biliMatched, requests, video.videoWidth, video.videoHeight);
      if (biliReady) bilibiliOwner = {video, page:location.href, cid:biliCid, source:currentSource, epoch:epoch.id,
        data:biliMatched,requests:requests.filter(c=>Number.isFinite(c.at))};
      items.push({ id: videos.get(video), width: video.videoWidth, height: video.videoHeight,
        fullscreen: fullscreen(video) || !!owner && fullscreen(owner),
        source: !protectedMedia ? (resource ? resource.source : /^https?:\/\//i.test(video.currentSrc || '') ? video.currentSrc : '') : '',
        server_play: serverPlay,
        protected: protectedMedia, frame: location.href, agent: navigator.userAgent,
        network: requests, network_epoch: epoch.id, blob: currentSource.startsWith('blob:'),
        bilibili: biliMatched,
        bilibili_ready: biliReady,
        bilibili_status: bilibiliStatus, bilibili_response_api: bilibiliResponseApi,
        bilibili_binding: biliBinding, bilibili_api_count: bilibiliData.length,
        bilibili_view_count: bilibiliViews.length,
        layout: owner?.getAttribute("format") || "",
        time: (Number.isFinite(video.currentTime) ? video.currentTime : 0) + (resource && Number.isFinite(resource.offset) ? resource.offset : 0),
        duration: Number.isFinite(video.duration) ? video.duration : 0,
        playing: !video.paused && !video.ended });
    }
    // A declarative VR player may keep its actual <video> in a closed shadow tree.
    // Read only the same public source the player declares; its media session still
    // acknowledges pause before the native handoff.
    if (!items.some(item => item.source || item.protected)) for (const player of document.querySelectorAll("dl8-video")) {
      if (items.length >= 16) break;
      const source = player.querySelector('source[type="video/mp4"], source[type="video/webm"]');
      if (!source || !/^https?:\/\//i.test(source.src || "")) continue;
      items.push({ id: "declared-" + items.length, width: 0, height: 0, source: source.src,
        fullscreen: fullscreen(player),
        protected: false, frame: location.href, agent: navigator.userAgent,
        layout: source.getAttribute("format") || player.getAttribute("format") || "",
        time: 0, duration: 0, playing: false });
    }
    const controlled = [...videos.keys()].filter(v => v.isConnected && (v.currentSrc || v.readyState > 0));
    try { port.postMessage({ type: "media", videos: items, pause_token: pauseLease?.token || 0,
      pause_has_media: controlled.length > 0, pause_held: !!pauseLease && controlled.every(v => v.paused || v.ended) }); }
    catch (_) { closed = true; }
  };
  const changed = () => {
    if (scheduled || closed) return;
    scheduled = true;
    setTimeout(send, 250);
  };
  const observe = (root) => {
    if (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11) return;
    const found = root.matches?.("video") ? [root] : [];
    found.push(...root.querySelectorAll("video"));
    let added = false;
    for (const video of found) {
      if (videos.has(video)) continue;
      added = true;
      videos.set(video, ++nextId);
      mediaEpoch.set(video, { id: nextId, since: Date.now() - 3000, loaded: !!video.currentSrc || video.readyState > 0 });
      serverState.set(video, { started: typeof performance !== 'undefined' ? performance.now() : 0, intent: false, key: '' });
      video.addEventListener('loadstart', () => {
        const epoch = mediaEpoch.get(video);
        if (epoch.loaded) { epoch.since = Date.now(); epoch.id = ++nextId; videos.set(video, nextId); }
        epoch.loaded = true;
        const state = serverState.get(video);
        state.started = gestureAt; state.intent = !suspended && performance.now() - gestureAt < 30000;
        state.key = ''; holdPaused(video); changed();
      });
      video.addEventListener('play', () => {
        const state = serverState.get(video);
        if (!suspended && !state.restoring) {
          if (state.key && !state.intent) videos.set(video, ++nextId);
          state.intent = true; changed();
        }
      });
      video.addEventListener('pause', () => { if (!suspended) { serverState.get(video).intent = false; changed(); } });
      video.addEventListener('ended', () => { serverState.get(video).intent = false; changed(); });
      video.addEventListener("encrypted", () => { encrypted.add(video); changed(); });
      for (const event of ["loadedmetadata", "resize", "durationchange", "play", "playing", "seeked", "pause", "emptied", "ended", "timeupdate"])
        video.addEventListener(event, changed);
      video.addEventListener("play", () => { if (suspended) video.pause(); else holdPaused(video); });
      holdPaused(video);
    }
    // Feeds and comments mutate constantly; only a new <video> changes the report.
    if (added) changed();
  };
  const mutation = new MutationObserver((records) => {
    for (const record of records) for (const node of record.addedNodes) observe(node);
  });
  mutation.observe(document, { childList: true, subtree: true });
  observe(document);
  // Web-component players (archive.org and others) keep <video> in a shadow root that neither
  // querySelectorAll nor the document observer reaches. Scanning every mutation for custom
  // elements would cost feed-heavy pages; scan after load and after each user press instead.
  const shadows = new WeakSet();
  const scanShadows = (root, depth = 0) => {
    if (closed || depth > 4) return;
    for (const element of root.querySelectorAll("*")) {
      if (!element.localName.includes("-")) continue;
      const shadow = element.openOrClosedShadowRoot || element.shadowRoot;
      if (!shadow) continue;
      if (!shadows.has(shadow)) {
        shadows.add(shadow);
        mutation.observe(shadow, { childList: true, subtree: true });
        observe(shadow);
      }
      scanShadows(shadow, depth + 1);
    }
  };
  for (const delay of [0, 2000, 5000, 10000]) setTimeout(() => scanShadows(document), delay);
  addEventListener("pointerdown", () => setTimeout(() => scanShadows(document), 1000), true);
  const connected = () => {
    closed = false;
    port = browser.runtime.connectNative("thru3d_video");
    const connection = port;
    port.onMessage.addListener((message) => {
    if (message?.action === "network_policy") {
      changed();
      const bili = message.bilibili === true;
      if (bili !== bilibiliEnabled) {
        bilibiliEnabled = bili; bilibiliData = []; bilibiliViews = []; network = []; bilibiliOwner = null;
        networkContext(true); changed();
      }
      const enabled = message.enabled === true;
      if (enabled !== networkEnabled) { networkEnabled = enabled; network = []; networkContext(true); changed(); }
      else networkContext();
    } else if (message?.action === "pause_media") {
      const token = message.token;
      if (!Number.isSafeInteger(token) || token <= lastPauseToken) return;
      lastPauseToken = token;
      // MediaSession.pause may have completed before this message arrives. Preserve
      // the native snapshot of this port's original playing IDs, not the new pause.
      const ids = Array.isArray(message.playing_ids) ? message.playing_ids.slice(0,16).map(String) : [];
      pauseLease = {token, page:location.href, videos:new Map(), playingIds:new Set(ids)};
      for (const video of videos.keys()) holdPaused(video);
      send();
    } else if (message?.action === "release_pause_media") {
      const saved = pauseLease;
      if (!saved || saved.token !== message.token) return;
      pauseLease = null;
      if (message.play === true && !suspended && saved.page === location.href) {
        for (const [video, old] of saved.videos) {
          if (!old.playing || !video.isConnected || video.currentSrc !== old.source || mediaEpoch.get(video)?.id !== old.epoch) continue;
          resuming.set(video, saved.token);
          const completed = () => { if (resuming.get(video) === saved.token) resuming.delete(video); changed(); };
          try { Promise.resolve(video.play()).then(completed, completed); } catch (_) { completed(); }
        }
      }
      send();
    } else if (message?.action === "suspend") {
      pauseLease = null;
      suspended = true;
      for (const video of videos.keys()) video.pause();
      send(); // A background page's timer may be throttled after Gecko becomes inactive.
    } else if (message?.action === "resume") {
      // Returning to the browser allows user-initiated playback; never auto-play it.
      suspended = false;
    } else if (message?.action === "capture_video" && Number.isSafeInteger(message.request) && message.request > 0) {
      const entry = [...videos].find(([, id]) => String(id) === message.id);
      const server = entry && serverState.get(entry[0]);
      handoff = entry && { video: entry[0], source: entry[0].currentSrc, request: message.request,
        serverKey: server?.key || '', offset: server?.offset || 0 };
    } else if (message?.action === "restore_video") {
      const saved = handoff;
      const restored = (retry = false) => {
        retry = retry && !!saved && saved.video.isConnected && saved.source === saved.video.currentSrc &&
          (!saved.serverKey || saved.serverKey === serverState.get(saved.video)?.key);
        try { port.postMessage({ type: "restore_video_result", request: message.request, retry }); } catch (_) {}
      };
      if (!saved || saved.request !== message.request || !saved.video.isConnected || saved.source !== saved.video.currentSrc ||
          saved.serverKey && saved.serverKey !== serverState.get(saved.video)?.key) { restored(); return; }
      handoff = null;
      suspended = false;
      const video = saved.video;
      // The restored page must not hand off again until the next deliberate play.
      const server = serverState.get(video);
      if (server) server.intent = false;
      if (Number.isFinite(message.time) && message.time >= 0) {
        const time = Math.max(0, message.time - saved.offset);
        try { video.currentTime = Number.isFinite(video.duration) ? Math.min(time, video.duration) : time; } catch (_) { /* Live media may not seek. */ }
      }
      if (message.play === true) {
        if (server) server.restoring = true;
        const complete = (retry = false) => { if (server) { server.intent = false; server.restoring = false; } send(); restored(retry); };
        try { Promise.resolve(video.play()).then(() => complete(), () => complete(true)); } catch (_) { complete(true); }
      } else { video.pause(); restored(); }
      send();
    } else if (message?.action === "snapshot") send();
    });
    port.onDisconnect.addListener(() => { if (port === connection) { closed = true; pauseLease = null; } });
    changed();
  };
  connected();
  connectNetwork();
  addEventListener("DOMContentLoaded", () => { bilibiliScanAt = 0; changed(); }, {once:true});
  addEventListener("fullscreenchange", () => { if (!closed) send(); }, true);
  addEventListener("pageshow", (event) => {
    if (event.persisted) { port.disconnect(); connected(); networkPort.disconnect(); connectNetwork(); }
  });
  addEventListener("pagehide", (event) => {
    network = []; networkPort.disconnect();
    if (!event.persisted) { handoff = null; mutation.disconnect(); videos.clear(); port.disconnect(); }
  });
})();
