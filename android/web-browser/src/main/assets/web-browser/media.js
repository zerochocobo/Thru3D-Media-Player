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
  let networkPort, network = [], networkPage = location.href;
  let networkEnabled = false;
  let bilibiliEnabled = false, bilibiliData = [], bilibiliRequested = [];
  let bilibiliStatus = 'idle', bilibiliResponseApi = false;
  let bilibiliInitial = null, bilibiliInitialPage = '', bilibiliScanAt = 0;
  const networkContext = (reset = false) => {
    try { networkPort?.postMessage({ type: "context", page: location.href, enabled: networkEnabled, bilibili: bilibiliEnabled, reset }); } catch (_) {}
  };
  const mediaEpoch = new WeakMap();
  const connectNetwork = () => {
    network = [];
    bilibiliData = []; bilibiliRequested = [];
    networkPort = browser.runtime.connect({ name: "thru3d_network" });
    const connection = networkPort;
    networkPort.onMessage.addListener(message => {
      if (connection !== networkPort || message?.type !== "network" || message.page !== location.href) return;
      network = Array.isArray(message.candidates) ? message.candidates.slice(0, 24) : [];
      bilibiliData = Array.isArray(message.bilibili) ? message.bilibili.slice(0, 4) : [];
      bilibiliRequested = Array.isArray(message.bilibili_requested) ? message.bilibili_requested.slice(0, 8) : [];
      bilibiliStatus = message.bilibili_status || 'idle'; bilibiliResponseApi = message.bilibili_response_api === true;
      changed();
    });
    networkPort.onDisconnect.addListener(() => { if (connection === networkPort) { network = []; bilibiliData = []; bilibiliInitial = null; changed(); } });
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
      networkPage = location.href; network = [];
      bilibiliData = []; bilibiliRequested = []; bilibiliInitial = null;
      networkContext(true);
    }
    if (bilibiliEnabled && typeof Thru3DBilibili !== 'undefined' &&
        (bilibiliInitialPage !== location.href || (!bilibiliInitial || bilibiliInitial.identity.pgc) && Date.now() - bilibiliScanAt >= 1000)) {
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
      // Exact URL matching works with several videos. Blob/MSE requests have no DOM id:
      // only associate them when this frame has one media element, within its load epoch.
      const requests = protectedMedia || !(networkEnabled || bilibiliEnabled) ? [] : network.filter(c => c.url === currentSource || c.original_url === currentSource ||
        currentSource.startsWith('blob:') && live.length === 1 && (c.at >= epoch.since || bilibiliEnabled));
      let biliIdentity = bilibiliInitial?.identity;
      const bili = bilibiliRequested.length ? bilibiliData.find(d => biliIdentity?.pgc
        ? d.ep === biliIdentity.ep && (!biliIdentity.id.startsWith('ss') || biliIdentity.id === 'ss' + d.season) : d.cid === biliIdentity?.cid) : bilibiliInitial?.data;
      if (biliIdentity?.pgc && bili?.whole && bili.ep === biliIdentity.ep)
        biliIdentity = {...biliIdentity, cid: bili.cid, aid: bili.aid, expected_duration: bili.duration};
      const biliCid = biliIdentity?.cid;
      const biliBinding = !bilibiliEnabled ? 'off' : typeof Thru3DBilibili === 'undefined' ? 'adapter_unavailable' :
        !bilibiliInitial ? Thru3DBilibili.initialStatus() : protectedMedia ? 'protected' : live.length !== 1 ? 'multiple_players' :
        !bili ? 'response_cid_missing' : (!biliIdentity.pgc && bili.id !== biliIdentity.id) || bili.avid && bili.avid !== biliIdentity.aid ? 'video_id_mismatch' :
        !(biliIdentity.expected_duration > 0) ? 'full_duration_missing' :
        Math.abs(bili.duration - biliIdentity.expected_duration) > Math.max(2, bili.duration * .01) ? 'full_duration_mismatch' :
        Math.abs(bili.duration - video.duration) > Math.max(2, video.duration * .01) ? 'player_duration_mismatch' : 'matched';
      const biliMatched = bilibiliEnabled && !protectedMedia && live.length === 1 && bili &&
        (biliIdentity?.pgc || bili.id === biliIdentity?.id) && bili.cid === biliCid &&
        (!bili.avid || bili.avid === biliIdentity.aid) &&
        biliIdentity.expected_duration > 0 &&
        Math.abs(bili.duration - biliIdentity.expected_duration) <= Math.max(2, bili.duration * .01) &&
        Math.abs(bili.duration - video.duration) <= Math.max(2, video.duration * .01)
          ? { ...bili, ...biliIdentity } : null;
      items.push({ id: videos.get(video), width: video.videoWidth, height: video.videoHeight,
        fullscreen: fullscreen(video) || !!owner && fullscreen(owner),
        source: !protectedMedia ? (resource ? resource.source : /^https?:\/\//i.test(video.currentSrc || '') ? video.currentSrc : '') : '',
        server_play: serverPlay,
        protected: protectedMedia, frame: location.href, agent: navigator.userAgent,
        network: requests, network_epoch: epoch.id, blob: currentSource.startsWith('blob:'),
        bilibili: biliMatched,
        bilibili_status: bilibiliStatus, bilibili_response_api: bilibiliResponseApi,
        bilibili_binding: biliBinding, bilibili_api_count: bilibiliData.length,
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
    try { port.postMessage({ type: "media", videos: items }); }
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
        state.key = ''; changed();
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
      for (const event of ["loadedmetadata", "durationchange", "play", "playing", "seeked", "pause", "emptied", "ended", "timeupdate"])
        video.addEventListener(event, changed);
      video.addEventListener("play", () => { if (suspended) video.pause(); });
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
        bilibiliEnabled = bili; bilibiliData = []; bilibiliRequested = []; network = [];
        networkContext(true); changed();
      }
      const enabled = message.enabled === true;
      if (enabled !== networkEnabled) { networkEnabled = enabled; network = []; networkContext(true); changed(); }
      else networkContext();
    } else if (message?.action === "pause_media") {
      // Native handoff pauses this document, without deactivating its peers or
      // preventing the user from operating the page afterwards.
      for (const video of videos.keys()) video.pause();
      send();
    } else if (message?.action === "suspend") {
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
    port.onDisconnect.addListener(() => { if (port === connection) closed = true; });
    changed();
  };
  connected();
  connectNetwork();
  addEventListener("fullscreenchange", () => { if (!closed) send(); }, true);
  addEventListener("pageshow", (event) => {
    if (event.persisted) { port.disconnect(); connected(); networkPort.disconnect(); connectNetwork(); }
  });
  addEventListener("pagehide", (event) => {
    network = []; networkPort.disconnect();
    if (!event.persisted) { handoff = null; mutation.disconnect(); videos.clear(); port.disconnect(); }
  });
})();
