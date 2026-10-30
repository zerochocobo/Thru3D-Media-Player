/* Small, data-only adapter. Reference: yt-dlp bilibili.py extract_formats at
 * 34ea29166e37d6f16849217982d0429aafc463e8. No Python framework or signing code. */
const Thru3DBilibili = (() => {
  "use strict";
  const page = value => {
    try {
      const u = new URL(value), pgc = /^\/bangumi\/play\/((?:ep|ss)[1-9][0-9]{0,19})\/?$/.exec(u.pathname)?.[1];
      const id = pgc || /^\/video\/(BV[A-Za-z0-9]+|av[0-9]+)\/?$/.exec(u.pathname)?.[1];
      const part = Number(u.searchParams.get('p') || 1);
      if (u.protocol !== 'https:' || u.hostname !== 'www.bilibili.com' || u.port || u.username || u.password ||
          !id || !Number.isSafeInteger(part) || part < 1 || part > 10000) return null;
      return { id, part: pgc ? 1 : part, ...(pgc ? { pgc: true } : {}) };
    } catch (_) { return null; }
  };
  const sameDocumentPage = (a, b) => {
    const x = page(a), y = page(b);
    return !!x && !!y && (x.id === y.id || x.pgc === true && y.pgc === true);
  };
  const mediaCid = value => {
    try {
      const u = new URL(value);
      // New representations use a decorated filename; the canonical directory still
      // identifies the full UGC part. Do not mistake those files for loose DASH segments.
      const directory = /^\/(?:v1\/resource\/)?upgcxcode\/\d{1,3}\/\d{1,3}\/([1-9][0-9]{0,19})\/[A-Za-z0-9_-]{1,160}\.m4s$/.exec(u.pathname)?.[1];
      const filename = /\/([1-9][0-9]{0,19})-[^/]+\.m4s$/.exec(u.pathname)?.[1];
      if (directory && filename && directory !== filename) return null;
      return directory || filename || null;
    } catch (_) { return null; }
  };
  // Called only for addresses declared by a bound Bilibili playurl response/SSR.
  // CDN domains and HTTPS ports are not a second trust registry. Native selection
  // requires this exact URL to have been requested by the same browser document.
  const address = (value, cid) => {
    try {
      const u = new URL(value);
      return typeof value === 'string' && value.length <= 8192 && u.protocol === 'https:' &&
        (!u.port || Number(u.port) >= 1) && !u.username && !u.password && !u.hash &&
        (!mediaCid(value) || mediaCid(value) === cid) ? value : null;
    } catch (_) { return null; }
  };
  const normalize = (raw, identity) => {
    try {
      if (!identity || !/^[1-9][0-9]{0,19}$/.test(String(identity.cid)) || !page(identity.page) || raw.code !== 0) return null;
      const d = raw.data;
      if (!d || d.is_preview || d.is_trial || d.has_drm || d.is_drm || d.drm_tech_type || !d.dash ||
          [125, 126].includes(d.quality) || !Number.isInteger(d.quality)) return null;
      const duration = Number(d.timelength) / 1000;
      if (!Number.isFinite(duration) || duration <= 0 || duration > 86400 || !Array.isArray(d.dash.video) ||
          !Array.isArray(d.dash.audio) || d.dash.video.length > 64 || d.dash.audio.length > 32) return null;
      const track = (t, video) => {
        // API quality is the requested/default tier; the web player's ABR can use another
        // offered SDR representation. Selection still requires an actually observed URL.
        if (!t || !Number.isInteger(t.id) || (video && [125, 126].includes(t.id))) return null;
        const urls = [t.baseUrl || t.base_url, ...(t.backupUrl || t.backup_url || []).slice(0, 8)]
          .map(u => address(u, identity.cid)).filter(Boolean);
        const codec = t.codecs;
        if (!urls.length || typeof codec !== 'string' || codec.length > 100 ||
            !(video ? /^(avc1|hev1|hvc1|av01)\./ : /^mp4a\./).test(codec)) return null;
        const rate = String(t.frameRate || t.frame_rate || '0').split('/').map(Number);
        const fps = rate.length === 2 ? rate[0] / rate[1] : rate[0];
        if (video && (!Number.isInteger(t.width) || !Number.isInteger(t.height) || t.width < 1 || t.height < 1 ||
            t.width > 8192 || t.height > 8192 || !Number.isFinite(fps) || fps <= 0 || fps > 240)) return null;
        return { id: t.id, urls, codec, width: video ? t.width : 0, height: video ? t.height : 0, fps: video ? fps : 0 };
      };
      const video = d.dash.video.map(t => track(t, true)).filter(Boolean);
      const audio = d.dash.audio.map(t => track(t, false)).filter(Boolean);
      if (!video.length || !audio.length) return null;
      const result = { ...identity, quality: d.quality, duration, video, audio };
      return JSON.stringify(result).length <= 96 * 1024 ? result : null;
    } catch (_) { return null; }
  };
  // PGC v2 uses a distinct envelope and explicit whole/preview status. Never infer
  // entitlement from a long duration: some previews report the full episode length.
  const normalizePgc = (raw, identity) => {
    try {
      const p = page(identity.page); if (!p?.pgc) return null;
      const envelope = raw?.data?.code !== undefined ? raw.data : raw;
      if (envelope?.code !== 0) return null;
      const d = envelope.result || envelope.data;
      // The observed /ogv/player/playview response declares whole/preview but omits
      // play_check. Only that exact endpoint may omit it; contradictory checks fail.
      if (!d || d.play_video_type !== 'whole' ||
          (d.play_check ? d.play_check.play_detail !== 'PLAY_WHOLE' : identity.api !== 'ogv_playview')) return null;
      const ep = String(d.supplement?.ogv_episode_info?.episode_id || '');
      const season = String(d.supplement?.ogv_season_info?.season_id || '');
      const cid = String(d.arc?.cid || ''), aid = String(d.arc?.aid || '');
      if (![ep, season, cid, aid].every(x => /^[1-9][0-9]{0,19}$/.test(x)) ||
          (p.id.startsWith('ep') ? p.id !== 'ep' + ep : p.id !== 'ss' + season) ||
          identity.ep && identity.ep !== ep || identity.cid && identity.cid !== cid) return null;
      const info = d.video_info;
      return normalize({code: 0, data: info}, {page: identity.page, id: p.id, part: 1,
        cid, aid, ep, season, pgc: true, whole: true, expected_duration: Number(info?.timelength) / 1000});
    } catch (_) { return null; }
  };
  const episode = (document, value) => {
    const p = page(value); if (!p?.pgc) return null;
    if (p.id.startsWith('ep')) return p.id.slice(2);
    const canonical = page(document.querySelector?.('link[rel="canonical"]')?.href || '');
    return canonical?.id.startsWith('ep') ? canonical.id.slice(2) : null;
  };
  // Parse an inline JSON assignment as data; never evaluate site script or getters.
  const assignment = (document, name) => {
    let count = 0, size = 0;
    for (const script of document.querySelectorAll('script:not([src])')) {
      const text = script.textContent || '';
      if (++count > 128 || (size += text.length) > 4 * 1024 * 1024) return null;
      if (text.length > 2 * 1024 * 1024) continue;
      const marker = new RegExp('(?:^|[;\\s])(?:window\\.|(?:const|let|var)\\s+)' + name + '\\s*=\\s*').exec(text);
      if (!marker) continue;
      const start = marker.index + marker[0].length;
      if (text[start] !== '{') continue;
      let depth = 0, quoted = false, escaped = false;
      for (let i = start; i < text.length; i++) {
        const c = text[i];
        if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
        else if (c === '"') quoted = true;
        else if (c === '{') depth++;
        else if (c === '}' && --depth === 0) {
          try { return JSON.parse(text.slice(start, i + 1)); } catch (_) { return null; }
        }
      }
    }
    return null;
  };
  let savedState = null, savedPlayinfo = null, savedPgc = null;
  const remember = scripts => {
    const source = { querySelectorAll: () => scripts };
    const state = assignment(source, '__INITIAL_STATE__'), v = state?.videoData;
    if (v && Array.isArray(v.pages) && v.pages.length <= 10000) {
      // Do not retain the account/recommendation data accompanying the public part map.
      const reduced = { cid: state.cid, videoData: { bvid: v.bvid, aid: v.aid, cid: v.cid,
        pages: v.pages.map(p => ({ page: p.page, cid: p.cid, duration: p.duration })) } };
      if (JSON.stringify(reduced).length <= 256 * 1024) savedState = reduced;
    }
    if (typeof location !== 'undefined' && page(location.href)?.pgc)
      savedPgc = normalizePgc(assignment(source, 'playurlSSRData'), {page: location.href}) || savedPgc;
    const play = assignment(source, '__playinfo__');
    if (play && JSON.stringify(play).length <= 1024 * 1024) savedPlayinfo = play;
  };
  // The site's SSR state script removes itself synchronously after execution. A mutation
  // record retains that detached SCRIPT node; reading its text needs no page-world bridge.
  if (typeof document !== 'undefined' && typeof location !== 'undefined' && page(location.href)) {
    const observer = new MutationObserver(records => {
      const scripts = [];
      for (const record of records) {
        if (record.target?.nodeName === 'SCRIPT' && !record.target.src) scripts.push(record.target);
        for (const node of [...record.addedNodes, ...record.removedNodes])
          if (node.nodeName === 'SCRIPT' && !node.src) scripts.push(node);
        if (scripts.length >= 128) break;
      }
      if (scripts.length) remember([...new Set(scripts)].slice(0, 128));
    });
    observer.observe(document, { childList: true, subtree: true });
    addEventListener('DOMContentLoaded', () => {
      remember(document.querySelectorAll('script:not([src])')); observer.disconnect();
    }, { once: true });
    addEventListener('pagehide', event => { if (!event.persisted) { observer.disconnect(); savedState = null; savedPlayinfo = null; savedPgc = null; } }, { once: true });
  }
  let initialStatus = 'not_read';
  const initial = (document, value) => {
    initialStatus = 'unsupported_page';
    const p = page(value); if (!p) return null;
    if (p.pgc) {
      const ep = episode(document, value);
      initialStatus = ep ? 'mapped' : 'episode_missing';
      if (!ep) return null;
      const data = normalizePgc(assignment(document, 'playurlSSRData'), {page: value, ep}) ||
        (savedPgc?.ep === ep && savedPgc.id === p.id ? savedPgc : null);
      return { identity: {page: value, id: p.id, part: 1, pgc: true, ep}, data };
    }
    const state = assignment(document, '__INITIAL_STATE__') || savedState, v = state?.videoData;
    initialStatus = !state ? 'initial_json_missing' : !v ? 'video_data_missing' : 'page_map_mismatch';
    if (!v || ![v.bvid, 'av' + v.aid].includes(p.id) || !Array.isArray(v.pages)) return null;
    const part = v.pages.find(part => part.page === p.part);
    const cid = String(part?.cid || '');
    initialStatus = 'part_missing';
    if (!/^[1-9][0-9]{0,19}$/.test(cid)) return null;
    const identity = { page: value, id: p.id, aid: String(v.aid || ''), part: p.part, cid, expected_duration: Number(part.duration) };
    // Inline playinfo belongs only to the original part; keep its CID binding immutable.
    const loadedCid = String(state.cid || v.cid || '');
    const data = loadedCid === cid ? normalize(assignment(document, '__playinfo__') || savedPlayinfo || {}, identity) : null;
    initialStatus = 'mapped';
    return { identity, data };
  };
  return { page, sameDocumentPage, mediaCid, address, normalize, normalizePgc, episode, initial, initialStatus: () => initialStatus };
})();
