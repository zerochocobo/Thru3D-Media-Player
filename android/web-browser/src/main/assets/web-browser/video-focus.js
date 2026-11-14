/* Where this frame shows its videos, for the browser's "focus video". Geometry only, on request. */
const Thru3DVideoFocus = (() => {
  'use strict';
  const LIMIT = 16;
  const clip = (a, b) => {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const right = Math.min(a.x + a.width, b.x + b.width), bottom = Math.min(a.y + a.height, b.y + b.height);
    return right > x && bottom > y ? { x, y, width: right - x, height: bottom - y } : null;
  };
  // The picture inside the element box after object-fit; letterbox bars inside the player are not video.
  const picture = (box, width, height, fit) => {
    if (!(width > 0 && height > 0) || fit === 'fill' || fit === 'cover') return box;
    let scale = Math.min(box.width / width, box.height / height);
    if (fit === 'none') scale = 1; else if (fit === 'scale-down') scale = Math.min(scale, 1);
    const w = width * scale, h = height * scale;
    return clip({ x: box.x + (box.width - w) / 2, y: box.y + (box.height - h) / 2, width: w, height: h }, box);
  };
  const rect = r => [r.x, r.y, r.width, r.height];
  // Players that are not showing a picture yet. Used only when no frame reports a visible video:
  // a video the page keeps transparent until its first frame, and an embedded player that
  // creates its video on play (players allow fullscreen or use an embed/player address; ad frames rarely do).
  const EMBED = /embed|player/i;
  const fallbacks = (win, top, hidden, view) => {
    const found = hidden.map(box => clip(box, view)).filter(Boolean).map(box => ({ rect: rect(box), kind: 'video' }));
    // An embedded player reports itself too, for when the frame around it has no content script.
    let own = '';
    try { own = win.location.pathname + ' ' + win.location.hostname; } catch (_) {}
    if (!top && EMBED.test(own)) found.push({ rect: rect(view), kind: 'player' });
    let frames = [];
    try { frames = win.document.querySelectorAll('iframe[allowfullscreen], iframe[allow*="fullscreen"], iframe[src*="embed" i], iframe[src*="player" i]'); } catch (_) {}
    for (const frame of frames) {
      if (found.length >= LIMIT) break;
      try {
        if (frame.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) === false) continue;
        const visible = clip(frame.getBoundingClientRect(), view);
        if (visible) found.push({ rect: rect(visible), kind: 'embed' });
      } catch (_) {}
    }
    return found;
  };
  const locate = (win, videos) => {
    const vv = win.visualViewport;
    const view = vv ? { x: vv.offsetLeft, y: vv.offsetTop, width: vv.width, height: vv.height } :
      { x: 0, y: 0, width: win.innerWidth, height: win.innerHeight };
    let top = false;
    try { top = win.top === win; } catch (_) {}
    const found = [], hidden = [];
    for (const video of videos) {
      if (found.length >= LIMIT) break;
      try {
        if (!video.isConnected) continue;
        const box = video.getBoundingClientRect();
        const shown = picture(box, video.videoWidth, video.videoHeight, win.getComputedStyle?.(video)?.objectFit || 'contain');
        if (video.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) === false) {
          if (shown && hidden.length < LIMIT) hidden.push(shown);
          continue;
        }
        const visible = shown && clip(shown, view);
        if (visible) found.push({ rect: rect(visible), playing: !video.paused && !video.ended && video.readyState > 2 });
      } catch (_) {}
    }
    // Gecko's screen origin of this frame's content; an iframe's offset in the top page is the difference.
    return { top, screen: [Number(win.mozInnerScreenX) || 0, Number(win.mozInnerScreenY) || 0],
      view: [view.x, view.y, view.width, view.height], videos: found,
      fallback: found.length ? [] : fallbacks(win, top, hidden, view) };
  };
  return { locate, picture };
})();
