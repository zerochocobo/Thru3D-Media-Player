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
  const fullscreen = (element) => {
    const root = document.fullscreenElement;
    return !!root && (root === element || !!root.contains?.(element));
  };
  const send = () => {
    scheduled = false;
    if (closed) return;
    const items = [];
    for (const [video, id] of videos) {
      if (!video.isConnected) { videos.delete(video); continue; }
      if (items.length >= 16) break;
      const protectedMedia = encrypted.has(video) || !!video.mediaKeys;
      const owner = video.closest?.("dl8-video");
      items.push({ id, width: video.videoWidth, height: video.videoHeight,
        fullscreen: fullscreen(video) || !!owner && fullscreen(owner),
        source: !protectedMedia && /^https?:\/\//i.test(video.currentSrc || "") ? video.currentSrc : "",
        protected: protectedMedia, frame: location.href, agent: navigator.userAgent,
        layout: owner?.getAttribute("format") || "",
        time: Number.isFinite(video.currentTime) ? video.currentTime : 0,
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
      video.addEventListener("encrypted", () => { encrypted.add(video); changed(); });
      for (const event of ["loadedmetadata", "durationchange", "play", "pause", "emptied", "ended", "timeupdate"])
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
    if (message?.action === "suspend") {
      suspended = true;
      for (const video of videos.keys()) video.pause();
      send(); // A background page's timer may be throttled after Gecko becomes inactive.
    } else if (message?.action === "resume") {
      // Returning to the browser allows user-initiated playback; never auto-play it.
      suspended = false;
    } else if (message?.action === "capture_video" && Number.isSafeInteger(message.request) && message.request > 0) {
      const entry = [...videos].find(([, id]) => String(id) === message.id);
      handoff = entry && { video: entry[0], source: entry[0].currentSrc, request: message.request };
    } else if (message?.action === "restore_video") {
      const saved = handoff;
      const restored = (retry = false) => {
        retry = retry && !!saved && saved.video.isConnected && saved.source === saved.video.currentSrc;
        try { port.postMessage({ type: "restore_video_result", request: message.request, retry }); } catch (_) {}
      };
      if (!saved || saved.request !== message.request || !saved.video.isConnected || saved.source !== saved.video.currentSrc) { restored(); return; }
      handoff = null;
      suspended = false;
      const video = saved.video;
      if (Number.isFinite(message.time) && message.time >= 0) {
        try { video.currentTime = Number.isFinite(video.duration) ? Math.min(message.time, video.duration) : message.time; } catch (_) { /* Live media may not seek. */ }
      }
      if (message.play === true) {
        try { Promise.resolve(video.play()).then(() => restored(), () => restored(true)); } catch (_) { restored(true); }
      } else { video.pause(); restored(); }
      send();
    } else if (message?.action === "snapshot") send();
    });
    port.onDisconnect.addListener(() => { if (port === connection) closed = true; });
    changed();
  };
  connected();
  addEventListener("fullscreenchange", () => { if (!closed) send(); }, true);
  addEventListener("pageshow", (event) => {
    if (event.persisted) { port.disconnect(); connected(); }
  });
  addEventListener("pagehide", (event) => {
    if (!event.persisted) { handoff = null; mutation.disconnect(); videos.clear(); port.disconnect(); }
  });
})();
